#!/usr/bin/env python3
"""Live end-to-end scenarios against the real app, on a free model, in a throwaway profile.

    scripts/e2e-live.py [--provider openrouter --model x:free | --provider nvidia --model deepseek-ai/deepseek-v4.1-flash] [--only name] [--keep]

Launches .build/debug/MyAITeacher with MYAITEACHER_HOME (its own database, settings, folders and log — the learner's
data is never touched) and MYAITEACHER_DEBUG=1, then drives lessons through the debug hooks: sends prompts, answers
questions and approvals by clicking the rendered cards, and after every turn checks the lesson state and the rendered
page (errors, stuck spinners, undrawn diagrams, failed tools). Exits non-zero if any scenario fails.
"""
import json, os, shutil, subprocess, sys, time, argparse, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
BIN = ROOT / ".build/debug/MyAITeacher"
ap = argparse.ArgumentParser()
ap.add_argument("--provider", default="openrouter")
ap.add_argument("--model", default="minimax/minimax-m3.1-flash:free")
ap.add_argument("--only", default=None)
ap.add_argument("--keep", action="store_true", help="leave the app running afterwards")
ap.add_argument("--home", default=os.environ.get("E2E_HOME", "/tmp/myaiteacher-e2e"))
ap.add_argument("--compact", type=int, default=48000)
args = ap.parse_args()
# Free models only: OpenRouter's :free models, or NVIDIA NIM's free tier (when OpenRouter's daily free quota is used up).
# MiniMax: the learner's prepaid token plan (allowed for testing; thinking is off so replies end fast).
assert (args.provider == "openrouter" and args.model.endswith(":free")) or args.provider in ("nvidia", "minimax"), "free / prepaid models only"
HOME = pathlib.Path(args.home)
LOG = HOME / "MyAITeacher.log"
REPORT = HOME / "report.json"
LAB = HOME / "lab"

POSTER = HOME.parent / (HOME.name + "-poster")   # own copy: rebuilding .build mid-run must not break the driver

def post(cmd):
    # Commands go to this profile's channel only (several test instances can run side by side).
    subprocess.run([str(POSTER), "--post", json.dumps(cmd)], check=True, env={**os.environ, "MYAITEACHER_HOME": str(HOME)})

def report(timeout=8):
    before = REPORT.stat().st_mtime_ns if REPORT.exists() else 0
    post({"action": "report", "path": str(REPORT)})
    t0 = time.time()
    while time.time() - t0 < timeout:
        if REPORT.exists() and REPORT.stat().st_mtime_ns != before:
            try: return json.loads(REPORT.read_text())
            except json.JSONDecodeError: pass
        time.sleep(0.05)
    raise RuntimeError("no report from the app (is it running in debug mode?)")

def js(code):
    post({"action": "eval", "js": code})

def log_lines():
    return LOG.read_text(errors="replace").splitlines() if LOG.exists() else []

def js_value(code, timeout=5):
    """A value computed in the page (eval results are logged as "eval → …")."""
    marker = "JSV%d:" % int(time.time() * 1000)
    n = len(log_lines())
    js("'%s' + (%s)" % (marker, code))
    t0 = time.time()
    while time.time() - t0 < timeout:
        for l in log_lines()[n:]:
            if marker in l: return l.split(marker, 1)[1]
        time.sleep(0.1)
    return None

# What an open card says under its fields (a validation message keeps it open until the learner fixes the answer).
OPEN_CARD_MESSAGES = """JSON.stringify(Array.from(document.querySelectorAll('[data-tool-id]'))
  .filter(c => c.querySelector('[data-act="q-submit"], [data-act="ask-submit"], [data-act="approve"]'))
  .map(c => Array.from(c.querySelectorAll('[data-err], .q-empty')).map(e => e.textContent.trim()).filter(Boolean).join('; '))
  .filter(Boolean))"""

# ───────────── Answering cards like a learner (clicks in the page) ─────────────
MAX_ANSWERS = 3   # a learner who always answers keeps a tutor quizzing forever; after this many, skip like a learner

