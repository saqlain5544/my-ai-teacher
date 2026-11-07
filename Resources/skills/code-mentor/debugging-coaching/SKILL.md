---
name: debugging-coaching
description: Teach the learner to find a bug themselves — reproduce, form a hypothesis, test it with prints, a trace or a smaller case — instead of fixing it for them.
---

# Coaching debugging

The goal is a learner who can debug, not a fixed bug. Don't edit their files; guide them.

1. **Reproduce together.** Ask what they expected and what happened; run the failing test or snippet (`run_tests`,
   `diagnostics`) so you both see the same error.
2. **Read the error with them.** Have them find the line in the traceback that's in *their* code, and say in their own
   words what the message means.
3. **Hypothesis before change.** Ask: "What do you think is going wrong, and how could you check?" Accept any testable
   guess.
4. **Narrow it down**, one tool per step:
   - a print or assertion at the boundary (is the value right going in? coming out?);
   - `trace` (Python) to step through and watch variables — let them predict the next value before you reveal it;
   - `debug` (C, C++, Rust, Swift, Zig; load it with `load_tools`) to show what the compiled program really does — see
     "With a debugger" below;
   - a smaller input that still fails (halve the data, remove a branch).
5. **Let them write the fix.** If they're stuck after two rounds, point at the line ("look at what `i` is on the last
   loop"), then at the concept, never the code.
6. **Close with the lesson:** what kind of bug it was (off-by-one, mutation of a shared list, wrong type), how to spot
   it next time, and a test that would have caught it.

## With a debugger (`debug`)

A debugger shows the learner their program's real state; it is for confirming what they expect, not for finding the bug
for them. Predict first, look second.

- **Before every look, ask.** "What do you expect `count` to be when we get to line 12?" or "Which line do you think it
  crashes on, and what will that pointer hold?" Wait for the answer, then step or run and compare. A wrong prediction is
  the lesson: ask what in the code made it differ.
- **Pick where to stop together.** Ask which line or function they would look at, and why; a breakpoint with a condition
  (`file.c:12 if i == 3`) is the way to skip to the interesting iteration. You can suggest where to *start*, not where the
  bug is.
- **Crashes.** Before running `crash`, have them guess what kind it is (null pointer, bad index, recursion that never
  ends). Then read the signal's plain-words explanation with them and ask which of the locals up the stack looks wrong
  and why. The learner's frames are shown; library frames are hidden on purpose.
- **Stepping.** `next` for what a line does, `step` to enter a call (ask first: "will this call change `total`?"),
  `finish` to come back, `print` to test a guess about an expression. One question per stop; don't narrate every value.
- **Symbols.** If the tool says there is no debug info, tell them the build command it names (`clang -g -O0`, `cargo
  build` without `--release`, `swift build`, `zig build-exe -O Debug`) and have them rebuild; it is a build lesson too.
- **Don't reveal the fix.** The state and the signal are evidence; the repair is theirs. If they are stuck after two
  stops, ask about the one value that is off ("what is `n` here, and where was it last set?") rather than naming the line
  to change. Uninitialised locals show leftover garbage: say so, it is part of what they are learning.
- **Go** goes through `dlv` when installed (one scripted run, no stepper); lldb does not understand goroutines.
- End the session (`stop`) when the question is answered: one session per lesson, and it holds the program mid-run.
