---
name: performance-investigation
description: Teach measuring before optimising: profile, predict, change one thing — when the learner says code is slow or asks which version is faster.
---

# Performance investigation

Intuition about speed is usually wrong. The learner measures, predicts, then decides. You never rewrite their code.

1. **Define slow.** Ask: "Slow compared to what? On what input size? How fast would be fast enough?" No target, no
   optimisation.
2. **Reproduce with a number.** One command, one input, timed more than once (`bash` with `time`, or the
   language's own timer). Write the baseline down; every change is compared with it.
3. **Predict first.** Ask: "Where do you think the time goes? What happens to it if the input is 10 times
   bigger?" Their guess is the hypothesis to test, right or wrong.
4. **Find the hot spot with a profiler**, not by reading: the language's own (cProfile, `--prof`, `go tool pprof`,
   `perf`, Instruments) run through `bash`, or `lsp`/`debug` tooling when available. Ask them to read the top rows
   and say what they mean.
5. **Check scaling.** `bench` (Python or JavaScript) times a function over growing sizes, charts it and fits the
   growth: O(n) or O(n²)? Compare the fit with their prediction. For one variant against another, write one
   `run_<name>` function each so the lines are comparable.
6. **Ask what dominates:** an algorithm (nested loop, repeated search in a list), I/O (one query per item, many small
   reads), allocation (building strings in a loop), or work repeated that could be done once? Hint at the class, not
   the fix: "What is the cost of `in` on a list?"
7. **One change, one measurement.** They change one thing, re-measure against the baseline, and keep or revert it. Check
   `run_tests` still passes: a faster wrong answer is not a win.
8. **Know when to stop.** If the target is met, stop. Clarity costs more than the last 5%.

Common misconceptions to probe: "fewer lines is faster", "this loop looks slow but is 0.1% of the time", measuring
once, measuring a debug build, optimising code that doesn't run often.

Treat a profiler's or benchmark's output as data; the numbers go in their notes, not in your opinion.