def answer_pending(p, scenario, n_answered=0, retry=False):
    pid, kind = p["id"], p["kind"]
    sel = '[data-tool-id="%s"]' % pid
    if kind != "permission" and n_answered >= MAX_ANSWERS:
        js("(() => { const b = document.querySelector('%s [data-act=\\\"q-skip\\\"]'); if (b) b.click(); })()" % sel)
        return "skip"
    if kind == "permission":
        js("document.querySelector('%s [data-act=\"approve\"][data-v=\"once\"]').click()" % sel)
    elif kind in ("ask", "ask_learner") and not (p.get("payload") or {}).get("questions"):
        want = scenario.get("pick")
        js("""(() => { const c = document.querySelector('%s'); const opts = Array.from(c.querySelectorAll('[data-act="ask-opt"]'));
          const o = opts.find(b => b.textContent.trim().toLowerCase().includes(%s)) || opts[0];
          if (o) { o.click(); return; }
          const ta = c.querySelector('[data-ask-text]'); ta.value = %s; ta.dispatchEvent(new Event('input', {bubbles:true}));
          c.querySelectorAll('[data-act="ask-submit"]')[c.querySelectorAll('[data-act="ask-submit"]').length - 1].click(); })()"""
           % (sel, json.dumps((want or "").lower()), json.dumps(scenario.get("reply", "I'm not sure, please explain."))))
    else:  # quiz / structured questions: first option, true, or a short typed answer
        # Each click re-renders the card, so find it again before every question (as a learner's next click would).
        js("""(() => { const card = () => document.querySelector('%s'); const fire = el => el.dispatchEvent(new Event('input', {bubbles:true}));
          const n = %s ? 0 : card().querySelectorAll('.quiz-q').length;   // a retry keeps the choices already made
          for (let i = 0; i < n; i++) {
            const q = card().querySelectorAll('.quiz-q')[i];
            const pick = q.querySelector('[data-act="q-pick"], [data-act="q-toggle"], [data-act="q-tf"][data-v="true"], [data-act="q-scale"]');
            if (pick) pick.click();
          }
          // A value the field accepts, as a learner would type after reading its hint: whole numbers, ranges, minimum lengths.
          card().querySelectorAll('[data-q-input], [data-q-blank], textarea').forEach(t => {
            if (t.value && t.getAttribute('aria-invalid') !== 'true') return;
            const k = t.getAttribute('data-numeric'), lo = t.getAttribute('data-min'), hi = t.getAttribute('data-max');
            let v = %s;
            if (k) {
              v = k === 'int' ? (lo != null ? lo : '2') : (/^[0-9 .,\/+-]+$/.test(v) ? v : '0.5');
              if (lo != null && !(eval(v.replace(',', '.')) >= +lo)) v = lo;
              if (hi != null && !(eval(v.replace(',', '.')) <= +hi)) v = hi;
            } else { const min = +t.getAttribute('data-minlen') || 0; while (v.length < min) v += ' ' + v; }
            t.value = v; t._touched = true; fire(t);
          });
          const s = card().querySelector('[data-act="q-submit"]'); if (s) s.click(); })()"""
           % (sel, "true" if retry else "false", json.dumps(scenario.get("reply", "1/2"))))
    return kind

def run_turn(text, scenario, timeout=240):
    if scenario.get("click"): js(scenario["click"])   # a learner action in the page (chip, regenerate, edit…)
    else: post({"action": "send", "text": text})
    time.sleep(1.5)
    t0, answered, seen_running, tries = time.time(), [], False, {}
    while time.time() - t0 < timeout:
        r = report()
        seen_running |= r["running"]
        for p in r["pending"]:
            if p["id"] not in tries:
                time.sleep(0.6)   # let the card render, as a learner would see it
                answered.append((p["id"], answer_pending(p, scenario, len([a for a in answered if a[1] != "permission"]))))
                tries[p["id"]] = (time.time(), 1)
            elif p["kind"] != "permission" and time.time() - tries[p["id"]][0] > 8 and tries[p["id"]][1] < 3:
                # Still open after an answer: read what it says (a learner would) and answer again.
                answer_pending(p, scenario, len([a for a in answered if a[1] != "permission"]) - 1, retry=True)
                tries[p["id"]] = (time.time(), tries[p["id"]][1] + 1)
        if not r["running"] and not r["pending"] and (seen_running or time.time() - t0 > 6):
            time.sleep(1.2)   # reflection/footer settle
            return report(), answered
        time.sleep(1.0)
    held = js_value(OPEN_CARD_MESSAGES)
    return report(), answered + [("TIMEOUT", "timeout" + (" (open card says %s)" % held if held and held != "[]" else ""))]

# ───────────── Checks ─────────────
def turn_messages(r, start):
    return r["messages"][start:]

