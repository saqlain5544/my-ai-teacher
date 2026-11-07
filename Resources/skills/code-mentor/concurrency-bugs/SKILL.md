---
name: concurrency-bugs
description: Coach a learner through race conditions, deadlocks and flaky async or threaded code — reason about interleavings, reproduce, then fix the cause.
---

# Concurrency bugs

These bugs hide when you look at them. Teach the learner to reason about what can interleave, not to add a lock until
it stops failing. They write the fix; you ask.

1. **Name the shared thing.** Ask: "What data is touched by more than one thread, task or callback? Who writes it?"
   If nothing is shared and mutable, the bug is probably elsewhere (ordering, a missing await).
2. **Draw two timelines.** Have them write two columns, one per thread, with the lines each runs. Then ask: "What if
   thread B runs between these two lines?" A ```steps or ```trace fence can show one bad interleaving once they have
   found it.
3. **Make it fail on purpose.** Flaky means rare. Increase the odds: more iterations, a `sleep` between the check and
   the use in a scratch copy, many workers, the race detector (`go test -race`, ThreadSanitizer, `-Xcheck`) run through
   `bash`. A bug they can reproduce is a bug they can fix. Save the failing run as a test if it can fail reliably.
4. **Classify it, asking not telling:**
   - check-then-act or read-modify-write without atomicity (a lost update);
   - a missing wait, await, join or flush (the result isn't ready);
   - lock ordering (two locks taken in different orders deadlock);
   - shared mutable state captured by a callback or closure.
5. **Choose the fix by the cause.** Ask what the lowest-cost fix is: don't share, make it immutable, send a message, hold a
   lock for the whole check-and-act, or use an atomic operation. "Why does adding a sleep appear to work?" is a good
   question to end on.
6. **Re-prove.** Run the repro many times (loop `run_tests`, or the race detector) and say how many runs convince
   them. Passing once proves nothing.

`trace` steps one sequential Python path, so use it for the logic around the bug, not for the race itself. When `debug`
is available, a breakpoint on each side shows the interleaving.

Never paste a fix. If they ask "just add a lock?", ask which two lines must not interleave and what the lock protects.
