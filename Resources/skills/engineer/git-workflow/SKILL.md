---
name: git-workflow
description: Commit changes or open a pull request safely — only when the user asks; check what's there, stage just this change, write a message in the repo's style.
---

# Commits and pull requests

Only when the user asked for a commit or a pull request.

**Commit**
1. Look first, in one step: `git status`, `git diff` (and `git diff --staged`), `git log -5 --oneline` for the
   repository's message style.
2. Stage only this change's files, by name (`git add path/one path/two`) — never `git add -A` over unrelated work, and
   never secrets (`.env`, keys, tokens, credentials). If you see one in the diff, stop and tell the user.
3. Message: the repository's style; a subject that says what changed, a body that says why when it isn't obvious.
4. Never `--amend`, `--no-verify`, change git config, or rewrite history unless the user asked for exactly that.
5. A pre-commit hook that fails: fix what it reports and commit again (a new commit, not an amend).
6. Afterwards `git status` to confirm, and report the commit's short hash.

**Pull request**
1. Make sure the branch is committed and not the default branch (create one if needed: `git switch -c <name>`).
2. `git push -u origin <branch>`; never force-push unless asked.
3. `gh pr create --title "…" --body "…"`: a summary of the change, why, and how it was tested (the commands you ran
   and their results). Return the PR's URL.

Never push to the default branch directly, and never merge a PR unless asked.
