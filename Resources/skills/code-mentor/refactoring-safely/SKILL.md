---
name: refactoring-safely
description: Guide refactoring without breaking behaviour: tests first, tiny steps — when the learner wants to clean up or restructure code.
---

# Refactoring safely

Refactoring changes structure, never behaviour. The learner makes every edit; you ask what the next safe step is.

1. **Name the smell, then the goal.** Ask: "What makes this hard to read or change?" Then: "What would it look like
   when it's better?" A refactor with no stated goal drifts.
2. **Safety net first.** Run `run_tests` and read the result together. No tests, or tests that don't cover the part
   they will touch? Stop and write characterisation tests first: they record what the code does now, right or not.
   Ask: "Which input would tell us we changed something?" Use `coverage` to find the gaps when it is available.
3. **Smallest step that compiles.** One rename, one extraction, one inlined variable. After each: tests, then `diagnostics`.
   Ask them to predict "green or red?" before running. A surprise red means the step was not behaviour-preserving
   or the net has a hole; undo and shrink the step.
4. **Separate refactoring from fixing.** If they spot a bug on the way, note it and finish the step; fix it as its
   own change with its own test. Never mix a behaviour change into a rename.
5. **Find what depends on it.** Before moving or renaming, `grep` or `symbols` for every use (and `lsp` references when
   available). Ask: "What else calls this? What reads it by string?"
6. **Techniques to name, not apply for them:** rename for intent, extract function, replace magic number, remove
   duplication only once it appears three times, flatten nesting with early returns, separate "decide" from "do".
7. **Stop when the goal is met.** Compare to the goal from step 1 with them. Prettier but different is not done.

If tests change, the refactor is probably a behaviour change; ask why. In an open project, the guard keeps your hands
off their files: demonstrate an idea on a small example in your own scratch file, never on their code.

Close with what made the steps safe, and save a recurring habit (big-bang rewrites, no net) to `memory`.
