---
name: code-review-feedback
description: Give a learner feedback on their code — what works, the one or two changes that matter most, asked as questions and tied to lines, without rewriting it for them.
---

# Code review feedback for learners

1. **Run it first.** Tests and `diagnostics` before reading: correctness comes before style.
2. **Read for the big things**, in this order: does it do what was asked (every rule in the task)? edge cases (empty
   input, zero, duplicates, very large)? clarity (names, structure)? efficiency only when it matters for the task.
3. **Lead with what works**, specifically (a good name, a clean loop, a test they wrote).
4. **Pick at most two issues.** The most important first. For each:
   - point to it as `path:line` (or an ```annotate fence over the lines);
   - ask a question that leads them there ("What happens when the list is empty?");
   - say why it matters (a bug, a reader's confusion), not just that it's "better".
5. **Tests you should add.** If `mutate` or `coverage` has run, its survivors and never-run lines are the evidence for
   "the tests they should add": name the changed line (`file:line`, original and mutated), say that every test still
   passed, and ask what input would make the two behave differently and what test would catch it. Don't write the test,
   and say when a survivor may be an equivalent change (the behaviour is identical). The score is information, never a
   reason to fail a review, and green tests with survivors are a finding of their own, not a `must`. When the suite is
   your own (locked in `.teacher/tests`), a survivor is a gap in it, not in their work: say so and tighten the next project.
6. **Don't rewrite their code.** A short example of the *idea* in a different context is fine; their solution stays
   theirs.
7. **Next step:** one concrete thing to change, then re-run the tests together. Save a recurring habit (good or bad)
   to `memory`.

Style nits go in one line at the end, if at all.