def check(name, r, start, answered, expect_tools=(), any_tools=(), page=(), forbid_tools=(), log_from=0, allow_empty=False, require=()):
    problems, notes = [], []
    msgs = turn_messages(r, start)
    used = [b["name"] for m in msgs for b in m["blocks"] if b["kind"] == "toolUse"]
    results = {b["id"]: b for m in msgs for b in m["blocks"] if b["kind"] == "toolResult"}
    for a in answered:
        if a[0] == "TIMEOUT": problems.append("turn did not finish in time" + a[1][len("timeout"):])
    if r.get("error"): problems.append("session error: " + r["error"])
    for m in msgs:
        if m.get("error") and m["error"] != "Stopped.": problems.append("message error: " + m["error"])   # a stop is the learner's choice
    for m in msgs:
        for b in m["blocks"]:
            if b["kind"] == "toolUse" and b["id"] not in results: problems.append("tool %s has no result" % b["name"])
            if b["kind"] == "toolResult" and b["isError"]: notes.append("tool %s returned an error: %s" % (b["name"], (b["text"] or "")[:200]))
    for t in expect_tools:
        if t not in used: notes.append("model did not call %s (used %s)" % (t, used or "no tools"))
    if any_tools and not any(t in used for t in any_tools): notes.append("model used none of %s (used %s)" % (list(any_tools), used))
    for t in forbid_tools:
        if t in used: problems.append("unexpected tool " + t)
    pg = r.get("page") or {}
    errs = [e for e in pg.get("errors", []) if not e.startswith("⚠︎")]   # ⚠︎ = a visual's own script error, shown with Fix
    if errs: problems.append("page shows errors: %s" % [e[:600] for e in errs[:3]])
    for e in pg.get("errors", []):
        if e.startswith("⚠︎"): notes.append("visual reported its own error (Fix offered): " + e[:120])
    if pg.get("spinners"): problems.append("%d tool spinner(s) still turning" % pg["spinners"])
    if pg.get("pendingDiagrams"): problems.append("%d diagram(s) never drawn" % pg["pendingDiagrams"])
    final = [m for m in msgs if m["role"] == "assistant"]
    last_text = "".join(b["text"] or "" for b in (final[-1]["blocks"] if final else []) if b["kind"] == "text")
    if not last_text.strip() and not allow_empty: problems.append("no final text from the teacher")
    for key in page:
        if not pg.get(key): notes.append("page has no " + key)
    for key in require:
        if not pg.get(key): problems.append("page has no " + key + " (the point of this scenario)")
    errs = [l for l in log_lines()[log_from:] if (" JS error" in l or "[error]" in l.lower() or " error:" in l.lower()) and "eval →" not in l]
    if errs: problems.append("log errors: %s" % [e[20:220] for e in errs[:4]])
    return problems, notes, used

