# Giving mentors a progress tracker: a course board, not a Jira board

**Question.** Should mentors get a kanban board (or another progress tracker) that they create, refine and update,
so they keep their state when the learner steers them away for a few replies?

**Short answer.** Yes — but build a **course state board** first, not a full drag-and-drop kanban. The valuable
parts are a small, stable state machine (one focus card, a parked lane, evidence-gated completion), a
**compact app-generated state header injected at the end of every request**, and a learner-visible board view.
A literal kanban UI is a good eventual view; it is a poor first *mechanism* on its own, because a board the mentor
must remember to read is another thing the mentor can forget.

This report is research and testing only: no product code was changed. The reference prototype is
[`board_model.py`](board_model.py), the UI sketch is [`board-mockup.html`](board-mockup.html), and the raw pilot
outputs are in `/tmp/mentor-board-research/` (not committed).

---

## 1. What state are we actually managing?

A mentor has three layers of state, and they fail differently:

| Layer | What it holds | Where it lives today | Failure mode |
|---|---|---|---|
| Learner model | Goals, level, preferences, misconceptions, mastery | `memory` + `mastery` (SQLite, cross-lesson) | Slow to update; not a plan |
| Lesson state | What was said, attempts, hints, exercises | Transcript + compaction summary | Compaction loss, context rot |
| Course / intent state | Why we are here, what is next, what is parked, what counts as done | `lesson_plan` + a one-line prompt summary | Fragmented, stale, not recency-injected |

The learner model is *what the mentor believes about the learner*. The course board is *what the mentor intends to do
next*. Conflating them is the main design trap: a board is not a second mastery store, and mastery is not a plan.

