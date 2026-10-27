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
  UI/          SwiftUI views + TranscriptView bridge + Inspector (files, plan, changes, browser, agents)
  App/         App entry, AppModel, settings, CLI (--cli), DebugHooks
Resources/web/ Transcript renderer (core app.js + registry.js + icons.js + components/*.js)
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
* **Everything stays in the app.** Links open in a tab of the in-app browser (right panel → Browser; the learner's tab,
  so the agent sees it only on a site its lesson approved), files preview in the inspector, mailto copies the address. Nothing launches Safari, Mail or Finder.
  Visuals run in sandboxed iframes (`allow-scripts` only, CSP `connect-src 'none'`) with libraries from `teacher-lib:`.
* **Storage writes.** A write whose failure the caller can't act on uses `db.run(…)` (or `db.write("what") { … }` for
  several statements), which logs to `Log.db`; never `try? db.execute`. Statements that must change together go in one
  `transaction` (a lesson message and its blob references, a lesson delete); transactions nest as savepoints. A row id comes from `db.insert(…)` (statement and id under one lock), never a
  separate `lastInsertRowID` read.
* **Tool gates compose.** Every extension's `shouldRun` is consulted in registration order: a deny ends it, and an
  approval the learner gives moves on to the next gate (an approval for one gate never skips another).
* **One HTTP session.** All model streams share `SSEClient`'s `URLSession` (per-task delegates), so steps and parallel
  sub-agents reuse the provider's warm connection instead of a new TLS handshake per request.
* **Quick questions** live in `~/.teacher/no-dir-conversations` (full access by default, no folder prompt).
* **Python** (`run_code` python and `math`/SymPy) follows Settings → Python: run without asking (default), ask, or off.
  Package installs (pip/uv/conda/brew/npm -g, also from inside code) are always refused.

## Context and cost
Every request = fixed prefix (system prompt + tool schemas) + history prepared by `ContextPolicy` (all O(n)):
1. **Deferred tools.** An agent's core tools are always sent (a tutor's 14); the rarely used ones (a tutor's 9, per
   `AgentTree`) are listed by one line each and loaded with
   `load_tools` (or automatically on first direct call). Tool order only ever grows, so the cached prefix holds.
2. **Old reasoning** is not resent (except Claude adaptive thinking, which must replay).
3. **Microcompaction epochs.** Past 70% of the budget, bulky tool results/inputs and images older than the last 3
   turns become head+tail stubs. The cut point jumps (epochs), so the prefix stays cacheable between jumps.
4. **Summary compaction** only if still over budget; keeps ~30% of the budget verbatim, counted in tokens (script-aware).
   `compactIfNeeded` returns the request-ready history, so a step prepares it once. Token estimates are cached per
   message (id + size), so the two or three estimates a step makes don't rescan a long lesson.
6. **Sub-agents** stub tool results older than their last 4 steps inside the current brief too (a research run has one
   brief), except when signed thinking is in the history; they keep thinking signatures so reasoning replays with tool calls.
5. **Budget** = min(Settings → Context budget, half the model's context window from provider metadata).

Model metadata (context window, max output, reasoning, vision, tools, free/pricing) comes from each provider's
`/models` (OpenRouter, Anthropic, Gemini, Groq, Mistral, OpenAI-compatible shapes), cached on disk for 24 h. It sets
`max_tokens`, hides thinking options for non-reasoning models and shows badges in the model picker. OpenRouter needs
reasoning disabled explicitly; models that require it fall back to low effort (learned at runtime).

Prompt caching: the system prompt starts with instructions identical across lessons; lesson context (date, memory,
folder) comes after `# Environment`. Anthropic-format requests send them as two cached blocks plus tools and the last
message as breakpoints; other providers cache the shared prefix implicitly. The plan, review and compaction-summary calls
opt out (`LLMRequest.cache = false`): their prefixes can never be read back, so their cache writes were pure cost. Their
usage is counted in the turn, the lesson and the usage log, so the cost dashboard is not 30–100% short.

Per-turn hidden context (`<context>` memory recall, the plan, revision notes) is marked `ephemeral`: after its turn,
microcompaction stubs it like a bulky tool result instead of re-sending it for the rest of the lesson. Token estimates are
script-aware (CJK/kana/Hangul ≈ 1 token per character, Latin ¼), because `chars / 4` under-counted a Japanese lesson 4–6×
and let requests run past the budget before compaction fired. The lesson window is also trimmed at load, and
`windowTrim` always makes progress when one long turn exceeds the window.

| Measured (free model `minimax-m3.1-flash:free`, OpenRouter) | Before | After |
|---|---|---|
| Fixed prefix per request | ~6.8k tok | **~4.35k tok** (−36%) |
| Output tokens, "thinking off" visual request | 7,194 | **1,258** (reasoning now actually off/low) |
| Cache hit, later steps of a lesson (real lessons) | — | **71–82%** |
| Cache hit, first request of a new lesson (shared prefix) | ~1% | **~5k of ~5.05k tokens** |

## Evaluations
Comparisons run offline, never randomised for learners: the course board system's three arms are forced with
`MYAITEACHER_EXP=course_board=nested|shallow|off` or the CLI's `--exp` (`BoardSystem`, `scripts/ab-board.py`), and a
mentor's lessons are measured headless (`--lesson`, `scripts/mentor-bench.py`). An in-app A/B framework (per-lesson
arms, exposure telemetry, an Insights card) once tested the `visual` tool's placement — rewording mattered more than
placement, so it is runtime-loaded — and was removed once nothing used it.

## Live visuals and practice
* ```` ```visual ```` fence (no extra round trip) or the `visual` tool (persists to `.teacher/visuals/`). Runtime:
  scripts run through indirect eval with async callbacks wrapped, so real error messages reach the learner and the
  Fix button sends them to the teacher; frames size to their content and load lazily.
* ```` ```practice ```` self-check cards and ```` ```steps {"reveal":true} ```` worked examples run entirely in the
  transcript (no tool call, nothing added to the context). Once every practice card is marked and one was missed, the
  result goes to the teacher unasked.
* ```` ```problem ```` cards are attempt first: the teacher's hints and solution stay hidden until the learner sends
  an attempt (it arrives as their message) or opens them. Opening help posts `study` events (logged as help); a solution
  seen before any attempt is also told to the teacher with the learner's next message (`ChatSession.studyNotes`). After
  90 s in view with nothing typed, the first hint opens by itself, once.

## Native hardware
WebKit renders the transcript in its own GPU-accelerated process; visuals run in sandboxed frames inside it.
NaturalLanguage (embeddings, language ID), Speech and the on-device language model (titles, ~0.5 s) run locally on the
Neural Engine/CPU; tool calls run in waves (consecutive read-only and network calls — reads, searches, fetches,
sub-agents — at once; a write, command, browser action or question alone, in the model's order); telemetry writes on a
background queue; SQLite uses WAL. Profiled with `scripts/perf` (mock model): the main thread is idle most of a turn and
its short stalls are WebKit IPC and transcript repaints, not computation, so there is no hand-written assembly — the
CPU-bound work is already native (ripgrep for `grep`, Accelerate for pitch, loudness (`Loudness`, one `vDSP_rmsqv` per
frame) and memory search, the Neural Engine for embeddings). Text scans over whole pages run on UTF-8 bytes in
`FastText`, 16 at a time with SIMD through plain ASCII and Unicode-exact elsewhere: token estimates (~20× the scalar
loop), whitespace collapsing in page conversion (42 → 2 ms/MB), and the word splitting of passage ranking (71 → 19
ms/MB) and memory indexing (85 → 58 ms/MB); `FastTextTests` checks they match the code they replaced on random text.
A lesson turn holds `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)` for its duration: the learner now
leaves for their own editor mid-turn, and App Nap would otherwise throttle the stream and tool processes.

## Transcript rendering
* Text deltas leave Swift on a `CADisplayLink` from the transcript's own view (`NSView.displayLink`) and land in the
  page's `requestAnimationFrame` loop, so a reply advances at the display's refresh rate (120 Hz on ProMotion) instead of
  a fixed 60 Hz timer. A hidden window's paused rAF is backed by a 120 ms timer.
* A frame rebuilds only what changed: finished markdown is cached by content, tool cards are memoised on everything their
  HTML depends on (result, meta, open state, progress), thinking streams as one text node and becomes markdown once it
  finishes, and an open code fence over 1,600 characters stays plain until it closes (highlighting the growing fence on
  every frame is quadratic).
* A plan is rendered from its structured modules — status mark, numbered title, objectives — never as one markdown
  paragraph; the model still gets the plan as list-shaped markdown.
* The renderer consumes a typed tree, not blocks: `nodes.js` projects each message into `message { children: [node] }`
  with stable ids (tool calls by call id, the rest by position), explicit tool-call → result links, and a vocabulary of
  six node types (text, thinking, tool, attachment, agentReport, error). Markdown is a leaf, not re-parsed into nodes;
  tool calls, thinking and results stay the structured events the providers already send. The model never writes the
  tree — it writes markdown, native tool calls and fences — so prose, streaming and small models are unaffected.
* Three registries in `registry.js`: `defineNode` (the node renderers, owned by `app.js`), `defineTool` (one
  descriptor per tool in `components/tools/`: icon, title, summary, body, open, compact; a generic default covers any
  tool without one) and `defineComponent` (rich blocks: parse → `schema`/`validate` → render inside an error boundary,
  with `pending`, `prose`, `fallback`, `mount`/`unmount` by selector, `styles`). A failing node, tool or component
  renders a readable box in place; an unknown block kind a fallback node. `registerFence`/`registerToolCard` remain as
  adapters. ```ui {"component": "chart", "props": {…}} renders any component by name; unknown names show their props.
* `index.html` lists no component: `components/manifest.js` is generated by `scripts/gen-web-manifest.py` from the files
  under `components/`, `bootstrap.js` loads them in order and then the core, and modules marked `// @lazy` (the plotter)
  load the first time a reply uses one of their components. A test fails when the manifest is stale.

## Adding features
| You want to… | Do this | Core changes |
|---|---|---|
| React to the agent loop (inject context, gate tools, observe results, act after a turn) | Implement `AgentExtension` (all hooks optional) and register it in `AppModel.registerExtensions()` | none |
| Add a feature with its own tools and hooks | One `Features.Module` (id, `tools`, `extensions`) in its folder, listed in `Features.all` (see `ComputerUse/ComputerUseFeature.swift`, `Study/CourseBoardFeature.swift`); name its tools in `AgentTree` for the agents that may use them | none |
| Listen to app events (UI badges, logging, sync) | `EventBus.subject.sink { … }` (`AppEvent`) | none |
| Add a tool | Conform to `Tool` (name, description, JSON schema, `risk`, `run`) and add it to `ToolRegistry.all`. Sub-agents get it only if it returns `self` (or a restricted variant) from `subAgentVariant`. `risk` drives permissions; interactive tools await `ctx.interactions.request(…)` | none |
| Add a provider | Add a `ProviderConfig` preset (Anthropic/OpenAI/Gemini wire format + quirks) to `ProviderCatalog`, or add a custom provider in Settings | none |
| Add a wire protocol | Implement `LLMClient` (emit `StreamEvent`s) and a case in `APIKind` | 1 switch |
| Summarise a long history (another agent, an import) | `Compaction.summaryRange(…)` picks the messages, `Compaction.summarise(…)` writes the rolling summary (digest fallback, usage per call, cancellation-safe) | none |
| Gate tool calls (budgets, policies) | Implement `shouldRun` in an `AgentExtension`; gates chain in registration order (`ExtensionHost.chain`). A gate that must wait on slow work (a command) returns `.pending { … }`, which the loop awaits without holding the main actor | none |
| Do slow work at a turn's edges or after a call | `willStartTurn` (the message that starts a turn: add to it or hold it back), `afterRun` (append to a result), `willEndTurn` (send the agent back to work): async, awaited by the loop | none |
| Run background work | `Runtime.job(name) { … }` (one per name, watchdog, restart on a crash), `Runtime.call` (returns a value), `Runtime.every` (periodic service) — not `Task.detached` | none |
| Add a sub-agent type | Settings → Agents, or a `.teacher/agents/<name>.md` in the folder (or `AgentCatalog.builtIns`) | none |
| Render a new fenced block (```xyz) or ```ui component | `TeacherUI.defineComponent({ names: ['xyz'], schema, render(props, ctx, env) })` in a file under `Resources/web/components/` (`raw: true` for text forms, `// @lazy` at the top to load on first use), then `scripts/gen-web-manifest.py` | none |
| Add a question type | `TeacherUI.registerQuestionType('type', {render})` + grading case in `Questions.grade` | none |
| Present a tool | `TeacherUI.defineTool({ name, icon, tone, title, summary(node), body(node, ctx), open, compact })` in `components/tools/` (`icon` names one of `icons.js`'s line icons, `tone` its family colour: blue files, slate shell, green tests, teal web, purple memory, orange teaching, indigo agents; a `card` replaces the whole frame); tools without one get the generic card, which summarises their arguments | none |
| A new kind of block in a reply | `TeacherUI.defineNode({ type, render(el, node, ctx, env), unmount })` — the semantic vocabulary is small on purpose; most things are components | `nodes.js` |
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
* **Project profile** (`ProjectProfile.detect`, once per session when the prompt is built): the manifests at the top of
  the folder (Package.swift, package.json scripts and lockfile, tsconfig, Cargo, go.mod, pyproject, build.zig,
  Makefile targets, CMake, Gradle, Maven, Gemfile, mix, deno) → build / check / test / lint / format commands, languages
  by file count (code only; a bounded walk), git branch and dirty count, `.teacher/commands`. It is the `# Project`
  section of the agent's prompt and the default commands of `diagnostics`.
* **Verification loop.** `WriteTool`/`EditTool` in agent mode (`ToolContext.codeAgent`) run `Diagnostics.quickCheck`
  on the file (py_compile, node --check, ruby -c, zig ast-check, swiftc -parse, gofmt -e, zsh -n, JSON; ≤ 10 s) and
  append the verdict to the result (`meta.syntaxErrors` marks the card). `diagnostics` runs the project's check, test
  or lint command (or one given) and parses clang/swift/zig/go, tsc, rustc, python and eslint output into
  `file:line:col severity message`, grouped by file and capped (`Diagnostics.parse` / `summary`). `bash` with
  `background: true` runs detached (≤ 30 min) and delivers a `<background-task>` message through `ChatSession.deliver`,
  like a sub-agent's report (the page renders it as one); sub-agents' shells stay in the foreground. `ShellState` keeps
  the lesson's running background tasks by handle: Stop cancels them (the processes end, nothing is delivered), and a
  foreground `bash` result names the ones still running. A coder sub-agent working in the lesson's folder (no
  worktree) backs files up under the turn's checkpoint too (`ToolContext.checkpointTurn`), so Undo covers its edits.
  `ProjectProfile.detect` caches per folder behind a fingerprint of the manifests' dates and sizes (ten minutes; the
  git part refreshed after a minute), so neither the prompt nor `diagnostics` re-walks the folder.
* **Checkpoints and undo** (`Checkpoints`, `CodeAgentExtension`): registered before `PermissionExtension`, its
  `shouldRun` copies a file to `.teacher/checkpoints/<turn>/` before the agent's first write or edit to it in the turn
  (a created file is recorded as absent). `didFinishTurn` keeps only files whose content differs from the backup and
  stores `checkpoint` and `changedFiles` on the turn's metrics (optional fields, so older messages decode); the page's
  footer offers **Undo this turn's changes** (`revert` message → `Checkpoints.restore`), the agent hears about an undo
  with the next message, and the newest 40 checkpoints are kept. No git needed; the Changes panel's git checkpoints
  are the user's own.
* `symbols`: a file's outline or the definitions of a name across the folder, by per-language regular expressions
  (ripgrep for the search) — definitions, not mentions. `edit` matches a block whose lines differ only in indentation
  or trailing whitespace when that match is unique, and re-indents the replacement. `ProjectCommands`:
  `<name>.md` in `.teacher/commands`, `.claude/commands`, `~/.teacher/commands` or `~/.claude/commands` (first found;
  `ns/name.md` is `/ns:name`) typed as `/name args` in a code session goes to the agent as hidden context with
  `$ARGUMENTS` and `$1`…`$9` filled in; `/init` and `/review` are built in unless a file replaces them, and `/compact
  [focus]` makes `ChatSession.compactNow` summarise everything so far (`Compaction.codingPrompt`) with no model turn.
* **Writes never erase unseen work** (`FileViews`, per agent: `shellID ?? conversationID`, so each sub-agent has its
  own): `read`, `write` and `edit` record a file's modification date and size; `write` refuses an existing file the
  agent hasn't read or whose stamp changed since (the user saved it, a command rewrote it); `edit` applies (exact
  match) and notes the change. Code agent and code mentor only (`ToolContext.codeAgent`, which sub-agents inherit).
* **Approvals** (`PermissionExtension`, execute risk): a command `ReadOnlyShell.allows` (the reviewer's strict
  allowlist) never asks, and `bash` runs exactly those through `ReadOnlyShell.run` (no shell, git hardened), so the
  same strictness that lets it skip approval decides how it runs. `CommandRules`: "Always allow “npm test …” in this
  folder" stores a prefix in `AppSettings.commandRules[folder]` (never in the folder, so a repository can't approve
  itself); a rule matches one simple command (no `; & | < > ( ) { } $` backquotes, backslashes or newlines outside
  single quotes; one leading `cd dir &&` allowed). git and hg never get rules: a repository's config can make them run
  programs, and a rule would let variants of their looking commands run outside `ReadOnlyShell`'s hardening. Package
  installs ask in agent mode, stay refused in lessons.
* **Arguments.** `ToolArgs.canonical` renames other agents' argument names (`file_path`, `run_in_background`,
  camelCase) to the tool's own in `ChatSession.execute` and the sub-agent loop, before any gate reads them.
* **Plan mode** (`PlanModeExtension`, before the permission gate; `Conversation.planMode`, ⇧⌘P or the composer): a
  hidden note on each message while it is on (and once after it goes off); `refusal` lets through only what looks —
  read-only risks, `ReadOnlyShell` commands, new `explore`/`reviewer` sub-agents (no resume or steering),
  `todo_write`, `project_memory`, `ask_learner`, the browser's reading actions. `exit_plan_mode` shows the plan
  (rendered Markdown on its card) under Approve / Keep planning; approval (`meta.planApproved`) turns plan mode off in
  `didRun`. It gates new calls only: a background coder started before plan mode went on keeps working.
* **Hooks** (`HooksExtension`, registered after `PlanModeExtension` and before `PermissionExtension`: a call plan mode
  refuses runs no hook, and a call a hook blocks is never put to the user). `HookSet` parses Claude Code's `hooks`
  JSON from `AppSettings.hooks` (Settings › Hooks) and the folder's `.claude/settings.json` + `settings.local.json`;
  matchers follow Claude Code's rules over both its tool names (`HookSet.claudeNames`) and the app's. `HookRunner` runs
  `/bin/sh -c` in the folder through `ProcessRunner` (off the main actor; `$CLAUDE_PROJECT_DIR`; the event as JSON on
  stdin, long strings clamped; per-hook timeout, 60 s default, 600 max; 64 KB of output kept, 8k characters shown to the
  agent), the matching hooks of an event at once, and maps exit codes and JSON decisions to `HookOutcome` (exit 2 or
  `block`/`deny` blocks; `ask` asks; `allow` is ignored, so hooks never widen permissions; other exits are reported to
  the user). The extension points: PreToolUse is `shouldRun` returning `ToolDecision.pending` (awaited by
  `ChatSession.execute`, chained like an approval by `ExtensionHost.chain`); PostToolUse is `afterRun` (successful calls;
  output and a "the hook rewrote the file" note appended to the result); UserPromptSubmit is `willStartTurn`
  (`ChatSession.admitPrompt` for turns `send`, `edit` or queued messages start: hidden context, or the message is
  removed and its text returned to the draft); Stop is `willEndTurn` (a hidden note and another step, at most
  `ChatSession.sendBackLimit` times per turn). Code agent only; sub-agents' calls don't pass through the extension
  host. A folder's hooks run only when `AppSettings.approvedHooks[folder]` equals the configuration's `fingerprint`
  (SHA-256 of every event, matcher, timeout and command), so a cloned repo never runs anything and any change asks
  again; the question is an `.ask` on the lesson's first tool call (cards render on tool calls), listing every command,
  and a decline holds for the lesson.
* **Queued messages.** `send` while a code agent runs appends to `ChatSession.queued` (shown above the composer, each
  can be taken back); `drainInbox` adds them, with a hidden note and the usual `willSend` context, at the next step
  boundary, and a reply with no tool calls continues instead of ending the turn. A turn that ends without reading
  them (an error, the step limit) starts the next one with them; a stopped turn hands their text back to the draft.
* **MCP client** (`MCP/`): stdio servers (newline-delimited JSON-RPC 2.0 on a child's stdin/stdout, `MCPStdioTransport`:
  `posix_spawn` in its own process group with only fds 0–2, stdin `F_SETNOSIGPIPE`, stderr into a 64 kB `MCPLog`) and
  streamable HTTP (`MCPHTTPTransport`: a POST per message, the reply as JSON or as an event stream that may carry
  notifications and the server's requests first, `Mcp-Session-Id` from `initialize` and `MCP-Protocol-Version` after
  it on every later message, DELETE on close, a 404 ends the link). `MCPConnection` matches responses by id, follows
  `tools/list` pages, answers the server's `ping` and `roots/list` (the folder), routes `notifications/progress` to the
  call that sent the token (its card's progress), sends `notifications/cancelled` on a timeout (300 s) or Stop, and
  fails every waiting call at once when the link ends. Results: text parts joined, images kept, resources as a line,
  `structuredContent` when there is no text, `isError` kept.
  * **Config** (`MCPConfig`): `AppSettings.mcpServers` (Settings → MCP) and the folder's `.mcp.json` (Claude Code's
    format; parsed once per modification date); a project server wins a name clash. `${VAR}` / `${VAR:-default}`
    expand from the user's shell environment when a server starts, never in what an approval shows. A project server is
    usable only when `AppSettings.mcpProjectDecisions[folder][name]` holds an approval for its `fingerprint` (a hash of
    type, command, args, env, url, headers, unexpanded), so a changed `.mcp.json` asks again; decisions live in the
    app, never in the folder.
  * **Supervision** (`MCPInstance`, one per folder and server, `MCPHub.instance`): a transient child of Runtime › `mcp`
    started on first use (a call, `load_tools`, or listing tools never seen before); a link that ends by itself is a
    crash, restarted with backoff (3 in 60 s, 1 → 8 s), after which it is `failed` until the next use starts it
    afresh. Stop (Settings, a config change) terminates the child; `applicationWillTerminate` → `MCPHub.shutdownNow`
    SIGTERMs every group and SIGKILLs what's left within 200 ms, marked so the exit isn't restarted.
  * **Tools** (`MCPTool`, `ToolRegistry.named` / `active(folder:)`): `mcp__<server>__<tool>` (unsafe characters as
    `_`, 64 at most with a hash suffix), the server's input schema (`$schema` dropped), `execute` risk. Only nodes with
    `AgentNode.mcp` (the engineer) get them, always deferred: `MCPHub.promptSection` writes a `# MCP servers` section
    after `# Environment` with one line per tool (first sentence, "(read-only)"), the servers' `instructions`, and a
    line per project server awaiting approval. Tool lists are remembered by fingerprint in `mcp-tools.json`, so a
    lesson's prompt starts no server it has listed before. `load_tools` takes tool names or a whole server
    (`mcp__<server>`); for an unapproved project server it asks the user first (a `permission` card showing the
    command) and stores the answer. A direct call to a known MCP tool loads it like any deferred tool.
  * **Gates**: `PermissionExtension.mcpGate` asks for every call regardless of folder access (once, the server for the
    lesson, or `AppSettings.mcpAlwaysAllow[folder]`); `PlanModeExtension.refusal` lets an MCP tool through only with
    the server's `annotations.readOnlyHint`. Sub-agents don't get MCP tools.
* **Instruction files** (`ProjectMemory.contextBlock`): the user's `~/.claude/CLAUDE.md` and `~/.teacher/AGENTS.md`,
  each parent folder's CLAUDE.md / AGENTS.md up to the home folder (outermost first), then the project's CLAUDE.md,
  .claude/CLAUDE.md, AGENTS.md, CLAUDE.local.md and .github/copilot-instructions.md; `@path` mentions of files that
  exist are appended (relative to the file, three deep, each once; 20k per file, 40k in all). A subfolder's own
  CLAUDE.md / AGENTS.md rides on the agent's first `read` of a file under it (`ProjectMemory.nested`).

## Browser and computer use (code agent)
* **Browser** (`browser` tool, right panel → Browser): WKWebView tabs over a persistent website data store of its own
  (non-persistent in test profiles), separate from the transcript. Links from lessons open in it as the learner's tabs. Off-panel tabs live in an
  offscreen panel so they keep rendering and can be screenshotted. A helper injected into an isolated content world of
  every frame builds the snapshot (roles, names, values, states; open shadow roots, same-origin iframes; cross-origin
  frames introduce themselves and are read on their own, refs `f2.ref_3`) and acts by ref with real event sequences
  (pointer/mouse/click, key/beforeinput/input, native value setter for framework-controlled inputs). Refs are stable
  per element and bound to their document (each answer carries the helper's token; a ref from an earlier page is
  refused). Console and fetch/XHR are captured in the page world; screenshots map back through their scale.
* **Fast by round trips**: `steps` runs up to 20 actions in one call (one envelope, stopping at the first failure);
  `snapshot: true` returns the controls after an action; an action reports the visible text it added (a confirmation,
  an error). After each action the tab settles by events, not a fixed pause: a navigation it started (seen within
  80 ms) until loaded, then the DOM until 100 ms without mutations (a click or key is watched for 0.35 s at least, for
  handlers on a short timer), then the requests it began. Approved cross-origin frames are snapshotted concurrently.
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
* Semantic recall uses Apple's 512-dim English sentence embedder. Non-Latin text gets no vector: encoded by the English
  model it was noise (Arabic related and unrelated sentences both ≈0.97 cosine, inside the store's 0.55–0.9 band, which
  made every pair *full* semantic evidence). Those memories fall back to lexical/FTS matching until a multilingual
  embedder ships. Latin-script text keeps the current model.

## Code mentor projects
* No `exercise` tool and no built-in editor. The mentor creates the starter files directly in the lesson folder (`write`/
  `edit`, gated by the folder grant) and writes the project's tests to `<folder>/.teacher/tests/`, run with `bash`. The
  learner edits in any external editor and asks the mentor to check; `bash` runs the tests where the files are.
* `.teacher/tests` is the only `.teacher/` path the agent may write (`PermissionExtension`, `SubAgentPolicy`);
  `.teacher/.gitignore` keeps `tests/` versioned alongside the project while the rest of `.teacher/` stays private.
* The mentor's shell is an ordinary shell in the folder — no scratch sandbox, no hidden test store, no reference
  solution, no leak detector and no CodeMirror bundle. The folder access grant and approval prompts are the boundary.
* **The review loop as mechanism** (`Study/MentorProject.swift`, `Tools/MentorTools.swift`, `Extensions/CodeMentorExtension.swift`).
  `.teacher/project.json` holds the project: title, concept, test command, every test run, the review rounds.
  `project_tests` set registers the command and runs it: red on the starter is the exit code (any runner, any
  language — `TestOutput.parse` reads pytest, jest/vitest, go, cargo, swift, zig, rspec/ExUnit, ctest summaries into
  counts for display, with colour codes stripped, and a summary that disagrees with the exit code is ignored). A suite
  that exits 0 on the starter is refused (vacuous); a command the shell can't run (126/127) or that times out is
  refused with its output; otherwise the output tail goes back to the mentor, which judges whether red means failing
  tests rather than a build error. Then it snapshots the learner's files (`.teacher/review/snapshot/`, text files only,
  bounded) as the baseline. `project_review` start runs the tests, diffs the files against the snapshot (`/usr/bin/diff
  -u` per changed file, capped) and returns the diffs, the run and the open findings; `findings` records the round
  (file, line, severity, text, concept), carries unresolved findings forward, marks resolved ids, takes a new snapshot,
  refuses a pass that still carries a `must`, and on a pass with the last run green records the project's concept with
  `StudyStore.recordAttempt`. A round belongs to a `start` that found changes (`openReview`); a pass needs that run
  green and the tests locked, and a `must` counts as resolved only when its file is among the changed ones. A project is
  **open** from its baseline until a review passes (`MentorProject.isOpen`); after a pass `set` starts the next project
  (the finished record is kept in `.teacher/projects/<n>.json`). After the baseline the tests are locked;
  `project_tests` unlock (an approval the learner gives, or the Project panel) opens them until the next `set`, which
  re-baselines and logs the change. `findings` carries a hint ladder per finding and the help the mentor gave; the
  learner's revealed hints and hint requests are `help` on the record, so a pass after help is recorded with
  `Help.hint`/`.solution` (evidence, not unaided mastery) and schedules a reimplementation follow-up; a pass opens an
  explain-back (`explain` grades it).
  `MentorGuard` holds the boundary while a project is open, and knows no language: `write`/`edit` of the learner's
  existing files or `.teacher/` (except `.teacher/mentor/`, and the tests while unlocked) are refused; new files are
  allowed. Every command tool (bash, run_code, run_tests, diagnostics, project_tests, project_review) runs under a
  `WriteFence` (`Core/WriteFence.swift`): a `sandbox-exec` profile, set as a task-local around the call, that
  `ProcessRunner` and `ShellJob` start their programs under. It denies writing each learner file and anything under
  `.teacher/` but `mentor/` (and `tests/` while unlocked); everything else stays writable, so every toolchain's build
  output works (`cc -o runner`, `javac -d classes`, `cargo`'s target/…). A refused write gets a note to the mentor.
  `task` starts only read-only types. What the guard stops is logged on the project.
  *Removed after measurement (2026-10-25):* a regex detector that withheld "solution code" from replies, tool inputs,
  tool output and thinking. It recognised function definitions in 10 of 24 languages tried, withheld the original
  source in 4 of 4 reimplementation projects (std's `array_list.zig`, Go's `container/list`, `container/heap`,
  `sort/search.go`), and with it `targets`, the starter-stub check, the HMAC seal on the record and the tests digest.
  The solution rule is the mentor's instruction and the DeepWork reviewer's check, which read any language.
  The Project panel (Inspector → Project, `UI/ProjectPanel.swift`) reads the record: the test trend, failing tests
  (rerun one via `ProjectTestRunner.filtered`: pytest -k, jest -t, go -run, cargo, swift --filter, zig test
  --test-filter; a hint request), open findings by file (hint rungs, open in an editor at the line, show in Files,
  copy path:line), the diff since the baseline, the protection state and the guard's log; Run tests, Request review
  (after a self-review sheet, kept with the round), Unlock the tests, Restore (the learner's files back to the last
  review, current versions to the Trash) and a Markdown report.
  **Measuring it.** `MyAITeacher --lesson spec.json` (`App/HeadlessLesson.swift`) runs a real lesson — the same
  `ChatSession`, tools and extensions — with no window, on its own `MYAITEACHER_HOME`, a hard time budget per turn,
  approvals given once and questions skipped, and prints one JSON line per turn (time to the first reply, tools, tool
  errors, the reply, the project record). `scripts/mentor-bench.py --bin <binary>` runs ten scenarios with it in
  parallel (beginner, expert, PhD, an unfamiliar language, data structures, seeded C/Elixir/Java/debugging projects
  reviewed after the learner's solution, a non-programming lesson; about ten minutes), with an optional judge;
  `scripts/bench-stats.py` counts what the app's own mechanisms did in those transcripts (nudges, revisions,
  answer-first notes, guard refusals, repeated replies). Comparing two binaries on it drove the changes below:
  against the build before them, answered within the budget went from 3 to 10 of 10, seeded projects passing review
  from 1 to 4 of 4, guard refusals from 16 to 1.
  **Answer first** (`Extensions/AnswerFirstExtension.swift`): "verify before you teach" has no natural end for a model
  (34 tool calls reading rustc for an expert's question; a PhD question where it built the OCaml compiler from
  source), so after 12 tool calls with no reply the learner can read, results carry a note to answer now, and at 24
  the next request offers no tools. Teaching modes only. A reply that hands over to the learner ("When you're done,
  ask me and I'll review") ends the turn: the "unfinished" rule had flagged all six such hand-offs it saw.
  `scripts/eval-mentor.py` runs mentor lessons through the built app (beginner, expert, an unfamiliar language,
  seeded C and Elixir projects reviewed after the learner's solution, a non-programming lesson), records friction
  (tool errors, seconds, registration, passes) and has a judge score level fit and responsiveness; `--repo` compares
  two builds. `MentorProbeTests` (MENTOR_PROBE=1) registers and passes a project in every toolchain installed.
  `CodeMentorExtension` appends a `<project_state>` line to every request
  (tests, files changed since the baseline by date and size, open findings) and nudges after tests are written. Code
  mentor mode also gets the engineer's tools (`symbols`, `diagnostics`, `project_tests`, `project_review` core), syntax
  checks after its writes, per-turn checkpoints of its scaffolding, and the project profile in its prompt.
* **Learning a language or library from its source** (`Tools/SourceTool.swift`): `source` resolves a library by name
  to where it lives on this Mac — Zig's std (`zig env`, via `Toolchains`), Rust's std/core/alloc (`rustc --print
  sysroot` + rust-src), Go's GOROOT/src and module cache, Python's stdlib and any importable module (`importlib`;
  built-ins without Python source are named as such), npm packages under the folder's `node_modules`, Cargo registry
  crates, SwiftPM checkouts, or a folder path — then locates, finds files by name, outlines (`SymbolsTool.outline`),
  reads numbered line ranges and greps within it. Roots are cached per launch. Core in Code mentor mode, deferred in
  other lessons; the instructions make the installed source the textbook and the projects reimplementations of it.

## Language mentor
* **Mode `language`** (`Instructions.mode(.language)`), with `language` and `vocab` as core tools (deferred in every
  other mode, loadable with `load_tools`). `LanguageTool`: profile (target/native/level in the `languages` table),
  transliterate (ICU `StringTransform`s; romaji through the keyboard's own table, since ICU reads "nn" as a doubled
  consonant), analyze (`NLTokenizer` word units + `NLTagger` lexical class and lemma, a Latin reading for other scripts),
  dictionary (Wiktionary's keyless REST definitions). `VocabTool`: the `vocab` table, each row linked to a flashcard in
  "<Language> vocabulary" (FSRS review in the Flashcards screen; `LanguageStore.swift`).
* **Runtime detection.** `LanguageExtension` computes a `LanguageState` per lesson: the language the learner asked for
  (a trigger-word window over their messages against `Languages.names`), else the most frequent non-native language of
  the replies (`lang=` tags and scripts, cached per message; replies already carry `meta.languages`), with the profile
  adding the level; the learner's own language is the dominant language of their messages. The state goes to the page
  (`T.setLanguage`, on reset and after every turn) and to `ChatSession.language` (the composer), and a one-line
  `<language_state>` is appended to the last learner message of every request (request copy only, like the board card).
* **Keyboard.** `Resources/web/keyboard-layouts.js` is the one layouts file: the page (`components/keyboard.js`) and the
  composer (`KeyboardLayouts` + `ScriptKeyboardView`, which parse the JSON after the assignment) both read it, with the
  same modes (tap, kana/romaji, "Mac keys"), compact/full state, helpers and tests. Composition lives in both
  (`keyboard.js` and `ScriptComposer`): Hangul jamo → syllables with compound vowels and finals and jamo-wise backspace;
  kana ゛゜ and small forms; romaji → kana syllable by syllable as typed; pinyin tones by key (tone1–4, cycle) or typed
  digit, placed on the last syllable (initial + final, so "nǐhao3" marks "hao"); combining marks (Vietnamese tones,
  niqqud, harakat) folding into the previous letter; `abugida` (a Devanagari/Bengali vowel letter after a consonant
  becomes its sign). `physical`/`physical_shift` rows map the Mac's key positions (event.code on the page, key codes in
  the composer) to the script's standard layout (Arabic PC, ЙЦУКЕН, 2-set Korean, InScript, Kedmanee…), and the key
  lights up. Kana before the caret that spell a saved word offer its kanji (`StudyStore.kanaWords`, sent with
  `T.setLanguage`). `InputSources` (Carbon TIS) finds the Mac's input source for the language: "Use Mac input" selects
  it (restored when the keyboard closes), "Add Mac input…" opens Keyboard settings — enabling one is the learner's call.
  On the page the panel opens by itself only for a field whose question has the target `lang` (or whose prompt is in the
  language); others keep the ⌨ toggle. The composer's language button and keys sit in a `FirstMouse` host
  (`NSHostingView` accepting the first mouse down): a SwiftUI button in an inactive window only activated it. Keys go to
  the composer of the keyboard's lesson (`sessionID`). Spell-check: every page input/textarea gets `spellcheck="false"`
  (`quietInputs`, all modes); the composer's spell-checker is off while a language is taught, and its autocorrect,
  grammar check and completion are always off.
* **Components** (`components/langlearn.js`, `components/langwork.js`): `gloss`, `listen`, `dialogue`, `conjugation`,
  `tones`; `reading` (Intl.Segmenter words until the app's `LanguageWork.analyze` answers with UTF-16 offsets, readings,
  lemmas and saved/known marks; ruby for all / new / no words; click a word → `LanguageWork.lookup`: reading, Wiktionary
  senses for the language section, else `DCSCopyTextDefinition`, deck status; translate a sentence →
  `LanguageWork.translate`: Translation framework when the pair is installed, else the on-device Foundation model,
  labelled; save with the sentence; sentence-by-sentence speech with `onFinish` → `T.lang('spoken')`, shadowing pauses;
  Done → `reading_log`); `correction` (the learner's text against the corrected one, word by word, errors with type and
  why, rubric, "more natural", a second attempt checked on the page). The bridge: page `{type:'langwork', op}` →
  `T.lang(kind, key, data)`.
* **Questions.** `speak` (`dictate` with the target → `T.dictation(key, text, final, info)` with the engine, the
  alignment and the pitch), `dictation` (`listen` is the key), `translate`, `rewrite`, `build_sentence`, `table`, and
  `rubric`/`min_words` on written ones. `TextDiff` aligns in order (LCS over words; characters for unspaced scripts;
  Japanese by kana reading unless strict, or by writing when that matches better) for dictation, speech and the cards.
  `accents: "strict"` keeps diacritics; harakat/niqqud are optional otherwise; pinyin marks and numbers agree. Written
  answers the app can't check come back with how to answer them (a ```correction per answer). Questions whose text
  slips into another script, or into simplified Chinese inside Japanese, are refused before the learner sees them; `vocab`
  add flags readings that contradict the dictionary.
* **`<language_state>`** also names the words due (to reuse in new sentences) and the week's reading.
* **Speech** (`Speech`, `SpeechEngines`, `OpenSpeech`). Recognition per language, best first: Apple's on-device
  SpeechAnalyzer (`SpeechTranscriber`, or `DictationTranscriber` where it has no model) when its model is installed
  (Settings › Voice downloads it through `AssetInventory`); Whisper when the learner installed it and the Mac would
  otherwise go online; else `SFSpeechRecognizer` (on device only for English on the test Mac). The card names the
  engine and says when audio went to Apple. The final result carries the pitch of the learner's voice against
  `AVSpeechSynthesizer.write` of the target (YIN F0 at 8 kHz, semitones around each median, 80 points, correlation),
  labelled as melody only. Voices: the best installed per language; the open-source voice when the Mac has only a
  compact one ("auto"). `OpenSpeech` downloads sherpa-onnx 1.13.8 (arm64 shared: bin/ + lib/), Supertonic 3 and
  Whisper large-v3-turbo int8 on request into Application Support/MyAITeacher/speech/, checks each file against a
  pinned sha256 (or git blob sha1), unpacks with /usr/bin/tar, and runs `sherpa-onnx-offline(-tts)` as subprocesses;
  any failure falls back to the Mac's engines.

  | Measured on the dev Mac (macOS 27.0.1) | ja | zh | ko | ar | es | fr | de | ru | hi |
  |---|---|---|---|---|---|---|---|---|---|
  | Mac voices installed (all compact) | 9 | 18 | 9 | 1 | 18 | 18 | 9 | 1 | 1 |
  | SFSpeechRecognizer | online | online | online | online | online | online | online | online | online |
  | SpeechTranscriber (on device, download) | ✓ | ✓ | ✓ | — | ✓ | ✓ | ✓ | — | ✓ |
  | DictationTranscriber (on device, download) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
  | Supertonic 3 voice (open, 129 MB) | ✓ | — | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
  | Whisper large-v3-turbo (open, 1.04 GB) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
  | Foundation model (translation fallback) | ✓ | ✓ | ✓ | — | ✓ | ✓ | ✓ | — | — |
* **Own texts and lookups anywhere** (`langwork.js`). A learner message with a pasted passage, an attached text/PDF
  (its text, or OCR of a photo) or a web page link gets **📖 Read** (`R.userActions`): the text mounts as a `reading` card
  under the message (`mountOwn`; a page goes through `LanguageWork.page`: URLSession + `HTMLToMarkdown` + `FetchCache`,
  `plainText` strips Markdown, cut at a paragraph near 8,000 characters). One lookup popover (`#rd-pop`, on `body`, since
  messages use paint containment) serves the reader and any selection: mouseup in a message with ≤40 letters selected
  offers **Look up**, with the sentence around the selection for saving.
* **Real audio** (`MediaTranscript`, `MediaPlayer`, `Composer.attachMedia`). An attached audio/video file (or a direct
  link to one, `langwork mediaURL` → `Downloader.fetch`, ≤500 MB) is copied to `.teacher/attachments/media/`, decoded
  with AVAssetReader to 16 kHz mono, cut at pauses (energy VAD, chunks ≤26 s) and transcribed per chunk by Whisper when
  installed (else `SFSpeechURLRecognitionRequest`, labelled), sentences timed proportionally inside each chunk. The file
  block carries `meta.media` + segments; `R.fileView` draws the player: per sentence ▶, loop, 0.6–1×
  (`AVPlayer` with the time-domain pitch algorithm, a boundary observer ends the stretch → `T.lang('mediaDone')`),
  hidden/shown text, write-what-you-hear checked with `TextDiff`. The send waits while `pendingMedia` is non-empty.
* **Spoken conversation** (`ConversationController`, `UI/Conversation.swift`). Explicit **Talk** start/stop; each turn:
  `Speech.dictate(stopAfterSilence: 1.4)` (`SilenceWatch`: voiced ≥0.4 s, then quiet relative to the noise floor) → the
  heard text is sent with a hidden ephemeral note (`meta.spoken`: reply short, in the language, corrections held back) →
  the reply's plain text is spoken → listening again. **End** sends a closing turn asking for the held-back corrections.
  The bar names the recognition engine (and whether audio leaves the Mac).
* **Pronunciation from pitch** (`Prosody`). On a speak take's final result, next to the melody chart: Mandarin — the take
  is cut into one syllable per character (voiced stretches from 16 kHz YIN with parabolic interpolation, joined or cut
  at loudness dips), each classified (level/rising/low/falling) and checked against the dictionary tone after sandhi
  (3-3, 不, 一); a syllable is judged only when the same method recovers its tone from the synthetic voice. Japanese
  (≤8 morae) — morae as equal shares of the voiced time; the drop is the first point as high as anything before it that
  falls 2.5 semitones within 150 ms (none in the last mora: final lowering), learner vs the synthetic voice. Single
  words elsewhere — the most prominent syllable (pitch, loudness, length). `Prosody.summary` puts one line into the
  answer the lesson reads. Measured on Apple's voices: 妈麻马骂 4/4 (Tingting, isolated), connected sentences ~70%;
  accent drop 雨/飴 right on Kyoko and Eddy, about 7/11 words on Kyoko overall.
* **Structure** (`LanguageStructure.swift`). `language_skills` (CEFR per skill + evidence; "A2?" = provisional, no
  sample yet) and `grammar_points` (per language, level, order) with mastery in the `mastery` table under
  "<language> grammar"; `language` action=grammar records production evidence (the learner's sentence as the note).
  `<language_state>` names the levels and the next points (`nextGrammar`: shaky first, then unseen, up to a level above
  theirs). `VocabTransfer`: export TSV with Anki's headers (`#separator`, `#html`, `#deck`, `#tags column`, `#columns`)
  or CSV; import Anki text exports, CSV/TSV with named columns, and `.apkg` (unzipped with ditto, the SQLite `notes`
  table of collection.anki21/anki2; the zstd `.anki21b` is refused with how to export a readable package).
* **Kanji/hanzi through the deck.** `StudyStore.hanCharacters` lists the Han characters of a language's saved words in
  the order met, each known/learning/new from its words' FSRS state; `LanguageWork.lookup` adds `kanji` (each character
  of the word with the learner's other words that share it) and the popover draws it (`R.kanjiHTML`). Stroke order and
  components need KanjiVG (CC BY-SA 3.0) / KANJIDIC2 (CC BY-SA 4.0) as an on-demand download; not built yet.
* **After a graded result** the tool result (quiz feedback steps, `ask_learner` form answers) ends the reply with the
  feedback: no new quiz in the same reply.

  Translation framework: ja→en reports "supported, not installed" (a download in System Settings); the other pairs were
  not probed. Dictionary Services had only English–Urdu and Arabic–English dictionaries enabled.

## Depth standard
Every teaching prompt carries the same standard:
* no toy or textbook-filler examples: real systems, data, papers and failure modes;
* teaching pitched at the frontier, getting harder after successes;
* solve and verify with tools before teaching;
* specific and quantitative.

Sub-agents' report rules ask for full-depth, verified work, and the code agent for production-grade changes. Reasoning
effort defaults to high for lessons and sub-agents; the live harness still runs with thinking off.

## Learning first
Two kinds of default came out of the AI-tutor trials. Answers on demand helped practice and hurt exams (Bastani, PNAS 2025);
help the learner had to ask for went unused. So these are app behaviour, not just prompt text:
* **Attempt first, in every teaching mode** (prompt rule plus ```` ```problem ```` cards). Graded questions carry a
  `hints` ladder, opened one at a time; after 75 s with nothing done, the first hint opens by itself.
* **Only unaided success counts.** `StudyStore.recordAttempt(help:certainty:)`: a right answer after a hint or a shown
  solution is logged with no mastery gain. A guess earns less (BKT guess 0.5). A wrong answer always counts.
* **Wrong answers name their misconception.** Graded questions tag wrong answers in `misconceptions`, which the page
  never sees. A hit goes into the result, into learner memory (kind misconception) and into a re-check follow-up. The result
  asks the teacher to explain the misconception, teach a real gap before checking again, and never quiz the same point twice in a
  row. The old "one near-identical retry" rule produced quiz loops in live runs. A concept missed again in the same lesson
  gets a worked example instead of another quiz.
* **Quizzes can be switched off** (`AppSettings.quizzes`, the toolbar's Quizzes button; `Testing`). The switch is sticky and
  takes effect on the next request. While it is off, `TestingExtension` appends a note to the learner's message (request
  copy only), and graded `ask_learner` returns a refusal. Quiz and Exam prep modes always test.
* **Skips carry a reason** (`Testing.SkipReason`: need more explanation, too easy, not now, unclear). The tool result tells the
  teacher what to do about each. **Don't know yet** (certainty 0) is not graded or recorded; the result asks for teaching.
* **Exam-style quizzes:** `ask_learner` takes a `case` (Markdown shown above the questions) that the questions refer to.
  A graded quiz is `ask_learner` with `graded: true` (`GradedQuiz`); the separate `quiz` tool, a second name for it, is
  gone (earlier lessons still draw its cards).
* **Certainty per question** (Guessing / Unsure / Sure, in `responses`):
  * a confident mistake is re-checked tomorrow and its flashcards come forward;
  * a lucky guess is flagged for a later check;
  * Progress › Confidence check shows how often the learner is right at each level.
* **Follow-ups** (`followups`), matched by concept key:
  * `recheck`, after a wrong answer: 2 days, or 1 when the learner was sure;
  * `transfer`, 3 days after reaching mastery: apply it in a new context;
  * `missed`, a forgotten flashcard: expires after a week.

  Due ones go into the lesson's instructions (`TeachingContextExtension.followUpSection`), so the teacher raises them.
  An unaided answer settles a follow-up only once it is due: a right answer closes it, a missed transfer check becomes a
  re-check, and a missed re-check comes back tomorrow.
* Graded choice, true/false, numeric and math questions must carry an `answer`. Without one, nothing is auto-graded and the
  learner model learns nothing from the answer. Wrapped keys (`{"item": …}`) and lists of accepted math forms are read.

## Course board

The mentor's intent for a goal that spans replies and lessons lives on a **course board** (`CourseBoard`, persisted as
version 2 of `plans.data`; legacy `modules` plans convert on read), not in the transcript. A board has cards with
stable ids (C1…), one of five lanes — backlog, doing (the one focus card, WIP = 1), review, done, parked — a `next`
action, prerequisites (`after`), a `concept` for evidence, the teaching mode it is taught in, a revision and a capped log.
`lesson_plan` writes it (add / start / park / resume / complete / note / move / get / list, plus create / update); the
app's evidence and the learner's Park in the panel write too, and all three go through one lock
(`CourseBoard.writes`, `StudyStore.mutateBoard`), reading the board fresh. Validation is the feature: a second `start`
names the current focus, a card whose `after` cards aren't done can't become the focus (`force` when the learner
already knows them), `complete` needs evidence that says something ("quiz 5/5", not "done"), `park` needs a reason, a
second `create` in a lesson that has a board is refused (`replace` to start another), an empty modules update is
refused, and a card completed while its concept's mastery is low gets a Review card (the board is intent; mastery is
belief). A lesson works from one board (`board_links`, set when a board is created, named or resumed from Progress);
several lessons can share it. A resumed lesson opens in the board's mode, and its first request carries the resume
brief (`mode="resume"`, what happened last time).

What keeps the mentor oriented is not the board but the **state card**: `CourseBoardExtension.willRequest` appends an
app-generated `<lesson_state>` block (course, focus, next, then, parked, open loop, watch, evidence; ≤ 200 tokens
whatever the course size) to the last learner message of every request — the request copy only, so the transcript
and the cached prefix stay clean, and it survives compaction because it is rendered from the database, not recovered
from the transcript. The usage rules sit once in the system prompt (`# Course board`). The summary prompt carries the
same block under "Course state", graded quiz answers and `mastery` records attach evidence to the card that teaches
the concept without moving it, and a ```problem the mentor just posed shows as the open loop. UI: the Plan inspector
tab, a strip above the composer, the transcript plan card and the Progress screen, whose **Continue this course**
links the board before the first message so the first request already carries the state. Learners park questions and
ask for checks; only the mentor marks cards done.

Cards carry **outlines** (`Card.outline`: sections with points and up to four levels of subsections, ids positional —
"2.3.1") and a `now` pointer: `lesson_plan outline` sets or refines one (finished sections keep their marks by title,
and the pointer follows its section when ids renumber), `section` marks one done and moves on. The header shows only
the position ("§2.3 Arena allocators (5/14 sections)"), so a 300-section book costs the same per request as a
one-card board. The parser takes outlines in the shapes models actually send (untitled groupings, `{"item": …}`
wrappers, objects for lists, `name`/`heading` for `title`): a strict parser made a live teacher give up and send flat
one-line outlines. Board writes take a lock — models send several `add`s in parallel, and read–modify–write on one row
lost cards. The rules say the board keeps the teacher oriented and is not a script: the learner's request outranks it.

`scripts/ab-board.py` measures whether all this helps or hurts: the installed app runs a twelve-turn course (two
detours, forced summarisation, time away, a request for the rest of the course) with a simulated expert learner, in
three arms forced with `MYAITEACHER_EXP=course_board=nested|shallow|off` (never randomised for learners), and a
stronger model scores each reply blind for depth and for continuity.

## Agent tree (tools and components)
Every agent is a node in one tree (`AgentTree`). A node declares what it adds; an agent gets everything on its path to
the root and never what its children add:

```
root ── files (read, write, batch edit, ls), web, load_tools, skill; sub-agents (runtime); core visualisations
│        skills: web-research, read-long-documents, visual-explanations
├── teacher ── ask_learner, math, run_code, memory, lesson_plan; bash, mastery, flashcards… (runtime); vocab, practice, problem
│   │          skills: lesson-design, quiz-writing, feedback-on-answers
│   ├── tutor · socratic · explain · quiz · exam · eli5 · research   (instructions differ, tools don't)
│   ├── language ── language, vocab; listen, gloss, dialogue, conjugation, tones, reading, correction
│   │               skills: conversation-practice, grammar-drills, pronunciation-coaching
│   └── code-mentor ── run_tests, project_tests, project_review, trace, symbols, diagnostics, bash; bench, source, glob, grep (runtime)
│                      skills: debugging-coaching, code-review-feedback, project-scaffolding
└── engineer ── the code agent: shell, search, run_tests, todo, task; jobs, browser and Mac control, project memory… (runtime)
                 skills: git-workflow, systematic-debugging, writing-tests, code-review
```

* **Three sets per node.** `core` tools go with every request; `deferred` ones load at runtime (one short line each in
  the prompt: the full description and typed schema arrive only once a tool is loaded, by `load_tools` or by calling it
  by name, which loads and runs it); `components` are the fences the agent may write. `ToolRegistry.active`,
  `load_tools` and a direct call to a tool all resolve against the agent's path, so a tutor can't load the code mentor's
  `run_tests` and the code mentor can't reach the code agent's browser. Core is what an agent uses in most turns;
  everything else is deferred (the code agent's per-request prefix went from ~9.5k to ~5.7k tokens).
* **Skills follow the tree** (`Skills`, `SkillTool`), in Claude Code's and OpenCode's format: a folder with a `SKILL.md`
  (front matter `name`, `description`, optional `agents`, `disable-model-invocation`). The app's own live in
  `Resources/skills/<node>/` and an agent gets those on its path; then the user's (`~/.teacher/skills`,
  `~/.claude/skills`, `~/.config/opencode/skill(s)`, `~/.agents/skills`, for every agent unless `agents` names some);
  then the open folder's (`.teacher/skills`, `.claude/skills`, `.opencode/skill(s)`, `.agents/skills`), later winning
  on a name. The prompt's `# Skills` section names each in one line (at most 40; `skill` with `query` searches the
  rest); `skill` returns a body only when the agent loads it. Settings › Agents lists each agent's skills.
* **Components follow the same tree.** The page gets the agent's component list with each `T.reset`; a fence outside it
  renders as its source, never a widget. Changing the set clears the markdown caches.
* **Guides follow it too.** Each node has a guide (`Guides`, editable in Settings › Instructions as "App guide" and
  "Tools guide: …"); an agent's prompt joins the guides on its path, root first, with `{more_tools}` filled from its own
  loadable tools.
* **The course board is core** for teachers: it must never depend on another tool being loaded (it used to arrive with
  `mastery`, so switching quizzes off removed the board too).

## Instructions and limits
* Every agent's standing instructions live in `Instructions` (teacher, each mode, board, app guide, code agent,
  built-in sub-agents), short by default and editable in Settings → Instructions (stored in `AppSettings.instructions`;
  a lesson keeps the prompt it started with, so its cached prefix stays valid — until its teaching mode or model
  changes: then the prompt is rebuilt for the new branch of the agent tree). The defaults say what the app needs —
  the standard of work, learner-first rules, how tools and rendering work — and leave teaching craft to the model.
* No tool-step cap by default (`maxToolTurns = 0`; the old saved default 40 reads as none): a reply works until it is
  done, carrying on past output limits (six times in a row at most: a model repeating itself hits the limit every time)
  and summarising as it goes. With a cap set, the last step offers no tools, so
  the reply always ends with a write-up instead of a dangling tool call.
* A turn ends for a reason: the work is done, the learner is needed (a question), Stop, a cap, or an error that isn't
  transient. A dropped or stalled stream is retried (three times, with backoff), also after part of the reply arrived;
  a reply that ends with its work plainly unfinished (`ChatSession.unfinished`: empty, announcing a step it never took
  after using tools, or a todo list still open) is sent back with a hidden note, at most twice a turn.
* A running `bash` card has **Background**: the learner sends the command to the background (a job, B1…) and the agent
  carries on; a backgrounded job's card shows its handle and URL and a Stop.
* Code lessons and the code agent get the installed toolchains (`Toolchains`: versions and standard-library paths,
  detected once in the background) so they teach the version the learner has. `write` and `run_code` drop a stray
  trailing `EOF` line (heredoc syntax models type into content).

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
* The page is a smaller window of that window: it renders the newest 300 messages (from a learner's turn) and says
  how many are earlier; "Show earlier" reveals in-memory ones 200 at a time, then loads older ones from disk. A long
  session drops the oldest from the page once it is a step past 300. Collapsed tool cards carry no body until opened.
* Learner memory: a store's index lives in RAM only under `MemoryTuning.indexBudget` (32 MB, ≈ 40k memories at under
  1 KB each: stems interned as UInt32 ids with sorted postings, vectors in one int8 slab, kind/importance/recency as
  Float32 struct-of-arrays). It loads under 80% of the budget and leaves past 100% (judged on counts, not capacities),
  and comes back once removals bring it under 80%. Content, subjects and norms stay in SQLite; a search reads only its
  result rows. Past the budget nothing is kept per memory: lexical candidates are FTS5 matches checked against
  `memories_active` (the FTS table also holds archived rows; each term's active rows read up to a cap, common terms
  counted exactly; FTS5's bm25 would score every match of a common term, ~1 s for 100k), and vectors stream from `vec`
  in 512-row chunks on four read-only, memory-mapped connections in parallel, into buffers allocated once, with bounded
  top-k heaps. Where the disk path can differ from the index is written down in `MemoryStore.search`. Dedup and the
  duplicate sweep use the same candidates (equal norms, rare terms, near vectors); a sweep run stops at 2,000 changed
  memories or 1,000 merges and the next one resumes from its own marker. Shedding drops the index and the scan
  connections. Every memory test also runs on the disk path (`*OnDiskTests`; recall on the labelled set is identical);
  `MemoryPlanTests` checks each statement's plan (nothing runs ANALYZE).
* Older databases: vectors are int8 in a new `vec` column; `embedding` stays the older builds' Float32 column, which this
  version only clears, so a build from before still reads a valid vector or none. The one-time work runs in the
  background after launch (`MemorySchema.upgrade`): a backup of what it rewrites — `id, embedding, norm` of each row it
  is about to change, in `<db>.pre-int8-<date>.sqlite` beside the database (SQLite transactions, so a crash or the CLI
  doing the same at once is safe; never the whole database: a folder's lessons stay out of it) — then this version's
  indexes, then the rows, 128 a transaction, each batch read and written inside it (an edit can't land in between).
  A crash, a lock held past the busy timeout or a full disk stops it unmarked; the next launch carries on
  (`MemoryMigrationTests`). Until then older rows still decode. Backups older than 30 days are deleted at launch.
  To restore one (app quit; `sqlite3 <db>`): `ATTACH '<backup>' AS b; UPDATE memories SET embedding = x.embedding,
  norm = x.norm, vec = NULL FROM b.memories AS x WHERE x.id = memories.id; DELETE FROM memory_meta WHERE key='vec_v1';`
  (`testABackupRestores` runs exactly this).
* Caches are bounded by size, not only count: page render caches (`Cache` in app.js: KaTeX, highlighting, finished
  markdown by content, streaming markdown segments, diagrams), the fetched-page cache (4M chars), URLCache (4 MB), SQLite
  (8 MB per connection).
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
  the digest fallback), `agents` (sub-agent runs), `mcp` (MCP servers, one child per folder and server, each with its
  own OS process). Root never gives up; it restarts a supervisor that did, with backoff.
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

## Activity log and background wake-ups
* **`ActivityLog`** writes one JSON object per line to `~/Library/Logs/MyAITeacher/activity-<day>.jsonl` (a test
  profile: `<home>/logs/`), off the caller's thread, a file per day kept 14 days. Events (`ev`):
  * `app.launch`, `message` (the user's text, attachments, command), `turn.start` and `turn.end` (time, steps, tools,
    usage, context tokens, time to first token, cancelled, error, changed files);
  * `request` for every model call, the main agent's and each sub-agent's (provider, model, latency, time to first
    token, usage with cache and reasoning, finish reason, retries, estimated usage);
  * `tool` for every call (time, ok, waited on approval, summary, result size; the whole input and result at `full`,
    and calls to tools the agent doesn't have);
  * `approval`, `memory`, `notice`, `folder`, `project` (from `EventBus`); `subagent.start` and `subagent.end`;
    `background.report` (and whether it woke the agent); `goal`; `log` (every `AppLog` line).

  The level (`AppSettings.activityLog`: off, standard, full) is in Settings › General. `--log-summary [day]` totals a
  day per model and per tool.
* **Background work wakes the agent** (Claude Code's background tasks):
  * A background sub-agent's report and a background shell job's end reach the lesson through `AppModel.deliver`.
  * Mid-turn, the report is read at the next step. In an idle lesson it starts a new turn. A lesson that isn't loaded
    keeps it in `undelivered` until it is opened.
  * The root guide tells every agent not to poll: carry on, or end the turn saying what it is waiting for.
  * `ChatSession.awaitedWork` (background sub-agents, and shell jobs that aren't servers) drives the composer's
    "Waiting for…" strip, and keeps `/goal` from nudging the agent on while its own work runs.

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

| Second round (on main 91870a6) | Before | After |
|---|---|---|
| WebContent at lesson open, 1,000 / 4,000 / 10,000 messages | 236 / 559 / 661 MB | **150 / 150 / 131 MB** |
| Open the lesson, same sizes | 650 / 2,052 / 2,592 ms | **215 / 215 / 219 ms** |
| WebContent, 4,000-message workload: peak / at the end | 1,210 / 817 MB | **451 / 196 MB** |
| One web_fetch, peak footprint (CLI): 300 KB / 1 MB / 3 MB page | 27 / 69 / 151 MB | **21 / 49 / 96 MB** |
| App footprint after three 3 MB fetches / conversion time | 219 MB / 538 ms | **153 MB / 352 ms** |

## Tool parity with Claude Code
| Claude Code tool | My AI Teacher | Notes |
|---|---|---|
| Bash | `bash` | zsh, persistent cwd per lesson, timeout (≤600 s), 30k-char head/tail truncation, huge output spilled to `.teacher/outputs` |
| Background jobs | `bash_jobs` | each command runs in its own process group (`ShellJob`); a server or watcher (a known command, or a printed localhost URL), a `cmd &`, or `background: true` moves to the background as B1… and the call returns; list, read new output, stop (the whole group); stopped when the lesson is deleted or the app quits |
| Read | `read` | `cat -n` lines, offset/limit, images (sent to the model), PDFs with page ranges, binary detection |
| Write | `write` | creates parents; permission-gated by folder access; refuses a file not read, or changed since (`FileViews`) |
| Edit | `edit` | exact unique match or `replace_all`, helpful errors; notes a file changed since it was read |
| Glob | `glob` | `**` globs, newest first; `rg --files` (honours .gitignore), the folder walk when that finds nothing |
| Grep | `grep` | ripgrep when installed (fallback `grep`), files (by match count)/content (grouped by file)/count modes, paths relative to the folder searched, `-A`/`-B`/`-C`, `-i`, glob and `type` filters, `multiline`, `offset` + `head_limit` paging |
| ExitPlanMode / plan mode | `exit_plan_mode` | ⇧⌘P; only looking tools run until the plan is approved |
| Queued messages | `ChatSession.queued` | sent while the agent works, read at its next step |
| Bash permission rules | `CommandRules` | "Always allow “npm test …” in this folder"; read-only commands never ask |
| Hooks | `HooksExtension` | PreToolUse (matcher; exit 2 or `decision: block` blocks, the reason goes to the model), PostToolUse (output reaches the model), UserPromptSubmit (context, or holds the message back), Stop (sends the agent back); Settings › Hooks and the project's `.claude/settings.json` in Claude Code's format, a project's only once approved for that folder and configuration; command hooks only, `allow` decisions ignored, the main agent's calls only |
| CLAUDE.md | `ProjectMemory.contextBlock` | user, parent folders, project, CLAUDE.local.md, `@imports`, subfolders on first read |
| LS | `ls` | sizes, hidden-noise filtering |
| WebSearch | `web_search` | free & keyless: DuckDuckGo + Bing (+ Brave fallback), ranked by reciprocal-rank fusion × query-word coverage, two per site first, tracking parameters stripped; a slow engine gets 1.5 s once the other has answered; 10-min cache; news mode (falls back to the web); papers mode (OpenAlex: relevance overall and among works cited 25+ times, fused, a log-citation boost); `read` adds the top pages' best passages |
| WebFetch | `web_fetch` | HTML→Markdown (article extraction, MathML→TeX), PDF→text, images, 15-min cache; `query` returns the BM25-best passages (`Passages`), pages of 12k characters list their later sections' offsets, same-site link addresses left out; `urls` reads up to 4 more pages in parallel in a shared budget (local addresses skipped) |
| TodoWrite | `todo_write` | rendered as a live checklist |
| Task / Agent | `task` + `agents` | types (explore/general/coder/reviewer/tester + app, `.teacher/agents/*.md` and `.claude/agents/*.md` with Claude Code's tool names), provider/model/effort/budget per call, tool allow/deny, JSON-schema reports, steering notes, resume, nesting, worktree isolation, supervised restarts; never above the lesson's grants |
| AskUserQuestion | `ask_learner` | 13 interactive component types, not just multiple choice |
| NotebookEdit | — | not needed for tutoring; `edit` works on `.ipynb` JSON |
| — (extra) | `run_code` | Python, JS, TS, Swift, C, C++, Go, Rust, Ruby, Bash, Java in a scratch dir |
| — (extra) | `diagnostics` | the project's check/test/lint command, output parsed to `file:line:col severity message`; syntax checks after every write/edit |
| — (extra) | `symbols` | a file's outline, or where a name is defined (not mentioned), across the folder |
| /rewind | Undo this turn's changes | per-turn checkpoints of every file the agent changed, restored from the transcript, no git needed |
| /command | `.teacher/commands`, `.claude/commands` (project and user) | slash commands with `$ARGUMENTS`, `$1`…`$9`, namespaces; built-in `/init`, `/review`, `/compact`, `/goal` (`GoalExtension`: `Conversation.goal` rides along hidden on every message; `ChatSession.advanceGoal` starts the next turn by itself until the agent calls `goal` met (with evidence) or blocked, the user stops, a turn fails, or 25 turns) |
| MCP (`mcp__server__tool`, `.mcp.json`) | `MCPHub`, `MCPTool` | stdio and streamable HTTP; app-level servers (Settings → MCP) and the project's `.mcp.json`, which needs the user's approval of each server's exact config; deferred, one line per tool, `load_tools` by tool or server; every call asked (per-server "always allow" per folder), plan mode only `readOnlyHint` tools; supervised (restart on crash, end with the app), stderr in Settings. Not yet: resources, prompts, OAuth, sub-agents, the old SSE transport |
| — (extra) | `math` | SymPy: evaluate/simplify/solve/diff/integrate/limit/series with assignments & tuples |
| — (extra) | graded `ask_learner`, `flashcards`, `mastery`, `lesson_plan` | graded quizzes, FSRS cards, BKT mastery, the course board |
| — (extra) | `memory` (search/save/update/forget) | learner model: scoped memories + concept graph (ids 12 / f3 / c7) |

## Measured (Apple Silicon, macOS 27)
* Cold launch → rendered transcript: **1.07 s**; app process footprint **~68–73 MB** + one WebKit content process (~90 MB).
* Same-machine comparison (RSS of all bundle processes): My AI Teacher 135 MB (+~90 MB WebKit) vs MiniMax Code 662 MB, Claude 1,418 MB.
* Streaming render: p50 3 ms / p95 8 ms per frame for a 3k-char mixed Markdown/KaTeX/Mermaid stream.
* Free web search: 12/12 varied queries returned ≥5 results (engines fall back for each other).
* Storage at 200k messages (422 MB database, debug build): 23.5k message writes/s (JSON + FTS index), a 400-message
  window loads in 2.6 ms, a count in 0.4 ms, lesson search 29 ms (common words) / 0.1 ms (rare); the app's footprint
  grew 20 MB. SQLite is not the bottleneck; the access patterns were (the search was 64 s before the rowid-range fix).
* Learner memory (`MemoryScaleTests`: 512-dim vectors, ~14-word memories; release build; before → after). Past the
  budget (50k, 500k) the store keeps nothing per memory, so its footprint is the scan's constant buffers:

  | Memories | Footprint the index adds | Search, median |
  |---|---|---|
  | 10k (in RAM) | +33.7 MB (3.5 KB each) → **+10.2 MB** (index 7.5 MB, ~0.8 KB each) | 1.4 → **0.6 ms** |
  | 50k (disk path) | +124.6 MB → **+1.9 MB** | 12.6 → **8.2 ms** |
  | 500k (disk path) | +1,430 MB → **+1.8 MB** | 132 → **48 ms** |

  Opening a 20k-memory database from an older build takes 18 ms; its one-time upgrade runs in the background (debug
  build: backup 37 ms, 45 MB; conversion 14 s, stepping aside 10 ms between batches so writers wait at most 31 ms on the
  store's connection, 125 ms on another process's).
