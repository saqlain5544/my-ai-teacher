# My AI Teacher — architecture

Native macOS tutor (Swift/SwiftUI + one WKWebView for the transcript). No third‑party Swift packages,
no Node/Electron runtime. Build: `scripts/build-app.sh` → `build/My AI Teacher.app`.

```
Sources/MyAITeacher/
  Core/        JSON, SSE client, SQLite wrapper, env/keys, images, speech, logging
  Providers/   LLMClient protocol + Anthropic / OpenAI-compatible / Gemini adapters, provider catalog
  Agent/       ChatSession (the agent loop), Hooks (extensions + EventBus), Metrics, SystemPrompt, ToolRegistry
  Extensions/  Features built on hooks: permissions, memory, language, activity, teaching context
  Tools/       Tool protocol + tools (files, shell, code, web, math, questions, study, memory)
  Memory/      Learner model: MemoryStore (indexed memories), ConceptGraph (subjects/concepts/prereqs + BKT mastery),
               MemoryHub (core block, lean recall), Reflection (mem0-style ops + consolidation) — see docs/memory-design.md
  Study/       FSRS-5 flashcards, BKT mastery, plans, quizzes, activity
  Workspace/   Folder workspaces (.teacher state), GlobalStore, Services
  Telemetry/   Local-only telemetry (events + daily rollups in teacher.sqlite) behind the Insights dashboard
  Native/      Apple on-device model jobs (lesson titles) — no network, weak-linked
  UI/          SwiftUI views + TranscriptView bridge + Inspector (files, in-app page viewer)
  App/         App entry, AppModel, settings, CLI (--cli), DebugHooks
Resources/web/ Transcript renderer (core app.js + registry.js + components/*.js)
```

## Invariants
* **Folders.** The teacher works inside a loaded folder. Its state lives in `<folder>/.teacher/`
  (`state.sqlite` = lessons + folder memory, `outputs/`, `attachments/`). Learner‑wide state (profile memory,
  flashcards, mastery, plans, usage) lives in `~/Library/Application Support/MyAITeacher/teacher.sqlite`.
* **Access.** Reading is allowed anywhere. Every folder starts **read‑only**; the learner grants **write** or **full**
  per folder (Settings → Tools, the sidebar folder menu, or an approval card). Grants are stored in the app's settings,
  never in the folder. Writes outside the folder are always asked. Tools never write into `.teacher/`.
* **Cache‑stable prompts.** The system prompt is built once per lesson and frozen (prompt caching + thinking
  signatures). Per‑turn context (recalled memories, mode changes) goes into hidden blocks of the learner message.
* **Append‑only history** except explicit edit/regenerate (which truncate) and compaction (which summarises a prefix
  for the request only; the transcript keeps everything).
* **Everything stays in the app.** Links open in the inspector's page viewer (ephemeral storage, no downloads, popups
  load in place), files preview in the inspector, mailto copies the address. Nothing launches Safari, Mail or Finder.
  Visuals run in sandboxed iframes (`allow-scripts` only, CSP `connect-src 'none'`) with libraries from `teacher-lib:`.
* **Quick questions** live in `~/.teacher/no-dir-conversations` (full access by default, no folder prompt).
* **Python** (`run_code` python and `math`/SymPy) follows Settings → Python: run without asking (default), ask, or off.
  Package installs (pip/uv/conda/brew/npm -g, also from inside code) are always refused.

## Context and cost
Every request = fixed prefix (system prompt + tool schemas) + history prepared by `ContextPolicy` (all O(n)):
1. **Deferred tools.** 12 core tools are always sent; 8 rarely used ones are listed by one line each and loaded with
   `load_tools` (or automatically on first direct call). Tool order only ever grows, so the cached prefix holds.
2. **Old reasoning** is not resent (except Claude adaptive thinking, which must replay).
3. **Microcompaction epochs.** Past 70% of the budget, bulky tool results/inputs and images older than the last 3
   turns become head+tail stubs. The cut point jumps (epochs), so the prefix stays cacheable between jumps.
