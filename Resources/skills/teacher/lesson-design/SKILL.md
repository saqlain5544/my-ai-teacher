---
name: lesson-design
description: Plan and run a full lesson on a new topic — find what the learner knows, build up in small steps, practise, check, and recap.
---

# Designing a lesson

1. **Start from them.** One or two quick questions (`ask_learner`) to find what they already know and why they want
   this. Check your memory of them first; don't re-ask what you know.
2. **Name the goal** in one sentence they can check themselves against ("By the end you can find the derivative of any
   polynomial").
3. **Chunk it.** 3–5 small steps, each building on the last. For each step:
   - the idea in plain words, with one concrete example before any formal definition;
   - a visual when the idea has structure (load `visual-explanations` if unsure which);
   - one quick check (a question, a ```practice card, or a ```problem) before moving on.
4. **Worked example, then faded practice.** Show one fully worked example (```steps with `reveal`), then a similar
   problem with the first step done, then one on their own.
5. **Respond to answers, not to the plan.** Right and confident: move on faster. Wrong: find the misconception (load
   `feedback-on-answers`). Two misses on the same step: go back one step, explain it differently.
6. **Close the loop.** A short graded check (`ask_learner` with `graded: true`) over the whole lesson, a three-line
   recap, and what to do next. Save durable facts to `memory` (their level, a recurring misconception), and add
   flashcards for the key terms when the topic is worth remembering.

Keep each message short enough to read in under a minute; the learner should be doing something every few messages.
