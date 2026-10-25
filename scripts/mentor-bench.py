#!/usr/bin/env python3
"""Fast code mentor bench: headless lessons (`MyAITeacher --lesson`), several at once, a hard budget per turn.

    scripts/mentor-bench.py --bin .build/debug/MyAITeacher --label after [--budget 240] [--jobs 4] [--only name] [--judge]

Each scenario runs in its own profile and folder. Checks are mechanical (answered within the budget, tool errors,
an unrequested project, a seeded project registered and passed after the learner's solution, the school detour);
`--judge` adds a judge model's 1–10 scores for level fit and responsiveness. Results: <out>/bench-<label>.json, and a
table on stdout. Compare two binaries (before/after a change) on the same scenarios.
"""
import argparse, concurrent.futures as cf, json, os, pathlib, shutil, subprocess, time, urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("--bin", required=True)
ap.add_argument("--label", required=True)
ap.add_argument("--provider", default="minimax")
ap.add_argument("--model", default="MiniMax-M3.1-Flash")
ap.add_argument("--budget", type=int, default=240)
ap.add_argument("--jobs", type=int, default=4)
ap.add_argument("--only", default=None)
ap.add_argument("--judge", action="store_true")
ap.add_argument("--deep", choices=["on", "off"], default=None, help="force DeepWork's plan-and-review on or off")
ap.add_argument("--out", default="/tmp/mentor-bench")
args = ap.parse_args()
assert args.provider in ("minimax", "nvidia") or args.model.endswith(":free") or args.model.endswith("-free"), "free / prepaid models only"

def clamp_project(lang):
    if lang == "c":
        return ({"clamp.c": "#include \"clamp.h\"\n#include <stdlib.h>\n\n/* Clamp x into [lo, hi]. */\nint clamp(int x, int lo, int hi) {\n    abort(); /* TODO */\n}\n",
                 "clamp.h": "int clamp(int x, int lo, int hi);\n",
                 "Makefile": "test: runner\n\t./runner\nrunner: clamp.c .teacher/tests/test_clamp.c\n\tcc -Wall -o runner clamp.c .teacher/tests/test_clamp.c -I.\n",
                 ".teacher/tests/test_clamp.c": "#include <stdio.h>\n#include \"clamp.h\"\nint main(void) {\n  int f = 0;\n  if (clamp(-1, 0, 5) != 0) { puts(\"FAIL below\"); f++; }\n  if (clamp(9, 0, 5) != 5) { puts(\"FAIL above\"); f++; }\n  if (clamp(3, 0, 5) != 3) { puts(\"FAIL inside\"); f++; }\n  printf(\"%d of 3 checks failed\\n\", f);\n  return f != 0;\n}\n"},
                {"clamp.c": "#include \"clamp.h\"\n\n/* Clamp x into [lo, hi]. */\nint clamp(int x, int lo, int hi) {\n    if (x < lo) return lo;\n    if (x > hi) return hi;\n    return x;\n}\n"}, "make test", "C")
    if lang == "elixir":
        return ({"clamp.ex": "defmodule Clamp do\n  @doc \"Clamp x into lo..hi.\"\n  def clamp(x, lo, hi) do\n    raise \"TODO\"\n  end\nend\n",
                 ".teacher/tests/clamp_test.exs": "Code.require_file(\"clamp.ex\")\nExUnit.start()\ndefmodule ClampTest do\n  use ExUnit.Case\n  test \"below\", do: assert Clamp.clamp(-1, 0, 5) == 0\n  test \"above\", do: assert Clamp.clamp(9, 0, 5) == 5\n  test \"inside\", do: assert Clamp.clamp(3, 0, 5) == 3\nend\n"},
                {"clamp.ex": "defmodule Clamp do\n  @doc \"Clamp x into lo..hi.\"\n  def clamp(x, lo, _hi) when x < lo, do: lo\n  def clamp(x, _lo, hi) when x > hi, do: hi\n  def clamp(x, _lo, _hi), do: x\nend\n"}, "elixir .teacher/tests/clamp_test.exs", "Elixir")
    if lang == "java":
        return ({"Clamp.java": "public class Clamp {\n    /** Clamp x into [lo, hi]. */\n    public static int clamp(int x, int lo, int hi) {\n        throw new UnsupportedOperationException(\"TODO\");\n    }\n}\n",
                 ".teacher/tests/ClampTest.java": "public class ClampTest {\n  public static void main(String[] a) {\n    int f = 0;\n    try { if (Clamp.clamp(-1, 0, 5) != 0) f++; } catch (Exception e) { f++; }\n    try { if (Clamp.clamp(9, 0, 5) != 5) f++; } catch (Exception e) { f++; }\n    try { if (Clamp.clamp(3, 0, 5) != 3) f++; } catch (Exception e) { f++; }\n    System.out.println(f + \" of 3 checks failed\");\n    System.exit(f == 0 ? 0 : 1);\n  }\n}\n"},
                {"Clamp.java": "public class Clamp {\n    /** Clamp x into [lo, hi]. */\n    public static int clamp(int x, int lo, int hi) {\n        return Math.max(lo, Math.min(x, hi));\n    }\n}\n"},
                "javac -d classes Clamp.java .teacher/tests/ClampTest.java && java -cp classes ClampTest", "Java")
    if lang == "debug":   # a debugging exercise: the starter is implemented, with a bug to find
        return ({"stats.py": "def mean(xs):\n    \"\"\"The arithmetic mean of a non-empty list.\"\"\"\n    total = 0\n    for i in range(1, len(xs)):\n        total += xs[i]\n    return total / len(xs)\n",
                 ".teacher/tests/test_stats.py": "import sys, os\nsys.path.insert(0, os.getcwd())\nfrom stats import mean\n\ndef test_one():\n    assert mean([4]) == 4\n\ndef test_many():\n    assert mean([1, 2, 3]) == 2\n"},
                {"stats.py": "def mean(xs):\n    \"\"\"The arithmetic mean of a non-empty list.\"\"\"\n    total = 0\n    for x in xs:\n        total += x\n    return total / len(xs)\n"},
                "python3 -m pytest -q .teacher/tests", "Python debugging")