4. **Summary compaction** only if still over budget; keeps ~30% verbatim.
5. **Budget** = min(Settings → Context budget, half the model's context window from provider metadata).

Model metadata (context window, max output, reasoning, vision, tools, free/pricing) comes from each provider's
`/models` (OpenRouter, Anthropic, Gemini, Groq, Mistral, OpenAI-compatible shapes), cached on disk for 24 h. It sets
`max_tokens`, hides thinking options for non-reasoning models and shows badges in the model picker. OpenRouter needs
reasoning disabled explicitly; models that require it fall back to low effort (learned at runtime).

Prompt caching: the system prompt starts with instructions identical across lessons; lesson context (date, memory,
folder) comes after `# Environment`. Anthropic-format requests send them as two cached blocks plus tools and the last
message as breakpoints; other providers cache the shared prefix implicitly.

| Measured (free model `minimax-m3.1-flash:free`, OpenRouter) | Before | After |
|---|---|---|
| Fixed prefix per request | ~6.8k tok | **~4.35k tok** (−36%) |
| Output tokens, "thinking off" visual request | 7,194 | **1,258** (reasoning now actually off/low) |
| Cache hit, later steps of a lesson (real lessons) | — | **71–82%** |
| Cache hit, first request of a new lesson (shared prefix) | ~1% | **~5k of ~5.05k tokens** |

## Experiments (A/B)
`Experiments` assigns each lesson a deterministic arm per experiment (FNV hash of experiment + lesson id), so a
lesson's prefix never changes and nothing is stored. `ExperimentExtension` publishes exposures and per-turn outcomes
(steps, tokens, seconds); telemetry stores them and Insights compares arms. Settings has an off switch; the CLI can
force arms with `--exp name=arm`. First experiment `visual_tool` (core vs deferred): offline, 3 prompts × 2 arms,
rewording the tool mattered more than placement (fence 2/3 in both arms), so **deferred** is the default (−250 tok/req).

## Live visuals and practice
* ```` ```visual ```` fence (no extra round trip) or the `visual` tool (persists to `.teacher/visuals/`). Runtime:
  scripts run through indirect eval with async callbacks wrapped, so real error messages reach the learner and the
  Fix button sends them to the teacher; frames size to their content and load lazily.
* ```` ```practice ```` self-check cards and ```` ```steps {"reveal":true} ```` worked examples run entirely in the
  transcript (no tool call, nothing added to the context).

## Native hardware
WebKit renders the transcript in its own GPU-accelerated process; visuals run in sandboxed frames inside it.
NaturalLanguage (embeddings, language ID), Speech and the on-device language model (titles, ~0.5 s) run locally on the
Neural Engine/CPU; read-only tools run in parallel; telemetry writes on a background queue; SQLite uses WAL.

## Adding features
| You want to… | Do this | Core changes |
|---|---|---|
| React to the agent loop (inject context, gate tools, observe results, act after a turn) | Implement `AgentExtension` (all hooks optional) and register it in `AppModel.registerExtensions()` | none |
| Listen to app events (UI badges, logging, sync) | `EventBus.subject.sink { … }` (`AppEvent`) | none |
| Add a tool | Conform to `Tool` (name, description, JSON schema, `risk`, `run`) and add it to `ToolRegistry.all`. `risk` drives permissions; interactive tools await `ctx.interactions.request(…)` | none |
| Add a provider | Add a `ProviderConfig` preset (Anthropic/OpenAI/Gemini wire format + quirks) to `ProviderCatalog`, or add a custom provider in Settings | none |
| Add a wire protocol | Implement `LLMClient` (emit `StreamEvent`s) and a case in `APIKind` | 1 switch |
| Run an A/B test | Add an `Experiment` to `Experiments.all` and branch on `Experiments.arm(e, unit: lessonID)` | none |
| Render a new fenced block (```xyz) | `TeacherUI.registerFence('xyz', (code, ctx, env) => html)` in `Resources/web/components/` and add the script to `index.html` | none |
| Add a question type | `TeacherUI.registerQuestionType('type', {render})` + grading case in `Questions.grade` | none |
| Custom tool card | `TeacherUI.registerToolCard('tool_name', (block, result, pending, ctx) => html)` | none |
| Post‑process rendered DOM | `TeacherUI.registerProcessor((root, ctx) => …)` (runs on freshly inserted nodes only) | none |
| Markdown syntax | `TeacherUI.registerMarkdown(md => md.use(…))` | none |
| Something under each reply | `TeacherUI.registerFooter((msg, turnMsgs, userMsg, ctx) => html)` | none |

