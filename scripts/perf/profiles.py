"""Recorders and analysis for scripts/perf/perf.py: CPU stacks (xctrace or sample), signposts (log stream), heap
snapshots (MallocStackLogging tools), then one data model for the report, a flat summary and the regression gate."""
import fnmatch, json, os, pathlib, re, shutil, signal, subprocess, threading, time, xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from datetime import datetime

BUCKET = 0.1          # seconds: stacks are aggregated per bucket × thread × stack
WAITS = re.compile(r"^(mach_msg2?_trap|mach_msg_overwrite|__psynch_cvwait|__psynch_mutexwait|__workq_kernreturn|kevent\w*|__semwait_signal|"
                   r"__ulock_wait2?|poll|__select|read|__recvfrom|semaphore_wait_trap|semaphore_timedwait_trap|__sigsuspend_nocancel|"
                   r"__wait4|_pthread_wqthread|start_wqthread|thread_start|__open_nocancel)$")


def run(cmd, timeout, **kw):
    try: return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, **kw)
    except subprocess.TimeoutExpired: return None


# ───────────── Signposts ─────────────
class SignpostStream:
    """`log stream --signpost` for the app's subsystem: begin/end pairs become intervals, events stay points."""
    def __init__(self, path, subsystem):
        self.path = path
        self.f = open(path, "w")
        self.p = subprocess.Popen(["log", "stream", "--signpost", "--style", "ndjson", "--level", "info", "--predicate", f'subsystem == "{subsystem}"'],
                                  stdout=self.f, stderr=subprocess.DEVNULL)
        time.sleep(1.0)   # the stream attaches before the app starts emitting

    def stop(self):
        time.sleep(1.0)   # the last end events are still in flight
        self.p.terminate()
        try: self.p.wait(5)
        except subprocess.TimeoutExpired: self.p.kill()
        self.f.close()

    def intervals(self, t0):
        opened, out, events = {}, [], []
        for line in pathlib.Path(self.path).read_text(errors="replace").splitlines():
            try: e = json.loads(line)
            except json.JSONDecodeError: continue
            kind, name = e.get("signpostType"), e.get("signpostName")
            if not kind or not name: continue
            t = parse_ts(e["timestamp"]) - t0
            key = (e.get("processID"), e.get("signpostID"), name)
            msg = e.get("eventMessage") or ""
            if kind == "begin": opened[key] = (t, msg)
            elif kind == "end" and key in opened:
                b, m = opened.pop(key)
                out.append({"name": name, "t": round(b, 4), "ms": round((t - b) * 1000, 3), "detail": m[:120]})
            elif kind == "event": events.append({"name": name, "t": round(t, 4), "detail": msg[:200]})
        return {"intervals": out, "events": events}


def parse_ts(s):   # "2026-10-21 21:10:00.123456+1100"
    return datetime.strptime(s, "%Y-%m-%d %H:%M:%S.%f%z").timestamp()


# ───────────── CPU stacks ─────────────
class Stacks:
    """Interned stacks aggregated per (bucket, process kind, thread, stack): small enough to embed in the report."""
    def __init__(self):
        self.ids, self.table, self.agg, self.bins = {}, [], Counter(), {}

    def add(self, t, kind, thread, frames, ms):
        sid = self.ids.get(frames)
        if sid is None: sid = self.ids[frames] = len(self.table); self.table.append(list(frames))
        self.agg[(round(int(t / BUCKET) * BUCKET, 2), kind, thread, sid)] += ms

    def data(self):
        return {"bucket": BUCKET, "stacks": self.table, "bins": self.bins, "samples": [[t, k, th, s, round(ms, 2)] for (t, k, th, s), ms in self.agg.items()]}

    def symbolicate(self, pid):
        """Frames a system-wide recording could not name (WebContent's, in the shared cache) get their names from atos run
        against our own process: the shared cache sits at the same address in every process of this boot."""
        addrs = sorted({f for st in self.table for f in st if f.startswith("0x")})
        names = {}
        for i in range(0, len(addrs), 400):
            r = run(["atos", "-p", str(pid)] + addrs[i:i + 400], 120)
            for a, line in zip(addrs[i:i + 400], (r.stdout.splitlines() if r and r.returncode == 0 else [])):
                m = re.match(r"^(.*) \(in ([^)]+)\)", line)
                if m: names[a] = frame_label(m.group(1), m.group(2)); self.bins[names[a]] = m.group(2)
        for st in self.table:
            for j, f in enumerate(st):
                if f.startswith("0x"): st[j] = names.get(f, "??? (JIT or unknown)")
        return len(names), len(addrs)


