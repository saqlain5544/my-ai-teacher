#!/usr/bin/env python3
"""Performance runs of the real app: workloads driven through DebugHooks, recorded from outside, one HTML report.

    scripts/perf/perf.py run [--workloads lesson,stream,recall,fetch,agents,render] [--home /tmp/myaiteacher-perf]
                             [--provider mock | --provider minimax --model MiniMax-M3] [--allocations] [--cpu auto|xctrace|sample|off]
                             [--baseline FILE] [--compare FILE] [--label NAME]
    scripts/perf/perf.py compare BASE.json NEW.json [--thresholds FILE]     exit 1 on a regression (for CI)
    scripts/perf/perf.py report RUN_DIR                                     rebuild report.html from a run's data.json

A run copies build/My AI Teacher.app (scripts/build-app.sh) to <home>/app, re-signed ad hoc with get-task-allow so the
recorders may attach, and starts it on a throwaway profile (<home>/profile: its own database, settings, folders, log;
stopped by its own pid, never the learner's copy). With --provider mock (default) a local OpenAI-compatible model
(mockllm.py) streams deterministic replies, so runs are free and comparable; minimax/openrouter-free run the same prompts live.

Recorded: CPU stacks (xctrace Time Profiler attached to the app, else `sample` in 2 s windows), main-thread hangs
(xctrace potential-hangs plus the app's own HangWatch), os_signpost intervals (`log stream`), phys_footprint and CPU of the
app and its WebKit WebContent/GPU/Networking processes every 250 ms (proc_pid_rusage), and with --allocations the live
heap by call stack after each workload (MallocStackLogging + heap/malloc_history/vmmap/leaks). Never waits on a dialog:
a recorder that does not start in time is dropped for its fallback.
"""
import argparse, ctypes, fcntl, json, os, pathlib, plistlib, re, shutil, signal, statistics, subprocess, sys, threading, time
from datetime import datetime

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE)); sys.dont_write_bytecode = True   # no __pycache__ in the repo
import mockllm, report, profiles   # noqa: E402

SUBSYSTEM = "com.saqlain.myaiteacher"
WORKLOADS = ["lesson", "stream", "recall", "fetch", "agents", "render"]


# ───────────── Process metrics (no task port needed) ─────────────
LIBC = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
LIBC.responsibility_get_pid_responsible_for_pid.argtypes = [ctypes.c_int]
LIBC.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
LIBC.proc_name.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
LIBC.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]


class RUsage(ctypes.Structure):   # rusage_info_v4
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in (
        "user", "system", "idle_wkups", "intr_wkups", "pageins", "wired", "resident", "footprint", "start", "exit",
        "c_user", "c_system", "c_idle", "c_intr", "c_pageins", "c_elapsed", "disk_r", "disk_w",
        "q0", "q1", "q2", "q3", "q4", "q5", "q6", "billed", "serviced", "logical_w", "lifetime_max_footprint",
        "instructions", "cycles", "billed_energy", "serviced_energy", "interval_max_footprint", "runnable")]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_tb = Timebase(); LIBC.mach_timebase_info(ctypes.byref(_tb))
TICK_NS = _tb.numer / _tb.denom


def rusage(pid):
    ru = RUsage()
    if LIBC.proc_pid_rusage(pid, 4, ctypes.byref(ru)) != 0: return None
    return ru


def pname(pid):
    buf = ctypes.create_string_buffer(256)
    return buf.value.decode(errors="replace") if LIBC.proc_name(pid, buf, 256) > 0 else ""


def all_pids():
    n = LIBC.proc_listallpids(None, 0)
    arr = (ctypes.c_int * (n + 64))()
    return [p for p in arr[:LIBC.proc_listallpids(arr, ctypes.sizeof(arr))] if p > 0]


def pids_running(exe):
    buf = ctypes.create_string_buffer(4096)
    return {p for p in all_pids() if LIBC.proc_pidpath(p, buf, 4096) > 0 and buf.value.decode(errors="replace") == str(exe)}


def webkit_children(pid):
    """WebKit's XPC processes are children of launchd; the kernel's responsibility link ties them to the app."""
    out = {}
    for p in all_pids():
        if p == pid: continue
        nm = pname(p)
        if nm.startswith("com.apple.WebKit") and LIBC.responsibility_get_pid_responsible_for_pid(p) == pid:
            out[p] = nm.rsplit(".", 1)[-1]
    return out


