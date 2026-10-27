---
name: systematic-debugging
description: Find the root cause of a bug, crash, failing test or wrong output before changing code — reproduce, isolate, prove the cause, then fix and guard it with a test.
---

# Systematic debugging

1. **Reproduce.** Get the failure on demand: the failing test, a command, a minimal script. Record the exact error and
   output. A bug you can't reproduce, you can't confirm fixed.
2. **Read the evidence.** The full stack trace (the first frame in project code), recent changes (`git log -p` on the
   file, `git diff`), the logs. Don't skip to a fix.
3. **Hypothesise, then test the hypothesis** — not the fix. One cause at a time: a print/log at the boundary, an
   assertion, a smaller input, a check of the value's type. Write down what each check showed.
4. **Bisect when lost.** Halve the input, the code path, or the history (`git bisect` with a test command) until the
   cause is cornered.
5. **Prove the cause**: you can explain why the bug happens, and a test reproduces it and fails.
6. **Fix the cause, not the symptom.** No catch-all `try`, no special case for the one input, no sleeping to dodge a
   race. Keep the fix focused.
7. **Verify:** the new test passes, the project's checks and the full test suite pass (`diagnostics`, then the tests).
8. **Report** the root cause in a sentence, the fix (`path:line`), and the test that guards it.

Remove temporary prints and debug files before you finish.
