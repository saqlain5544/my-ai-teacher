#!/usr/bin/env python3
"""A/B evaluation of the course board: does it help the teacher stay on a long course — or cost it depth?

    scripts/ab-board.py [--arms nested,shallow,off] [--seeds 1] [--turns 12] [--parallel 3]
                        [--provider minimax --model MiniMax-M3.1-Flash] [--judge MiniMax-M3] [--out /tmp/ab-board]
    scripts/ab-board.py --judge-only /tmp/ab-board          (re-score saved runs)

Each run launches the installed app (build/My AI Teacher.app) in its own throwaway profile with
MYAITEACHER_EXP=course_board=<arm> (nested: the board with book-style outlines; shallow: cards only; off: no board, no
state header, no board rules) and plays a long course with a simulated learner — an experienced backend engineer
learning distributed consensus — through the debug channel: two unrelated detours, a low context budget that forces
summarisation mid-course, a "where were we?" after time away, and a request for the rest of the course.

A stronger model then scores, blind to the arm:
  depth       each teaching reply (1–10): correct, at the frontier for this learner, real systems not toy examples
  continuity  each reply after a detour, a summary or time away (0–10): back on the course thread, the right next step
  map         the final "rest of my course" reply (0–10): coherent, consistent with what was covered, complete
plus cost (tokens, seconds, tool calls) and board use, per arm. Results: <out>/report.md and <out>/results.json.
"""
import argparse, json, os, pathlib, random, re, shutil, sqlite3, subprocess, sys, threading, time, urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "build/My AI Teacher.app"
BIN = APP / "Contents/MacOS/MyAITeacher"

ap = argparse.ArgumentParser()
ap.add_argument("--arms", default="nested,shallow,off")
ap.add_argument("--seeds", type=int, default=1)
ap.add_argument("--turns", type=int, default=12)
ap.add_argument("--parallel", type=int, default=3)
ap.add_argument("--provider", default="minimax")
ap.add_argument("--model", default="MiniMax-M3.1-Flash")
ap.add_argument("--judge", default="MiniMax-M3")
ap.add_argument("--learner", default="MiniMax-M3.1-Flash")
ap.add_argument("--compact", type=int, default=24000, help="context budget in tokens (low, to force summaries)")
ap.add_argument("--turn-timeout", type=int, default=900)
ap.add_argument("--out", default="/tmp/ab-board")
ap.add_argument("--judge-only", default=None)
args = ap.parse_args()

# ───────────── Models (MiniMax token plan, Anthropic-compatible) ─────────────
def llm(model, system, user, max_tokens=1500, retries=4):
    """Text from the model (thinking off; an empty answer — all budget spent thinking — is retried with more room)."""
    for attempt in range(retries):
        body = {"model": model, "max_tokens": max_tokens * (attempt + 1) + 2000, "system": system,
                # MiniMax M3.x only allows adaptive thinking: the lowest effort is as close to "off" as it gets (as the app sends).
                "thinking": {"type": "adaptive"}, "output_config": {"effort": "low"}, "messages": [{"role": "user", "content": user}]}
        try:
            req = urllib.request.Request("https://api.minimax.io/anthropic/v1/messages", data=json.dumps(body).encode(),
                                         headers={"x-api-key": os.environ["MINIMAX_API_KEY"], "anthropic-version": "2023-06-01",
                                                  "Content-Type": "application/json"})
            r = json.load(urllib.request.urlopen(req, timeout=300))
            text = "".join(c.get("text", "") for c in r.get("content", []) if c.get("type") == "text").strip()
            if text: return text
        except Exception:
            if attempt == retries - 1: raise
        time.sleep(3 * (attempt + 1))
    raise RuntimeError(f"{model} returned no text")

def json_in(text):
    m = re.search(r"\{.*\}", text or "", re.S)
    try: return json.loads(m.group(0)) if m else None
    except json.JSONDecodeError: return None

# ───────────── The simulated learner ─────────────
PERSONA = """You are role-playing a learner in a tutoring app. You are Sam, a senior backend engineer (8 years of Go, Postgres,
Kafka, Kubernetes) who wants to master distributed consensus properly: implement Raft, understand Multi-Paxos, read the
papers, and handle production failure modes. You are smart and engaged but genuinely learning: you attempt every exercise
(sometimes with a plausible mistake, about one time in three), you answer questions briefly in your own words, and you
push back if the material is too basic. Reply only with what Sam types next — one short message, no narration."""

