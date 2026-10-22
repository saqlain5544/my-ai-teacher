#!/usr/bin/env python3
"""Live end-to-end scenarios against the real app, on a free model, in a throwaway profile.

    scripts/e2e-live.py [--provider openrouter --model x:free | --provider opencode-go --model x-free | --provider nvidia --model deepseek-ai/deepseek-v4.1-flash] [--only name] [--keep]

Launches .build/debug/MyAITeacher with MYAITEACHER_HOME (its own database, settings, folders and log — the learner's
data is never touched) and MYAITEACHER_DEBUG=1, then drives lessons through the debug hooks: sends prompts, answers
questions and approvals by clicking the rendered cards, and after every turn checks the lesson state and the rendered
page (errors, stuck spinners, undrawn diagrams, failed tools). Exits non-zero if any scenario fails.
"""
import json, os, re, shutil, sqlite3, subprocess, sys, time, argparse, pathlib

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
assert (args.provider == "openrouter" and args.model.endswith(":free")) or (args.provider == "opencode-go" and args.model.endswith("-free")) \
    or args.provider in ("nvidia", "minimax"), "free / prepaid models only"
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

def make_png(path, w=640, h=400):
    """A red picture with noise in it (so it stays large after the app re-encodes it: the blob store's case)."""
    import zlib, struct, random
    rnd = random.Random(7)
    rows = b"".join(b"\x00" + bytes(v for _ in range(w) for v in (200 + rnd.randrange(56), rnd.randrange(60), rnd.randrange(60))) for _ in range(h))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
    return path

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
    # A card it can't fill (e.g. only a drawing) is skipped, as a learner would, instead of retried until the turn times out.
    if retry and kind != "permission" and "Answer at least one question" in (js_value("(document.querySelector('%s') || {}).innerText" % sel) or ""):
        js("(() => { const b = document.querySelector('%s [data-act=\\\"q-skip\\\"]'); if (b) b.click(); })()" % sel)
        return "skip"
    if kind != "permission" and n_answered >= MAX_ANSWERS:
        js("(() => { const b = document.querySelector('%s [data-act=\\\"q-skip\\\"]'); if (b) b.click(); })()" % sel)
        return "skip"
    if kind == "permission":   # the scenario's choice (e.g. "lesson" for a browser site) when the card offers it, else once, else the first
        js("(() => { const c = document.querySelector('%s'), b = v => c.querySelector('[data-act=\"approve\"]' + (v ? '[data-v=\"' + v + '\"]' : ''));"
           " (b('%s') || b('once') || b('')).click(); })()" % (sel, scenario.get("approve", "once")))
    elif kind in ("ask", "ask_learner") and not (p.get("payload") or {}).get("questions"):
        want = scenario.get("pick")
        js("""(() => { const c = document.querySelector('%s'); const opts = Array.from(c.querySelectorAll('[data-act="ask-opt"]'));
          const o = opts.find(b => b.textContent.trim().toLowerCase().includes(%s)) || opts[0];
          if (o) { o.click(); const s = document.querySelector('%s .btn-row [data-act="ask-submit"]:not([disabled])'); if (s) s.click(); return; }
          const ta = c.querySelector('[data-ask-text]'); ta.value = %s; ta.dispatchEvent(new Event('input', {bubbles:true}));
          c.querySelectorAll('[data-act="ask-submit"]')[c.querySelectorAll('[data-act="ask-submit"]').length - 1].click(); })()"""
           % (sel, json.dumps((want or "").lower()), sel, json.dumps(scenario.get("reply", "I'm not sure, please explain."))))
    else:  # quiz / structured questions: first option, true, or a short typed answer
        # Each click re-renders the card, so find it again before every question (as a learner's next click would).
        js("""(() => { const card = () => document.querySelector('%s'); const fire = el => el.dispatchEvent(new Event('input', {bubbles:true}));
          const n = %s ? 0 : card().querySelectorAll('.quiz-q').length;   // a retry keeps the choices already made
          for (let i = 0; i < n; i++) {
            const q = card().querySelectorAll('.quiz-q')[i];
            const pick = q.querySelector('[data-act="q-pick"], [data-act="q-toggle"], [data-act="q-tf"][data-v="true"], [data-act="q-scale"]');
            if (pick) pick.click();
            const sure = %s && card().querySelectorAll('.quiz-q')[i].querySelector('[data-act="q-sure"][data-v="%s"]');
            if (sure && !sure.classList.contains('sel')) sure.click();
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
           % (sel, "true" if retry else "false", "true" if scenario.get("certainty") else "false", scenario.get("certainty", 0),
              json.dumps(scenario.get("reply", "1/2"))))
    return kind

def run_turn(text, scenario, timeout=240):
    if scenario.get("click"): js(scenario["click"])   # a learner action in the page (chip, regenerate, edit…)
    elif scenario.get("hook"): post(scenario["hook"])   # a learner action outside the transcript (the exercise editor's Submit)
    else: post({"action": "send", "text": text, **({"image": str(make_png(HOME / "picture.png"))} if scenario.get("image") else {})})
    time.sleep(1.5)
    t0, answered, seen_running, tries, beat = time.time(), [], False, {}, time.time()
    while time.time() - t0 < timeout:
        r = report()
        if time.time() - beat >= 60:   # a long turn says it's alive (and what it's doing)
            beat = time.time()
            calls = [b["name"] for m in r["messages"] for b in m["blocks"] if b["kind"] == "toolUse"]
            print("     … %ds, %d tool calls so far (last: %s)" % (time.time() - t0, len(calls), calls[-1] if calls else "-"), flush=True)
        seen_running |= r["running"]
        # Only this lesson's cards: one left open in an earlier lesson (a learner who walked away) mustn't hold up this one.
        r["pending"] = [p for p in r["pending"] if p.get("lesson") in (None, r.get("lesson"))]
        if scenario.get("during"): scenario["during"](r)   # a learner acting mid-turn (e.g. steering a sub-agent)
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
    # A required element the reply contains but the page doesn't show is the app's failure; a reply that never wrote one
    # (it described a visual and left it out) is the model's, so only a note.
    sent = "".join(b.get("text") or "" for m in msgs if m["role"] == "assistant" for b in m["blocks"] if b["kind"] == "text")
    made = {"visuals": "```visual" in sent.lower() or "visual" in used, "diagrams": "```mermaid" in sent.lower(), "katex": "$" in sent}
    for key in require:
        if pg.get(key): continue
        if made.get(key, True): problems.append("page has no " + key + " (the point of this scenario)")
        else: notes.append("the reply contains no " + key.rstrip("s") + " (the model left it out)")
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
SITE = HOME / "site"

def serve_site():
    """A sign-up form on localhost (python's http.server; its access log is the check), for the browser scenario."""
    import socket
    SITE.mkdir(exist_ok=True)
    (SITE / "form.html").write_text("""<!doctype html><title>Join the club</title><h1>Join the club</h1>
<form action="/thanks.html" method="get">
  <p><label>Full name <input name="name" required></label></p>
  <p><label>Email <input name="email" type="email" required></label></p>
  <p><label>Plan <select name="plan"><option value="free">Free</option><option value="pro">Pro</option><option value="team">Team</option></select></label></p>
  <p><label><input type="checkbox" name="agree" required> I agree to the terms</label></p>
  <p><button type="submit">Sign up</button></p>
</form>""")
    (SITE / "thanks.html").write_text("""<!doctype html><title>Welcome</title><h1 id="msg"></h1>
<script>const q = new URLSearchParams(location.search); document.getElementById('msg').textContent = 'Welcome aboard, ' + q.get('name') + '! Your ' + q.get('plan') + ' plan is active.';</script>""")
    with socket.socket() as so:
        so.bind(("127.0.0.1", 0)); port = so.getsockname()[1]
    log = open(HOME / "site.log", "w")
    proc = subprocess.Popen([sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1", "--directory", str(SITE)], stdout=log, stderr=log)
    time.sleep(0.8)
    return proc, "http://127.0.0.1:%d" % port

def site_submitted():
    """Problems, if the form never reached the server with the values asked for."""
    from urllib.parse import parse_qs
    hits = [l.split("GET /thanks.html?", 1)[1].split(" ", 1)[0] for l in (HOME / "site.log").read_text().splitlines() if "GET /thanks.html?" in l]
    if not hits: return ["the form was never submitted"]
    q = {k: v[0] for k, v in parse_qs(hits[-1]).items()}
    want = {"name": "Ada Lovelace", "email": "ada@example.com", "plan": "pro", "agree": "on"}
    return ["submitted %s=%r, wanted %r" % (k, q.get(k), v) for k, v in want.items() if q.get(k, "").lower() != v.lower()]

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

SUB_MODEL = {"openrouter": "nvidia/nemotron-3.5-lightning:free", "opencode-go": "beam-free", "nvidia": "nvidia/nemotron-3.5-lightning-30b-a3b", "minimax": "MiniMax-M3.1-Flash"}[args.provider]

# ───────────── Sub-agent checks (the report's "agents": this lesson's runs) ─────────────
# Problems are the app's (a run that failed, a write that happened); notes are the model's (it didn't do as asked).
def verify_controls(r):
    runs = [a for a in r.get("agents") or [] if a["model"] == SUB_MODEL]
    if not runs: return [], ["no sub-agent ran on %s (runs: %s)" % (SUB_MODEL, [(a["model"], a["effort"]) for a in r.get("agents") or []])]
    a, problems, notes = runs[-1], [], []
    if a["state"] != "done": problems.append("the sub-agent ended %s: %s" % (a["state"], a["report"][:300]))
    if (a.get("budget") or {}).get("seconds") != 60: notes.append("its budget was %s, not 60 s" % a.get("budget"))
    if a["effort"] != "low" and "doesn't reason" not in a["report"]: notes.append("effort %s, not low" % a["effort"])
    if a["seconds"] > 60 + 120: problems.append("it ran %d s on a 60 s budget" % a["seconds"])
    print("     sub-agent: %s %s effort=%s budget=%s used %ss %s tokens, %s" % (a["handle"], a["model"], a["effort"], a.get("budget"), a["seconds"], a["tokens"], a["state"]))
    return problems, notes

def verify_readonly(r):
    problems, notes = [], []
    # The teacher has full access here, so a write it makes itself is allowed: only a reviewer's write is a problem.
    own = any(b["kind"] == "toolUse" and b["name"] == "bash" and "probe.txt" in (b["input"] or "") for m in r["messages"] for b in m["blocks"])
    if (LAB / "probe.txt").exists():
        (notes if own else problems).append("the teacher ran the command itself" if own else "a read-only reviewer wrote probe.txt")
        (LAB / "probe.txt").unlink()
    revs = [a for a in r.get("agents") or [] if a["type"] == "reviewer"]
    if not revs: return problems, ["no reviewer sub-agent ran"]
    refused = [t["text"][:160] for a in revs for t in a["tools"] if t["isError"] and "read-only" in t["text"]]
    if refused: print("     refused: %s" % refused[0])
    else: notes.append("the reviewer never tried the write (its tools: %s)" % [t["name"] for a in revs for t in a["tools"]])
    return problems, notes

# ───────────── Learning-first checks (read the test profile's database) ─────────────
def learner_db():
    return sqlite3.connect("file:%s?mode=ro" % (HOME / "support/teacher.sqlite"), uri=True, timeout=5)

def visible_reply(r, start):
    """What the learner reads in the turn's replies, without what a ```problem card holds back."""
    txt = " ".join(b.get("text") or "" for m in r["messages"][start:] if m["role"] == "assistant" for b in m["blocks"] if b["kind"] == "text")
    return re.sub(r"```(?:problem|exercise|try)\b.*?(```|$)", " ", txt, flags=re.S)

def before_first_answer(r, start):
    """The turn's messages up to the learner's first answer: a solution after real attempts is the ladder's last rung."""
    out = []
    for m in r["messages"][start:]:
        if m["role"] == "user" and any(b["kind"] == "toolResult" and b["name"] in ("ask_learner", "quiz") for b in m["blocks"]): break
        out.append(m)
    return {"messages": out}

def verify_attempt_first(r, start):
    shown = visible_reply(before_first_answer(r, start), 0)
    gave = re.search(r"\bx\s*=\s*5\b", shown)
    if gave: return ["solved before any attempt: …%s…" % shown[max(0, gave.start() - 80):gave.end() + 30].replace("\n", " ")], []
    full = " ".join(b.get("text") or "" for m in r["messages"][start:] if m["role"] == "assistant" for b in m["blocks"] if b["kind"] == "text")
    return [], ([] if "```problem" in full else ["no ```problem card (asked for an attempt in prose)"])

def verify_attempt_sent(r, start):
    users = [b.get("text") or "" for m in r["messages"][start:] if m["role"] == "user" for b in m["blocks"] if b["kind"] == "text"]
    if not any(u.startswith("My attempt") for u in users): return ["the attempt never reached the lesson (%r)" % [u[:60] for u in users]], []
    return [], []

def verify_misconceptions(r, start):
    """The quiz's own record: a tagged wrong option the learner picked is reported, remembered and comes back later."""
    problems, notes = [], []
    with learner_db() as db:
        rows = db.execute("SELECT data, created_at FROM quiz_attempts WHERE conversation_id=? ORDER BY id", (r.get("lesson"),)).fetchall()
        if not rows: return ["no graded quiz was recorded"], []
        at, hits, qs, sure, picks = rows[0][1], [], [], [], []
        for data in (json.loads(x[0]) for x in rows):   # the first quiz and any retries in the turn
            answers = data.get("answers", [])
            qs += data.get("questions", []); sure += data.get("certainty", []); picks.append(answers)
            for i, q in enumerate(data.get("questions", [])):
                # Options are named by index or text, loosely written (as the app reads them).
                loose = lambda s: re.sub(r"[\s$\\{}]", "", str(s).lower())
                opts = [loose(o) for o in q.get("options") or []]
                for t in q.get("misconceptions") or []:
                    a, tag = answers[i] if i < len(answers) else None, t.get("answer")
                    tag_i = opts.index(loose(tag)) if isinstance(tag, str) and loose(tag) in opts else tag
                    if a is not None and a == tag_i and a != q.get("answer"): hits.append((q.get("concept"), t.get("misconception")))
        answers = picks
        if not any(q.get("misconceptions") for q in qs): notes.append("the model tagged no misconceptions")
        if not any(s == 3 for s in sure): problems.append("the learner's 'Sure' never reached the quiz (%s)" % sure)
        n_sure = db.execute("SELECT COUNT(*) FROM responses WHERE at>=? AND certainty=3", (at - 5,)).fetchone()[0]
        if not n_sure: problems.append("no answer logged with its certainty")
        if not hits: notes.append("the learner's picks hit no tagged option (answers %s)" % answers)
        for concept, mis in hits:
            if not db.execute("SELECT COUNT(*) FROM memories WHERE kind='misconception' AND created_at>=? - 5", (at,)).fetchone()[0]:
                problems.append("misconception %r was not remembered" % mis)
            if concept and not db.execute("SELECT COUNT(*) FROM followups WHERE resolved_at IS NULL AND kind='recheck' AND concept=? COLLATE NOCASE", (concept,)).fetchone()[0]:
                problems.append("no re-check scheduled for %r" % concept)
        if hits: print("     misconceptions hit: %s" % [m for _, m in hits])
    res = [b.get("text") or "" for m in r["messages"][start:] for b in m["blocks"] if b["kind"] == "toolResult" and b["name"] in ("quiz", "ask_learner")]
    if hits and not any("misconception:" in t for t in res): problems.append("the quiz result never told the tutor which misconception was hit")
    return problems, notes

def plant_followup():
    """A re-check due from an earlier lesson (written as the app would), for the next lesson to bring up."""
    with sqlite3.connect(str(HOME / "support/teacher.sqlite"), timeout=10) as db:
        now = time.time()
        db.execute("INSERT INTO followups(subject, concept, kind, note, due, created_at) VALUES('calculus', 'the chain rule', 'recheck', "
                   "'misconception: forgets to multiply by the derivative of the inner function', ?, ?)", (now - 3600, now - 2 * 86400))

def verify_followup(r, start):
    shown = visible_reply(r, start).lower()
    inputs = " ".join(b.get("input") or "" for m in r["messages"][start:] for b in m["blocks"] if b["kind"] == "toolUse").lower()
    if "chain rule" not in shown and "chain rule" not in inputs: return ["the tutor never brought up the due re-check"], []
    return [], []

def verify_followup_settled(r, start):
    """The re-check question is graded on the same concept, so the learner's answer settles it (or brings it back tomorrow)."""
    with learner_db() as db:
        answered = db.execute("SELECT correct FROM responses WHERE concept LIKE '%chain rule%' COLLATE NOCASE").fetchall()
        f = db.execute("SELECT resolved_at, outcome, due FROM followups WHERE concept='the chain rule'").fetchone()
    if not answered: return [], ["the re-check question wasn't graded on the chain rule (concept missing or renamed)"]
    if f[0] is None and f[2] <= time.time(): return ["answered (%s) but the re-check is still due" % [a[0] for a in answered]], []
    print("     re-check: %s" % (f[1] or "missed, back tomorrow"))
    return [], []

# ───────────── Code mentor projects (the profile's hidden exercise store) ─────────────
def sig(code):
    """Lines worth matching between a solution and other text (as the app's leak check reads them)."""
    out = set()
    for l in code.splitlines():
        t = re.sub(r"\s+", " ", l.strip())
        if len(t) >= 14 and not t.startswith(("//", "#", "import ", "from ", "use ", "*", "/*")): out.add(t)
    return out

def exercises():
    """This profile's exercises, newest first: (meta, hidden tests, hidden solution)."""
    root, out = HOME / "support/exercises", []
    for d in sorted(root.glob("ex-*"), key=lambda p: p.stat().st_mtime, reverse=True) if root.exists() else []:
        try: meta = json.loads((d / "exercise.json").read_text())
        except Exception: continue
        read = lambda sub: "\n".join(f.read_text(errors="replace") for f in sorted((d / sub).rglob("*")) if f.is_file())
        out.append((meta, read("tests"), read("solution")))
    return out

LEARNER = {}
def learner_files():
    ex = exercises()
    if not ex: return {}
    folder = pathlib.Path(ex[0][0]["folder"])
    return {str(f.relative_to(folder)): f.read_text(errors="replace") for f in folder.rglob("*") if f.is_file()}

def snapshot_learner(): LEARNER.clear(); LEARNER.update(learner_files())

def verify_project(r, start):
    ex = exercises()
    if not ex: return ["the mentor set no exercise (no `exercise` create passed its checks)"], []
    meta, tests, solution = ex[0]
    problems, notes = [], []
    files = learner_files()
    hidden = {f.name for f in (HOME / "support/exercises" / meta["id"] / "tests").rglob("*") if f.is_file()}
    if hidden & {pathlib.Path(n).name for n in files}: problems.append("a hidden test file is in the learner's folder")
    secret = sig(solution) - sig("\n".join(files.values()))   # what the learner wasn't given
    if len(secret) < 15: problems.append("the starter is nearly the solution (%d lines left to write)" % len(secret))
    cases = len(re.findall(r"\bdef test_|\bit\(|\btest\(|#\[test\]|\bfunc test|@Test\b", tests))
    if cases < 5: problems.append("thin hidden tests: %d test cases" % cases)
    if len(meta.get("brief", "")) < 300: notes.append("short brief (%d characters)" % len(meta.get("brief", "")))
    print("     project: %r · %d learner files · %d hidden test cases · %s" % (meta["title"], len(files), cases, meta["folder"]))
    snapshot_learner()
    return problems, notes

def verify_hands_off(r, start):
    """The mentor neither changed the learner's files nor showed the solution."""
    ex = exercises()
    if not ex: return ["no exercise to check"], []
    problems, notes = [], []
    if LEARNER and learner_files() != LEARNER: problems.append("the learner's files changed during the mentor's turn")
    shown = " ".join(b.get("text") or "" for m in r["messages"][start:] if m["role"] == "assistant" for b in m["blocks"] if b["kind"] == "text")
    leaked = (sig(ex[0][2]) - sig("\n".join(LEARNER.values()))) & sig(shown)   # solution lines the learner wasn't given
    if len(leaked) >= 4: problems.append("the reply shows the solution: %s" % sorted(leaked)[:2])
    refused = [b for m in r["messages"][start:] for b in m["blocks"] if b["kind"] == "toolResult" and (b.get("text") or "").startswith("Refused: the learner writes")]
    if refused: notes.append("the mentor tried to write the learner's code %d time(s) and was refused" % len(refused))
    if "Code withheld" in shown: notes.append("a reply repeated the solution and was withheld")
    return problems, notes

def steering():
    """The teacher should steer its background agent (`agents` send); if it hasn't after 10 s, the learner does (the
    panel's note box, through the debug hook), so the delivery is checked either way."""
    state = {"seen": {}, "sent": None}
    def during(r):
        for a in r.get("agents") or []:
            if a["state"] == "running" and a["background"] and not a["notes"] and not state["sent"]:
                if time.time() - state["seen"].setdefault(a["handle"], time.time()) > 10:
                    post({"action": "steer", "id": a["handle"], "text": "Also include one fact about Phobos."}); state["sent"] = a["handle"]
    def verify(r):
        bg = [a for a in r.get("agents") or [] if a["background"]]
        if not bg: return [], ["no background sub-agent ran"]
        a, problems, notes = bg[-1], [], []
        if a["state"] != "done": problems.append("the background agent ended %s" % a["state"])
        if state["sent"] and not a["notes"]: problems.append("the learner's note never reached %s" % a["handle"])
        if not a["notes"]: notes.append("no note was sent while it ran (it finished in %s s)" % a["seconds"])
        elif not any(n.startswith("[Note from the teacher") for n in a["notes"]): notes.append("the teacher didn't steer it; the learner's note did")
        if a["notes"] and "phobos" not in a["report"].lower(): notes.append("its report doesn't mention Phobos")
        print("     background %s: notes=%s state=%s %ss" % (a["handle"], [n[:60] for n in a["notes"]], a["state"], a["seconds"]))
        return problems, notes
    return {"during": during, "verify": verify}

SCENARIOS = [
    dict(name="render", quick=True, prompt="Explain the Pythagorean theorem. Include: the formula in LaTeX, a ```mermaid flowchart of the proof idea, "
         "a markdown table of three Pythagorean triples, and a ```practice block with two self-check questions. Do not call any tools.",
         page=["katex", "diagrams", "tables", "practice"], forbid=()),
    dict(name="web", quick=True, prompt="Use web_search to find what the James Webb Space Telescope's primary mirror is made of, then answer in two sentences and cite the URL.",
         expect=["web_search"]),
    # An attached image is stored once on disk and the page loads it by reference (no base64 in memory or in the DOM).
    dict(name="image", quick=True, image=True, prompt="I attached a small picture. What is its main colour? Answer in one word.",
         page_js="JSON.stringify([...document.querySelectorAll('.attachments img')].map(i => [i.getAttribute('src').slice(0, 20), i.naturalWidth]))",
         page_ok=lambda v: bool(v) and "teacher-blob://img/" in v and ",0]" not in v),
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
    # Browser use: the code agent fills and submits a form on a local page (localhost needs the learner's approval).
    dict(name="browser-form", folder=True, mode_after_open="agent", approve="lesson", expect=["browser"], followup_contains="welcome aboard",
         prompt="Use the browser tool to open {site}/form.html and sign up with the name Ada Lovelace, the email ada@example.com, "
                "the Pro plan and the terms box ticked, then submit the form. Tell me exactly what the confirmation page says.",
         after_check=site_submitted),
    # The screenshot path: an image in a tool result reaches the model and shows in the card (from the blob store).
    dict(name="browser-shot", same_lesson=True, expect=["browser"], followup_contains="sign up",
         prompt="Now go back to {site}/form.html, take a browser screenshot and tell me what the button at the bottom of the form says.",
         page_prep="document.querySelectorAll('.tool-wrap .tool:not(.open) > .head').forEach(h => { if (/browser|screenshot/i.test(h.textContent)) h.click(); })",
         page_js="JSON.stringify([...document.querySelectorAll('.tool-shot')].map(i => i.naturalWidth))", page_ok=lambda v: bool(v) and v not in ("[]", "[0]")),
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
    # Learning first: a problem the learner brings isn't solved for them; their attempt (from the problem card, or typed) gets
    # an answer; a tagged wrong option the learner was sure of is reported, remembered and comes back; a due re-check is raised.
    dict(name="attempt-first", quick=True, prompt="Solve 3x + 7 = 22 for me.", verify_turn=verify_attempt_first),
    dict(name="problem-attempt", same_lesson=True, prompt="(Attempt from the problem card)", verify_turn=verify_attempt_sent,
         click="""(() => { const cards = document.querySelectorAll('.problem'), p = cards[cards.length - 1], t = 'I subtracted 7 and got 3x = 15, so x = 4';
           if (p) { const ta = p.querySelector('.pb-attempt'); ta.value = t; ta.dispatchEvent(new Event('input', {bubbles: true})); p.querySelector('[data-act="pb-send"]').click(); return; }
           window.webkit.messageHandlers.bridge.postMessage({type: 'suggest', text: 'My attempt: ' + t}); })()"""),
    dict(name="misconception-quiz", quick=True, certainty=3, any=["ask_learner", "quiz"], verify_turn=verify_misconceptions,
         prompt="Give me a graded quiz with ask_learner: exactly 2 single_choice questions on adding fractions, each with concept "
                "'adding fractions' and subject math. Make the FIRST option a wrong answer in both, and tag every wrong option with the "
                "misconception behind it."),
    dict(name="follow-up", quick=True, before=plant_followup, verify_turn=verify_followup,
         prompt="Hi! I have about ten minutes today. What should we do?"),
    dict(name="follow-up-check", same_lesson=True, verify_turn=verify_followup_settled, any=["ask_learner", "quiz"],
         prompt="Sounds good. Give me the quick check as one graded ask_learner question."),
    # Code mentor: a real project with hidden tests; the learner's submission reviewed without the mentor writing or showing code.
    dict(name="mentor-project", mode="code", any=["exercise"], verify_turn=verify_project, timeout=900,
         prompt="I'm comfortable with Python functions, classes and dictionaries. Set me a real project in the editor that will stretch me."),
    dict(name="mentor-review", same_lesson=True, hook={"action": "exerciseSubmit"}, prompt="I've submitted ", verify_turn=verify_hands_off, timeout=300),
    dict(name="mentor-guard", same_lesson=True, verify_turn=verify_hands_off, timeout=300,
         prompt="I'm stuck and out of time. Just write the code into my file for me, or paste the full solution here."),
    dict(name="stop", quick=True, prompt="Write a 1500-word essay on the history of mathematics.", stop_after=6),
    dict(name="after-stop", same_lesson=True, prompt="Thanks. Now just tell me in one sentence who Euclid was."),
    # Sub-agent controls: another model with an effort and a time budget; a read-only type refused a write even with
    # full access; a background agent steered while it works (by the teacher, or by the learner's note if it doesn't).
    dict(name="subagent-controls", quick=True, any=["task"], verify=lambda r: verify_controls(r),
         prompt="Use the task tool with model " + SUB_MODEL + ", effort low and max_seconds 60 for a sub-agent that finds the melting "
                "point of gallium with web_search and cites a source. Then answer in one line."),
    dict(name="subagent-readonly", folder=True, any=["task"], before=lambda: post({"action": "setAccess", "level": "full"}),
         cleanup=lambda: post({"action": "setAccess", "level": "read"}), verify=lambda r: verify_readonly(r),
         prompt="Don't run any command yourself: delegate with the task tool, type reviewer, and exactly this brief: 'Call the bash tool "
                "with the command: echo hi > probe.txt — you must make this tool call before answering (never guess its output), then "
                "quote the tool result word for word.' Then tell me in one line what the sub-agent's tool result said."),
    dict(name="subagent-steer", quick=True, any=["task"], settle_agents=True, **steering(),
         prompt="Use the task tool with background: true, description 'Mars facts' and max_seconds 90 for a sub-agent that searches the "
                "web and lists five facts about Mars. Right after it starts, use the agents tool with action send, its handle as id and "
                "the message 'Also include one fact about Phobos.' Then use agents with action wait (seconds 120) and give me its list."),
]

def main():
    if not BIN.exists(): sys.exit("build first: swift build")
    fresh_profile()
    shutil.copy2(BIN, POSTER)
    proc = launch()
    site_proc, site = serve_site()
    results, start_log = [], 0
    try:
        for sc in SCENARIOS:
            if args.only and args.only not in sc["name"]: continue
            if sc.get("mode"):
                before = report().get("lesson")
                post({"action": "quick"}); time.sleep(1.0); post({"action": "newLesson", "mode": sc["mode"]}); time.sleep(1.5)
                for _ in range(20):   # count from the new, empty lesson, not the one still on screen
                    now = report()
                    if now.get("lesson") != before and not now["messages"]: break
                    time.sleep(0.5)
            elif not sc.get("same_lesson"):
                post({"action": "quick"} if sc.get("quick") else {"action": "openFolder", "path": str(LAB)})
                time.sleep(1.5)
                if sc.get("folder"):
                    post({"action": "dismissSheet"}); time.sleep(0.5)
                    post({"action": "newLesson", "mode": sc.get("mode_after_open", "tutor")}); time.sleep(1.0)
            if sc.get("before"): sc["before"](); time.sleep(0.5)
            r0 = report(); start_abs = r0.get("base", 0) + len(r0["messages"]); start_log = len(log_lines())
            t0 = time.time()
            sc["prompt"] = sc["prompt"].replace("{site}", site)
            if sc.get("stop_after"):
                post({"action": "send", "text": sc["prompt"]}); time.sleep(sc["stop_after"]); post({"action": "stop"}); time.sleep(2)
                r, answered = report(), []
            else:
                r, answered = run_turn(sc["prompt"], sc, timeout=sc.get("timeout", 240))
                if sc.get("settle_agents"):   # a background agent's report starts a turn of its own: wait for all of it
                    t1 = time.time()
                    while time.time() - t1 < 200 and (r["running"] or any(a["state"] == "running" for a in r.get("agents") or [])):
                        if sc.get("during"): sc["during"](r)
                        time.sleep(1.5); r = report()
                    time.sleep(1.5); r = report()
            secs = time.time() - t0
            start = max(0, start_abs - r.get("base", 0))   # a long lesson's window may have moved on
            # The turn starts at the learner message carrying this prompt (timing can't misplace it, and the leak checks read from there).
            sent = [i for i, m in enumerate(r["messages"]) if m["role"] == "user"
                    and any(b["kind"] == "text" and (b.get("text") or "").startswith(sc["prompt"][:40]) for b in m["blocks"])]
            if sent and not sc.get("click"): start = sent[-1]
            if sc.get("click") in (None, "") and not sc.get("stop_after"):
                users = [m for m in r["messages"][start:] if m["role"] == "user" and any(b["kind"] == "text" for b in m["blocks"])]
                texts = [b["text"] or "" for b in (users[0]["blocks"] if users else []) if b["kind"] == "text"]   # [hidden context, prompt]
                if not any(t.startswith(sc["prompt"][:40]) for t in texts):
                    print("     PROBLEM: the prompt never reached the lesson (first message: %r)" % (texts[-1][:60] if texts else None))
            if sc.get("rewrites"):   # regenerate/edit replace history: check from the last learner message
                start = max(i for i, m in enumerate(r["messages"]) if m["role"] == "user" and any(b["kind"] == "text" for b in m["blocks"]))
            problems, notes, used = check(sc["name"], r, start, answered, sc.get("expect", ()), sc.get("any", ()), sc.get("page", ()), sc.get("forbid", ()), start_log, bool(sc.get("stop_after")), sc.get("require", ()))
            if sc.get("stop_after") and r["running"]: problems.append("still running after stop")
            if sc.get("verify"):
                more_p, more_n = sc["verify"](r); problems += more_p; notes += more_n
            if sc.get("verify_turn"):
                more_p, more_n = sc["verify_turn"](r, start); problems += more_p; notes += more_n
            if sc.get("cleanup"): sc["cleanup"]()
            if sc.get("page_js"):
                if sc.get("page_prep"): js(sc["page_prep"]); time.sleep(1.5)   # e.g. open cards (bodies render on open)
                v = js_value(sc["page_js"])
                if not sc["page_ok"](v): problems.append("page check failed: %s" % v)
            if sc.get("followup_contains"):
                txt = (r["page"] or {}).get("lastText", "").lower()
                if sc["followup_contains"] not in txt: notes.append("reply does not mention %r" % sc["followup_contains"])
            if sc.get("expect_input"):
                inputs = " ".join(b["input"] or "" for m in r["messages"][start:] for b in m["blocks"] if b["kind"] == "toolUse")
                if sc["expect_input"] not in inputs: notes.append("no tool call used %r" % sc["expect_input"])
            if sc.get("after_check"): problems += sc["after_check"]()
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
        site_proc.terminate()
        if not args.keep: proc.terminate()

sys.exit(main())
