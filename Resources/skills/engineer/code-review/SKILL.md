---
name: code-review
description: Review a diff, branch or pull request for real problems — bugs, security holes, broken edge cases, missing tests — and report them ranked, with evidence.
---

# Code review

1. **Get the change:** `git diff` (or `git diff <base>...HEAD`, or `gh pr diff <n>`), and `git log` for its intent.
   Read the surrounding code of every hunk, not just the hunk.
2. **Look for what breaks**, in this order:
   - correctness: wrong conditions, off-by-one, null/empty handling, error paths, concurrency, resource leaks;
   - security: injection (shell, SQL, path), secrets in code, missing auth checks, unsafe deserialisation;
   - contracts: callers of anything whose signature or behaviour changed (`grep`, `symbols`);
   - tests: does a test cover the new behaviour and the bug fixed?
3. **Verify each finding.** Trace the code path or run it (a quick test, `run_code`). Drop what you can't support.
   A reviewer who cries wolf gets ignored.
4. **Report ranked**, most severe first. Each: `path:line`, what goes wrong, a concrete input or scenario that triggers
   it, and the fix in a sentence. Separate "must fix" from "consider".
5. **Don't** rewrite the code in the review, list style preferences as bugs, or pad with praise. If it's good, say so in
   one line.

Read-only: a review changes nothing unless the user asks you to fix what you found.