OPENING = ("I'm a senior backend engineer (Go, Postgres, Kafka). I want to master distributed consensus properly over the "
           "next six weeks: implement Raft myself, understand Multi-Paxos, read the papers, and know the production failure "
           "modes. Teach me — and keep track of where we are as we go.")
SCRIPT = {   # turn index (1-based) -> fixed learner message; the rest come from the simulated learner
    1: OPENING,
    5: "Unrelated, quick one: how do I get Postgres to use an index for a lookup inside a JSONB column?",
    7: "Sorry, one more unrelated thing: what's a good way to rate-limit an HTTP API in Go?",
    10: "I had to step away for a few days. Where were we, and what's next?",
    12: "Give me the full picture: what's the rest of my course from here, in order?",
}
KIND = {1: "teach", 5: "detour", 6: "return", 7: "detour", 8: "return", 10: "resume", 12: "map"}

# ───────────── Driving one app instance ─────────────
class Run:
    def __init__(self, arm, seed):
        self.arm, self.seed = arm, seed
        self.name = f"{arm}-{seed}"
        self.home = pathlib.Path(args.out) / self.name
        self.log = []

    lesson = None   # the run's lesson id: every command names it, so a selection change can't misdirect a send

    def post(self, cmd):
        if self.lesson and "lesson" not in cmd: cmd = {**cmd, "lesson": self.lesson}
        subprocess.run([str(BIN), "--post", json.dumps(cmd)], check=True, env={**os.environ, "MYAITEACHER_HOME": str(self.home)})

    def report(self, timeout=15):
        p = self.home / "report.json"
        before = p.stat().st_mtime_ns if p.exists() else 0
        self.post({"action": "report", "path": str(p)})
        t0 = time.time()
        while time.time() - t0 < timeout:
            if p.exists() and p.stat().st_mtime_ns != before:
                try: return json.loads(p.read_text())
                except json.JSONDecodeError: pass
            time.sleep(0.2)
        raise RuntimeError(self.name + ": no report")

    def launch(self):
        if self.home.exists(): shutil.rmtree(self.home)
        (self.home / "support").mkdir(parents=True)
        (self.home / "support/settings.json").write_text(json.dumps({
            "providerID": args.provider, "model": args.model, "thinking": "off", "autoMemory": True, "python": "allow",
            "compactAtTokens": args.compact, "showThinking": True, "learnerName": "Sam"}))
        subprocess.run(["open", "-n", "-g", "-a", str(APP), "--env", f"MYAITEACHER_HOME={self.home}", "--env", "MYAITEACHER_DEBUG=1",
                        "--env", f"MYAITEACHER_EXP=course_board={self.arm}"], check=True)
        t0 = time.time()
        while time.time() - t0 < 40:
            lp = self.home / "MyAITeacher.log"
            if lp.exists() and "transcript ready" in lp.read_text(): break
            time.sleep(0.5)
        time.sleep(2)

    def quit(self):
        try:
            pid = (self.home / "app.pid").read_text().strip()
            subprocess.run(["kill", pid], check=False)
        except Exception:
            subprocess.run(["pkill", "-f", f"MYAITEACHER_HOME={self.home}"], check=False)

    def answer(self, pend, transcript_tail):
        """A question card waiting for the learner: Sam answers it, through the page like a click would."""
        pid, payload = pend["id"], pend.get("payload") or {}
        sel = '[data-tool-id="%s"]' % pid
        if pend.get("kind") == "permission":
            self.post({"action": "eval", "js": "(() => { const c = document.querySelector('%s'); const b = c && (c.querySelector('[data-act=\"approve\"][data-v=\"once\"]') || c.querySelector('[data-act=\"approve\"]')); if (b) b.click(); })()" % sel})
            return
        qs = payload.get("questions") or [{"prompt": payload.get("question", ""), "options": payload.get("options") or [], "type": "single_choice" if payload.get("options") else "short_text"}]
        ask = "The tutor asks you, in a form:\n" + "\n".join(
            f"Q{i+1} ({q.get('type','')}): {q.get('prompt') or q.get('question','')}" + (("\n  options: " + " | ".join(f"{j}: {o}" for j, o in enumerate(q.get('options') or [])) ) if q.get('options') else "")
            for i, q in enumerate(qs)) + '\n\nAnswer as Sam. Reply with JSON only: {"answers": [an option number for choice questions, or your short text]}'
        out = json_in(llm(args.learner, PERSONA, transcript_tail[-3000:] + "\n\n" + ask, 600)) or {}
        answers = out.get("answers") or []
        js = """(() => { const card = () => document.querySelector('%s'); const ans = %s; const c = card(); if (!c) return;
          const opts = c.querySelectorAll('[data-act="ask-opt"]');
          if (opts.length && !c.querySelector('.quiz-q')) { const k = Number.isInteger(ans[0]) ? ans[0] : 0; (opts[k] || opts[0]).click();
            const s = c.querySelector('.btn-row [data-act="ask-submit"]:not([disabled])'); if (s) s.click(); return; }
          const free = c.querySelector('[data-ask-text]');
          if (free && !c.querySelector('.quiz-q')) { free.value = String(ans[0] ?? 'Not sure.'); free.dispatchEvent(new Event('input', {bubbles: true}));
            const bs = c.querySelectorAll('[data-act="ask-submit"]'); bs[bs.length - 1].click(); return; }
          const qs = c.querySelectorAll('.quiz-q');
          qs.forEach((q, i) => { const a = ans[i];
            const picks = q.querySelectorAll('[data-act="q-pick"], [data-act="q-toggle"], [data-act="q-tf"], [data-act="q-scale"]');
            if (picks.length) { const k = Number.isInteger(a) ? a : 0; (picks[k] || picks[0]).click(); return; }
            const t = q.querySelector('input[data-q-input], textarea[data-q-input]'); if (t) { t.value = String(a ?? ''); t.dispatchEvent(new Event('input', {bubbles: true})); } });
          const s = card().querySelector('[data-act="q-submit"]'); if (s) s.click(); else { const k = card().querySelector('[data-act="q-skip"]'); if (k) k.click(); } })()""" % (sel, json.dumps(answers))
        self.post({"action": "eval", "js": js})

    def user_count(self, r):
        return sum(1 for m in r["messages"] if m["role"] == "user" and any(b["kind"] == "text" for b in m["blocks"]))

    def turn(self, text):
        r = self.report()
        if not self.lesson and r.get("lesson"): self.lesson = r["lesson"]
        start, before = len(r["messages"]), self.user_count(r)
        t0, answered = time.time(), set()
        # Delivered only when the lesson shows the message: a send while a reply still runs is refused, so wait and resend.
        while True:
            if not self.report().get("running"):
                self.post({"action": "send", "text": text}); time.sleep(3)
                if self.user_count(self.report()) > before: break
            if time.time() - t0 > args.turn_timeout: return start, time.time() - t0, True
            time.sleep(5)
        while time.time() - t0 < args.turn_timeout:
            r = self.report()
            pend = [p for p in (r.get("pending") or []) if p["id"] not in answered]
            if pend:
                tail = self.transcript_text()
                for p in pend:
                    self.answer(p, tail); answered.add(p["id"])
                time.sleep(3); continue
            if not r.get("running") and not r.get("pending"):
                time.sleep(4)   # a reply between steps (a sub-agent report, an approval) can look idle for a moment
                r = self.report()
                if not r.get("running") and not r.get("pending"): return start, time.time() - t0, False
                continue
            time.sleep(4)
        self.post({"action": "stop"}); time.sleep(3)
        return start, time.time() - t0, True

    def db(self):
        dbs = list(self.home.glob("**/.teacher/state.sqlite"))
        return sqlite3.connect(str(dbs[0])) if dbs else None

    def messages(self):
        con = self.db()
        if not con: return []
        conv = con.execute("SELECT id FROM conversations ORDER BY updated_at DESC LIMIT 1").fetchone()
        rows = con.execute("SELECT data FROM messages WHERE conversation_id=? ORDER BY seq", (conv[0],)).fetchall() if conv else []
        return [json.loads(r[0]) for r in rows]

    def conversation(self):
        con = self.db()
        row = con.execute("SELECT data FROM conversations ORDER BY updated_at DESC LIMIT 1").fetchone() if con else None
        return json.loads(row[0]) if row else {}

    def transcript_text(self):
        out = []
        for m in self.messages()[-12:]:
            t = "".join(b.get("text") or "" for b in m.get("blocks", []) if b.get("kind") == "text" and not (b.get("meta") or {}).get("hidden"))
            if t.strip(): out.append(("Sam: " if m["role"] == "user" else "Tutor: ") + t.strip())
        return "\n\n".join(out)

    def play(self):
        self.launch()
        random.seed(self.seed)
        turns = []
        try:
            for n in range(1, args.turns + 1):
                text = SCRIPT.get(n) or llm(args.learner, PERSONA, self.transcript_text()[-6000:] + "\n\nWhat does Sam type next?", 400)
                start, secs, timed_out = self.turn(text)
                msgs = self.messages()
                user_idx = max((i for i, m in enumerate(msgs) if m["role"] == "user" and any((b.get("text") or "").strip() == text.strip() for b in m.get("blocks", []))), default=len(msgs) - 1)
                after = msgs[user_idx + 1:]
                reply = "\n\n".join("".join(b.get("text") or "" for b in m.get("blocks", []) if b.get("kind") == "text") for m in after if m["role"] == "assistant").strip()
                tools = [b.get("name") for m in after for b in m.get("blocks", []) if b.get("kind") == "toolUse"]
                usage = [m.get("usage") or {} for m in after if m["role"] == "assistant"]
                tokens = sum((u.get("input", 0) or 0) + (u.get("output", 0) or 0) for u in usage)
                conv = self.conversation()
                turns.append({"n": n, "kind": KIND.get(n, "teach"), "learner": text, "reply": reply, "tools": tools, "seconds": round(secs, 1),
                              "timed_out": timed_out, "tokens": tokens, "compacted": bool(conv.get("compactSummary"))})
                print(f"  [{self.name}] turn {n:2d} {KIND.get(n,'teach'):8s} {secs:5.0f}s tools={len(tools):2d} board={tools.count('lesson_plan')} "
                      f"compacted={bool(conv.get('compactSummary'))} reply={len(reply)}c", flush=True)
        finally:
            board = []
            try:
                con = sqlite3.connect(str(self.home / "support/teacher.sqlite"))
                board = [json.loads(r[0]) for r in con.execute("SELECT data FROM plans")]
            except Exception: pass
            (self.home / "run.json").write_text(json.dumps({"arm": self.arm, "seed": self.seed, "turns": turns, "board": board}, indent=1))
            self.quit()
        return turns

