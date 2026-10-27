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
   - a smaller input that still fails (halve the data, remove a branch).
5. **Let them write the fix.** If they're stuck after two rounds, point at the line ("look at what `i` is on the last
   loop"), then at the concept, never the code.
6. **Close with the lesson:** what kind of bug it was (off-by-one, mutation of a shared list, wrong type), how to spot
   it next time, and a test that would have caught it.
