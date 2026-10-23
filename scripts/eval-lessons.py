#!/usr/bin/env python3
"""Lesson quality eval: real requests through the real app, graded by a judge model against a depth rubric.

    scripts/eval-lessons.py --provider nvidia --model deepseek-ai/deepseek-v4.1-flash --label deep [--deep off] [--thinking high]
                            [--only name] [--judge-provider nvidia --judge-model deepseek-ai/deepseek-v4.1-flash]

Each lesson is the learner's first message in a fresh quick lesson of the live harness's throwaway profile (quizzes the
teacher asks are skipped, so every run compares one turn). The full reply comes from the lesson's database (drafts the
self-check replaced are left out); the judge scores it 1–10 on six criteria. Results: <home>/eval-<label>.json and .md,
and a one-line summary per lesson. Compare two labels (e.g. --deep on vs off) to see what a change did.
"""
import argparse, importlib.util, json, pathlib, sqlite3, subprocess, sys, time, urllib.request, uuid

ap = argparse.ArgumentParser()
ap.add_argument("--provider", default="nvidia")
ap.add_argument("--model", default="deepseek-ai/deepseek-v4.1-flash")
ap.add_argument("--thinking", default="high")
ap.add_argument("--deep", default="on", choices=["on", "off"])
ap.add_argument("--label", default=None)
ap.add_argument("--only", default=None)
ap.add_argument("--judge-provider", default="nvidia")
ap.add_argument("--judge-model", default="deepseek-ai/deepseek-v4.1-flash")
ap.add_argument("--home", default="/tmp/myaiteacher-e2e")
args = ap.parse_args()
label = args.label or ("deep" if args.deep == "on" else "plain")

# The live harness: its launcher, turn runner and report reader (free / prepaid providers only, as it enforces).
sys.argv = ["e2e-live.py", "--provider", args.provider, "--model", args.model, "--home", args.home]
spec = importlib.util.spec_from_file_location("e2e", pathlib.Path(__file__).with_name("e2e-live.py"))
E = importlib.util.module_from_spec(spec); spec.loader.exec_module(E)
E.MAX_ANSWERS = 0   # one turn per lesson: any quiz the teacher asks is skipped, as a learner would

LESSONS = [
    ("spinning-top", "I'm a second-year engineering student and I know torque and angular momentum. Explain properly why a spinning top doesn't fall over, and why it precesses instead."),
    ("tcp-congestion", "How does TCP congestion control actually work, and why did Google move from loss-based algorithms like CUBIC to BBR?"),
    ("eigen", "Teach me eigenvalues and eigenvectors so I understand what they mean, not just how to compute them."),
    ("ab-peeking", "I run A/B tests at work. Explain why peeking at results early inflates false positives, by how much, and what to do about it."),
    ("mrna", "Explain how mRNA vaccines work, from the lipid nanoparticle all the way to the immune response."),
    ("crisis-2008", "Why did the 2008 financial crisis spread from US subprime mortgages to banks all over the world?"),
    ("python-gil", "Explain Python's GIL: what it protects, why it limited multi-core performance, and what has changed in recent Python versions."),
    ("incline", "Solve this for me: a 2 kg block slides down a 30° incline with a friction coefficient of 0.2. Find its acceleration."),
]

RUBRIC = """You grade one reply from an AI tutor to a learner's first message. Score each criterion from 1 (poor) to 10 (excellent):
- correctness: facts, numbers and derivations are right; nothing misleading.
- depth: explains mechanisms and the why at a level an expert would call correct and complete for this learner; not superficial.
- grounding: concrete real-world examples, data, systems or problems; no toy or textbook-filler examples.
- pedagogy: builds understanding actively (questions, checks, misconception-aware); when the learner asks for a homework answer, it gets them to attempt rather than handing over the full solution.
- verification: claims that needed checking were checked (tools used where it mattered) or sourced; uncertainty stated where real.
- clarity: well organised, readable, a sensible length.
Be strict: 9–10 is rare and means expert-level work. Answer with JSON only:
{"scores": {"correctness": n, "depth": n, "grounding": n, "pedagogy": n, "verification": n, "clarity": n}, "strengths": ["…"], "weaknesses": ["…"]}"""

JUDGES = {"nvidia": ("https://integrate.api.nvidia.com/v1", "NVIDIA_API_KEY"), "opencode-go": ("https://opencode.ai/inference/go/openai/v1", "OPENCODE_API_KEY"),
          "openrouter": ("https://openrouter.ai/api/v1", "OPENROUTER_API_KEY")}

