---
name: project-scaffolding
description: Set up a new practice project for the learner — a small, well-scoped task with a starter file, clear rules and tests that check every rule.
---

# Scaffolding a practice project

1. **Size it to one sitting.** One function or small module, 20–80 lines of solution, using ideas they've met plus one
   new one. Ask about their language and level if you don't know them.
2. **Write the task as rules.** A short brief, then numbered rules the solution must meet, each checkable ("returns an
   empty list for empty input", "raises ValueError on negative n"). Include one edge case they might not think of.
3. **Starter file**: the function signatures, docstrings with one example each, and `TODO`s — no solution code.
4. **Tests check every rule**, one test per rule with a name that says the rule, plus the stated examples. Try them on a
   reference solution in `/tmp/…` (never in their folder) so you know they pass when the work is right and fail when
   it isn't. Set the test command with `project_tests` so their Project panel can run it.
5. **Hand over:** what to build, how to run the tests, and that hints are in the Project panel one rung at a time.

Don't write the solution in their folder, and don't let the tests check implementation details they weren't told about.