## Metrics (OpenTelemetry GenAI‑aligned)
* `StepMetrics` per LLM call: provider, model, TTFT, duration, usage (input/cache read/cache write/output/reasoning),
  finish reason, retries, tool calls, `usageEstimated`. Decode speed = (output − 1) / (duration − TTFT).
* `TurnMetrics` per learner turn: wall time, TTFT, steps, tools (duration, ok, time waiting for the learner), summed
  usage, memories recalled/written, languages.
* `ConversationStats` per lesson; `usage_log` per day × provider × model (Progress → Model usage).

## Sub-agents
* `task` runs `SubAgent`: its own context and loop (stream → bounded tools in parallel → repeat), recorded as a
  `SubAgentRun` transcript. The right-hand panel's **Agents** tab renders it live with the lesson renderer (read-only);
  it opens when a sub-agent starts, and the card in the lesson has **Open** and **Stop**.
* The teacher may pick the sub-agent's model (`model`): the choices are the provider's fetched list (tool-capable),
  free-only when the lesson's model is free, listed in the tool spec per lesson. Unknown ids are refused with the list.
* Budget: 10 model calls or 120 s, then it is told to write its report from what it has; if it still won't, the
  sources it read come back instead of nothing. Stop (its own, or the lesson's) ends it at once; the lesson gets the
  partial findings. The trimmed transcript is kept in the tool result so a finished run can be reopened later.

## Timeouts
* Every tool has `timeout(_:)` (nil only for tools that wait for the learner); `runBounded` enforces it with
  `withDeadline`, which returns on time even if the work ignores cancellation (it is abandoned, never awaited).
  web_search 30 s, web_fetch 40 s, bash/run_code their own limit + margin, sub-agent budget + report.
* Abandoned work still costs CPU and memory, so in-process work checks `Task.isCancelled` itself: the HTML
  converter every 256 nodes, the glob walk every 512 entries; subprocesses are terminated on cancel.
* The HTML converter is bounded: nesting past 40 levels is read as plain text with an explicit stack (no
  recursion, so no stack overflow), output stops at 400k characters, element text comes from an iterative capped
  walk (`XMLNode.stringValue` is O(text × depth)), and each child renders in its own autorelease pool.
* A model stream that goes silent for 120 s fails (providers send keep-alives while thinking).

## Provider stream guard
* Every client is wrapped in `GuardedClient` (Providers/StreamGuard.swift). When a host's tool-call parser fails, models
  put their protocol in the text; the guard parses DeepSeek DSML/V3/V3.1, Qwen/Hermes/Qwen3-Coder/GLM `<tool_call>`,
  MiniMax M2/M3, Kimi, Mistral, Llama `<|python_tag|>`, Nemotron `<TOOLCALL>`, Harmony and Gemma 4 into real tool calls
  (values typed by the tool schema), drops end-of-turn tokens and garbled markers, turns a bare `</think>` into
  reasoning, removes duplicate calls, and handles markers split across chunks. Tool arguments are coerced to the schema
  before every tool runs (stringified arrays, numbers, booleans).
* Thinking off is real: NIM gets the family's `chat_template_kwargs`; MiniMax gets `thinking: disabled` (or adaptive at
  low effort for models that require it, learned from the 400); OpenRouter gets `reasoning: {enabled: false}`.

## Code agent
* Mode `agent` ("Code agent", ⇧⌘K): a software-engineer prompt, the whole coding toolset up front, and project memory
  in `.teacher/code-memory.md` (plus CLAUDE.md / AGENTS.md) instead of the learner model; `project_memory` tool.

