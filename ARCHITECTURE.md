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
* **Storage writes.** A write whose failure the caller can't act on uses `db.run(…)` (or `db.write("what") { … }` for
  several statements), which logs to `Log.db`; never `try? db.execute`. Statements that must change together go in one
  `transaction` (a lesson message and its blob references, a lesson delete); transactions nest as savepoints.
* **Tool gates compose.** Every extension's `shouldRun` is consulted in registration order: a deny ends it, and an
  approval the learner gives moves on to the next gate (an approval for one gate never skips another).
* **One HTTP session.** All model streams share `SSEClient`'s `URLSession` (per-task delegates), so steps and parallel
  sub-agents reuse the provider's warm connection instead of a new TLS handshake per request.
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
  transcript (no tool call, nothing added to the context). Once every practice card is marked and one was missed, the
  result goes to the teacher unasked.
* ```` ```problem ```` cards are attempt first: the teacher's hints and solution stay hidden until the learner sends
  an attempt (it arrives as their message) or opens them. Opening help posts `study` events (logged as help); a solution
  seen before any attempt is also told to the teacher with the learner's next message (`ChatSession.studyNotes`). After
  90 s in view with nothing typed, the first hint opens by itself, once.

## Native hardware
WebKit renders the transcript in its own GPU-accelerated process; visuals run in sandboxed frames inside it.
NaturalLanguage (embeddings, language ID), Speech and the on-device language model (titles, ~0.5 s) run locally on the
Neural Engine/CPU; read-only tools run in parallel; telemetry writes on a background queue; SQLite uses WAL.
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
| Listen to app events (UI badges, logging, sync) | `EventBus.subject.sink { … }` (`AppEvent`) | none |
| Add a tool | Conform to `Tool` (name, description, JSON schema, `risk`, `run`) and add it to `ToolRegistry.all`. `risk` drives permissions; interactive tools await `ctx.interactions.request(…)` | none |
| Add a provider | Add a `ProviderConfig` preset (Anthropic/OpenAI/Gemini wire format + quirks) to `ProviderCatalog`, or add a custom provider in Settings | none |
| Add a wire protocol | Implement `LLMClient` (emit `StreamEvent`s) and a case in `APIKind` | 1 switch |
| Run an A/B test | Add an `Experiment` to `Experiments.all` and branch on `Experiments.arm(e, unit: lessonID)` | none |
| Run background work | `Runtime.job(name) { … }` (one per name, watchdog, restart on a crash), `Runtime.call` (returns a value), `Runtime.every` (periodic service) — not `Task.detached` | none |
| Add a sub-agent type | Settings → Agents, or a `.teacher/agents/<name>.md` in the folder (or `AgentCatalog.builtIns`) | none |
| Render a new fenced block (```xyz) or ```ui component | `TeacherUI.defineComponent({ names: ['xyz'], schema, render(props, ctx, env) })` in a file under `Resources/web/components/` (`raw: true` for text forms, `// @lazy` at the top to load on first use), then `scripts/gen-web-manifest.py` | none |
| Add a question type | `TeacherUI.registerQuestionType('type', {render})` + grading case in `Questions.grade` | none |
| Present a tool | `TeacherUI.defineTool({ name, icon, title, summary(node), body(node, ctx), open, compact })` in `components/tools/` (a `card` replaces the whole frame); tools without one get the generic card | none |
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
  copy only), and `quiz` and graded `ask_learner` return a refusal. Quiz and Exam prep modes always test.
* **Skips carry a reason** (`Testing.SkipReason`: need more explanation, too easy, not now, unclear). The tool result tells the
  teacher what to do about each. **Don't know yet** (certainty 0) is not graded or recorded; the result asks for teaching.
* **Exam-style quizzes:** `quiz` and `ask_learner` take a `case` (Markdown shown above the questions) that the questions
  refer to.
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
action, prerequisites (`after`), a `concept` for evidence, a revision and a capped log. `lesson_plan` is the only
writer: add / start / park / resume / complete / note / move / get / list, plus the legacy create / update. Validation
is the feature: a second `start` names the current focus, `complete` needs evidence, `park` needs a reason, an empty
modules update is refused, and a card completed while its concept's mastery is low gets a Review card (the board is
intent; mastery is belief). A lesson works from one board (`board_links`, set when a board is created, named or
resumed from Progress); several lessons can share it.

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
root ── files (read, write, batch edit, ls), web, sub-agents (task), load_tools; core visualisations
├── teacher ── ask_learner, math, run_code, bash, memory, lesson_plan; quiz, mastery, flashcards (runtime); vocab, practice, problem
│   ├── tutor · socratic · explain · quiz · exam · eli5 · research   (instructions differ, tools don't)
│   └── code-mentor ── run_tests; glob, grep (runtime); layout, tree
└── engineer ── the code agent: shell, search, run_tests, todo, project memory, browser and Mac control; layout, tree
```

* **Three sets per node.** `core` tools go with every request; `deferred` ones load at runtime with `load_tools` (one line
  each in the prompt, which keeps context small); `components` are the fences the agent may write. `ToolRegistry.active`,
  `load_tools` and a direct call to a tool all resolve against the agent's path, so a tutor can't load the code mentor's
  `run_tests` and the code mentor can't reach the code agent's browser.
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
  a lesson keeps the prompt it started with, so its cached prefix stays valid). The defaults say what the app needs —
  the standard of work, learner-first rules, how tools and rendering work — and leave teaching craft to the model.
* No tool-step cap by default (`maxToolTurns = 0`; the old saved default 40 reads as none): a reply works until it is
  done, carrying on past output limits and summarising as it goes. With a cap set, the last step offers no tools, so
  the reply always ends with a write-up instead of a dangling tool call.
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
| — (extra) | `quiz`, `flashcards`, `mastery`, `lesson_plan` | graded quizzes, FSRS cards, BKT mastery, the course board |
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