def seeded(lang):
    files, solution, cmd, name = clamp_project(lang)
    return dict(seed=files, turns=[
        dict(text="My course gave me this %s exercise: the starter is in this folder and its tests are in .teacher/tests (run with `%s`). "
                  "Register it as my project so you can review my work later. Don't explain it to me, I'll try it myself." % (name, cmd)),
        dict(files=solution, text="I've done it and saved the file. Please review my work.")], seeded=True)

SCENARIOS = {
    "beginner-python": dict(turns=[dict(text="I've never written any code before. What is a variable? Show me with Python.")]),
    "expert-rust": dict(turns=[dict(text="I'm a compiler engineer. In Rust, what exactly does the borrow checker prove when it rejects a second mutable borrow, and how do two-phase borrows relax that rule?")]),
    "phd-types": dict(turns=[dict(text="I'm a PhD student in programming languages. Why does ML's value restriction exist — what goes wrong with let-polymorphism and refs without it — and how does OCaml's relaxed value restriction weaken it?")]),
    "dsa-intermediate": dict(turns=[dict(text="I can code in Go but never learned data structures. Teach me how a hash map handles collisions, with a small exercise in this folder.")]),
    "elixir-learn": dict(turns=[dict(text="I know Python well. Teach me Elixir's pattern matching, with a small exercise in this folder.")]),
    "seeded-c": seeded("c"),
    "seeded-elixir": seeded("elixir"),
    "seeded-java": seeded("java"),
    "seeded-debugging": seeded("debug"),
    "chemistry-tutor": dict(mode="tutor", turns=[dict(text="I have an exam on organic reaction mechanisms (SN1, SN2, E1, E2) in two weeks. Help me prepare.")]),
}

RUBRIC = """You grade an AI tutor's reply. The learner's message states their level. Score 1 (poor) to 10 (excellent):
- level_fit: pitched at the learner's stated level (a beginner gets the basics without jargon; an expert gets expert depth, no basics).
- responsiveness: does what the learner asked now, no more and no less.
- correctness: facts and code are right.
Be strict. JSON only: {"level_fit": n, "responsiveness": n, "correctness": n}"""

