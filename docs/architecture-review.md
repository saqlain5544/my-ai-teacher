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
* `ChatSession.swift`: stream handling moved out into `ReplyBuilder` (pure, unit tested). Tool execution and the step
  loop could follow; they were left in place because another session's uncommitted edits sit in `execute`.
* Computer use and the course board are `Features.Module`s; testing and language could follow. A module's hooks
  register right after the permission gate, so each move needs the check done for the board: the hooks it implements
  must keep their order relative to the other extensions that implement the same hooks.
* The quiz-grouping check is in `renderer.test.js`. The late-progress change has no renderer test: the page API can't see
  the memory it frees, and a visible check would pass without it.