def thread_label(fmt):
    name = re.sub(r"\s*\(0x[0-9a-f]+\)", "", fmt.split(" (", 1)[0] if "(" in fmt else fmt).strip()
    return "Main Thread" if name.lower().startswith("main thread") else (name if name and not name.startswith("Thread") else "worker threads")


def frame_label(name, binary, addr=None):
    name = (name or "").strip()
    if not name or name.startswith("0x"): name = addr if addr else f"??? ({binary or 'unknown'})"   # an address: atos may name it later
    return name[:180]


class Xctrace:
    """xctrace Time Profiler attached to one process; potential hangs come with it. Stopped with SIGINT."""
    mode = "xctrace"

    def __init__(self, pid, raw, t0, kind="app", timeout=40, system_wide=False):
        self.raw, self.t0, self.kind, self.note, self.extra, self.pid, self.system_wide = raw, t0, kind, "", [], pid, system_wide
        self.trace = raw / f"{kind}.trace"
        self.logf = open(raw / f"xctrace-{kind}.log", "w")
        target = ["--all-processes"] if system_wide else ["--attach", str(pid)]
        self.p = subprocess.Popen(["xcrun", "xctrace", "record", "--template", "Time Profiler"] + target + ["--output", str(self.trace),
                                   "--no-prompt", "--time-limit", "3600s"], stdout=self.logf, stderr=subprocess.STDOUT)
        start = time.time()
        while time.time() - start < timeout:   # a permission prompt or a stuck attach never holds the run
            txt = (raw / f"xctrace-{kind}.log").read_text(errors="replace")
            if "Ctrl-C to stop" in txt: time.sleep(1.5); return
            if self.p.poll() is not None: break
            time.sleep(0.2)
        self.kill(); raise RuntimeError("xctrace did not start: " + (raw / f"xctrace-{kind}.log").read_text(errors="replace")[-300:])

    def kill(self):
        if self.p.poll() is None: self.p.kill()

    def attach_extra(self, pid, kind):
        if self.system_wide: return   # already recorded
        try: self.extra.append(Xctrace(pid, self.raw, self.t0, kind))
        except RuntimeError as e: self.note += f" {kind}: {e}"

    def stop(self):
        if self.p.poll() is None:
            self.p.send_signal(signal.SIGINT)
            try: self.p.wait(180)
            except subprocess.TimeoutExpired: self.kill()
        self.logf.close()

    def finish(self, pidkind, stacks=None):
        stacks = stacks or Stacks()
        self.stop()
        hangs = []
        if self.trace.exists():
            toc = run(["xcrun", "xctrace", "export", "--input", str(self.trace), "--toc"], 120)
            m = re.search(r"<start-date>([^<]+)</start-date>", toc.stdout if toc else "")
            start = datetime.fromisoformat(m.group(1).replace("Z", "+00:00")).timestamp() - self.t0 if m else 0
            xml = self.raw / f"{self.kind}-time-profile.xml"
            r = run(["xcrun", "xctrace", "export", "--input", str(self.trace), "--output", str(xml), "--xpath",
                     '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'], 600)
            if r and r.returncode == 0 and xml.exists(): parse_time_profile(xml, start, self.kind, stacks, pidkind if self.system_wide else None)
            hx = run(["xcrun", "xctrace", "export", "--input", str(self.trace), "--xpath",
                      '/trace-toc/run[@number="1"]/data/table[@schema="potential-hangs"]'], 120)
            if hx and hx.returncode == 0: hangs = parse_hangs(hx.stdout, start, self.kind)
            xml.unlink(missing_ok=True)
            # An attached trace stays in raw/ for Instruments; a system-wide one also holds every other process's samples.
            if self.system_wide: shutil.rmtree(self.trace, ignore_errors=True)
        for x in self.extra:
            d = x.finish(pidkind, stacks); hangs += d["hangs"]
        if self.kind == "app":
            named, total = stacks.symbolicate(self.pid)
            if total: self.note += f" atos named {named}/{total} frames"
        return {"mode": self.mode + (" (all processes)" if self.system_wide else ""), "note": self.note.strip(), "stacks": stacks, "hangs": hangs}


