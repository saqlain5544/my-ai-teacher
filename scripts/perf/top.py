#!/usr/bin/env python3
"""Text view of a run's CPU samples: heaviest self and inclusive frames per process kind and workload.

    scripts/perf/top.py RUN_DIR [--workload lesson] [--kind WebContent] [--n 30] [--grep regex]
"""
import argparse, json, pathlib, re
from collections import Counter, defaultdict

ap = argparse.ArgumentParser()
ap.add_argument("run_dir"); ap.add_argument("--workload"); ap.add_argument("--kind"); ap.add_argument("--n", type=int, default=30)
ap.add_argument("--grep", help="also print the heaviest callers of frames matching this")
a = ap.parse_args()
d = json.loads((pathlib.Path(a.run_dir) / "data.json").read_text())
st, w = d["stacks"], next((x for x in d["workloads"] if x["name"] == a.workload), None)
by = defaultdict(lambda: (Counter(), Counter(), [0.0]))
for t, kind, th, sid, ms in st["samples"]:
    if (w and not w["t0"] <= t <= w["t1"]) or (a.kind and kind != a.kind): continue
    s, inc, tot = by[kind]
    frames = st["stacks"][sid]
    s[frames[-1]] += ms; tot[0] += ms
    for f in set(frames): inc[f] += ms
for kind, (s, inc, tot) in sorted(by.items(), key=lambda kv: -kv[1][2][0]):
    print(f"\n=== {kind}: {tot[0]:.0f} ms of samples")
    print("-- self");      [print(f"{v:9.0f}  {f[:160]}") for f, v in s.most_common(a.n)]
    print("-- inclusive"); [print(f"{v:9.0f}  {f[:160]}") for f, v in inc.most_common(a.n * 2)]
    if a.grep:
        callers = Counter()
        for t, k, th, sid, ms in st["samples"]:
            if k != kind or (w and not w["t0"] <= t <= w["t1"]): continue
            fr = st["stacks"][sid]
            for i, f in enumerate(fr):
                if re.search(a.grep, f): callers[" ← ".join(reversed(fr[max(0, i - 6):i + 1]))] += ms; break
        print(f"-- paths into /{a.grep}/"); [print(f"{v:9.0f}  {p[:400]}") for p, v in callers.most_common(12)]