# ───────────── Judging (blind to the arm) ─────────────
JUDGE_SYS = "You are an exacting reviewer of tutoring for expert learners. You score strictly and return JSON only."
def judge_depth(learner, reply):
    p = f"""The learner is a senior backend engineer learning distributed consensus (Raft, Multi-Paxos, production failure modes).
Their message: <learner>{learner[:2000]}</learner>
The tutor's reply: <reply>{reply[:9000]}</reply>
Score the reply from 1 to 10 for DEPTH: technically correct and precise; pitched at the frontier for this expert (not basic,
not textbook filler); grounded in real systems, papers, data and failure modes rather than toy examples; actually advances
their mastery (exercises, implementation detail, checks). 1 = shallow/wrong/toy, 5 = solid textbook, 8 = what a top
distributed-systems engineer would teach, 10 = exceptional. JSON: {{"depth": n, "why": "one sentence"}}"""
    return json_in(llm(args.judge, JUDGE_SYS, p, 400)) or {}

def judge_continuity(thread, learner, reply, kind):
    p = f"""A tutor is running a multi-week course for a senior engineer learning distributed consensus. The course so far (the
tutor's earlier on-topic replies, condensed):
<course>{thread[-7000:]}</course>
Situation: {dict(return_="the learner just came back after an unrelated detour", resume="the learner returns after days away and asks where they were", map="the learner asks for the rest of the course").get(kind if kind != 'return' else 'return_', kind)}.
The learner said: <learner>{learner[:1500]}</learner>
The tutor replied: <reply>{reply[:8000]}</reply>
Score 0–10 for CONTINUITY: does the reply return to the right place in the course (not restart it, not repeat what was
done, not drop open threads such as an unanswered exercise), with the right next step? For a course map: is it coherent,
consistent with what was actually covered, and complete for the goal? JSON: {{"continuity": n, "why": "one sentence"}}"""
    return json_in(llm(args.judge, JUDGE_SYS, p, 400)) or {}