def parse_time_profile(path, start, kind, stacks, pidkind=None):
    """time-profile rows (ids defined once, then referenced); with `pidkind` (a system-wide recording) only our processes."""
    vals = {}
    def val(el):
        ref = el.get("ref")
        if ref is not None: return vals.get(ref)
        tag = el.tag
        if tag in ("tagged-backtrace", "backtrace"):
            frames = []
            for f in el.iter("frame"):
                if f.get("ref") is not None: frames.append(vals.get(f.get("ref"), "?")); continue
                b = f.find("binary")
                bname = b.get("name") if b is not None and b.get("name") else (vals.get("bin:" + b.get("ref")) if b is not None else None)
                if b is not None and b.get("id"): vals["bin:" + b.get("id")] = b.get("name")
                label = frame_label(f.get("name"), bname, f.get("addr"))
                if bname and label not in stacks.bins: stacks.bins[label] = bname
                if f.get("id"): vals[f.get("id")] = label
                frames.append(label)
            v = tuple(reversed(frames))   # root first
        elif tag == "thread":
            v = thread_label(el.get("fmt", ""))
            pr = el.find("process")
            if pr is not None and pr.get("id") is not None: vals["pid:" + pr.get("id")] = (pr.findtext("pid") or "")
        elif tag == "process":
            v = el.findtext("pid") or ""
            if el.get("id") is not None: vals["pid:" + el.get("id")] = v
        elif tag in ("sample-time", "weight"): v = int(el.text or 0)
        else: v = el.get("fmt")
        if el.get("id") is not None: vals[el.get("id")] = v
        return v
    for ev, el in ET.iterparse(str(path), events=("end",)):
        if el.tag != "row": continue
        cols, k = {}, kind
        for c in el:
            if c.tag == "process": cols["pid"] = vals.get("pid:" + c.get("ref")) if c.get("ref") is not None else val(c)
            else: cols[c.tag] = val(c)
        if pidkind is not None:
            k = pidkind.get(int(cols.get("pid") or 0))
            if k is None: el.clear(); continue
        frames = cols.get("tagged-backtrace") or cols.get("backtrace")
        if frames: stacks.add(start + cols.get("sample-time", 0) / 1e9, k, cols.get("thread") or "?", frames, (cols.get("weight") or 1e6) / 1e6)
        el.clear()


def parse_hangs(xml_text, start, kind):
    out, vals = [], {}
    try: root = ET.fromstring(xml_text)
    except ET.ParseError: return out
    for row in root.iter("row"):
        cols = {}
        for c in row:
            if c.get("ref") is not None: cols[c.tag] = vals.get(c.get("ref")); continue
            v = (int(c.text or 0), c.get("fmt")) if c.tag in ("start-time", "duration") else c.get("fmt")
            if c.get("id") is not None: vals[c.get("id")] = v
            cols[c.tag] = v
        st, du = cols.get("start-time"), cols.get("duration")
        if st and du:
            out.append({"t": round(start + st[0] / 1e9, 3), "ms": round(du[0] / 1e6), "type": cols.get("hang-type") or "hang", "source": f"xctrace ({kind})"})
    return out


