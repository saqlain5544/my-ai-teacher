#!/usr/bin/env python3
"""Code mentor eval: real lessons through the real app, measured for friction and judged for teaching.

    scripts/eval-mentor.py --label before [--repo /path/to/checkout] [--provider minimax --model MiniMax-M3.1-Flash] [--only name]

Each scenario runs in its own lesson folder (code mentor mode unless it says otherwise) on the live harness's throwaway
profile. Measured per scenario: seconds, tool calls, tool errors (refusals), whether a project was registered and a
review passed, the reply's length, and whether the `school` tool or a lesson design ran. A judge model scores the
replies 1–10 for correctness, level fit, responsiveness and pedagogy. Results: <home>/../mentor-<label>.json.
`--repo` picks the checkout whose built app and harness are used, so two builds can be compared on the same scenarios.
"""
import argparse, importlib.util, json, pathlib, shutil, sqlite3, subprocess, sys, time, urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("--label", required=True)
ap.add_argument("--repo", default=str(pathlib.Path(__file__).resolve().parent.parent))
ap.add_argument("--provider", default="minimax")
ap.add_argument("--model", default="MiniMax-M3.1-Flash")
ap.add_argument("--only", default=None)
ap.add_argument("--judge-provider", default="nvidia")
ap.add_argument("--judge-model", default="deepseek-ai/deepseek-v4.1-flash")
ap.add_argument("--home", default="/tmp/myaiteacher-mentor-eval")
args = ap.parse_args()

sys.argv = ["e2e-live.py", "--provider", args.provider, "--model", args.model, "--home", args.home]
spec = importlib.util.spec_from_file_location("e2e", pathlib.Path(args.repo) / "scripts/e2e-live.py")
E = importlib.util.module_from_spec(spec); spec.loader.exec_module(E)
E.MAX_ANSWERS = 1

CLAMP_TESTS = {
    "c": ({"clamp.c": "#include \"clamp.h\"\n#include <stdlib.h>\n\n/* Clamp x into [lo, hi]. */\nint clamp(int x, int lo, int hi) {\n    abort(); /* TODO */\n}\n",
           "clamp.h": "int clamp(int x, int lo, int hi);\n",
           "Makefile": "test: runner\n\t./runner\nrunner: clamp.c .teacher/tests/test_clamp.c\n\tcc -Wall -o runner clamp.c .teacher/tests/test_clamp.c -I.\n",
           ".teacher/tests/test_clamp.c": "#include <stdio.h>\n#include \"clamp.h\"\nint main(void) {\n  int f = 0;\n  if (clamp(-1, 0, 5) != 0) { puts(\"FAIL below\"); f++; }\n  if (clamp(9, 0, 5) != 5) { puts(\"FAIL above\"); f++; }\n  if (clamp(3, 0, 5) != 3) { puts(\"FAIL inside\"); f++; }\n  printf(\"%d of 3 checks failed\\n\", f);\n  return f != 0;\n}\n"},
          {"clamp.c": "#include \"clamp.h\"\n\n/* Clamp x into [lo, hi]. */\nint clamp(int x, int lo, int hi) {\n    if (x < lo) return lo;\n    if (x > hi) return hi;\n    return x;\n}\n"}, "make test"),
    "elixir": ({"clamp.ex": "defmodule Clamp do\n  @doc \"Clamp x into lo..hi.\"\n  def clamp(x, lo, hi) do\n    raise \"TODO\"\n  end\nend\n",
                ".teacher/tests/clamp_test.exs": "Code.require_file(\"clamp.ex\")\nExUnit.start()\ndefmodule ClampTest do\n  use ExUnit.Case\n  test \"below\", do: assert Clamp.clamp(-1, 0, 5) == 0\n  test \"above\", do: assert Clamp.clamp(9, 0, 5) == 5\n  test \"inside\", do: assert Clamp.clamp(3, 0, 5) == 3\nend\n"},
               {"clamp.ex": "defmodule Clamp do\n  @doc \"Clamp x into lo..hi.\"\n  def clamp(x, lo, _hi) when x < lo, do: lo\n  def clamp(x, _lo, hi) when x > hi, do: hi\n  def clamp(x, _lo, _hi), do: x\nend\n"}, "elixir .teacher/tests/clamp_test.exs"),
}

def seeded(lang):
    files, solution, cmd = CLAMP_TESTS[lang]
    return dict(seed=files, solution=solution,
                prompt="My course gave me this %s exercise: the starter is in this folder and its tests are in .teacher/tests (run with `%s`). "
                       "Please register it as my project so you can review my work later. Don't explain clamp to me, I'll try it myself." % (lang.upper() if lang == "c" else lang.capitalize(), cmd),
                review="I've implemented clamp and saved the file. Please review my work.")

SCENARIOS = [
    dict(name="beginner", prompt="I've never written any code before. What is a variable? Show me with Python."),
    dict(name="expert", prompt="I'm a compiler engineer. In Rust, what exactly does the borrow checker prove when it rejects a second mutable "
                               "borrow, and how do two-phase borrows relax that rule?"),
    dict(name="elixir-learn", prompt="I know Python well. Teach me Elixir's pattern matching, with a small exercise in this folder."),
    dict(name="seeded-c", **seeded("c")),
    dict(name="seeded-elixir", **seeded("elixir")),
    dict(name="chemistry", mode="tutor", prompt="I have an exam on organic reaction mechanisms (SN1, SN2, E1, E2) in two weeks. Help me prepare."),
]

