# My AI Teacher — architecture

Native macOS tutor (Swift/SwiftUI + one WKWebView for the transcript). No third‑party Swift packages,
no Node/Electron runtime. Build: `scripts/build-app.sh` → `build/My AI Teacher.app`.

```
Sources/MyAITeacher/
  Core/        JSON, SSE client, SQLite wrapper, env/keys, images, speech, logging, Runtime/ (supervised processes)
  Providers/   LLMClient protocol + Anthropic / OpenAI-compatible / Gemini adapters, provider catalog
  Agent/       ChatSession (the agent loop), Hooks (extensions + EventBus), Metrics, SystemPrompt, ToolRegistry
  Extensions/  Features built on hooks: permissions, memory, language, activity, teaching context
  Tools/       Tool protocol + tools (files, shell, code, web, math, questions, study, memory)
  Browser/     The code agent's in-app browser (tabs, injected helper, `browser` tool)
  ComputerUse/ Native Mac control: capture/input/AX backends, tiers and grants, `computer` + `mac` tools, approvals
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
| Run background work | `Runtime.job(name) { … }` (one per name, watchdog, restart on a crash), `Runtime.call` (returns a value), `Runtime.every` (periodic service) — not `Task.detached` | none |
| Add a sub-agent type | Settings → Agents, or a `.teacher/agents/<name>.md` in the folder (or `AgentCatalog.builtIns`) | none |
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
* `task` runs `SubAgent`: its own context and loop (stream → tools → repeat), recorded as a `SubAgentRun` transcript.
  The right-hand panel's **Agents** tab renders it live with the lesson renderer (read-only) with its type, provider,
  model, effort and budget use (steps, seconds, tokens, cost) as it works, a note box to steer it, and Stop.
* The teacher chooses per call; defaults and limits come from **Settings → Agents** (`AppSettings.agents`):
  * `type`: built-in `explore` (default; read-only research), `general`, `coder`, `reviewer` (read-only), `tester`
    (no edits); app-level types from Settings; project types from `<folder>/.teacher/agents/*.md` (frontmatter: name,
    description, tools, deny, read_only, provider, model, effort, max_steps/max_seconds/max_tokens, isolation; the body
    is the system prompt — user-authored project files, the app never writes them). Built-in names can't be redefined.
  * `provider`/`model`: the lesson provider's fetched list, or any other provider with a key (Settings can limit that,
    and paid models there are off by default). A free lesson only ever delegates to models known to be free (metadata, or
    a `:free` id), even before any list has loaded. Retired ids map to their
    successor; loose names resolve through `Fuzzy` when one candidate clearly fits ("using deepseek-v4-pro for 'deepseek
    v4 pro'"), otherwise the error suggests the closest three.
  * `effort` off/low/medium/high (default off), sent as `LLMRequest.thinking` through the same clients as the lesson, so
    every provider's mapping applies (NIM `chat_template_kwargs`, MiniMax disabled/adaptive, OpenRouter `reasoning`,
    DeepSeek `thinking`); a model whose metadata says it doesn't reason gets off.
  * Budget `max_steps` / `max_seconds` / `max_tokens` (input + output over the run, its own sub-agents' included),
    clamped to the limits (a number past Int, NaN or infinity counts as not given); past it the agent is told to report from
    what it has, with a capped report call (8k tokens; 4k for a schema repair). A run still going 300 s past its time
    budget is stopped (the backstop). The tool's own timeout follows the run's budget (the call's, a resumed run's, or its
    type's). `unbounded` needs the setting, always runs in the background, stays stoppable.
  * `tools` / `deny_tools` narrow the type's tools; `output_schema` (JSON Schema, `JSONSchemaCheck`) is checked after
    the report with one repair turn; the teacher gets the JSON (and `meta.structured`).
  * `isolation: "worktree"` (coder types, code mode, a git repo, write access): it works on a `git worktree` in the
    app's support folder (made with hooks and fsmonitor off), removed if nothing changed, otherwise reported with its
    path, branch and diff stat; kept ones go with their `teacher/…` branch after 14 days, at a later launch. Its shell and
    code start in the worktree.
* Permissions are a ceiling, never a prompt (`SubAgentPolicy`): a sub-agent may do what the lesson may do without
  asking (folder access, approvals the learner gave in this lesson, the Python setting, disabled tools) and nothing more;
  writes must land inside its folder (or worktree), never `.teacher/` — checked on the real path (the deepest existing
  ancestor through realpath, so symlinked folders and dangling links are followed) and case-insensitively, as APFS is;
  the lesson's own `Workspace.contains`/`isStatePath` use the same check. Installs are refused (pip/uv/poetry/conda/gem/
  cargo/go/brew, global npm/pnpm/yarn/bun). Read-only types never get write tools, and their `bash` never reaches a shell:
  `ReadOnlyShell` splits the command into a pipeline of argument lists and runs each program directly (Process, pipes
  between them), with only bare program names from a list, their allowlisted reading flags, and no word containing
  `\ $ { } * ? [ ] ( ) = ! ~`; git runs with fsmonitor, hooks, external diff and textconv off. Nested sub-agents (up to
  Settings' depth) can't exceed their parent, and a resume meets the same concurrency and depth limits.
* `agents`: list/status (type, model, effort, budget use, tokens, time, cost), `send` (a note it reads before its next
  step), `wait` (the teacher then has the report; it isn't delivered again), `stop`, `resume`. At most N at once per lesson.
* Each run is a supervised process (Runtime › agents): a provider error that may pass (429/5xx, timeouts, lost
  connections) crashes it, the supervisor restarts it after 1 s → 2 s → 4 s, and the new incarnation resumes from the
  transcript (the failed reply is dropped, unfinished tool calls are answered as interrupted); after 3 restarts in 60 s it
  reports from what it has. A watchdog ends a run that goes 300 s without a stream event or a tool finishing (a provider
  that only sends keep-alives); the incarnation it ends writes nothing more (no "stopped" report, no worktree cleanup)
  and the restart carries on, so Stop still reaches the live one. Stop goes through the supervisor, so a stopped run is
  never restarted. Writes from a replaced incarnation are dropped (`RunWriter`); notes it never read pass to the next
  incarnation (`Mailbox.remaining`).
* Memory: images in sub-agent transcripts spill to the lesson's `BlobStore`; requests send only the newest 2 images. A
  finished run keeps its transcript in memory only while it is among the newest 4 (or on screen): older ones park it,
  whole (images by blob reference), in a per-launch temporary folder and keep their summary and report; it comes back
  when shown or resumed. The folder goes at quit, and a crashed launch's at the next.
  `MemoryGovernor`'s shed parks every finished transcript but the one on screen. The trimmed transcript (no images) is
  also kept in the tool result, so a run from an earlier launch reopens from there.

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

## Browser and computer use (code agent)
* **Browser** (`browser` tool, right panel → Browser): WKWebView tabs over a persistent website data store of its own
  (non-persistent in test profiles), separate from the transcript and the page viewer. Off-panel tabs live in an
  offscreen panel so they keep rendering and can be screenshotted. A helper injected into an isolated content world of
  every frame builds the snapshot (roles, names, values, states; open shadow roots, same-origin iframes; cross-origin
  frames introduce themselves and are read on their own, refs `f2.ref_3`) and acts by ref with real event sequences
  (pointer/mouse/click, key/beforeinput/input, native value setter for framework-controlled inputs). Refs are stable
  per element and bound to their document (each answer carries the helper's token; a ref from an earlier page is
  refused). Console and fetch/XHR are captured in the page world; screenshots map back through their scale.
* **Sites are the lesson's**: while the agent acts, every main-frame navigation (links, scripts, form posts, server and
  meta redirects, back/forward) must go to a site its lesson approved, or it is cancelled with a notice; what it reads
  (snapshots, text, logs, switching tabs, the page after an action, cross-origin frames) only ever comes from approved
  sites. Between actions the learner may browse anywhere public. This Mac and the LAN (parsed addresses, reserved
  names, names that resolve there) open only with an approval or the learner's typing, and a content rule list stops
  public pages loading anything from them. One popup per click; downloads one at a time, cancelled with their call.
* **Mac** (`mac` for apps and the AX tree, `computer` for pixels): ScreenCaptureKit screenshots that show only granted
  apps, sized ≤1568 px / 1.15 MP with an exact per-axis mapping to screen points (zoom keeps that mapping); CGEvent input
  marked as the agent's own. Before every event: the frontmost app, the app receiving keys (AX focused application — a
  panel such as Spotlight takes keys without being frontmost) and the window under the pointer are checked against
  grants and tiers (browsers view only, terminals/IDEs click only and never their menus, password managers and this app
  never). Keys and buttons held are tracked and released without checks on Stop, errors, timeouts and at turn end.
  One lesson controls the Mac at a time. A floating "Agent is controlling your Mac" panel has Stop; Esc twice (global
  monitor, the agent's own keys ignored) stops too. AX calls run off the main actor under a global messaging timeout.
  Capture, input and desktop state are protocols, so tests run on fakes and never touch the real Mac.
* **Approvals** (`ComputerUseGate` behind `ComputerUseExtension`, the usual cards): sites for this task, this lesson or
  always (localhost, LAN, files and data: pages never always); a frame of another origin asks for its own site after
  the page's; every download (the page's file name only in the details); JavaScript evaluation; the apps named in
  `request_access`. "Always" grants live in settings (Settings → Tools lists and removes them), never in a folder.
  Passwords, payment details and ID numbers are refused by field (asked again before each typed piece, since Tab and
  Return move focus), by content, and for character keys and paste in such a field; uploads are always refused. Page
  and app content returns inside an `untrusted_*_content` envelope that starts with a reminder and can't be closed early.
* **Providers**: one generic schema for every model; non-vision models get the AX tree where a screenshot would go.
  Claude on api.anthropic.com gets Anthropic's native tool only for documented models (the computer toolset for Opus 5
  and the 5.5 models, `computer_20251124` for those documented with it); member calls map onto `computer` and replay
  with `toolset_name` only while the request declares the toolset. A failed action skips the rest of its batch.
  Requests carry only the latest two screenshots, except for Claude with replayed thinking: there history is never
  edited (it would invalidate later thinking blocks) and the API clears old screenshots (`clear_tool_uses_20250919`
  once one is in the history, every other tool in `exclude_tools`). Microcompaction and the lesson summary still change
  the history once, at a boundary: for the models that check thinking against it (Fable 5.1, Opus/Sonnet/Haiku 5.5)
  requests with thinking on send `block_binding.prefix_mismatch_behavior: "drop_block"`, so those blocks are dropped
  instead of every later request failing on an enforced account.
* **macOS permissions**: Screen Recording and Accessibility are checked (`CGPreflightScreenCaptureAccess`,
  `AXIsProcessTrustedWithOptions` without prompting); `mac permissions` shows the learner a card that opens Settings or
  asks macOS. The app is ad-hoc signed, so a rebuild drops both grants; the app remembers the last build that had them
  and says so.

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

## Runtime (supervised lightweight processes)
`Core/Runtime/`: Erlang/OTP-style processes on Swift concurrency — tasks in this process, not OS processes.
* `Proc` (an actor): a body task, an `AsyncStream` mailbox (FIFO per sender, depth counted; timed `receive` and
  non-blocking `drain` work with markers queued behind the messages, so a waiting `next()` is never cancelled), links
  (an abnormal exit signals the other side; trapping turns it into a callback) and monitors. A body that throws, or goes
  past its watchdog without a heartbeat (receiving, or `heartbeat()`), ends as a crash. `stop` cancels it and abandons it
  after a grace (`.killed`) — like `withDeadline`, an uncooperative body is never awaited.
* `Supervisor`: children by `ChildSpec` (permanent / transient / temporary), one-for-one or rest-for-one, restart
  intensity (more than N restarts in T s: it stops every child and crashes itself, for its parent to decide), per-child
  limits (one flaky job gives up alone), exponential backoff. Supervisors nest; children are linked to their supervisor.
* `Registry`: processes by pid and name, supervisors by name, restart counts; `Runtime.metrics` (process count, mailbox
  depth, restarts) shows in the Agents panel's footer and `{"action":"runtime"}`; the debug report carries it too.
* The tree, started on first use: root → `services` (permanent: `telemetry.flush`, which replaced a GCD timer; a hung
  flush is ended by its watchdog and restarted, without queuing another tick behind the stuck one), `jobs` (one per name:
  `memory.reflect:<lesson>`, `memory.consolidate`, `embeddings.warmup` (on a GCD thread, not the cooperative pool),
  `worktrees.prune`, and `lesson.compact#n` via `Runtime.call`, which retries a failed summary call with backoff before
  the digest fallback), `agents` (sub-agent runs). Root never gives up; it restarts a supervisor that did, with backoff.
* Watchdogs measure silence, not running time: a job's work gets a heartbeat (`Runtime.Job.beat`, `call`'s `beat`), and
  a model client wrapped in `BeatingClient` beats on every streamed event — so a long summary or reflection is never cut
  off mid-answer and billed twice; only one that goes quiet is ended (compaction 120 s, reflection 180 s).
* What it can't do: catch a Swift trap (force unwrap, out-of-range index, overflow) or a crash in a framework. Those end
  the app, so risky native work belongs behind a subprocess. Already out of process: shell and code (`bash`, `run_code`),
  Python/SymPy (`math`), ripgrep, git, and WebKit's content process (`WebWatchdog`). Still in process, on untrusted
  input: the HTML→Markdown converter (XMLDocument/libxml2, bounded but in-process), PDF text (PDFKit), image decoding
  (ImageIO), NaturalLanguage embeddings and SQLite — none is behind a subprocess today.

## Frozen pages
* Visuals run model-written JavaScript in sandboxed frames that share the transcript's process, so an endless loop
  would freeze the lesson. `WebWatchdog` pings each transcript (and sub-agent) page every 2 s while its window is
  visible; after 8 s without an answer it ends the web process, reloads, and the lesson renders again with visuals
  paused behind ▶ Run (a notice says why). `MyAITeacher --webtest --watchdog` checks this end to end.

## Testing
* `scripts/e2e.sh [--live]` — the whole loop: build, unit tests, renderer suite (light + dark), and with `--live`
  the scripted lessons. Run it after every change.
* `swift test` — unit tests (SSE/think-tag parsing, FSRS, BKT, grader, math equivalence, HTML→Markdown, workspaces,
  memory, deadlines, sub-agent model choice / failure / cancellation). `RuntimeTests`: mailbox order, both restart
  strategies, intensity and per-child limits with backoff, restart policies, watchdog, stop without leaked tasks, links and
  monitors. `SubAgentTests` (a scripted fake model): budgets, types, read-only and grant ceilings, structured output with
  repair, steering, restart-and-resume, provider/model/effort choice (fuzzy, retired ids), nesting, memory bounds.
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

## Performance
* `scripts/perf/perf.py run [--workloads lesson,stream,recall,fetch,agents,render] [--allocations] [--system-wide]` —
  runs the release bundle (a copy in `--home`, default `/tmp/myaiteacher-perf`, re-signed with get-task-allow so tools
  can attach) on a throwaway profile and drives six workloads through debug hooks: a 4,000-message lesson
  (`seedLesson`, then paging back, leaving, reopening), a 60k-character streamed reply, recall over 10,000 memories
  (`seedMemories`, `recall`), web_fetch of a 3 MB page (`runTool`), four parallel sub-agents, and the renderer stress
  suite (`scripts/perf/render-stress.js`). Replies come from a local mock model (`mockllm.py`, free and repeatable);
  `--provider minimax` or an OpenRouter `:free` model run the same scenarios live.
* Recorded: xctrace Time Profiler attached to the app (`sample` in 2 s windows if xctrace can't start; never waits on a
  dialog), with `--system-wide` the WebContent stacks too (named with `atos`); main-thread hangs (xctrace plus the app's
  own `HangWatch`); `os_signpost` intervals (`Telemetry/Signposts.swift`: turns, model streams, tools, render batches,
  SQL, lesson loads, recall, context, compaction, HTML conversion; on only with `MYAITEACHER_SIGNPOSTS=1`); phys_footprint
  and CPU of the app and each WebKit process every 250 ms; with `--allocations` the live heap by allocating stack after
  each workload (MallocStackLogging, `heap`, `malloc_history`, `vmmap`, `leaks`).
* Output in `<home>/runs/<label>/`: `report.html` (one file, no network: flame graph, CPU heatmap, memory and CPU per
  process, signpost p50/p95, hangs with the main thread's stacks, allocation stacks), `summary.json`, raw traces.
  `scripts/perf/top.py RUN [--workload w --kind WebContent]` lists the heaviest frames as text.
* Regression gate: `--baseline FILE` saves a run's summary, `--compare FILE` (or `perf.py compare A B`) diffs every
  metric (all are costs) against thresholds (memory +10% and +15 MB, times +25% and +25 ms…; `--thresholds` overrides)
  and exits 1 on a regression.
* Freed memory stays in the footprint on this macOS (a 150 MB burst of 40 KB–3 MB blocks, freed, stays at 150 MB;
  `malloc_zone_pressure_relief` returns 0), so every transient peak becomes steady-state memory: keep peaks small.

| Measured (release, mock model, M5, sequential runs) | Before | After |
|---|---|---|
| Open a 4,000-message lesson / reopen it | 6.0–6.4 s / 26–28 s | **2.0–2.3 s / 2.1–2.4 s** |
| Main-thread stall opening it | 225–284 ms | **0** (none ≥ 100 ms) |
| WebContent CPU opening a 2,000-message lesson | 14.9 s | **7.0 s** |
| App footprint, peak while opening it | 139–157 MB | **111–114 MB** |
| App footprint after a 60k-character reply (long lesson reflected on) | 187–201 MB | **130–133 MB** |
| WebContent peak, 4,000-message lesson | 991–1,406 MB | **783–849 MB** |
| Renderer: reset 2,000 messages / page back 1,000 | 5.1–5.7 s / 1.6–1.8 s | **1.0 s / 0.7 s** |
| Renderer: 60k-character stream, frame p50 / p95 / max | 18 / 29 / 34 ms | **17 / 19 / 26 ms** |
| Recall over 10,000 memories (main thread) | p50 4–5 ms | same |

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
| Task / Agent | `task` + `agents` | types (explore/general/coder/reviewer/tester + app and `.teacher/agents/*.md`), provider/model/effort/budget per call, tool allow/deny, JSON-schema reports, steering notes, resume, nesting, worktree isolation, supervised restarts; never above the lesson's grants |
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