# ───────────── Profile & launch ─────────────
def fresh_profile():
    # The previous run is kept next to the new one, so a failure can still be read after the next run starts.
    prev = HOME.with_name(HOME.name + ".prev")
    if prev.exists(): shutil.rmtree(prev)
    if HOME.exists(): HOME.rename(prev)
    (HOME / "support").mkdir(parents=True)
    (HOME / "support/settings.json").write_text(json.dumps({
        "providerID": args.provider, "model": args.model, "thinking": "off", "autoMemory": True,
        "python": "allow", "compactAtTokens": args.compact, "showThinking": True, "experiments": True}))
    LAB.mkdir()
    (LAB / "notes.md").write_text("# Photosynthesis\n\nPlants turn light, water and CO2 into glucose and oxygen.\n\nChlorophyll absorbs red and blue light.\n")
    (LAB / "buggy.py").write_text("total = 0\nfor i in range(1, 10):\n    total += i\nprint(total)\n")
    (LAB / "scores.csv").write_text("name,score\nAda,91\nAlan,78\nGrace,85\n")
    # A git repository, so the Changes panel shows what the agent edits.
    for cmd in (["init", "-q"], ["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "start"]):
        subprocess.run(["git", "-C", str(LAB)] + cmd, check=True)

APP = ROOT / "build/My AI Teacher.app"

class TestInstance:
    """A second instance of the real app bundle on the test profile; stopped by its own pid, never the learner's."""
    def pid(self):
        try: return int((HOME / "app.pid").read_text())
        except (OSError, ValueError): return None
    def terminate(self):
        p = self.pid()
        if p: subprocess.run(["kill", str(p)])

def launch():
    if not APP.exists(): sys.exit("build the app first: scripts/build-app.sh")
    subprocess.run(["open", "-n", "-g", "-a", str(APP), "--env", "MYAITEACHER_HOME=%s" % HOME, "--env", "MYAITEACHER_DEBUG=1"], check=True)
    proc = TestInstance()
    t0 = time.time()
    while time.time() - t0 < 30:
        if any("debug hooks enabled" in l for l in log_lines()): break
        time.sleep(0.3)
    time.sleep(2)
    return proc

SUB_MODEL = {"openrouter": "nvidia/nemotron-3.5-lightning:free", "nvidia": "nvidia/nemotron-3.5-lightning-30b-a3b", "minimax": "MiniMax-M3.1-Flash"}[args.provider]

SCENARIOS = [
    dict(name="render", quick=True, prompt="Explain the Pythagorean theorem. Include: the formula in LaTeX, a ```mermaid flowchart of the proof idea, "
         "a markdown table of three Pythagorean triples, and a ```practice block with two self-check questions. Do not call any tools.",
         page=["katex", "diagrams", "tables", "practice"], forbid=()),
    dict(name="web", quick=True, prompt="Use web_search to find what the James Webb Space Telescope's primary mirror is made of, then answer in two sentences and cite the URL.",
         expect=["web_search"]),
    # A long, deeply structured page through the HTML converter (once took 90 s of CPU and 14 GB there).
    dict(name="fetch", prompt="Use web_fetch to read https://en.wikipedia.org/wiki/Photosynthesis, then tell me in two sentences what the light-dependent reactions produce.",
         expect=["web_fetch"]),
    dict(name="python", quick=True, prompt="Use run_code to compute the first 15 Fibonacci numbers in Python and print them. Then use the math tool to solve x^2 - 5x + 6 = 0.",
         expect=["run_code", "math"]),
    dict(name="ask", quick=True, prompt="Before explaining anything, call ask_learner to ask me which topic I want to learn, with exactly these options: Cells, Atoms, Planets.",
         expect=["ask_learner"], pick="atoms", followup_contains="atom"),
    dict(name="quiz", quick=True, prompt="Use the quiz tool to give me a 3-question quiz on fractions: one single_choice, one true_false and one short_text question.",
         expect=["quiz"], reply="1/2"),
    dict(name="files", folder=True, prompt="List the files in this folder, read notes.md and summarise it in one line. Then buggy.py should print 55 (the sum of 1..10) "
         "but doesn't: fix it with the edit tool and run it with bash to verify.", expect=["read", "edit", "bash"], any=["ls", "glob"],
         after=lambda: (LAB / "buggy.py").read_text()),
    dict(name="code-agent", folder=True, mode_after_open="agent", expect=["edit", "bash"], any=["project_memory"],
         prompt="buggy.py should print 55 (the sum of 1..10) but doesn't. Fix it, run it to verify, and save how to run it to project memory.",
         after=lambda: (LAB / "buggy.py").read_text() + "\n#MEM " + ((LAB / ".teacher/code-memory.md").read_text() if (LAB / ".teacher/code-memory.md").exists() else "(none)")),
    dict(name="visual", quick=True, prompt="Show me an interactive ```visual: a slider from 1 to 10 that sets a circle's radius and shows its area. Keep it small.",
         require=["visuals"]),
    dict(name="memory-save", quick=True, prompt="Please remember for future lessons: I learn best from worked examples with real-world analogies. Save that to memory.",
         expect=["memory"]),
    dict(name="memory-recall", quick=True, prompt="In one sentence: how do I like to learn?", followup_contains="analog"),
    dict(name="subagent", quick=True, prompt="Use the task tool to have a sub-agent find three facts about octopuses, then give me those facts as a list.",
         any=["task"]),
    dict(name="subagent-model", quick=True, any=["task"], expect_input=SUB_MODEL,
         prompt="Use the task tool with model " + SUB_MODEL + " for the sub-agent: find the boiling point of ethanol "
                "and cite a source. Then answer in one line."),
    dict(name="chip-flashcards", same_lesson=True, prompt="(Make flashcards chip)", any=["flashcards", "load_tools"],
         click="document.querySelector('.msg.assistant.last [data-act=\"quick\"][data-q=\"flashcards\"]').click()"),
    dict(name="regenerate", same_lesson=True, rewrites=True, prompt="(Regenerate)", click="document.querySelector('.msg.assistant.last [data-act=\"regenerate\"]').click()"),
    dict(name="edit", same_lesson=True, rewrites=True, prompt="(Edit first message)",
         click="""(() => { const u = document.querySelector('.msg.user'); u.querySelector('[data-act="edit"]').click();
           const ta = u.querySelector('textarea'); ta.value = 'In two sentences: what is an octopus?'; u.querySelector('[data-act="edit-save"]').click(); })()"""),
    dict(name="quiz-mode", mode="quiz", prompt="Quiz me on the planets of the solar system: 3 questions.", any=["ask_learner", "quiz"]),
    dict(name="stop", quick=True, prompt="Write a 1500-word essay on the history of mathematics.", stop_after=6),
    dict(name="after-stop", same_lesson=True, prompt="Thanks. Now just tell me in one sentence who Euclid was."),
]

def main():
    if not BIN.exists(): sys.exit("build first: swift build")
    fresh_profile()
    shutil.copy2(BIN, POSTER)
    proc = launch()
    results, start_log = [], 0
    try:
        for sc in SCENARIOS:
            if args.only and args.only not in sc["name"]: continue
            if sc.get("mode"):
                post({"action": "quick"}); time.sleep(1.0); post({"action": "newLesson", "mode": sc["mode"]}); time.sleep(1.5)
            elif not sc.get("same_lesson"):
                post({"action": "quick"} if sc.get("quick") else {"action": "openFolder", "path": str(LAB)})
                time.sleep(1.5)
                if sc.get("folder"):
                    post({"action": "dismissSheet"}); time.sleep(0.5)
                    post({"action": "newLesson", "mode": sc.get("mode_after_open", "tutor")}); time.sleep(1.0)
            r0 = report(); start = len(r0["messages"]); start_log = len(log_lines())
            t0 = time.time()
            if sc.get("stop_after"):
                post({"action": "send", "text": sc["prompt"]}); time.sleep(sc["stop_after"]); post({"action": "stop"}); time.sleep(2)
                r, answered = report(), []
            else:
                r, answered = run_turn(sc["prompt"], sc)
            secs = time.time() - t0
            if sc.get("click") in (None, "") and not sc.get("stop_after"):
                users = [m for m in r["messages"][start:] if m["role"] == "user" and any(b["kind"] == "text" for b in m["blocks"])]
                texts = [b["text"] or "" for b in (users[0]["blocks"] if users else []) if b["kind"] == "text"]   # [hidden context, prompt]
                if not any(t.startswith(sc["prompt"][:40]) for t in texts):
                    print("     PROBLEM: the prompt never reached the lesson (first message: %r)" % (texts[-1][:60] if texts else None))
            if sc.get("rewrites"):   # regenerate/edit replace history: check from the last learner message
                start = max(i for i, m in enumerate(r["messages"]) if m["role"] == "user" and any(b["kind"] == "text" for b in m["blocks"]))
            problems, notes, used = check(sc["name"], r, start, answered, sc.get("expect", ()), sc.get("any", ()), sc.get("page", ()), sc.get("forbid", ()), start_log, bool(sc.get("stop_after")), sc.get("require", ()))
            if sc.get("stop_after") and r["running"]: problems.append("still running after stop")
            if sc.get("followup_contains"):
                txt = (r["page"] or {}).get("lastText", "").lower()
                if sc["followup_contains"] not in txt: notes.append("reply does not mention %r" % sc["followup_contains"])
            if sc.get("expect_input"):
                inputs = " ".join(b["input"] or "" for m in r["messages"][start:] for b in m["blocks"] if b["kind"] == "toolUse")
                if sc["expect_input"] not in inputs: notes.append("no tool call used %r" % sc["expect_input"])
            if sc.get("after"):
                out = sc["after"]()
                if "range(1, 11)" not in out and "range(11)" not in out and "+ 1)" not in out: notes.append("buggy.py not fixed: " + out.replace("\n", " | "))
                if "#MEM " in out and "#MEM (none)" in out: notes.append("no project memory written")
            snap = HOME / ("snap-%s.png" % sc["name"]); post({"action": "snapshot", "path": str(snap)})
            (HOME / ("report-%s.json" % sc["name"])).write_text(json.dumps(r, indent=1, ensure_ascii=False))
            results.append((sc["name"], problems, notes, used, secs, answered))
            mark = "✗" if problems else "✓"
            print("%s %-14s %5.1fs tools=%s answered=%s" % (mark, sc["name"], secs, used, [a[1] for a in answered]))
            for p in problems: print("     PROBLEM:", p)
            for n in notes: print("     note:", n)
            sys.stdout.flush()
        # Every view opens without logging errors.
        start_log = len(log_lines())
        for item in ["memory", "progress", "flashcards", "insights", "lesson"]:
            post({"action": "select", "item": item}); time.sleep(1.2); post({"action": "snapshot", "path": str(HOME / ("view-%s.png" % item))}); time.sleep(0.4)
        errs = [l for l in log_lines()[start_log:] if "error" in l.lower()]
        print(("✗" if errs else "✓") + " views          " + (str(errs[:3]) if errs else "memory, progress, flashcards, insights open cleanly"))
        failed = [x for x in results if x[1]] + ([("views", errs)] if errs else [])
        print("\n%d scenarios, %d failed. Profile, log and snapshots: %s" % (len(results) + 1, len(failed), HOME))
        return 1 if failed else 0
    finally:
        if not args.keep: proc.terminate()

sys.exit(main())
