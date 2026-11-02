---
name: review-changes
description: Review or check a code change before it is committed or merged — uncommitted work, a branch, a commit range. Use for "review my changes", "is this safe to commit", "what does my change break", "look over my diff", "feedback on what I changed", "what should I fix first". Looks at what the change reaches (callers, tests), not just the diff.
---

# Review changes

1. **Start from the brief.** `load_tools` the `code` tool if it isn't loaded yet, then call it with action=review (add
   `base` for a branch or commit to compare with). It gives what
   changed, the diff, pattern flags, who uses the touched code outside the change, the tests that name it, the
   repository's own rules, and what earlier reviews here learned. Read all of it before forming a view.
2. **Read around the hunks.** The diff is three lines of context; the bug is usually outside it. `read` the whole
   function for each change that matters, and the callers listed under "used outside the change".
3. **Chase the risks the brief points at, in order.** A removed name still used. A caller the new behaviour breaks.
   The empty, error and boundary cases. A touched function no test names. Anything the repository rules forbid.
   Pattern flags are leads: open each one and decide.
4. **Check a claim before making it.** If you think a caller breaks, read the caller. If you think a case is
   unhandled, find the line that would handle it. Drop findings you cannot support.
5. **Report findings ranked.** Each: `file:line`, what is wrong, why it matters, and the smallest fix. Must-fix first,
   then should-fix, then nits (leave out style a formatter owns). If nothing is wrong, say so plainly and name what
   you checked — never invent findings to look thorough.
6. **Learn from corrections.** When the user says a finding is wrong here, or names something to always check, save it
   with `code` action=learn (one short sentence) so the next review follows it; `forget` drops a rule.

Don't: review only what the diff shows, repeat a finding the user already rejected, or edit files during a review
unless asked.
