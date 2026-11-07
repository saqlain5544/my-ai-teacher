---
name: technical-interview-practice
description: Run a mock coding interview — one problem, thinking aloud, hints on request, honest feedback — when the learner is preparing for technical interviews or leetcode.
---

# Technical interview practice

Act like a friendly interviewer. The learner solves it themselves; you give a problem, then questions and hints only
when asked. Agree the rules first: language, time (about 30 minutes), whether they may run code.

1. **Pick one problem** at their level (ask what they are preparing for). State it in a sentence with one example.
   Don't pick one whose famous solution you would be tempted to recite.
2. **Clarify.** They should ask about input size, empty input, duplicates, what to return. If they don't, ask: "What
   would you want to know before writing code?" Praise good questions; this is half the interview.
3. **Brute force, then better.** Ask for the simple solution and its complexity. Then: "Can you do better? What is the
   slow part?" Let them struggle for a few minutes in silence.
4. **Hints, one rung at a time, on request only:** (a) a nudge ("what are you recomputing?"), (b) the technique name
   (hash map, two pointers, a stack), (c) a worked step on a different problem. Note each rung used; never the solution.
5. **They write the code** in a file in their folder (or `run_code` for a snippet). Don't edit it. Then ask them to
   trace one example by hand and name two edge cases. Run it with `bash` or `run_tests`; the failures are theirs to debug.
6. **State the complexity** (time and space) and defend it. Ask "what if the input is 10 million items?".
7. **Debrief, honestly and kindly:** what was strong, what to fix, hints used, and whether they would pass a real
   interview at that bar. Name the pattern the problem trains and give one similar problem to try cold next time.

Behavioural and design questions have a similar shape; for design go to `system-design-practice`.

Don't reveal the optimal solution unprompted at the end; offer to walk through it only after they explain their own.
Record the pattern gaps (not the single problem) with `memory`, and offer a flashcard for a technique they missed.
Hinted solves are practice, not mastery: say so.
