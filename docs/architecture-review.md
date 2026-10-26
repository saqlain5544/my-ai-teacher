# Architecture review (October 2026)

A review of the whole app for bugs and for how well it takes new features. 19 commits, `97a7954`…`b9d8423`. Each area
below lists what changed and how it is checked. [ARCHITECTURE.md](../ARCHITECTURE.md) holds the resulting rules and
extension points.

## Adding features
| Change | Commit | Checked by |
|---|---|---|
| A feature's tools and hooks are one `Features.Module`: computer use, then the course board | `5405835`, + `Study/CourseBoardFeature.swift` | `ToolRegistryTests`, live browser and follow-up lessons |
| A tool declares its own sub-agent access (`subAgentVariant`); the pool is derived | `811ac98` | `ToolRegistryTests` |
| Every extension's tool gate is consulted: an approval moves on to the next gate | `97a7954` | `ArchitectureTests` (gate chain) |
| Compaction is its own unit (`Compaction.summaryRange` / `summarise`), usable by any agent | `a79c6ec` | `CompactionTests`, a live MiniMax summary |
| Storage: `db.run` / `db.write` log failures, transactions nest as savepoints, `db.insert` returns its own row id | `97a7954`, `7939c56` | `ArchitectureTests` |
| Anthropic's 4-breakpoint limit is a test, not a runtime surprise | `3afed60` | `CacheBreakpointTests` |

## Context handling
| Change | Commit |
|---|---|
| Token counts are script-aware everywhere (budget, squeeze, compaction keep window, estimated usage) | `97a7954` |
| A step prepares the request history once (was two or three times) | `97a7954` |
| Per-message token estimates are cached | `29a58cb` |
| Sub-agents trim older tool results inside one brief and keep thinking signatures | `29a58cb` |
| The last-resort squeeze also trims oversized tool inputs (not with signed thinking) | `3977458` |
| A failed memory reflection is retried instead of marking the lesson reflected | `b9d8423` |

## Caching
| Change | Commit |
|---|---|
| One shared HTTP session for all model streams (connection reuse) | `97a7954` |
| Model metadata: no disk read per call for providers without a cache; no duplicate list requests | `97a7954` |
| Base64 images resent each step come from a 32 MB LRU (released under memory pressure) | `7939c56` |
| Web-fetch cache: a page larger than the cache is not kept | `c71fa61` |
| Renderer: bounded code-output cache; streamed tool progress freed once the result arrives | `97a7954`, `e1090d5` |

## UI and UX
| Change | Commit |
|---|---|
| Focus rings, message actions on keyboard focus, `prefers-reduced-motion` | `97a7954` |
| VoiceOver labels on icon-only buttons; the page viewer's stop button stops | `29a58cb` |
| Quiz choices are named groups (VoiceOver reads the question and "2 of 4") | `c58f557` |
| An ungraded quiz no longer claims "no answer key" when a free-text answer just didn't match | `a79c6ec` |

## Bugs fixed
| Bug | Commit |
|---|---|
| A crash between saving a message and its image references let the launch sweep delete its images | `97a7954` |
| An approval for one tool gate skipped every later gate | `97a7954` |
| Stopping during a retry backoff still sent a request | `97a7954` |
| Claude sub-agents with reasoning lost their thinking (signatures dropped) | `29a58cb` |
| In-stream errors were all 500s, so bad requests were retried 3× (OpenAI-format and Anthropic) | `29a58cb`, `119c1d7` |
| A new memory, concept or card could be reported with another row's id | `7939c56` |
| A flashcard review's schedule and log were written separately | `119c1d7` |
| A cancelled tool waited forever for the learner; a duplicate wait orphaned the first | `838cc63` |
| A failed telemetry flush dropped its batch | `82d1c51` |
| The app crashed at launch when its folder could not be used | `c6f4ba6` |
| `OutputCollector` counted a whole chunk as dropped | `97a7954` |
| The live harness's Skip never picked a reason, so unfillable cards hung | `a79c6ec` |

## Verification
* 326 unit tests (`swift test`), 128 renderer tests in light and dark (`--webtest`), the watchdog check.
* Live lessons on MiniMax-M3.1-Flash: sub-agents (5 scenarios), stop / after-stop, follow-up / follow-up-check, browser
  form and screenshot.
* Reviewed and found sound, no change: folder access checks, the agents' browser (tab teardown, log caps), every
  force-unwrap, the follow-up scheduler, Gemini thought-signature round trips, sub-agent handles.

## Left open
* `ChatSession.swift`: stream handling moved out into `ReplyBuilder` (pure, unit tested), which the sub-agent loop
  now shares (one set of stream rules; it had drifted before, dropping thinking signatures). Tool execution and the step
  loop could follow; they were left in place because another session's uncommitted edits sit in `execute`.
* Computer use and the course board are `Features.Module`s. Testing and language stay plain extensions on purpose:
  testing has no tools (a module would add nothing), and language adds a system-prompt section, so registering it
  with the modules (after the permission gate) would reorder the prompt every new lesson gets.