def judge_run(run):
    thread, scored = [], []
    for t in run["turns"]:
        s = dict(t)
        if t["kind"] in ("teach", "return", "resume") and t["reply"]:
            s.update({"depth_" + k: v for k, v in judge_depth(t["learner"], t["reply"]).items()})
        if t["kind"] in ("return", "resume", "map") and t["reply"]:
            s.update({"cont_" + k: v for k, v in judge_continuity("\n\n---\n\n".join(thread), t["learner"], t["reply"], t["kind"]).items()})
        if t["kind"] in ("teach", "return", "resume") and t["reply"]: thread.append(t["reply"][:1500])
        scored.append(s)
    return scored

def summarise(results):
    import statistics as st
    rows, by = [], {}
    for r in results: by.setdefault(r["arm"], []).append(r)
    for arm, runs in by.items():
        ts = [t for r in runs for t in r["scored"]]
        mean = lambda xs: round(st.mean(xs), 2) if xs else None
        rows.append({"arm": arm, "runs": len(runs),
                     "depth": mean([t["depth_depth"] for t in ts if isinstance(t.get("depth_depth"), (int, float))]),
                     "continuity": mean([t["cont_continuity"] for t in ts if t["kind"] in ("return", "resume") and isinstance(t.get("cont_continuity"), (int, float))]),
                     "map": mean([t["cont_continuity"] for t in ts if t["kind"] == "map" and isinstance(t.get("cont_continuity"), (int, float))]),
                     "tokens/turn": mean([t["tokens"] for t in ts]), "seconds/turn": mean([t["seconds"] for t in ts]),
                     "tools/turn": mean([len(t["tools"]) for t in ts]), "board calls/turn": mean([t["tools"].count("lesson_plan") for t in ts]),
                     "timeouts": sum(t["timed_out"] for t in ts), "compacted": any(t["compacted"] for t in ts)})
    return rows