class Sampler:
    """`sample` in 2 s windows (a time axis for the heatmap); time blocked in a wait primitive is dropped (sample sees idle threads)."""
    mode = "sample"

    def __init__(self, pid, raw, t0, kind="app"):
        self.raw, self.t0, self.note, self.stop_flag, self.targets = raw, t0, "", threading.Event(), [(pid, kind)]
        self.files = []
        self.th = threading.Thread(target=self.loop, daemon=True); self.th.start()

    def attach_extra(self, pid, kind): self.targets.append((pid, kind))

    def loop(self):
        i = 0
        while not self.stop_flag.is_set():
            pid, kind = self.targets[-1] if len(self.targets) > 1 and alive(self.targets[-1][0]) else self.targets[0]
            f = self.raw / f"sample-{i:04d}.txt"
            t = time.time() - self.t0
            r = run(["sample", str(pid), "2", "1", "-mayDie", "-file", str(f)], 30)
            if r is None or r.returncode != 0 or not f.exists():
                if not alive(self.targets[0][0]): break
                self.note = "sample failed: " + ((r.stderr or "")[-200:] if r else "timeout"); time.sleep(1); continue
            self.files.append((t, kind, f)); i += 1

    def finish(self, pidkind, stacks=None):
        stacks = stacks or Stacks()
        self.stop_flag.set(); self.th.join(40)
        for t, kind, f in self.files: parse_sample(f.read_text(errors="replace"), t, kind, stacks)
        return {"mode": self.mode, "note": self.note, "stacks": stacks, "hangs": []}


def alive(pid):
    try: os.kill(pid, 0); return True
    except OSError: return False


SAMPLE_LINE = re.compile(r"^(\s*[+!:| ]*)(\d+) (.*)$")


def parse_sample(text, t, kind, stacks):
    """The call-graph section: a tree drawn with indentation; self samples (count − children) become folded stacks."""
    if "Call graph:" not in text: return
    body = text.split("Call graph:", 1)[1]
    path, thread = [], None   # [(depth, label, count, child_total)]
    def close(to_depth):
        while path and path[-1][0] >= to_depth:
            d, label, count, kids = path.pop()
            self_ms = count - kids
            leaf = label.split(" (", 1)[0]
            if self_ms > 0 and thread and not WAITS.match(leaf):
                stacks.add(t + 1.0, kind, thread, tuple(p[1] for p in path) + (label,), float(self_ms))
            if path: path[-1][3] += count
    for line in body.splitlines():
        if not line.strip(): continue
        if line.startswith(("Total number in stack", "Binary Images", "Sort by top")): break
        m = SAMPLE_LINE.match(line)
        if not m: continue
        depth, rest = len(m.group(1)), m.group(3)
        if rest.startswith("Thread_"):
            close(0)
            q = re.search(r"(?:DispatchQueue_\d+: )?([^ ]+(?: [^ (]+)*)\s*(?:\((?:serial|concurrent)\))?$", rest.split(None, 1)[1] if " " in rest else "")
            label = q.group(1) if q else rest
            thread = "Main Thread" if "com.apple.main-thread" in rest else ("worker threads" if not q or label.startswith("Thread_") else label.strip())
            continue
        close(depth)
        name = rest.split("  (in ", 1)
        binary = name[1].split(")", 1)[0] if len(name) > 1 else ""
        label = frame_label(name[0], binary)
        stacks.bins.setdefault(label, binary)
        path.append([depth, label, int(m.group(2)), 0])
    close(0)


def cpu_recorder(mode, pid, raw, t0, system_wide=False):
    if mode == "off": return None
    if mode in ("auto", "xctrace"):
        try: return Xctrace(pid, raw, t0, system_wide=system_wide)
        except RuntimeError as e:
            if mode == "xctrace": raise
            s = Sampler(pid, raw, t0); s.note = f"xctrace unavailable, fell back to sample ({str(e)[:160]})"; return s
    return Sampler(pid, raw, t0)