* The quiz-grouping check is in `renderer.test.js`. The late-progress change has no renderer test: the page API can't see
  the memory it frees, and a visible check would pass without it.

# Bug hunt (25 October 2026)

A second pass over the whole app for bugs and for features that cost more than they give. `d06a5ab`…`8f6bcb9`.

## Bugs fixed
| Bug | Commit | Checked by |
|---|---|---|
| Model HTML could make working app buttons: the attribute filter missed attributes after a `/` or a closing quote, and a `>` inside a quoted value | `d06a5ab` | `renderer.test.js` (fake UI) |
| A single choice key given as text was read as an index ("2" keyed option "3"); a key naming no option marked everyone wrong, a negative one trapped | `2aafe6a` | `FeatureTests` |
| Answer first's tool-call count carried over into a regenerated, retried or background-report turn, which then lost its tools on its first request | `2143ec9` | live lessons |
| A DeepWork plan was added again on regenerate or retry, and an edited message kept the old question's plan | `2143ec9` | |
| The step that must write the reply sent tool calls without tools; Anthropic's API refuses that (a 400 instead of the answer) | `1866581` | `TurnContinuationTests`, MiniMax live |
| `web_fetch` reached localhost and the local network unasked, unlike the browser | `b8e7262` | `SubAgentTests`, live redirect and DNS checks |
| The mentor's write fence let a command rename the folder holding the learner's files | `1b23dd9` | `MentorCockpitTests`, sandbox-exec |
| A cut-off reply was continued without limit when no step cap was set | `ec86f82` | |
| Language writes used `try? db.execute`; removing a word and its card wasn't one transaction | `2143ec9` | |
| Headless lessons reported no first reply when it came with the last step | `8f6bcb9` | live |

## Pruned
| What | Commit |
|---|---|
| The A/B experiments framework (no experiments left): arms, exposure telemetry, the Insights card, the Settings switch. The course board choice is `BoardSystem` | `daf3698` |
| The `quiz` tool, a second name for graded `ask_learner` (now `GradedQuiz`) | `5d71563` |
| A duplicate registration of the course board extension, and 14 functions nothing called | `daf3698`, `5ba10f2` |

## Verification
* 451 unit tests, 155 renderer tests in light and dark, the watchdog check; a clean build with no warnings (17 before).
* Live headless lessons on MiniMax-M3.1-Flash (tutor and explain, with plans, reviews and graded questions).

## Live code-mentor session (26 October 2026)

Three tasks in the real app, driven through the UI (a test profile, MiniMax-M3.1-Flash, thinking off, quizzes off,
Read & write access): an LRU cache project with two review rounds, an expression-evaluator project started in the
same lesson, and a question about a slow asyncio downloader.

| Turn | Wall time | Model calls | Prompt tokens | Where the time went |
|---|---|---|---|---|
| LRU project created | 3 m 01 s | 7 | 121k | model 116 s, approvals 42 s, tools 0.6 s |
| Review 1 (both bugs found, one the tests missed) | 1 m 53 s | 8 | 196k | model 69 s, approvals 24 s |
| Review 2 | 2 m 21 s | 8 | 260k | model 120 s |
| Evaluator project | 10 m 11 s | 29 | 1.72M | model 413 s, approvals 170 s: the locked previous project |
| Evaluator review | 2 m 03 s | 10 | 666k | model 104 s |
| asyncio question | 1 m 21 s | 8 | 540k | model 61 s |

Tools took under 10 s a turn; the model's own steps took 60–90% of every turn. MiniMax reasons whenever tools are
present even with `thinking: disabled` (42k reasoning tokens over the session); an explicit budget was slower (8k
output tokens against 3.4k), so off stays the setting. The reviewer pass rewrote four of six drafts and each time for
a real reason (a claimed test fix that had been refused, a giveaway fix, two factual errors), so it stays on.

What it fixed, besides the UI:

| Problem seen | Fix |
|---|---|
| A second project in the same lesson dead-ended: the mentor's own new test file was refused as "the learner's", so it recorded a pass that never happened to get out | Files the mentor creates while a project is open stay its own (`mentorFiles`, also outside the command fence); `project_tests` park puts a project aside unfinished with the learner's approval; a headless rerun switches projects in 61 s with no refusal |
| Tests locked the moment they were registered, so fixing a wrong expectation needed the learner to unlock | Tests are the mentor's draft until the learner changes a file (`testsAreDraft`); set again, still red-first |
| Four approvals for one lesson's tests (bash, set, review start, status) | One `tests` grant for the three test tools, implied by a shell grant; actions that run nothing don't ask; Request review grants it; prompts say "run your tests for the review" with the command, not "start" |
| Every scratch write of a reference solution asked again | Writes in the system's temporary folder don't ask |
| Startup instructions ~10.4k characters for a code lesson | Terse defaults (teacher, Code mentor, board, app and tools guides): 7.9k, every rule and format kept |