def report_md(rows, results):
    cols = ["arm", "runs", "depth", "continuity", "map", "tokens/turn", "seconds/turn", "tools/turn", "board calls/turn", "timeouts", "compacted"]
    md = ["# Course board A/B", "", f"Model {args.model} (thinking off), judge {args.judge}, learner {args.learner}, context budget {args.compact} tokens.", "",
          "| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    md += ["| " + " | ".join(str(r[c]) for c in cols) + " |" for r in rows]
    md += ["", "## Per-turn judgements"]
    for r in results:
        md.append(f"\n### {r['arm']} (seed {r['seed']})")
        for t in r["scored"]:
            md.append(f"- turn {t['n']} {t['kind']}: depth {t.get('depth_depth','–')} cont {t.get('cont_continuity','–')} · "
                      f"{t.get('depth_why') or t.get('cont_why') or ''}")
    return "\n".join(md)

def main():
    out = pathlib.Path(args.judge_only or args.out); out.mkdir(parents=True, exist_ok=True)
    if not args.judge_only:
        if not BIN.exists(): sys.exit("build the app first: scripts/build-app.sh")
        runs = [Run(arm, seed) for seed in range(1, args.seeds + 1) for arm in args.arms.split(",")]
        sem = threading.Semaphore(args.parallel)
        def go(r):
            with sem:
                try: r.play()
                except Exception as e: print(f"  [{r.name}] failed: {e}", flush=True)
        threads = [threading.Thread(target=go, args=(r,)) for r in runs]
        for t in threads: t.start(); time.sleep(4)
        for t in threads: t.join()
    results = []
    for f in sorted(out.glob("*/run.json")):
        run = json.loads(f.read_text())
        if not run["turns"]: continue
        print(f"judging {f.parent.name}…", flush=True)
        run["scored"] = judge_run(run)
        results.append(run)
    rows = summarise(results)
    (out / "results.json").write_text(json.dumps({"summary": rows, "runs": results}, indent=1))
    (out / "report.md").write_text(report_md(rows, results))
    print(report_md(rows, results).split("## Per-turn")[0])

if __name__ == "__main__":
    main()