RUBRIC = """You grade an AI tutor's turn in a lesson. The learner's message states their level. Score 1 (poor) to 10 (excellent):
- correctness: facts, code and claims are right.
- level_fit: pitched at the learner's stated level (a beginner gets the basics without jargon; an expert gets expert depth, no basics).
- responsiveness: does what the learner asked now, no more and no less (no unrequested projects or detours; nothing asked for left out).
- pedagogy: builds real understanding (checks, attempts, examples that fit), without handing over work the learner said they'd do.
Be strict. Answer with JSON only: {"scores": {"correctness": n, "level_fit": n, "responsiveness": n, "pedagogy": n}, "weaknesses": ["…"]}"""

def judge(request, reply, tools):
    base, key_name = {"nvidia": ("https://integrate.api.nvidia.com/v1", "NVIDIA_API_KEY"), "openrouter": ("https://openrouter.ai/api/v1", "OPENROUTER_API_KEY")}[args.judge_provider]
    key = subprocess.run(["zsh", "-ilc", "printenv " + key_name], capture_output=True, text=True).stdout.strip()
    body = {"model": args.judge_model, "max_tokens": 3000, "messages": [{"role": "system", "content": RUBRIC},
            {"role": "user", "content": "The learner wrote:\n%s\n\nTools the tutor used:\n%s\n\nWhat the learner read:\n%s" % (request, tools[:3000] or "(none)", reply[:24000])}]}
    req = urllib.request.Request(base + "/chat/completions", data=json.dumps(body).encode(), headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    for _ in range(4):
        try:
            with urllib.request.urlopen(req, timeout=300) as r: text = json.load(r)["choices"][0]["message"]["content"]
            return json.loads(text[text.index("{"): text.rindex("}") + 1])
        except Exception as e:
            err = e; time.sleep(20)
    return {"error": str(err)}

def turn_stats(r, prompt):
    msgs = r["messages"]
    start = max((i for i, m in enumerate(msgs) if m["role"] == "user" and any((b.get("text") or "").startswith(prompt[:40]) for b in m["blocks"])), default=0)
    turn = msgs[start:]
    uses = [b for m in turn for b in m["blocks"] if b["kind"] == "toolUse"]
    errs = [(b.get("name"), (b.get("text") or "")[:220]) for m in turn for b in m["blocks"] if b["kind"] == "toolResult" and b.get("isError")]
    reply = "\n\n".join(b.get("text") or "" for m in turn if m["role"] == "assistant" for b in m["blocks"] if b["kind"] == "text")
    design = any((b.get("text") or "").startswith("<context>\nYour lesson design") for m in turn for b in m["blocks"])
    return dict(tools=[b["name"] for b in uses], tool_errors=errs, chars=len(reply), design=design,
                inputs="\n".join("%s %s" % (b["name"], (b.get("input") or "")[:160]) for b in uses)), reply

def project(folder):
    p = folder / ".teacher/project.json"
    if not p.exists(): return None
    j = json.loads(p.read_text())
    return dict(registered=j.get("snapshotAt") is not None, command=j.get("testCommand"), rounds=[r.get("verdict") for r in j.get("rounds", [])],
                runs=["%s/%s%s" % (x["passed"], x["passed"] + x["failed"], " err" if x["errored"] else "") for x in j.get("runs", [])])

def main():
    E.fresh_profile()
    E.shutil.copy2(E.BIN, E.POSTER)
    proc = E.launch()
    results = []
    try:
        for sc in SCENARIOS:
            if args.only and args.only not in sc["name"]: continue
            folder = E.HOME / "labs" / sc["name"]
            folder.mkdir(parents=True)
            for k, v in (sc.get("seed") or {}).items():
                (folder / k).parent.mkdir(parents=True, exist_ok=True); (folder / k).write_text(v)
            E.post({"action": "openFolder", "path": str(folder)}); time.sleep(1.5)
            E.post({"action": "dismissSheet"}); time.sleep(0.5)
            E.post({"action": "newLesson", "mode": sc.get("mode", "code")}); time.sleep(1.5)
            t0 = time.time()
            r, answered = E.run_turn(sc["prompt"], {"reply": "I'm not sure, can you explain?"}, timeout=1200)
            stats, reply = turn_stats(r, sc["prompt"])
            stats["seconds"] = round(time.time() - t0)
            stats["timeout"] = any(a[0] == "TIMEOUT" for a in answered)
            res = dict(name=sc["name"], **stats)
            if sc.get("review"):
                for k, v in sc["solution"].items(): (folder / k).write_text(v)
                t1 = time.time()
                r2, a2 = E.run_turn(sc["review"], {"reply": "I'm not sure."}, timeout=900)
                s2, reply2 = turn_stats(r2, sc["review"])
                res["review"] = dict(seconds=round(time.time() - t1), tools=s2["tools"], tool_errors=s2["tool_errors"], chars=s2["chars"])
                reply += "\n\n[next turn, after the learner implemented it]\n" + reply2
            res["project"] = project(folder)
            g = judge(sc["prompt"], reply, stats["inputs"]) if reply.strip() else {"error": "no reply"}
            res["scores"], res["weaknesses"], res["judge_error"] = g.get("scores"), g.get("weaknesses"), g.get("error")
            res["reply"] = reply[:24000]
            res.pop("inputs")
            results.append(res)
            print(json.dumps(res, ensure_ascii=False), flush=True)
            (E.HOME / ("report-%s.json" % sc["name"])).write_text(json.dumps(r, indent=1, ensure_ascii=False))
    finally:
        proc.terminate()
    out = pathlib.Path(args.home).parent / ("mentor-%s.json" % args.label)
    out.write_text(json.dumps({"label": args.label, "repo": args.repo, "model": args.model, "results": results}, indent=1, ensure_ascii=False))
    print("→", out)

main()