In tutoring-system terms (VanLehn's two loops), the transcript handles the **inner loop** (step-level help) and the
board handles the **outer loop** (task selection and sequencing). McLaren's recent "third loop" argument is a useful
warning: the *form* of instruction (explain, practice, quiz, project, review) is also a runtime variable. A card should
therefore be able to say not only *what* is next but *how* it should be taught — at least as an optional field.

## 2. Why the current app loses state

The app already has more state machinery than it looks: `lesson_plan`, `todo_write`, `mastery`, follow-ups,
DeepWork's per-turn plan, and compaction. The problem is where each sits in the request.

### 2.1 The active plan is a headline, not a state

`TeachingContextExtension` adds a plan summary to the system prompt: title, id, `done/total`, and the next module's
title — one line per plan, at most three plans (`Sources/MyAITeacher/Extensions/MemoryExtension.swift:167-177`).
The full module list, objectives, notes and ordering reach the model only when the plan is created or updated (the
tool result carries the plan) or when it calls `lesson_plan get`; there is no per-turn injection. The tool is deferred
(`Sources/MyAITeacher/Agent/ToolRegistry.swift:10-12`), so it is also not in the schema list until loaded. A learner
detour does not even need to be long for the detailed plan to be out of sight.

### 2.2 The system prompt is frozen at the first turn

`ChatSession.loop()` builds the system prompt once and caches it (`Sources/MyAITeacher/Agent/ChatSession.swift:306`);
`systemPromptSections` are evaluated at that moment (`:664`). That is deliberate for prompt caching, but it means a
plan created or changed mid-lesson is **not** reflected in the system prompt. The model has to rediscover it from the
transcript or a tool call. The one-line plan summary is a snapshot taken before the lesson's own work happened.

### 2.3 Microcompaction truncates the plan tool result

`ContextPolicy.stubLimit = 1_200` (`Sources/MyAITeacher/Agent/ContextPolicy.swift:11`). Once a trim epoch passes an
old tool result, its text is cut to roughly 800 characters of head + 400 of tail (`:156-174`). In a temporary test with
a 3,269-character, 12-module plan, the request copy became 1,279 characters and **module 7 was gone**. The head kept the
title and the first modules; the tail kept the end; the middle disappeared. The model sees a plausible-looking plan
with missing modules — worse than seeing no plan, because it may not notice.

### 2.4 Summary compaction can erase the plan entirely

When the lesson passes its context budget, the prefix is replaced by an LLM summary
(`Sources/MyAITeacher/Agent/ChatSession.swift:682-737`). The summary prompt asks for Goal / What was covered /
Learner's understanding / Exercises & results / Decisions & preferences / Files & artifacts / Next steps
(`:711-715`). Those are good headings, but **there is no field for the active plan, focus card, parked items, or
evidence**. The plan tool result is removed with the prefix. In the test, after compaction the plan was gone and only
"Covered: limits. Next steps: continue the plan." remained. Anthropic's own long-running-agent work found the same
class of failure and fixed it with a structured feature list plus a progress file; LangChain's Deep Agents team added
dedicated "session intent" and "next steps" fields to its summary prompt after observing post-summary goal drift.

### 2.5 Updates are full-list replacements, and they are lossy

`lesson_plan action="update"` replaces the entire `modules` array (`Sources/MyAITeacher/Tools/TeachingTools.swift:138-146`).
There are no stable card ids, no per-card moves, no revision. A model that wants to mark one module done must re-emit
the whole list; if it omits a module or its objectives, they are gone. In the test, updating "Limits" to done with a
one-module array left a one-module plan and dropped the other two modules' objectives. This is exactly the kind of
rewrite that long-context models get subtly wrong.

### 2.6 The checklist is ephemeral and UI-only

`todo_write` returns text and nothing else (`Sources/MyAITeacher/Tools/TeachingTools.swift:314-338`). The last call is
mirrored into `ChatSession.todos` for the UI (`ChatSession.swift:30,70,497`), but there is no persisted checklist
and no per-turn injection. It survives only while the tool result is in the transcript. It is a fine scratchpad for a
single multi-step task; it is not course state.

### 2.7 Plans are global, and "continue this plan" is thin

`StudyStore.plans()` returns every plan with no conversation filter (`Sources/MyAITeacher/Study/StudyStore.swift:368-381`).
That is reasonable for a learner-wide curriculum, but it means a plan made in lesson A is visible in lesson B with no
explicit link. The Progress screen's "Continue this plan" opens a new lesson with only the title and plan id in the
prompt (`Sources/MyAITeacher/UI/StudyViews.swift:429-431`). The new lesson must call `lesson_plan get` to see the
modules; otherwise it sees only the one-line summary. This is the cross-lesson version of the same failure.

### 2.8 DeepWork's plan is per-turn, not durable

DeepWork writes a hidden plan into the user message for that turn (`Sources/MyAITeacher/Agent/DeepWork.swift:24-83`;
inserted at `ChatSession.swift:327`). It is useful for one substantial reply, but it is not a course plan and it is
subject to the same trim/compaction rules.

### Measured effect

A temporary XCTest suite (added for the research, removed afterward) confirmed the mechanics:

| Check | Result |
|---|---|
| 3,269-char plan through a trim epoch | 1,279 chars; module 7 absent; a stub notice appears |
| Plan after summary compaction | Plan gone; only the summary text remains |
| `lesson_plan update` with one module | 1 of 3 modules remains; objectives lost |
| Plan made in lesson A from lesson B | Visible (`plans()` is global) |
| Compact 3-card header vs 30-card full board | ~88 tokens vs ~582 tokens (app's chars/4 estimate) |

The full existing suite is green: **264 tests, 3 skipped, 0 failures**.

## 3. Options, compared

Scored 1–5; higher is better except "cost", where higher means more expensive.

| Option | Persists across turns | Handles detours | Learner visibility | Evidence integrity | Model/tool simplicity | Implementation cost | Verdict |
|---|---:|---:|---:|---:|---:|---:|---|
| Status quo (transcript + one-line plan) | 3 | 1 | 3 | 2 | 5 | 1 | Fails after compaction |
| Persistent flat checklist | 4 | 2 | 3 | 1 | 5 | 1 | Better, but no structure or focus |
| Upgraded syllabus/outline | 4 | 2 | 4 | 2 | 4 | 2 | Good skeleton; weak live position |
| **Course board (3–4 lanes + focus + parked)** | **5** | **5** | **5** | **4** | **3** | **3** | **Recommended** |
| Goal stack (push/pop on detour) | 4 | 5 | 1 | 1 | 4 | 2 | Excellent detour primitive; no overview |
| DAG / prerequisite graph | 5 | 3 | 4 | 3 | 2 | 5 | Best sequencing; overkill now |
| Markdown state file (`NOTES.md`) | 5 | 3 | 3 | 2 | 4 | 2 | Flexible but unstructured; file-tool exposure |
| Analytics dashboard (mastery/activity) | 2 | 1 | 5 | 4 | 5 | 3 | Reports, doesn't steer |

**Recommendation: a hybrid.** The board gives the overview and learner visibility; the goal stack is the internal
mechanism for a detour (park → answer → resume); the state header is the delivery mechanism. A full DAG can come later
as `after` links on cards; it does not need a graph database now.

Why a literal kanban is not the first move:

* A board with columns but no injected state is still invisible to the model when it matters.
* Kanban's value is WIP limits and flow; a tutor's main risk is **losing the thread**, not parallel work.
* The app already has a plan card and a Progress plan view; a second, competing planning surface would confuse both the
  model and the learner. Codex recently made `update_plan` opt-in, and the related issue describes the failure mode:
  a host with its own planning surface ends up with two competing ones.
* Columns are the easy part; stable ids, evidence and a return path are the hard part.

## 4. The proposed design: a course board + a state header

### 4.1 Objects

One board per course/goal, attached to a lesson via `Conversation.boardID` (optional, cross-lesson). A board has:

```
goal, subject, deadline?, focus_id, revision, cards[], log[], updated_at
```

A card has:

```
id (stable, c1…), title, lane (backlog|doing|review|done|parked),
next (one concrete action), objectives[]?, after[]?, concept?,
evidence[]?, note?, source (mentor|learner|app), updated_at
```

The persisted shape (versioned inside `plans.data`, so no migration table is needed yet):

```json
{
  "version": 2,
  "goal": "be ready for the Calculus I final",
  "subject": "Calculus I",
  "deadline": "2026-11-03",
  "focus": "c1",
  "revision": 7,
  "cards": [
    {"id": "c1", "title": "Limits and continuity", "lane": "doing",
     "next": "three one-sided-limit problems, then a continuity check",
     "objectives": ["graphical limits", "one-sided limits", "continuity"],
     "concept": "one-sided limits", "evidence": ["graphical limits 4/5"]},
    {"id": "c2", "title": "Derivatives", "lane": "backlog", "after": ["c1"],
     "objectives": ["power/product/quotient rules", "chain rule"]},
    {"id": "p1", "title": "Why does 0.999… equal 1?", "lane": "parked",
     "note": "learner tangent, answered; return if limits come up again"}
  ],
  "log": [
    {"rev": 7, "at": "2026-10-22T09:14:00Z", "actor": "mentor",
     "event": "park", "card": "p1", "note": "answered in one line; not part of the course"}
  ]
}
```

Lanes:

* **Backlog** — ordered; `after` links express prerequisites.
* **Doing** — exactly one focus card (WIP = 1). Its `next` is the concrete next action, not a topic.
* **Review** — retrieval/transfer checks, fed by follow-ups and mastery; does not consume the WIP slot.
* **Done** — requires evidence; archived after a while.
* **Parked** — tangents and blockers, with a reason. This is the lane that makes detours safe.

Why these lanes: backlog → doing → done is the minimum useful kanban; review maps to the app's existing spaced
repetition and transfer checks; parked is the specific answer to "the learner steered me away for a few replies".
Blocked is a tag (`after` unmet, or `note` with a blocker) rather than a separate lane, so the board stays small.

### 4.2 Transitions (the tool contract)

Evolve `lesson_plan` rather than adding a third planning tool. Keep `create`/`get`/`list`/`update` working, and add:

| Action | Input | Rule |
|---|---|---|
| `add` | title, lane?, next?, objectives?, after? | New id, appended log |
| `start` / `focus` | id | WIP=1; error names the current focus |
| `park` | id, reason | Reason required; clears focus if it was focused |
| `resume` | id | Only parked cards; sets focus |
| `complete` | id, evidence | Evidence required; moves to done |
| `note` | id, text | Appends to the card and the log |
| `move` | id, lane, position? | Generic; still enforces WIP/evidence |
| `get` | id? | Full board as Markdown + `meta.board` JSON |
| `update` | id, modules? | Legacy full-list form; converts to cards |

Every mutation increments `revision` and appends `{revision, at, actor, card, from, to, note}` to a capped log.
The log is the board's history; it is what survives when the transcript is summarised, and it is what makes
"what happened while we were away?" answerable. It also gives the reflection pass something concrete to work with.

Validation is the feature, not red tape:

* `start` of a second card fails with: "C1 is doing. Park it, complete it, or pass `replace: true`."
* `complete` without evidence fails with: "Say what evidence shows this is done — a quiz score, an exercise pass, a
  correct explanation."
* `park` without a reason fails: a parked item with no reason is just a lost item.
* `update` with an empty modules array fails rather than wiping the course.

Example calls:

```json
{"action": "add", "title": "Why does 0.999… equal 1?", "lane": "parked",
 "note": "learner tangent; answer briefly, return if limits come up"}
```
```json
{"action": "complete", "id": "c1",
 "evidence": "3/3 one-sided-limit problems unaided, including a jump discontinuity"}
```

A detour normally creates a **parked** card; it does not move the focus. That is the difference between answering a
tangent and abandoning the lesson. The response to a mutation is the updated compact state header, not the full board.

The prototype in [`board_model.py`](board_model.py) exercises these invariants (WIP, evidence, park/resume, log).

#### 4.2.1 What the mentor does, turn by turn

* **Start a course.** Create the board with 4–8 cards: diagnostic, the modules in order, and a review card. Set the
  first focus and its `next` as a concrete action ("solve three one-sided-limit problems"), not a topic ("limits").
* **A normal turn.** Read the state header; answer from `Focus`; end with the next action or a question. If the learner
  completes the action, call `complete` with evidence before moving on.
* **A detour.** Answer the learner's question. If it is worth returning to, `add` a card in `parked` with a one-line
  reason; the focus does not move. If it is a prerequisite gap, `note` the blocker on the focus card and add a
  remediation card. Then return to `Focus` in the same reply or the next one.
* **A plan change.** Call `move`/`start`/`add`; never silently change the plan in prose. The tool result gives the new
  header, so the next step is consistent.
* **End of lesson.** Update the focus's `next` to the exact first action for next time; leave the rest of the board
  alone. The app writes the resume brief from the board, not from the transcript.
* **New lesson.** The board resumes; the mentor gets `mode="resume"` with last time, focus, next and parked. It does
  not need to ask "where were we?".

This is deliberately a small number of operations. A mentor should spend its effort on teaching, not on board
administration; if it is writing more than a few board calls per lesson, the granularity is too fine.

### 4.3 The state header (the important part)

The board alone is passive. Every request should end with a compact, app-generated state header, appended to the last
user message **only in the request copy** (never stored in the transcript):

```xml
<lesson_state rev="7" source="app">
Course: Calculus I — final in 12 days
Focus: C1 Limits and continuity (doing)
Next: three one-sided-limit problems, then a continuity check
Then: C2 Derivatives (after C1)
Parked (2): Python list mutation; laptop advice
Open loop: awaiting the attempt at lim x→2⁻ |x-2|/(x-2)
Watch: one-sided limits (2 misses); hint rung: targeted hint
Evidence: graphical limits 4/5; one-sided limits 3/3 unaided
</lesson_state>
```

Measured cost: **103 tokens** in the prototype with the open loop and watch fields; **47 tokens** for a 30-card board
without them. The full 30-card board is **446 tokens**. The header should be capped (say 200 tokens) and carry only
facts; the usage rules belong once in the system prompt:

> The `<lesson_state>` block is generated by the app, not the learner. It is authoritative for what we are doing.
> Start each reply from Focus and Next. If the learner detours, answer it, park it if it is worth returning to, then
> return to Focus. Never mark a card done without evidence. If the plan changes, update the board; do not keep a
> private plan.

Why this shape works:

* **Recency.** It sits at the tail, after the learner's words, where attention is strongest. The "lost in the middle"
  result and Manus's `todo.md` recitation both point the same way: restate the objective at the end, not only at the
  start.
* **Goal drift.** The goal-drift evaluation found that agents drift most when they must switch back after pursuing
  another goal, and that strong goal elicitation reduces it. A focus/next/parked block is a constant, concrete
  elicitation; a one-line system prompt summary is not.
* **Post-compaction survival.** It is generated from the board's database row, not reconstructed from the transcript.
  Compaction can discard the plan tool result; the header still knows the focus and next action.
* **Cache-friendly.** Appending to the last message preserves the prefix (the system prompt, tools, and earlier turns).
  Rebuilding the system prompt every turn would change the prefix and defeat prompt caching. The header is a suffix,
  not a prefix.
* **Cheap.** ~100 tokens per turn is ~5,000 tokens over 50 turns — about 1–2% of a 400k budget, and a fraction of the
  plan text it replaces. At a 64k budget it is ~8%, which is why the cap matters; it still buys more than it costs.
* **Truthful.** It is generated by the app from the board and observed state, not written by the model. The model can
  still be wrong, but the state block is not another hallucination surface.

"Open loop" and "watch" should be **observed** where possible, not self-reported: the pending `ask_learner` question,
the last `problem` fence awaiting an attempt, the hint/solution the learner opened, the latest mastery deltas. The app
already has these signals (`InteractionCenter`, transcript components, `studyNotes`, `StudyStore`). This is the part
that makes the header a *mentor state card*, not just a task list.

#### 4.3.1 The mentor state card versus the board

It helps to separate two things that are easy to conflate:

| | Course board (durable) | Mentor state card (per request) |
|---|---|---|
| Owner | Mentor, via the tool | App, generated |
| Lifetime | Whole course, across lessons | One request |
| Content | Goal, cards, focus, next, parked, log | Focus, next, then, parked, open loop, watch, evidence |
| Purpose | Remember the plan | Put the plan in the model's attention now |
| Mutability | Explicit moves, revisioned | Recomputed from board + observed state |

The board is the source of truth for intent. The card is the projection of that intent into the model's working
memory, enriched with observed signals the mentor should not have to remember (the pending question, the hint rung,
the last mastery delta). If the board is stale, the card is stale; that is why the board's revision and log matter.
If the card is omitted, the board still exists but the model may not use it; that is why automatic injection matters.

This also answers "manage the state of mentors efficiently": the mentor should not have to spend turns re-reading its
own plan or asking the learner "where were we?". The app should hand it a fresh, small, truthful state card at the
point of generation, and let the transcript hold the detail.

Full board retrieval is explicit: `lesson_plan get` returns the whole board, and a mutating call returns the updated
compact header. Do not inject the full board every turn.

### 4.4 Compaction

Add a short board section to the summary prompt (and to the deterministic digest fallback):

```
Active course state (preserve verbatim):
<lesson_state>…</lesson_state>
```

Even with the header re-injected every turn, this is useful for the summary itself, for a new lesson resumed from a
summary, and for the reflection pass. It is a small change to `ChatSession.compactIfNeeded` and `ContextPolicy.digest`;
it does not require the board to be re-read from the transcript.

### 4.5 Cross-lesson resume

A new lesson linked to the board should get a **resume brief**, not just a title:

```
<lesson_state mode="resume">
Course: Calculus I — final in 12 days
Last time: graphical limits passed; one-sided limits 2 misses.
Focus: C1 Limits and continuity
Next: three one-sided-limit problems, then a continuity check.
Parked: Python list mutation; laptop advice.
</lesson_state>
```

This is the same renderer, with a different header line. It replaces the current "Continue this plan" prompt that only
mentions title and id. The Progress screen's button becomes a one-click resume that sets `boardID` and opens the lesson.

### 4.6 UI

* **Inspector tab "Plan"** (alongside Files / Exercise / Changes / Agents): four columns + a parked drawer. The focus
  card is visually dominant; the next action is a sentence, not a title. The board is visible while chatting, so the
  learner can see where they are.
* **Strip above the composer**: `Focus: Limits — next: 3 one-sided problems · 2 parked · 12 days to final`. One click
  opens the inspector. This is the at-a-glance view; the full board does not need to occupy chat space.
* **Transcript card**: extend the existing plan card (already in the working tree) to render lanes, focus and evidence.
  Collapse it after the turn; the learner can expand it.
* **Progress screen**: show the board's focus, next, parked count and progress, not only a progress bar. Keep the
  existing "Continue this plan" but make it a resume with the brief.
* **Learner actions**: park a question ("save for later"), request a check ("I think I know this"), add a note. Do not
  let the learner mark a card done; let them ask for a check, which becomes a quiz/transfer item. This keeps the
  evidence rule intact while preserving agency.
* **Accessibility**: status is text + icon, not colour alone; keyboard moves for cards; the strip is readable at narrow
  widths.

### 4.7 Automatic evidence and review

The board should consume the app's existing evidence rather than compete with it:

* A graded `ask_learner`/`quiz` answer on a card's `concept` appends evidence (and a timestamp) but does **not** move
  the card. The mentor decides.
* An `exercise check` pass/fail appends evidence. A pass is strong evidence; a fail is a blocker note.
* A due follow-up (`recheck`, `transfer`, `missed`) creates or refreshes a **Review** card. This is how the board stays
  connected to spaced repetition.
* Completing a card with low mastery is allowed but flagged: "done by evidence; mastery 0.62 — review card scheduled."
  The board is intent; mastery is belief. The flag surfaces the gap instead of hiding it.
* A card's `concept` links to `mastery`, but the board does not store a mastery percentage (it would go stale).

### 4.8 Multi-mentor / sub-agents

Start with **one writer**: the main mentor. Sub-agents get a card's brief and return evidence; they do not write the
board. If multiple mentors or sub-agents need to work in parallel later, add `assignee` and use the board revision for
optimistic concurrency: a mutation includes the revision it saw; a stale write is rejected with the current state.
Swimlanes per mentor are a UI concern, not a v1 data concern. The course board is the shared blackboard; a mode switch
does not create a new board.

## 5. Testing plan and what the first tests showed

### 5.1 What was run

* **Existing suite:** `swift test` → 264 tests, 3 skipped, 0 failures.
* **Temporary research tests (removed):** four tests for plan truncation, summary loss, lossy update, global scope,
  plus a header-cost measurement. They used the real `ContextPolicy`, `StudyStore` and `LessonPlanTool`.
* **Reference prototype:** `python3 research/board_model.py` → header 103 tokens (with open loop/watch), 30-card full
  board 446 tokens, WIP/evidence invariants enforced.
* **Live pilot:** one short synthetic lesson, `deepseek-ai/deepseek-v4.1-flash` via NVIDIA, `--thinking off`,
  `--no-tools`, five unrelated detours. Four variants (full plan, stubbed plan, summary only, summary + header), one
  sample each. This is a pilot, not a controlled study.

### 5.2 Pilot results

| Variant | What the model saw | Focus | Next action |
|---|---|---|---|
| Full plan early | Whole plan + 5 detours | One-sided limits (correct) | "Three one-sided-limit problems" (correct, but over-delivered a problem) |
| Stubbed plan | Head/tail of plan, middle gone | One-sided limits (correct) | Invented a specific problem, not the planned sequence |
| Summary only | "Covered limits; one-sided shaky; continue the plan" | One-sided limits (inferred correctly) | Invented a diagnostic problem, not the plan |
| Summary + state header | Summary + ~100-token header at the tail | Limits & continuity: one-sided limits | **Three one-sided-limit problems, then a continuity check** (exact) |

Interpretation: in a short context the current model is good at recovering the *topic*; the precise *next action* is
what degrades first. The header restored the exact action and the model obeyed the "FOCUS and NEXT only" format in that
variant. This is consistent with the structural tests: after trimming/compaction, the full plan is not in context; the
header is. It is not proof that a board improves learning outcomes — that needs the A/B below.

Caveats: one model, one sample per arm, short context (~1.5k tokens), synthetic transcript, no tool calls, and the
control also succeeded. Do not present this as a benchmark. It is a smoke test that the header is salient and precise.

### 5.3 Tests to add before shipping

**Offline (fast, deterministic):**

1. `ContextTests`: a board header survives compaction and trim; it appears exactly once at the tail; it is not stored
   in the transcript; its size is under 200 tokens; the system prompt stays byte-identical for a stable board.
2. `LearningFirstTests`/new `BoardTests`: create → add → start → park → resume → complete; WIP=1; evidence required;
   park reason required; stale revision rejected; 30-card board caps the header; 100-card board does not inject all
   cards; corrupt/missing board falls back to no header (never a broken request).
3. `ToolParityTests`: `lesson_plan` actions and error messages; legacy `modules` update still works; `todo_write` is not
   used for course state (prompt-level test).
4. Renderer tests: board card with 0/1/30 cards, long titles, evidence, parked drawer; narrow width; keyboard.

**Live (scripted, repeatable):**

* Scenario: a six-week exam course, 20–30 turns, three detours of 2–3 turns each, forced compaction at 25% of the
  context window (as LangChain recommends for stress-testing), then "where were we?" and "teach the next thing."
* Arms: (A) current, (B) header only, (C) header + board tool, (D) full board every turn. Use the existing
  `Experiments` mechanism with a per-lesson arm; it is deterministic and cache-safe.
* Metrics:
  * **Resume fidelity** (primary): does the reply name the correct focus card and next action? Judged by a rubric plus
    a deterministic check of focus/next keywords.
  * **Time to return**: turns between a detour and the next on-focus action.
  * **Premature completion**: cards marked done without evidence, or done while mastery is low.
  * **Redundant work**: repeated explanation of a done card; duplicate cards.
  * **Detour preservation**: parked items that are later resumed vs lost.
  * **Cost**: prompt tokens, cache reads, TTFT, tool calls; header tokens per turn.
  * **Learner agency**: does the learner use park/resume? (survey + telemetry).
* Acceptance targets (suggested): resume fidelity +20% relative to current, premature completion −50%, header ≤200
  tokens, zero plan loss after compaction in the deterministic test. Tune after the first run.

## 6. Risks and counterarguments

* **Ceremony.** A board can become a second job. Mitigate with three lanes + parked, one focus, a compact strip, and
  `todo_write` for micro-steps. The board is for the course, not for every paragraph.
* **Staleness.** A wrong board is worse than no board. Mitigate with revision, `updated_at`, app-generated header,
  evidence, and a visible "last updated" in the UI. If the mentor deviates, it must update the board.
* **Over-planning / model capability.** Claude Code now enables task tools by default only on older models; Codex made
  `update_plan` opt-in. A capable model may track a short lesson without a written plan. The app supports many models,
  including smaller free ones and long courses; make the board experiment-gated, not forced. Measure before defaulting.
* **Tool proliferation.** There are already `lesson_plan`, `todo_write` and DeepWork plans. Do not add a fourth
  planning surface. Evolve `lesson_plan`; use `todo_write` only for the current task; keep DeepWork as a one-turn
  reasoning aid.
* **Token/cache cost.** The header is cheap but not free. Put rules in the system prompt once, facts in the header,
  cap the header, inject only when a board exists, and never inject the full board every turn.
* **Learner rigidity.** A board can make the lesson feel like a checklist. Parked cards and a "request a different
  route" action keep the learner in control; the mentor should say when it is parking something and why.
* **Evidence gaming.** A model may mark done to look productive. Require evidence and show it; do not let the learner
  mark done; flag low-mastery completions.
* **Privacy.** The board contains goals and notes; it lives in the local SQLite DB and travels to the model like the
  transcript. Do not copy it into project files or memory reflection without the same consent boundaries.
* **Migration.** Existing plans have `modules`; convert lazily to cards, keep reading both shapes, and never delete the
  old data on first write.

## 7. Recommendation and next steps

**Build the course board, in this order:**

1. **Data + converter.** Version the `plans.data` JSON (`version: 2`) with `cards`, `focus`, `revision`, `log`;
   convert existing `modules` to cards on read. Add optional `Conversation.boardID`.
2. **Tool.** Extend `lesson_plan` with `add/start/park/resume/complete/note/move/get`; keep `create/update/list`;
   enforce WIP and evidence. Return the compact state on mutations, the full board on `get`. Put it in the core tool
   set for teaching modes (not deferred) so the mentor can always update it.
3. **Header injection.** Add a `BoardExtension` (`willRequest`) that appends `<lesson_state>` to the last user message
   in the request copy. Add the usage rules once to the system prompt. Add a header-size cap and a no-board fallback.
4. **UI.** Extend the existing plan card; add the inspector Plan tab and the strip above the composer. Keep drag-and-drop
   out of v1.
5. **Compaction + resume.** Add the board to the summary prompt/digest; add the cross-lesson resume brief.
6. **Evidence hooks.** Quiz/mastery/exercise/follow-up → evidence/review cards; no automatic done.
7. **Experiment.** `mentor_board` arms (off/header/header+tool/full-board) on the existing `Experiments` mechanism;
   run the scripted detour scenario; decide on full board UI from the data.

**Do not build yet:** drag-and-drop, swimlanes, multiple boards per lesson, sub-agent board writes, automatic
re-planning, a separate board database before the JSON shape is stable.

**Open questions for you:**

* Is the board per **course/goal** (cross-lesson) or per **lesson**? I recommend course-level, with the lesson linking
  to it.
* Should the learner be able to edit card status, or only park/request a check? I recommend park/request, not done.
* Which modes get it first? I recommend tutor/exam/quiz (where sequencing matters most), then code mentor for projects.
* Is the priority **state retention** or **learner progress visibility**? The design serves both, but the first
  experiment should pick one primary metric.

---

## Appendix A — Code references

| What | Where |
|---|---|
| System prompt cached for the lesson | `Sources/MyAITeacher/Agent/ChatSession.swift:306`, sections at `:664` |
| One-line plan section | `Sources/MyAITeacher/Extensions/MemoryExtension.swift:167-177` |
| Plan tool and lossy update | `Sources/MyAITeacher/Tools/TeachingTools.swift:101-183`, update at `:138-146` |
| Deferred tools | `Sources/MyAITeacher/Agent/ToolRegistry.swift:10-12` |
| Checklist / UI-only todos | `Sources/MyAITeacher/Tools/TeachingTools.swift:314-338`; `ChatSession.swift:30,70,497` |
| Trim stub | `Sources/MyAITeacher/Agent/ContextPolicy.swift:11,156-174` |
| Compaction summary | `Sources/MyAITeacher/Agent/ChatSession.swift:682-737`; headings `:711-715` |
| Plans global | `Sources/MyAITeacher/Study/StudyStore.swift:368-381` |
| Continue plan prompt | `Sources/MyAITeacher/UI/StudyViews.swift:429-431` |
| Plan card UI | `Resources/web/app.js:955-981`; SwiftUI card `Sources/MyAITeacher/UI/StudyViews.swift:410-435` |
| DeepWork plan | `Sources/MyAITeacher/Agent/DeepWork.swift:24-83`; inserted `ChatSession.swift:327` |

## Appendix B — Sources

* Anthropic, *Effective context engineering for AI agents* — context as a finite attention budget, compaction,
  structured note-taking, just-in-time retrieval. <https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents>
* Anthropic, *Effective harnesses for long-running agents* — feature-list JSON, progress file, reading state at the
  start of each session, premature completion. <https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents>
* Manus, *Context Engineering for AI Agents* — `todo.md` recitation at the end of context, ~50 tool calls, keep failures
  visible. <https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus>
* Liu et al., *Lost in the Middle* — U-shaped attention; relevant information in the middle is used less.
  <https://arxiv.org/abs/2307.03172>
* Arike et al., *Evaluating Goal Drift in Language Model Agents* — all evaluated models drift; goal switching is the
  hardest case; strong elicitation helps. <https://arxiv.org/abs/2505.02709>
* Hong, Troynikov, Huber, *Context Rot* — performance degrades with input length; focused prompts beat full history.
  <https://www.trychroma.com/research/context-rot>
* LangChain, *Context Management for Deep Agents* — offloading, summarisation with session intent and next steps,
  targeted evals for post-summary goal drift. <https://www.langchain.com/blog/context-management-for-deepagents>
* Claude Code, *Track todos* — todo lifecycle, task tools only on some models, newer models track without a written
  list. <https://code.claude.com/docs/en/agent-sdk/todo-tracking>
* Claude Code, *Tools reference* — TaskCreate/TaskUpdate/TaskList and TodoWrite availability.
  <https://code.claude.com/docs/en/tools-reference>
* Codex, *Make the update_plan tool opt-in* — default off, remove bundled guidance when disabled.
  <https://github.com/openai/codex/commit/a9519cbcdd2d664530edb2469224ee03c1056799>
* Codex issue #33890 — two competing planning surfaces make tool selection less predictable.
  <https://github.com/openai/codex/issues/33890>
* VanLehn, *The Behavior of Tutoring Systems* (IJAIED, 2006) — outer loop task selection vs inner loop step feedback.
  <https://journals.sagepub.com/doi/10.3233/IRG-2006-16%283%2902>
* McLaren, *VanLehn's Two Loops Aren't Enough* (AIED 2026) — instructional form as a runtime variable; a third,
  meta-adaptive loop. <https://www.cs.cmu.edu/~bmclaren/pubs/McLaren-VanLehnsTwoLoops%20ArentEnough-AIED2026.pdf>
* Ezoe, Goto, Kato, *Development of a Self-Regulated Learning Tool and Analysis of Learning Behavior Patterns* (JSET,
  2024) — a kanban-style self-regulated learning tool and study-log analysis for teacher visibility.
  <https://www.jstage.jst.go.jp/article/jsetstudy/2024/4/2024_JSET2024-4-B11/_pdf/-char/en>

## Appendix C — Pilot prompts

The pilot used a single synthetic lesson: a six-week calculus plan (limits in progress, one-sided limits shaky,
next action: three one-sided-limit problems then a continuity check), five unrelated detours (Python list mutation,
laptop advice, tokens, Helix, one more), and the prompt "OK, back to calculus. Where were we? Give FOCUS and NEXT only."
The four variants replaced the plan with: (A) the full plan, (B) a 1,279-character head+tail stub, (C) a summary, and
(D) a summary plus the state header. The model was `deepseek-ai/deepseek-v4.1-flash` via NVIDIA with reasoning off and
tools disabled. Raw outputs: `/tmp/mentor-board-research/*.json`.