# ───────────── Heap (MallocStackLogging=lite) ─────────────
def heap_snapshot(pid, raw, name, leaks=False):
    """Live heap by type (heap), by allocating call stack (malloc_history -allBySize), VM regions (vmmap) and leaks."""
    snap = {"workload": name, "types": [], "stacks": [], "regions": [], "leaks": None, "footprint_mb": None}
    r = run(["heap", "-s", str(pid)], 180)
    if r and r.returncode == 0:
        (raw / f"heap-{name}.txt").write_text(r.stdout)
        for l in r.stdout.splitlines():
            m = re.match(r"^\s*(\d+)\s+(\d+)\s+([\d.]+)\s+(.+?)\s{2,}(\S.*?)\s{2,}(\S+)\s*$", l) or re.match(r"^\s*(\d+)\s+(\d+)\s+([\d.]+)\s+(.+?)\s*$", l)
            if m: snap["types"].append({"count": int(m.group(1)), "bytes": int(m.group(2)), "name": m.group(4).strip()[:120]})
        snap["types"] = sorted(snap["types"], key=lambda x: -x["bytes"])[:40]
    # Close to a gigabyte of text for a big heap: parsed as it streams, only the merged top stacks are kept.
    p = subprocess.Popen(["malloc_history", str(pid), "-allBySize"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, errors="replace")
    timer = threading.Timer(300, p.kill); timer.start()
    try: snap["stacks"] = parse_malloc_history(p.stdout)
    finally: timer.cancel(); p.wait()
    (raw / f"malloc-{name}.json").write_text(json.dumps(snap["stacks"], indent=1))
    r = run(["vmmap", "--summary", str(pid)], 120)
    if r and r.returncode == 0:
        (raw / f"vmmap-{name}.txt").write_text(r.stdout)
        snap["regions"], snap["footprint_mb"] = parse_vmmap(r.stdout)
    if leaks:
        r = run(["leaks", str(pid)], 300)
        if r and r.stdout:
            (raw / f"leaks-{name}.txt").write_text(r.stdout)
            m = re.search(r"(\d+) leaks? for (\d+) total leaked bytes", r.stdout)
            if m: snap["leaks"] = {"count": int(m.group(1)), "bytes": int(m.group(2))}
    return snap


ALLOCATORS = re.compile(r"^(_?malloc\w*|calloc|realloc|_?posix_memalign|operator new|swift_slowAlloc|swift_allocObject|_xzm_\w+|nanov2_\w+|szone_\w+|"
                        r"mfm_\w+|default_zone_\w+|_malloc_zone_\w+|malloc_zone_\w+|_malloc_type_\w+|__CFSafelyReallocate\w*|bmalloc\w*)")


def parse_malloc_history(lines, top=40):
    """'N calls for M bytes: thread |root | … | leaf' lines, merged by their innermost frames, biggest first. Only heap
    allocations count: the VM regions it also lists (mapped files, IOSurfaces from WebKit) are not malloc memory."""
    agg = defaultdict(lambda: [0, 0])
    for l in lines:
        m = re.match(r"^\s*(\d+) calls? for (\d+) bytes: (.*)$", l)
        if not m: continue
        frames = []
        for f in m.group(3).split("|")[1:]:
            fm = re.match(r"^\s*0x[0-9a-f]+ \(([^)]*)\) (.*?)(?:\s{2,}\S+:\d+)?\s*$", f)
            frames.append(fm.group(2) if fm else f.strip())
        cut = next((i for i, f in enumerate(frames) if ALLOCATORS.match(f)), None)
        if cut is None: continue
        key = tuple(frames[max(0, cut - 14):cut])
        agg[key][0] += int(m.group(1)); agg[key][1] += int(m.group(2))
    rows = sorted(agg.items(), key=lambda kv: -kv[1][1])[:top]
    return [{"count": c, "bytes": b, "stack": list(k)} for k, (c, b) in rows]


def parse_vmmap(text):
    regions, fp = [], None
    m = re.search(r"Physical footprint:\s+([\d.]+)([KMG])", text)
    if m: fp = float(m.group(1)) * {"K": 1 / 1024, "M": 1, "G": 1024}[m.group(2)]
    sec = text.split("REGION TYPE", 1)[1] if "REGION TYPE" in text else ""
    for l in sec.splitlines()[2:]:
        if l.startswith("===") or not l.strip(): break
        m = re.match(r"^(.+?)\s{2,}([\d.]+[KMGB]?)\s+([\d.]+[KMGB]?)\s+([\d.]+[KMGB]?)\s+([\d.]+[KMGB]?)", l)
        if m: regions.append({"region": m.group(1).strip(), "virtual": m.group(2), "resident": m.group(3), "dirty": m.group(4), "swapped": m.group(5),
                              "dirty_mb": round(to_mb(m.group(4)) + to_mb(m.group(5)), 1)})
    return sorted(regions, key=lambda r: -r["dirty_mb"])[:20], fp


def to_mb(s):
    m = re.match(r"([\d.]+)([KMGB]?)", s)
    return float(m.group(1)) * {"K": 1 / 1024, "M": 1, "G": 1024, "B": 1 / 2**20, "": 1 / 2**20}[m.group(2)] if m else 0


# ───────────── Data model ─────────────
def assemble(run_, cpu, sp):
    pts = run_.sampler.points
    procs = defaultdict(lambda: {"points": []})
    for t, pid, kind, fp, cpu_s, pct in pts:
        p = procs[(pid, kind)]; p.update(pid=pid, kind=kind); p["points"].append([t, round(fp / 2**20, 1), pct])
    hangs = list((cpu or {}).get("hangs", []))
    for e in sp["events"]:   # the app's own stall watch, with exact times
        if e["name"] == "hang":
            ms = float(re.match(r"([\d.]+)", e["detail"]).group(1))
            hangs.append({"t": round(e["t"] - ms / 1000, 3), "ms": round(ms), "type": "main-thread stall", "source": "HangWatch"})
    hangs.sort(key=lambda h: h["t"])
    stacks = cpu["stacks"].data() if cpu else {"bucket": BUCKET, "stacks": [], "samples": []}
    for h in hangs:   # what the main thread was doing during each hang
        c = Counter()
        for t, kind, th, sid, ms in stacks["samples"]:
            if th == "Main Thread" and kind == "app" and h["t"] - BUCKET <= t <= h["t"] + h["ms"] / 1000: c[sid] += ms
        h["stacks"] = [{"ms": round(ms, 1), "frames": stacks["stacks"][sid]} for sid, ms in c.most_common(3)]
    marks = [e for e in sp["events"] if e["name"] == "mark"]
    return {
        "meta": {"label": run_.label, "date": datetime.now().isoformat(timespec="seconds"), "provider": run_.a.provider,
                 "model": "perf-mock" if run_.a.provider == "mock" else run_.a.model, "cpu": cpu["mode"] if cpu else "off",
                 "cpu_note": cpu.get("note", "") if cpu else "", "allocations": bool(run_.a.allocations),
                 "args": {k: v for k, v in vars(run_.a).items() if k in ("messages", "memories", "stream_chars", "stream_cps", "agents", "fetch_kb", "fetch_url", "workloads")},
                 "machine": machine()},
        "workloads": run_.workloads, "processes": list(procs.values()), "stacks": stacks, "hangs": hangs,
        "signposts": sp["intervals"], "events": [e for e in sp["events"] if e["name"] != "hang"], "marks": marks, "heaps": run_.heaps,
    }


def machine():
    r = run(["sysctl", "-n", "machdep.cpu.brand_string", "hw.memsize"], 5)
    v = run(["sw_vers", "-productVersion"], 5)
    parts = (r.stdout.split("\n") if r else []) + [""]
    return f"{parts[0].strip()}, {int(parts[1]) // 2**30 if parts[1].strip().isdigit() else '?'} GB, macOS {v.stdout.strip() if v else '?'}"


def pct(xs, p):
    s = sorted(xs)
    return s[min(len(s) - 1, int(p * len(s)))] if s else 0


def in_workload(t, w): return w["t0"] <= t <= w["t1"]


def summary(data):
    """A flat {metric: value} of costs (lower is better) per workload: the regression gate compares these."""
    out = {}
    for w in data["workloads"]:
        n = w["name"]
        for k, v in w["metrics"].items():
            if isinstance(v, (int, float)) and not isinstance(v, bool): out[f"{n}.{k}"] = v
        by_kind = defaultdict(list)
        for p in data["processes"]:
            kind = "WebContent" if p["kind"].endswith("WebContent") else ("app" if p["kind"] in ("app", "render") else p["kind"].split(":")[-1])
            if p["kind"].startswith("render") != (n == "render"): continue
            by_kind[kind] += [pt for pt in p["points"] if in_workload(pt[0], w)]
        for kind, pts in by_kind.items():
            if pts:
                out[f"{n}.{kind}_peak_mb"] = max(pt[1] for pt in pts)
                out[f"{n}.{kind}_end_mb"] = pts[-1][1]
        totals = defaultdict(float)
        for kind, pts in by_kind.items():
            for pt in pts: totals[round(pt[0] * 4) / 4] += pt[1]
        if totals: out[f"{n}.total_peak_mb"] = round(max(totals.values()), 1)
        for name in sorted({s["name"] for s in data["signposts"]}):
            ms = [s["ms"] for s in data["signposts"] if s["name"] == name and in_workload(s["t"], w)]
            if len(ms) >= 3: out[f"{n}.sp.{name}.p95_ms"] = round(pct(ms, 0.95), 2)
            if ms: out[f"{n}.sp.{name}.max_ms"] = round(max(ms), 2)
        own, web = ("render", "render:WebContent") if n == "render" else ("app", "WebContent")
        for kind, key in ((own, "cpu_s"), (web, "web_cpu_s")):   # WebContent stacks come with --system-wide
            ms = sum(s[4] for s in data["stacks"]["samples"] if s[1] == kind and in_workload(s[0], w))
            if ms: out[f"{n}.{key}"] = round(ms / 1000, 2)
    h = data["hangs"]
    out["all.hangs_250ms"] = len([x for x in h if x["ms"] >= 250])
    out["all.hang_max_ms"] = max((x["ms"] for x in h), default=0)
    return {k: (round(v, 2) if isinstance(v, float) else v) for k, v in out.items()}


DEFAULT_THRESHOLDS = {"*_mb": {"rel": 0.10, "abs": 15}, "*_ms": {"rel": 0.25, "abs": 25}, "*_s": {"rel": 0.25, "abs": 1.0},
                      "*hang*": {"rel": 0.5, "abs": 2}, "*.rendered": {"rel": 0.2, "abs": 50}, "*": {"rel": 0.25, "abs": 1}}
IGNORED = ["*.seed_s", "*.messages_in_window", "*.subagents", "*.reply_chars_seen", "*.frames", "*.nodes", "*.rendered", "*.steps"]


def thresholds(path):
    th = dict(DEFAULT_THRESHOLDS)
    if path: th.update(json.loads(pathlib.Path(path).read_text()))
    return th


def compare(base, new, th):
    """Each metric is a cost: a regression is worse than the baseline by both the relative and the absolute margin."""
    rows = []
    for k in sorted(set(base) | set(new)):
        if any(fnmatch.fnmatch(k, g) for g in IGNORED): continue
        b, n = base.get(k), new.get(k)
        if b is None or n is None:
            rows.append({"metric": k, "base": b, "new": n, "delta": None, "status": "new" if b is None else "missing"}); continue
        rule = next(v for g, v in th.items() if fnmatch.fnmatch(k, g))
        d = n - b
        bad = d > rule["abs"] and (b == 0 or d / abs(b) > rule["rel"])
        good = -d > rule["abs"] and (b == 0 or -d / abs(b) > rule["rel"])
        rows.append({"metric": k, "base": b, "new": n, "delta": round(d, 2), "pct": round(d / b * 100, 1) if b else None,
                     "status": "regression" if bad else ("improved" if good else "same")})
    return {"rows": rows, "regressions": sum(r["status"] == "regression" for r in rows), "improved": sum(r["status"] == "improved" for r in rows)}


def compare_text(res):
    lines = [f"{res['regressions']} regression(s), {res['improved']} improvement(s)"]
    for r in res["rows"]:
        if r["status"] in ("regression", "improved"):
            lines.append(f"  {'✗' if r['status'] == 'regression' else '✓'} {r['metric']}: {r['base']} → {r['new']}" + (f" ({r['pct']:+.0f}%)" if r.get("pct") is not None else ""))
    return "\n".join(lines)
