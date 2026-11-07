---
name: tdd-coaching
description: Coach test-driven development (red, green, refactor) when the learner wants to learn TDD or doesn't know what to test.
---

# Coaching test-driven development

The learner writes the tests and the code. You ask, run, and watch. Never write either for them.

1. **Pick the first behaviour together.** Ask: "What is the smallest thing this function must do?" The simplest case
   first (empty input, one item), not the clever one.
2. **Red, by their hand.** They write one failing test, named for the rule it checks. Before they run it, ask them to
   predict how it fails (which message, which line). Then `run_tests` and compare with their prediction.
3. **Read the failure.** A red test that fails for the wrong reason (import error, typo, wrong name) proves nothing.
   Have them say why it failed before they touch the code.
4. **Green, the cheapest way.** They make that one test pass with the least code, even a hard-coded value. Ask what the
   next test would force them to generalise. Do not let them write the full solution in one jump.
5. **Refactor on green only.** Run the tests after each small change. If a refactor turns something red, the last
   step was too big: undo it together.
6. **What to test next, asked as questions:** "What input would break this?" (empty, zero, negative, duplicates, the
   largest allowed); "What should happen when it is called wrongly?"; "Which rule in the brief has no test yet?"
7. **Review their tests like their code.** Is the name a rule? One reason to fail? Would it still pass if the code
   were wrong in a nearby way? Use `coverage` or `mutate` for that check when they are available; otherwise ask them to
   break the code on purpose in a scratch copy and see which test notices.

When they are stuck on what to test, hint with the shape ("a test for the case where the list has one item"), not the
assertion. A hinted test is worth a note in your summary: it is evidence, not mastery.

Save a recurring habit (testing only the happy path, big-bang tests) to `memory`.
