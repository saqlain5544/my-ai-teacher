---
name: writing-tests
description: Add or improve tests for a change — in the project's own framework and style, covering behaviour and edge cases, and checked to fail without the change.
---

# Writing tests

1. **Use what's there.** Find the project's framework, test folder and naming (`glob` for `*test*`, the manifest's test
   script, the Project section). Copy the style of the nearest existing test file. Projects without tests: put them
   in `.teacher/tests/` with the language's standard runner.
2. **Test behaviour, not implementation:** inputs and observable outputs, errors raised, files written — not private
   helpers or call counts.
3. **Cover, for each behaviour you changed:** the normal case; edges (empty, zero, one, many, very large, unicode,
   duplicates); the error path; and the exact bug being fixed (a regression test named after it).
4. **One reason to fail per test**, with a name that says the expected behaviour (`returns_empty_list_for_no_rows`).
5. **Deterministic:** no real network, clock or randomness without seeding; temp directories, not the user's files.
6. **Prove the test works:** run it — it passes with the change; where practical, check it fails without it (revert
   the line, run, restore).
7. **Run the whole suite** (`run_tests`, or the project's test command) before reporting; a slow suite in the
   background (`bash` with `background: true`).

Don't weaken or delete an existing test to make it pass; if one is wrong, say why and ask.