class Sampler(threading.Thread):
    """phys_footprint and CPU of the app and its WebKit processes every `interval` seconds."""
    def __init__(self, t0, interval=0.25):
        super().__init__(daemon=True)
        self.t0, self.interval, self.roots, self.points, self.stop_flag = t0, interval, {}, [], threading.Event()
        self.lock = threading.Lock()

    def watch(self, pid, kind):
        with self.lock: self.roots[pid] = kind

    def run(self):
        procs, last, n = {}, {}, 0
        while not self.stop_flag.is_set():
            if n % 8 == 0:   # WebKit processes come and go (the watchdog restarts a frozen page)
                with self.lock: roots = dict(self.roots)
                procs = dict(roots)
                for r, kind in roots.items():
                    for c, nm in webkit_children(r).items(): procs[c] = nm if kind == "app" else f"{kind}:{nm}"
            t = time.time() - self.t0
            for pid, kind in procs.items():
                ru = rusage(pid)
                if not ru: continue
                cpu = (ru.user + ru.system) * TICK_NS / 1e9
                prev = last.get(pid)
                pct = (cpu - prev[1]) / (t - prev[0]) * 100 if prev and t > prev[0] else 0
                last[pid] = (t, cpu)
                self.points.append((round(t, 3), pid, kind, ru.footprint, round(cpu, 3), round(pct, 1)))
            n += 1
            self.stop_flag.wait(self.interval)

    def stop(self):
        self.stop_flag.set(); self.join(2)


# ───────────── The app under test ─────────────
class App:
    def __init__(self, a, out):
        self.home = pathlib.Path(a.home).resolve()
        self.profile = self.home / "profile"
        self.log = self.profile / "MyAITeacher.log"
        self.out, self.args = out, a
        self.bundle = self.home / "app" / "My AI Teacher.app"
        self.exe = self.bundle / "Contents/MacOS/MyAITeacher"
        self.pid = None

    def prepare_bundle(self, src):
        """A copy of the release bundle that profilers may attach to: same binary, plus get-task-allow."""
        src = pathlib.Path(src)
        if not (src / "Contents/MacOS/MyAITeacher").exists(): sys.exit(f"build the app first: scripts/build-app.sh  ({src} missing)")
        stamp = self.home / "app" / "source-mtime"
        mtime = str((src / "Contents/MacOS/MyAITeacher").stat().st_mtime_ns) + str((src / "Contents/Resources/web/app.js").stat().st_mtime_ns)
        if self.exe.exists() and stamp.exists() and stamp.read_text() == mtime: return
        (self.home / "app").mkdir(parents=True, exist_ok=True)
        subprocess.run(["rsync", "-a", "--delete", str(src) + "/", str(self.bundle) + "/"], check=True)
        ent = plistlib.loads((ROOT / "scripts/entitlements.plist").read_bytes())
        ent["com.apple.security.get-task-allow"] = True
        ent_path = self.home / "app" / "perf-entitlements.plist"
        ent_path.write_bytes(plistlib.dumps(ent))
        subprocess.run(["codesign", "--force", "--deep", "--sign", "-", "--options", "runtime", "--entitlements", str(ent_path), str(self.bundle)],
                       check=True, capture_output=True)
        stamp.write_text(mtime)

    def check_stopped(self):
        # One run per home: two would share (and delete) one profile and pid file.
        self.home.mkdir(parents=True, exist_ok=True)
        self.lock = open(self.home / "run.lock", "w")
        try: fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: sys.exit(f"another perf run is using {self.home}; wait for it or pass another --home")
        old = self.pid_from_file()
        if old and rusage(old) and pids_running(self.exe) & {old}: sys.exit(f"the instance from the last run (--keep) is still running: kill {old}")

    def fresh_profile(self, settings):
        if self.profile.exists(): shutil.rmtree(self.profile)
        (self.profile / "support").mkdir(parents=True)
        (self.profile / "support/settings.json").write_text(json.dumps(settings))
        (self.profile / "lab").mkdir()

    def pid_from_file(self):
        try: return int((self.profile / "app.pid").read_text())
        except (OSError, ValueError): return None

    def launch(self, env):
        cmd = ["open", "-n", "-g", "-a", str(self.bundle), "--env", f"MYAITEACHER_HOME={self.profile}", "--env", "MYAITEACHER_DEBUG=1",
               "--env", "MYAITEACHER_SIGNPOSTS=1"]
        for k, v in env.items(): cmd += ["--env", f"{k}={v}"]
        subprocess.run(cmd, check=True)
        self.wait_log("debug hooks enabled", 0, 40)
        t0 = time.time()
        while time.time() - t0 < 10 and not self.pid_from_file(): time.sleep(0.1)
        self.pid = self.pid_from_file()
        if not self.pid: sys.exit("the app did not write its pid file")
        self.wait_log("transcript ready", 0, 30)

    def terminate(self):
        p = self.pid_from_file()   # only ever the instance this run started, by its own pid file
        if not p: return
        os.kill(p, signal.SIGTERM)
        t0 = time.time()
        while time.time() - t0 < 10 and rusage(p): time.sleep(0.2)

    def post(self, cmd):
        subprocess.run([str(self.exe), "--post", json.dumps(cmd)], check=True, env={**os.environ, "MYAITEACHER_HOME": str(self.profile)})

    def lines(self):
        return self.log.read_text(errors="replace").splitlines() if self.log.exists() else []

    def wait_log(self, pattern, since, timeout):
        rx = re.compile(pattern)
        t0 = time.time()
        while time.time() - t0 < timeout:
            for l in self.lines()[since:]:
                if rx.search(l): return l
            time.sleep(0.1)
        raise RuntimeError(f"timed out after {timeout}s waiting for log /{pattern}/")

    def js(self, code, timeout=10):
        marker = "JSV%d:" % int(time.time() * 1000)
        n = len(self.lines())
        self.post({"action": "eval", "js": "'%s' + (%s)" % (marker, code)})
        l = self.wait_log(re.escape(marker), n, timeout)
        return l.split(marker, 1)[1]

    def report(self, timeout=10):
        path = self.profile / "report.json"
        before = path.stat().st_mtime_ns if path.exists() else 0
        self.post({"action": "report", "path": str(path)})
        t0 = time.time()
        while time.time() - t0 < timeout:
            if path.exists() and path.stat().st_mtime_ns != before:
                try: return json.loads(path.read_text())
                except json.JSONDecodeError: pass
            time.sleep(0.05)
        raise RuntimeError("no report from the app")

    def run_turn(self, text, timeout=300):
        """Sends a learner message and waits for the turn to end (sub-agents included)."""
        n = len(self.lines())
        self.post({"action": "send", "text": text})
        self.wait_log("sent: ", n, 10)
        t0, seen = time.time(), False
        while time.time() - t0 < timeout:
            r = self.report()
            seen |= r["running"]
            if (seen or time.time() - t0 > 5) and not r["running"]: return r
            time.sleep(0.5)
        raise RuntimeError("turn did not finish in time")