def shell_env(name):
    return subprocess.run(["zsh", "-ilc", "printenv " + name], capture_output=True, text=True).stdout.strip()

def judge(request, reply, tools):
    base, key_name = JUDGES[args.judge_provider]
    body = {"model": args.judge_model, "max_tokens": 4000, "messages": [
        {"role": "system", "content": RUBRIC},
        {"role": "user", "content": "The learner wrote:\n%s\n\nTools the tutor used this turn:\n%s\n\nThe reply:\n%s" % (request, tools or "(none)", reply[:30000])}]}
    if "deepseek" in args.judge_model: body["reasoning_effort"] = "high"
    req = urllib.request.Request(base + "/chat/completions", data=json.dumps(body).encode(), headers={
        "Authorization": "Bearer " + shell_env(key_name), "Content-Type": "application/json", "User-Agent": "my-ai-teacher-eval/1.0",
        "x-opencode-session": "eval-" + uuid.uuid4().hex[:8]})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=300) as r: text = json.load(r)["choices"][0]["message"]["content"]
            j = json.loads(text[text.index("{"): text.rindex("}") + 1])
            return j
        except Exception as e:
            err = e; time.sleep(5)
    return {"error": str(err)}

def turn_from_db(lesson, prompt):
    """The learner's message and the full turn after it, from the lesson's database (drafts the self-check replaced left out)."""
    db = sqlite3.connect("file:%s?mode=ro" % (E.HOME / ".teacher/no-dir-conversations/.teacher/state.sqlite"), uri=True)
    msgs = [json.loads(d) for (d,) in db.execute("SELECT data FROM messages WHERE conversation_id=? ORDER BY seq", (lesson,))]
    start = max((i for i, m in enumerate(msgs) if m["role"] == "user" and any((b.get("text") or "").startswith(prompt[:40]) for b in m["blocks"])), default=0)
    reply, tools, drafts = [], [], 0
    for m in msgs[start + 1:]:
        if m["role"] != "assistant": continue
        if (m.get("meta") or {}).get("superseded"): drafts += 1; continue
        for b in m["blocks"]:
            if b["kind"] == "text" and b.get("text"): reply.append(b["text"])
            if b["kind"] == "toolUse": tools.append("%s %s" % (b.get("name"), json.dumps(b.get("input"))[:200]))
    return "\n\n".join(reply), tools, drafts

def main():
    E.fresh_profile()
    settings = json.loads((E.HOME / "support/settings.json").read_text())
    settings.update({"thinking": args.thinking, "deepWork": args.deep == "on", "compactAtTokens": 0, "showThinking": False})
    (E.HOME / "support/settings.json").write_text(json.dumps(settings))
    E.shutil.copy2(E.BIN, E.POSTER)
    proc = E.launch()
    results = []
    try:
        for name, prompt in LESSONS:
            if args.only and args.only not in name: continue
            E.post({"action": "quick"}); time.sleep(1.5)
            t0 = time.time()
            r, answered = E.run_turn(prompt, {"reply": "I'm not sure."}, timeout=900)
            secs = time.time() - t0
            reply, tools, drafts = turn_from_db(r.get("lesson"), prompt)
            g = judge(prompt, reply, "\n".join(tools)) if reply else {"error": "no reply"}
            scores = g.get("scores") or {}
            overall = round(sum(scores.values()) / len(scores), 2) if scores else None
            results.append({"lesson": name, "seconds": round(secs), "tools": len(tools), "revised": drafts, "chars": len(reply),
                            "overall": overall, "scores": scores, "strengths": g.get("strengths"), "weaknesses": g.get("weaknesses"), "error": g.get("error")})
            print("%-15s overall %s · %s · %ds · %d tools · %s" % (name, overall, " ".join("%s %s" % (k[:4], v) for k, v in scores.items()),
                                                                secs, len(tools), "revised" if drafts else "first draft"), flush=True)
    finally:
        proc.terminate()
    done = [x["overall"] for x in results if x["overall"] is not None]
    mean = round(sum(done) / len(done), 2) if done else None
    out = {"label": label, "provider": args.provider, "model": args.model, "thinking": args.thinking, "deep": args.deep,
           "judge": "%s/%s" % (args.judge_provider, args.judge_model), "mean": mean, "lessons": results}
    (E.HOME.parent / ("eval-%s.json" % label)).write_text(json.dumps(out, indent=1, ensure_ascii=False))
    print("\n%s: mean %s over %d lessons → %s" % (label, mean, len(done), E.HOME.parent / ("eval-%s.json" % label)))

main()