## Learning model
* Mastery fades since the last practice (never below 40%), with a half-life that grows with each correct recall.
  `readyToLearn` = not solid, every prerequisite solid; `fading` = was solid, now slipping. Both go into the teacher's
  memory block ("Study next") and Memory › Overview.
* Guards: restated facts with changed numbers/negations supersede (old text in history); reflection only edits what it
  was shown and archives instead of deleting; concepts fold only with the same words or a trailing qualifier;
  prerequisites stay acyclic; the concept index updates incrementally.

## Long lessons
* A lesson loads as a window (from the compaction point or the last 400 messages); earlier messages page in on request.
  Compaction folds ranges into a rolling summary (digest fallback if the model fails); requests still over budget
  squeeze their largest outputs. SSE parsing is linear; lesson search ranks only the newest 2,000 matches.
* Storage: measured, SQLite is not the bottleneck (the access patterns were), so no custom engine.

## Bounded memory
The app's footprint must not grow with how much the learner has done: data lives on disk, memory holds a window.
* Images: payloads ≥ 16k base64 chars go to a content-addressed `BlobStore` beside the lesson's database
  (`<db dir>/blobs/ab/<sha256>`); messages keep a reference (`Block.blob`). Request builders read `Block.payload`
  (inline or from disk) only for images they send; the transcript loads `teacher-blob://img/<ref>`, so no base64 sits
  in Swift memory or the DOM. `blob_refs` records which message uses which blob; deleting or truncating a lesson collects
  unreferenced blobs (10-minute grace for ones whose message isn't saved yet), and a launch sweep catches orphans.
* Lesson window: besides the 400-message cap, loaded messages have a 24 MB budget. When the learner sends, the oldest
  display-only messages (before the compaction point; whole turns) leave memory and the page (`T.trimBefore`); what the
  next request needs is never trimmed, and is itself bounded by compaction.
* Caches are bounded by size, not only count: page render caches (`Cache` in app.js: KaTeX, highlighting, markdown
  segments, diagrams), the fetched-page cache (4M chars), URLCache (4 MB), SQLite (8 MB per connection).
* `MemoryGovernor` is the safety net: on macOS memory pressure, or a footprint over 1.5 GB, it drops everything that
  rebuilds (memory indexes, fetched pages, SQLite caches, page caches) and returns freed pages to the system.
  `{"action":"shed"}` triggers it in a test instance; the log records the footprint before and after.
* In-process work that a deadline abandons checks cancellation itself (see Timeouts), so abandoned work stops using memory.

## Frozen pages
* Visuals run model-written JavaScript in sandboxed frames that share the transcript's process, so an endless loop
  would freeze the lesson. `WebWatchdog` pings each transcript (and sub-agent) page every 2 s while its window is
  visible; after 8 s without an answer it ends the web process, reloads, and the lesson renders again with visuals
  paused behind ▶ Run (a notice says why). `MyAITeacher --webtest --watchdog` checks this end to end.

## Testing
* `scripts/e2e.sh [--live]` — the whole loop: build, unit tests, renderer suite (light + dark), and with `--live`
  the scripted lessons. Run it after every change.
* `swift test` — unit tests (SSE/think-tag parsing, FSRS, BKT, grader, math equivalence, HTML→Markdown, workspaces,
  memory, deadlines, sub-agent model choice / failure / cancellation).
* `MyAITeacher --webtest Tests/web/renderer.test.js [--dark] [--only name]` — loads the real transcript page in the
  app's WebKit (offscreen) and runs ~60 tests: every fence and component, streaming frame by frame, sanitising,
  tool cards, quiz answering, visuals, Mermaid re-render from cache, performance. Exits non-zero on any failure or
  unexpected page error.
* `scripts/e2e-live.py [--only name] [--keep] [--model x:free]` — live lessons on a free model in a throwaway profile
  (`MYAITEACHER_HOME`, its own database, settings, folders and log; the learner's data is never touched). It starts a
  second instance of the app bundle (window titled "(test profile)", stopped by its own pid), sends prompts, answers
  questions and approvals by clicking the rendered cards, and checks each turn: errors, stuck spinners, undrawn
  diagrams, failed tools, files changed on disk. Reports and snapshots land in the profile folder.
* Debug hooks (`MYAITEACHER_DEBUG=1`): `MyAITeacher --post '{"action":"report","path":"/tmp/r.json"}'` (also
  `snapshot`, `send`, `quick`, `stop`, `pending`, `answer` by id/title, `eval`, `select`, `newLesson`, `openFolder`,
  `status`, `sessions`). Logs: `~/Library/Logs/MyAITeacher.log`, or `$MYAITEACHER_HOME/MyAITeacher.log`.
* `MyAITeacher --cli "prompt" [--provider …] [--model …] [--thinking low] [--dump]` — headless provider call;
  `--cli --tool web_search '{"query":"…"}'` runs any tool; `--cli --spec ask_learner` prints a tool's schema.
  `MYAITEACHER_TRACE_SSE=1` prints every raw stream event (to tell a model's output from a parsing bug).

## Tool parity with Claude Code
| Claude Code tool | My AI Teacher | Notes |
|---|---|---|
| Bash | `bash` | zsh, persistent cwd per lesson, timeout (≤600 s), 30k-char head/tail truncation, huge output spilled to `.teacher/outputs` |
| Read | `read` | `cat -n` lines, offset/limit, images (sent to the model), PDFs with page ranges, binary detection |
| Write | `write` | creates parents; permission-gated by folder access |
| Edit | `edit` | exact unique match or `replace_all`, helpful errors |
| Glob | `glob` | `**` globs, newest first, skips build/vcs folders |
| Grep | `grep` | ripgrep when installed (fallback `grep`), files/content/count modes, context, `-i`, glob filter |
| LS | `ls` | sizes, hidden-noise filtering |
| WebSearch | `web_search` | free & keyless: DuckDuckGo + Bing (+ Brave fallback) merged; news mode |
| WebFetch | `web_fetch` | HTML→Markdown (article extraction, MathML→TeX), PDF→text, images, pagination, 15-min cache |
| TodoWrite | `todo_write` | rendered as a live checklist |
| Task / Agent | `task` | sub-agent with its own context (read-only + web + math tools), parallelisable, model choosable, live in the Agents panel, stoppable |
| AskUserQuestion | `ask_learner` | 13 interactive component types, not just multiple choice |
| NotebookEdit | — | not needed for tutoring; `edit` works on `.ipynb` JSON |
| — (extra) | `run_code` | Python, JS, TS, Swift, C, C++, Go, Rust, Ruby, Bash, Java in a scratch dir |
| — (extra) | `math` | SymPy: evaluate/simplify/solve/diff/integrate/limit/series with assignments & tuples |
| — (extra) | `quiz`, `flashcards`, `mastery`, `lesson_plan` | graded quizzes, FSRS cards, BKT mastery, curricula |
| — (extra) | `memory` (search/save/update/forget) | learner model: scoped memories + concept graph (ids 12 / f3 / c7) |

## Measured (Apple Silicon, macOS 27)
* Cold launch → rendered transcript: **1.07 s**; app process footprint **~68–73 MB** + one WebKit content process (~90 MB).
* Same-machine comparison (RSS of all bundle processes): My AI Teacher 135 MB (+~90 MB WebKit) vs MiniMax Code 662 MB, Claude 1,418 MB.
* Streaming render: p50 3 ms / p95 8 ms per frame for a 3k-char mixed Markdown/KaTeX/Mermaid stream.
* Free web search: 12/12 varied queries returned ≥5 results (engines fall back for each other).
* Storage at 200k messages (422 MB database, debug build): 23.5k message writes/s (JSON + FTS index), a 400-message
  window loads in 2.6 ms, a count in 0.4 ms, lesson search 29 ms (common words) / 0.1 ms (rare); the app's footprint
  grew 20 MB. SQLite is not the bottleneck; the access patterns were (the search was 64 s before the rowid-range fix).