# ───────────── Workloads ─────────────
class Run:
    def __init__(self, a):
        self.a = a
        self.label = a.label or datetime.now().strftime("%Y%m%d-%H%M%S")
        self.out = pathlib.Path(a.home).resolve() / "runs" / self.label
        if self.out.exists(): shutil.rmtree(self.out)
        (self.out / "raw").mkdir(parents=True)
        self.app = App(a, self.out)
        self.t0 = time.time()
        self.workloads, self.heaps = [], []

    def now(self): return round(time.time() - self.t0, 3)

    def footprint_mb(self):
        ru = rusage(self.app.pid)
        return round(ru.footprint / 2**20, 1) if ru else None

    def web_mb(self):
        """The app's WebContent processes (the lesson's page, and a sub-agent's when one is open)."""
        return round(sum(ru.footprint for p, k in webkit_children(self.app.pid).items() if k == "WebContent" and (ru := rusage(p))) / 2**20, 1)

    def workload(self, name, fn):
        print(f"▸ {name}", flush=True)
        n = len(self.app.lines())
        self.app.post({"action": "mark", "name": "begin " + name})
        w = {"name": name, "t0": self.now(), "metrics": {}}
        try: fn(w["metrics"])
        except Exception as e:   # one broken workload must not lose the rest of the run
            w["error"] = str(e); print(f"  ✗ {name}: {e}", flush=True)
        w["t1"] = self.now()
        self.app.post({"action": "mark", "name": "end " + name})
        stalls = [float(m) for l in self.app.lines()[n:] for m in re.findall(r"perf: main thread stalled (\d+) ms", l)]
        w["metrics"]["hang_count"] = len([s for s in stalls if s >= 250])
        w["metrics"]["stall_max_ms"] = max(stalls, default=0)
        self.workloads.append(w)
        if self.a.allocations: self.heap_checkpoint(name)
        for k, v in w["metrics"].items(): print(f"    {k} = {v}")

    def heap_checkpoint(self, name):
        print(f"  · heap after {name}", flush=True)
        self.heaps.append(profiles.heap_snapshot(self.app.pid, self.out / "raw", name, leaks=(name == self.order[-1])))

    # The workloads. Each fills `m` with what it measured; memory and stalls come from the recorders.
    def w_lesson(self, m):
        n = len(self.app.lines())
        t = time.time()
        self.app.post({"action": "seedLesson", "messages": self.a.messages, "title": "Perf lesson"})
        line = self.app.wait_log(r"seeded lesson (\S+) ", n, 600)
        lesson = re.search(r"seeded lesson (\S+) ", line).group(1)
        m["seed_s"] = round(time.time() - t, 2)
        t = time.time()
        line = self.app.wait_log(r"reset Perf lesson: \d+ messages", n, 300)
        m["open_ms"] = round((time.time() - t) * 1000)
        m["messages_in_window"] = int(re.search(r"(\d+) messages →", line).group(1))
        m["rendered"] = int(re.search(r"→ (\d+) rendered", line).group(1))
        time.sleep(4); m["app_open_mb"], m["web_open_mb"] = self.footprint_mb(), self.web_mb()
        older = []
        for _ in range(3):   # the learner scrolls back: earlier messages page in
            n = len(self.app.lines()); t = time.time()
            if self.app.js("(() => { const b = document.querySelector('[data-act=\"older\"]'); if (b) b.click(); return !!b; })()") != "true": break
            self.app.wait_log(r"reset Perf lesson", n, 120); older.append(round((time.time() - t) * 1000))
        if older: m["older_ms_max"] = max(older)
        time.sleep(3); m["app_scrolled_mb"], m["web_scrolled_mb"] = self.footprint_mb(), self.web_mb()
        n = len(self.app.lines())
        self.app.post({"action": "newLesson"}); self.app.wait_log(r"reset ", n, 30)
        time.sleep(5); m["app_left_mb"] = self.footprint_mb()
        n = len(self.app.lines()); t = time.time()
        self.app.post({"action": "select", "item": "lesson", "id": lesson}); self.app.wait_log(r"reset Perf lesson", n, 300)
        m["reopen_ms"] = round((time.time() - t) * 1000)
        time.sleep(3)

    def w_stream(self, m):
        self.app.post({"action": "quick"}); time.sleep(1.5)
        prompt = (f"PERF:stream chars={self.a.stream_chars} cps={self.a.stream_cps}" if self.a.provider == "mock" else
                  "Write a detailed explanation of the chain rule, about 2,500 words, with many worked examples in LaTeX, a Python code block "
                  "and a markdown table. Do not call any tools.")
        t = time.time(); r = self.app.run_turn(prompt)
        m["turn_s"] = round(time.time() - t, 1)
        last = [x for x in r["messages"] if x["role"] == "assistant"][-1:]
        m["reply_chars_seen"] = sum(len(b.get("text") or "") for x in last for b in x["blocks"])   # report clips each block at 1,200
        time.sleep(3)

    def w_recall(self, m):
        n = len(self.app.lines()); t = time.time()
        self.app.post({"action": "seedMemories", "count": self.a.memories})
        self.app.wait_log(r"seeded \d+ memories", n, 900)
        m["seed_s"] = round(time.time() - t, 1)
        before = self.footprint_mb()
        n = len(self.app.lines())
        self.app.post({"action": "recall", "times": 10})
        line = self.app.wait_log(r"recall ms=", n, 300)
        ms = [int(x) for x in re.search(r"ms=\[([^\]]*)\]", line).group(1).split(",") if x.strip()]
        m["first_ms"], m["p50_ms"], m["max_ms"] = ms[0], int(statistics.median(ms)), max(ms)
        m["index_mb"] = round((self.footprint_mb() or 0) - (before or 0), 1)
        self.app.post({"action": "quick"}); time.sleep(1.0)
        t = time.time(); self.app.run_turn("How do I differentiate sin(x^2) with the chain rule? I keep confusing derivatives and integrals.")
        m["turn_with_recall_s"] = round(time.time() - t, 1)

    def w_fetch(self, m):
        ms = []
        for i in range(3):
            url = self.a.fetch_url or f"http://127.0.0.1:{self.mock_port}/big.html?kb={self.a.fetch_kb}&depth=60&n={i}"
            n = len(self.app.lines())
            self.app.post({"action": "runTool", "name": "web_fetch", "input": {"url": url + ("" if not self.a.fetch_url else f"{'&' if '?' in url else '?'}perf={i}")}})
            line = self.app.wait_log(r"runTool web_fetch ", n, 120)
            ms.append(int(re.search(r"ms=(\d+)", line).group(1)))
            if "ok=true" not in line: m["error"] = line[-200:]
        m["fetch_ms_max"], m["fetch_ms_first"] = max(ms), ms[0]
        time.sleep(3); m["app_after_mb"] = self.footprint_mb()

    def w_agents(self, m):
        self.app.post({"action": "quick"}); time.sleep(1.5)
        topics = ["the boiling point of ethanol", "the speed of sound in water", "the density of gold", "the half-life of carbon-14",
                  "the melting point of iron", "the speed of light in glass"][:self.a.agents]
        prompt = (f"PERF:agents n={self.a.agents} chars=6000" if self.a.provider == "mock" else
                  f"Use the task tool {len(topics)} times in parallel (one call each, all in the same reply) to research: {'; '.join(topics)}. "
                  "Then list the facts.")
        t = time.time(); r = self.app.run_turn(prompt, timeout=400)
        m["turn_s"] = round(time.time() - t, 1)
        m["subagents"] = sum(1 for x in r["messages"] for b in x["blocks"] if b["kind"] == "toolUse" and b["name"] == "task")
        time.sleep(3)

    def w_render(self, m):
        """The renderer on its own: the stress suite in the app's WebKit, offscreen with rAF running (frame times are real)."""
        out = self.out / "raw" / "render-stress.txt"
        before = pids_running(self.app.exe)
        # Through LaunchServices, so the process is responsible for its own WebKit processes (and they are measured too).
        subprocess.run(["open", "-n", "-g", "-a", str(self.app.bundle), "--stdout", str(out), "--stderr", str(out), "--env",
                        f"MYAITEACHER_HOME={self.app.profile}", "--args", "--webtest", str(HERE / "render-stress.js")], check=True)
        t = time.time()
        while not (new := pids_running(self.app.exe) - before) and time.time() - t < 20: time.sleep(0.05)
        if not new: raise RuntimeError("the renderer stress process did not start")
        pid = new.pop()
        self.sampler.watch(pid, "render")
        if self.cpu: self.cpu.attach_extra(pid, "render")
        while rusage(pid) and time.time() - t < 300: time.sleep(0.2)
        for l in out.read_text().splitlines():
            if "PERFJSON " in l:
                d = json.loads(l.split("PERFJSON ", 1)[1]); c = d.pop("case")
                for k, v in d.items():
                    if isinstance(v, (int, float)): m[f"{c}.{k}"] = v

    # ───────────── Orchestration ─────────────
    def settings(self):
        s = {"thinking": "off", "autoMemory": True, "python": "allow", "compactAtTokens": 48000, "showThinking": True}
        if self.a.provider == "mock":
            s.update(providerID="perf-mock", model="perf-mock", customProviders=[{
                "id": "perf-mock", "name": "Perf mock", "api": "openai", "baseURL": f"http://127.0.0.1:{self.mock_port}/v1", "envKeys": [],
                "defaultModel": "perf-mock", "keyOptional": True, "headers": {}, "isCustom": True, "supportsVision": False,
                "suggestedModels": ["perf-mock"], "quirks": []}])
        else:
            s.update(providerID=self.a.provider, model=self.a.model)
        return s

    def main(self):
        a = self.a
        assert a.provider == "mock" or (a.provider == "openrouter" and a.model.endswith(":free")) or a.provider == "minimax", "free / prepaid models only"
        self.order = [w for w in a.workloads.split(",") if w]
        unknown = set(self.order) - set(WORKLOADS)
        if unknown: sys.exit(f"unknown workloads: {', '.join(sorted(unknown))}")
        self.mock = mockllm.serve(); self.mock_port = self.mock.server_address[1]
        self.app.check_stopped()
        self.app.prepare_bundle(a.app)
        self.app.fresh_profile(self.settings())
        sp = profiles.SignpostStream(self.out / "raw" / "signposts.ndjson", SUBSYSTEM)
        env = {"MallocStackLogging": "lite"} if a.allocations else {}
        self.t0 = time.time()
        self.app.launch(env)
        print(f"app pid {self.app.pid}, profile {self.app.profile}", flush=True)
        self.sampler = Sampler(self.t0); self.sampler.watch(self.app.pid, "app"); self.sampler.start()
        self.cpu = profiles.cpu_recorder(a.cpu, self.app.pid, self.out / "raw", self.t0, a.system_wide)
        if self.cpu: print(f"cpu: {self.cpu.mode}" + (f" ({self.cpu.note})" if self.cpu.note else ""), flush=True)
        try:
            time.sleep(2)
            for name in self.order: self.workload(name, getattr(self, "w_" + name))
        finally:
            pidkind = {pt[1]: pt[2] for pt in self.sampler.points}
            cpu_data = self.cpu.finish(pidkind) if self.cpu else None   # while the app runs: atos names frames against it
            self.sampler.stop()
            if not a.keep: self.app.terminate()
            sp.stop()
            self.mock.shutdown()
        data = profiles.assemble(self, cpu_data, sp.intervals(self.t0))
        (self.out / "data.json").write_text(json.dumps(data))
        summary = profiles.summary(data)
        (self.out / "summary.json").write_text(json.dumps(summary, indent=1, sort_keys=True))
        code = 0
        if a.compare:
            base = json.loads(pathlib.Path(a.compare).read_text())
            data["compare"] = profiles.compare(base, summary, profiles.thresholds(a.thresholds))
            code = 1 if any(r["status"] == "regression" for r in data["compare"]["rows"]) else 0
            (self.out / "data.json").write_text(json.dumps(data))
        if a.baseline:
            pathlib.Path(a.baseline).parent.mkdir(parents=True, exist_ok=True)
            pathlib.Path(a.baseline).write_text(json.dumps(summary, indent=1, sort_keys=True))
        report.write(data, self.out / "report.html")
        latest = self.out.parent / "latest"
        if latest.is_symlink() or latest.exists(): latest.unlink()
        latest.symlink_to(self.out.name)
        print(f"\nreport: {self.out / 'report.html'}")
        if data.get("compare"): print(profiles.compare_text(data["compare"]))
        return code


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--home", default="/tmp/myaiteacher-perf")
    r.add_argument("--app", default=str(ROOT / "build/My AI Teacher.app"))
    r.add_argument("--workloads", default=",".join(WORKLOADS))
    r.add_argument("--provider", default="mock", choices=["mock", "minimax", "openrouter"])
    r.add_argument("--model", default="MiniMax-M3")
    r.add_argument("--messages", type=int, default=4000, help="huge lesson size")
    r.add_argument("--memories", type=int, default=10000)
    r.add_argument("--stream-chars", type=int, default=60000)
    r.add_argument("--stream-cps", type=int, default=6000)
    r.add_argument("--agents", type=int, default=4)
    r.add_argument("--fetch-kb", type=int, default=3000)
    r.add_argument("--fetch-url", default=None, help="a real page instead of the local 3 MB one")
    r.add_argument("--cpu", default="auto", choices=["auto", "xctrace", "sample", "off"])
    r.add_argument("--system-wide", action="store_true", help="xctrace all processes, kept to the app's own (WebContent stacks included)")
    r.add_argument("--allocations", action="store_true", help="MallocStackLogging + heap/malloc_history/vmmap/leaks after each workload")
    r.add_argument("--label", default=None)
    r.add_argument("--keep", action="store_true", help="leave the app running")
    r.add_argument("--baseline", default=None, help="write this run's summary here")
    r.add_argument("--compare", default=None, help="diff against this baseline summary; exit 1 on a regression")
    r.add_argument("--thresholds", default=None)
    c = sub.add_parser("compare"); c.add_argument("base"); c.add_argument("new"); c.add_argument("--thresholds", default=None)
    p = sub.add_parser("report"); p.add_argument("run_dir")
    a = ap.parse_args()
    if a.cmd == "run": return Run(a).main()
    if a.cmd == "compare":
        res = profiles.compare(json.loads(pathlib.Path(a.base).read_text()), json.loads(pathlib.Path(a.new).read_text()), profiles.thresholds(a.thresholds))
        print(profiles.compare_text(res))
        return 1 if any(x["status"] == "regression" for x in res["rows"]) else 0
    d = pathlib.Path(a.run_dir)
    report.write(json.loads((d / "data.json").read_text()), d / "report.html")
    print(d / "report.html")
    return 0


if __name__ == "__main__":
    sys.exit(main())
