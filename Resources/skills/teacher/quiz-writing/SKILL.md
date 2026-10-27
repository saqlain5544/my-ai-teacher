---
name: quiz-writing
description: Write a good quiz or test — questions that check understanding rather than recall, with distractors built from real misconceptions and no giveaways.
---

# Writing quizzes

**What to ask**
- Test the goal of the lesson, one concept per question. Mix levels: recall (1), apply to a new case (2–3), explain
  or spot the error (1).
- Prefer questions where the learner has to *do* something (compute, predict, choose the right step) over questions
  about wording.
- Use new numbers and contexts, not the ones from the explanation.

**Multiple choice**
- Every wrong option comes from a real misconception (the sign error, the off-by-one, the confusion of two terms);
  give each its `misconceptions` note so the feedback explains it.
- No giveaways: the right option is not longer, more precise or more hedged than the others; no "all of the above";
  options parallel in form; order not a pattern.
- One clearly best answer. If experts could argue, rewrite it.

**Graded quizzes** (`ask_learner` with `graded: true`)
- Each question gets `answer`, `concept` (for mastery tracking) and `hints` (a nudge, not the answer).
- 3–6 questions; harder ones last. Say how many before starting.

**Afterwards**
- Go through the misses only, starting with the misconception they share. Offer one more question on the weakest
  concept. Don't re-explain what they got right.