def judge(request, reply):
    key = subprocess.run(["zsh", "-ilc", "printenv NVIDIA_API_KEY"], capture_output=True, text=True).stdout.strip()
    body = {"model": "deepseek-ai/deepseek-v4.1-flash", "max_tokens": 2000, "messages": [{"role": "system", "content": RUBRIC},
            {"role": "user", "content": "The learner wrote:\n%s\n\nThe reply:\n%s" % (request, reply[:20000])}]}
    req = urllib.request.Request("https://integrate.api.nvidia.com/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    for _ in range(3):
        try:
            with urllib.request.urlopen(req, timeout=180) as r: t = json.load(r)["choices"][0]["message"]["content"] or ""
            return json.loads(t[t.index("{"): t.rindex("}") + 1])
        except Exception as e:
            err = str(e); time.sleep(10)
    return {"error": err}

OUT = pathlib.Path(args.out) / args.label

def run(name):
    sc = SCENARIOS[name]
    d = OUT / name
    if d.exists(): shutil.rmtree(d)
    d.mkdir(parents=True)
    spec = {"mode": sc.get("mode", "code"), "folder": str(d / "lab"), "seed": sc.get("seed", {}), "budget": args.budget, "turns": sc["turns"]}
    if args.deep: spec["deepWork"] = args.deep == "on"
    (d / "spec.json").write_text(json.dumps(spec))
    t0 = time.time()
    p = subprocess.run([args.bin, "--lesson", str(d / "spec.json"), "--provider", args.provider, "--model", args.model, "--thinking", "off"],
                       env={**os.environ, "MYAITEACHER_HOME": str(d / "home")}, capture_output=True, text=True,
                       timeout=args.budget * len(sc["turns"]) + 120)
    (d / "stdout.txt").write_text(p.stdout + "\n--- stderr ---\n" + p.stderr[-5000:])
    turns = [json.loads(l[len("LESSON-TURN "):]) for l in p.stdout.splitlines() if l.startswith("LESSON-TURN ")]
    r = dict(name=name, seconds=round(time.time() - t0), turns=turns)
    first = turns[0] if turns else {}
    # The learner has an answer: a reply they can read within the budget (the turn may keep working after it).
    r["first_reply"] = first.get("first_reply_seconds")
    r["answered"] = r["first_reply"] is not None or (bool(first) and not first["timed_out"] and first["chars"] > 0)
    r["tool_calls"] = sum(len(t["tools"]) for t in turns)
    r["tool_errors"] = sum(len(t["tool_errors"]) for t in turns)
    r["school_calls"] = sum(t["tools"].count("school") for t in turns)
    proj = (turns[-1] if turns else {}).get("project")
    r["project_made"] = bool(proj)
    if sc.get("seeded"):
        r["registered"] = bool(turns and (turns[0].get("project") or {}).get("registered"))
        r["passed"] = bool(proj and "pass" in proj.get("rounds", []))
        r["starter_untouched"] = all((d / "lab" / k).read_text() == v for k, v in sc["seed"].items() if not k.startswith(".teacher") and (d / "lab" / k).exists()) if len(turns) < 2 else None
    if args.judge and first.get("reply"):
        r["judge"] = judge(sc["turns"][0]["text"], first["reply"])
    return r

def main():
    names = [n for n in SCENARIOS if not args.only or any(o in n for o in args.only.split(","))]
    results = []
    with cf.ThreadPoolExecutor(args.jobs) as ex:
        for r in ex.map(run, names):
            results.append(r)
            print(json.dumps({k: v for k, v in r.items() if k != "turns"}), flush=True)
    OUT.mkdir(parents=True, exist_ok=True)
    (pathlib.Path(args.out) / ("bench-%s.json" % args.label)).write_text(json.dumps(results, indent=1, ensure_ascii=False))
    print("\n| scenario | answered | first reply s | turn s | tools | errors | project | registered | passed | judge |\n|---|---|---|---|---|---|---|---|---|---|")
    for r in results:
        t = r["turns"][0] if r["turns"] else {}
        print("| %s | %s | %s | %s%s | %d | %d | %s | %s | %s | %s |" % (r["name"], "yes" if r["answered"] else "NO", r["first_reply"] or "-", t.get("seconds", "-"), " (timeout)" if t.get("timed_out") else "",
              r["tool_calls"], r["tool_errors"], "yes" if r["project_made"] else "-", r.get("registered", "-"), r.get("passed", "-"),
              " ".join("%s %s" % (k[:4], v) for k, v in (r.get("judge") or {}).items())))

main()
