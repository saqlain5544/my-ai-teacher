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
  Browser/     The agents' in-app browser (tabs, injected helper, `browser` tool)
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
Resources/drawing/ The drawing set's references (`draw`), one file per kind, by agent tree node
```

## Invariants
* **Folders.** The teacher works inside a loaded folder. Its state lives in `<folder>/.teacher/`
  (`state.sqlite` = lessons + folder memory, `outputs/`, `attachments/`). Learner‑wide state (profile memory,
  flashcards, mastery, plans, usage) lives in `~/Library/Application Support/MyAITeacher/teacher.sqlite`.
* **Access.** Reading is allowed anywhere (except the credential locations, see "Secrets"). Every folder starts **read‑only**; the learner grants **write** or **full**
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
1. **Deferred tools.** An agent's core tools are always sent (a tutor's 14); the rarely used ones (a tutor's 14, per
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

7. **The summary keeps what the app knows.** `ContextFacts` is appended to every summary after the model's text, under
   "Kept by the app": the course state (goal), the todo list, the mentor project's test command and last result, files
   written or edited this lesson (`Conversation.touchedFiles`, newest first), background jobs of this lesson, the files
   read last. It is cut by whole lines to 4% of the budget (200–1,200 tokens), holds no clocks, and is built once per
   compaction and stored with the summary, so the prefix is byte-stable until the next one. A rolling summary strips the
   old section before merging, so it is replaced, never stacked. The summary prompt asks for goal, decisions and why,
   open tasks, misconceptions, errors and fixes, test status and exact paths.
8. **`/compact [focus]` and `/context`** are commands on the lesson, not turns (`ContextCommand`, handled in
   `ChatSession.send`). `/compact` keeps the last tenth of the budget verbatim (automatic compaction keeps 30%), summarises,
   and reports tokens before → after; a short lesson says there is nothing to compact. `/context` counts, with the budget's
   own estimate, the system prompt, memory, deferred-tool list, tool definitions, then messages, tool results, images and
   reasoning of the next request, what microcompaction saves, the summary, the cache hit rate, and names the biggest.
9. **Repeat reads.** `read` of the same range of an unchanged file (`FileViews` stamp, taken before the read) returns a
   one-line note with `meta.sameAs` = the earlier call, only when that result is in `ContextPolicy.liveResults` (after the
   compaction point and the trim epoch, the request-ready history (not the stored lesson) inside its budget, not cut by `StepCap`; never for adaptive Claude, whose
   history the API edits, nor sub-agents, which pass no live set). The epoch can still jump past the earlier result later,
   so `ContextPolicy.expandRepeats` runs first in `prepare` (and `demoteSqueezedNotes` after the squeeze turns a note whose target was cut into "read it again"): a note whose earlier result is stubbed or summarised becomes
   the file again from the stored transcript, or says to read it again when that is paged out. The model never holds a
   pointer to content it no longer has.
10. **One step is bounded.** `StepCap`: a step's tool results (parallel tools, a sub-agent's report) may add about a sixth
   of the budget (40k–160k characters); the largest keep 5k head + 1.5k tail and the full text goes to `.teacher/outputs`
   with its path. Results under 12k characters are never cut.

| Scripted 30-turn lesson (4 files read every turn, 3 parallel 45k-char greps, budget 24k tokens; `ContextManagementTests`) | Tokens sent over all requests |
|---|---|
| Before | 8.00M |
| Repeat reads only | 8.00M (−0%: the greps alone put the request over budget, so no earlier result is trusted) |
| Step cap only | 3.55M (−56%) |
| Both | **3.52M (−57%)**: the cap is nearly all of it; repeat reads add about one point on top, more in a lesson of reads and small outputs |
| Fixed prefix (`--cli --measure --no-memory`) | ~6.4k tok, unchanged |

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

**Drawing formats load on demand.** The prompt names the drawing kinds in one line and `draw` returns a kind's format,
example and limits when the agent asks (see Live visuals). The root guide used to carry every fence's format, and the
code mentor's guide its views' JSON shapes, in every request. Measured with `--cli --measure --no-memory` (chars/4,
learner memory left out):

| Fixed prefix per request | Before | After |
|---|---|---|
| Tutor, Socratic (system prompt + core tools) | 6,384 tok | **6,328 tok** (−56) |
| Language mentor | 8,557 tok | **8,501 tok** (−56) |
| Code mentor | 7,856 tok | **7,740 tok** (−116) |
| of which `draw`'s definition (new, every request) | — | 80 tok |
| On demand: one kind's reference / the catalog | — | 136–987 tok (mermaid largest) / 895 tok |

## Evaluations
Comparisons run offline, never randomised for learners: the course board system's three arms are forced with
`MYAITEACHER_EXP=course_board=nested|shallow|off` or the CLI's `--exp` (`BoardSystem`, `scripts/ab-board.py`), and a
mentor's lessons are measured headless (`--lesson`, `scripts/mentor-bench.py`). An in-app A/B framework (per-lesson
arms, exposure telemetry, an Insights card) once tested the `visual` tool's placement — rewording mattered more than
placement, so it is runtime-loaded — and was removed once nothing used it.

## Live visuals and practice
* **The drawing set** (`Drawing`, `DrawTool`): every kind of figure an agent can put in a reply. These are the fences
  ```mermaid (Mermaid 12, ~30 diagram types), ```plot, ```chart, ```svg, ```visual, ```math, ```steps, ```timeline,
  ```compare, ```cards, ```kv, ```csv and ```json; the libraries a visual loads (three.js r158, d3 7.9, Chart.js 4.5,
  Matter.js 0.20, KaTeX 0.19); and the code mentor's views (```predict, ```annotate, ```trace, ```layout, ```tree).
  The prompt names the kinds in one line of the root guide. `draw` (core at the root, so every mentor and the research
  sub-agents have it; ~80 tokens) returns a kind's exact format, a working example and its limits; with no kinds it
  returns the catalog and how to choose (the old visual-explanations skill). References are
  `Resources/drawing/<node>/<kind>.md` and follow the agent tree like skills, gated by the components the agent's page
  draws: a tutor asking for ```layout is told it belongs to the code mentor. A fence or library called as a tool, and a
  drawing that fails in the learner's view, both point the agent to `draw`. A failed drawing is reported by its own kind
  (the page used to report every broken component as a chart). The renderer suite draws every example in every
  reference (light and dark), so a format that drifts fails a test.
* Live check (MiniMax-M3.1-Flash, thinking off, same prompts, `main` against this): the tutor drew a diagram and a
  chart in 2/2 runs in both arms, loading `draw` both times; the code mentor drew in 1/3 runs before and 3/3 after (a
  ```predict each time, a ```layout once). The risk the design carries showed once: a run that skipped `draw` wrote a
  ```predict with prose for JSON. The learner saw the error, and it reached the teacher with its format's name.
* Limits the references state, measured in the app's WebKit: the ```svg sanitiser drops `id`, `class`, `<style>` and
  `<foreignObject>` (so no gradients, markers or `<use>`); three.js is the core build (no OrbitControls); visuals have
  no storage or modules (a `type="module"` script runs as a classic one); KaTeX inside a visual needs
  `output: 'mathml'` (the frame has no KaTeX stylesheet); Matter's mouse swallows the wheel unless its listener is
  removed.
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
    description, tools, deny, read_only, provider, model, effort, max_steps/max_seconds/max_tokens; the body
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
* Permissions are a ceiling, never a prompt (`SubAgentPolicy`): a sub-agent may do what the lesson may do without
  asking (folder access, approvals the learner gave in this lesson, the Python setting, disabled tools) and nothing more;
  writes must land inside its folder, never `.teacher/` — checked on the real path (the deepest existing
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
  that only sends keep-alives); the incarnation it ends writes nothing more (no "stopped" report)
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

## Coding tools, approvals, hooks and MCP
The autonomous Code agent mode left the app (it is now a separate Rust CLI, `~/coding-agent`); a saved session of it
opens as Code mentor (`TeachingMode` decodes an unknown mode as `.code`). The coding tools below serve the code mentor;
approvals, hooks and MCP cover every agent.
* **Project profile** (`ProjectProfile.detect`, once per session when the prompt is built): the manifests at the top of
  the folder (Package.swift, package.json scripts and lockfile, tsconfig, Cargo, go.mod, pyproject, build.zig,
  Makefile targets, CMake, Gradle, Maven, Gemfile, mix, deno) → build / check / test / lint / format commands, languages
  by file count (code only; a bounded walk), git branch and dirty count. It is the `# Project` section of the code
  mentor's prompt and the default commands of `diagnostics`.
* **Verification loop.** `WriteTool`/`EditTool` in Code mentor mode (`ToolContext.codeAgent`) run
  `Diagnostics.quickCheck` on the file (py_compile, node --check, ruby -c, zig ast-check, swiftc -parse, gofmt -e,
  zsh -n, JSON; ≤ 10 s) and append the verdict to the result (`meta.syntaxErrors` marks the card). `diagnostics` runs
  the project's check, test or lint command (or one given) and parses clang/swift/zig/go, tsc, rustc, python and eslint
  output into `file:line:col severity message`, grouped by file and capped (`Diagnostics.parse` / `summary`). `bash`
  with `background: true` runs detached (≤ 30 min) and delivers a `<background-task>` message through
  `ChatSession.deliver`, like a sub-agent's report (the page renders it as one); sub-agents' shells stay in the
  foreground. `ShellState` keeps the lesson's running background tasks by handle: Stop cancels them (the processes end,
  nothing is delivered), and a foreground `bash` result names the ones still running. A coder sub-agent working in the
  lesson's folder backs files up under the turn's checkpoint too (`ToolContext.checkpointTurn`), so Undo covers its
  edits. `ProjectProfile.detect` caches per folder behind a fingerprint of the manifests' dates and sizes (ten minutes;
  the git part refreshed after a minute), so neither the prompt nor `diagnostics` re-walks the folder.
* **Checkpoints and undo** (`Checkpoints`, `CodeAgentExtension`, Code mentor mode): registered before
  `PermissionExtension`, its `shouldRun` copies a file to `.teacher/checkpoints/<turn>/` before the agent's first write
  or edit to it in the turn (a created file is recorded as absent). `didFinishTurn` keeps only files whose content
  differs from the backup and stores `checkpoint` and `changedFiles` on the turn's metrics (optional fields, so older
  messages decode); the page's footer offers **Undo this turn's changes** (`revert` message → `Checkpoints.restore`),
  the agent hears about an undo with the next message, and the newest 40 checkpoints are kept. No git needed; the
  Changes panel's git checkpoints are the user's own.
* `symbols`: a file's outline or the definitions of a name across the folder, by per-language regular expressions
  (ripgrep for the search) — definitions, not mentions. `edit` matches a block whose lines differ only in indentation
  or trailing whitespace when that match is unique, and re-indents the replacement. `ProjectCommands` holds a lesson's
  own `/` commands only: the follow-ups (`/simpler`, `/quiz`…) and the mode switches (`/socratic`…).
* **Writes never erase unseen work** (`FileViews`, per agent: `shellID ?? conversationID`, so each sub-agent has its
  own): `read`, `write` and `edit` record a file's modification date and size; `write` refuses an existing file the
  agent hasn't read or whose stamp changed since (the user saved it, a command rewrote it); `edit` applies (exact
  match) and notes the change. Code mentor only (`ToolContext.codeAgent`, which sub-agents inherit).
* **Approvals** (`PermissionExtension`, execute risk): a command `ReadOnlyShell.allows` (the reviewer's strict
  allowlist) never asks, and `bash` runs exactly those through `ReadOnlyShell.run` (no shell, git hardened), so the
  same strictness that lets it skip approval decides how it runs. `CommandRules`: "Always allow “npm test …” in this
  folder" stores a prefix in `AppSettings.commandRules[folder]` (never in the folder, so a repository can't approve
  itself); a rule matches one simple command (no `; & | < > ( ) { } $` backquotes, backslashes or newlines outside
  single quotes; one leading `cd dir &&` allowed). git and hg never get rules: a repository's config can make them run
  programs, and a rule would let variants of their looking commands run outside `ReadOnlyShell`'s hardening. Package
  installs are refused.
* **Arguments.** `ToolArgs.canonical` renames other agents' argument names (`file_path`, `run_in_background`,
  camelCase) to the tool's own in `ChatSession.execute` and the sub-agent loop, before any gate reads them.
* **Hooks** (`HooksExtension`, every lesson, registered before `PermissionExtension`: a call a hook blocks is never
  put to the user). `HookSet` parses Claude Code's `hooks`
  JSON from `AppSettings.hooks` (Settings › Hooks) and the folder's `.claude/settings.json` + `settings.local.json`;
  matchers follow Claude Code's rules over both its tool names (`HookSet.claudeNames`) and the app's. `HookRunner` runs
  `/bin/sh -c` in the folder through `ProcessRunner` (off the main actor; `$CLAUDE_PROJECT_DIR`; the event as JSON on
  stdin, long strings clamped; per-hook timeout, 60 s default, 600 max; 64 KB of output kept, 8k characters shown to the
  agent), the matching hooks of an event at once, and maps exit codes and JSON decisions to `HookOutcome` (exit 2 or
  `block`/`deny` blocks; `ask` asks; `allow` is ignored, so hooks never widen permissions; other exits are reported to
  the user). The extension points: PreToolUse is `shouldRun` returning `ToolDecision.pending` (awaited by
  `ChatSession.execute`, chained like an approval by `ExtensionHost.chain`); PostToolUse is `afterRun` (successful calls;
  output and a "the hook rewrote the file" note appended to the result); UserPromptSubmit is `willStartTurn`
  (`ChatSession.admitPrompt` for turns `send` or `edit` start: hidden context, or the message is
  removed and its text returned to the draft); Stop is `willEndTurn` (a hidden note and another step, at most
  `ChatSession.sendBackLimit` times per turn). Sub-agents' calls don't pass through the extension
  host. A folder's hooks run only when `AppSettings.approvedHooks[folder]` equals the configuration's `fingerprint`
  (SHA-256 of every event, matcher, timeout and command), so a cloned repo never runs anything and any change asks
  again; the question is an `.ask` on the lesson's first tool call (cards render on tool calls), listing every command,
  and a decline holds for the lesson.
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
    `_`, 64 at most with a hash suffix), the server's input schema (`$schema` dropped), `execute` risk. The `root` node
    has `AgentNode.mcp`, so every agent gets them, always deferred: `MCPHub.promptSection` writes a `# MCP servers`
    section after `# Environment` in every lesson's prompt with one line per tool (first sentence, "(read-only)"), the
    servers' `instructions`, and a line per project server awaiting approval. Tool lists are remembered by fingerprint
    in `mcp-tools.json`, so a lesson's prompt starts no server it has listed before. `load_tools` takes tool names or a
    whole server (`mcp__<server>`); for an unapproved project server it asks the user first (a `permission` card
    showing the command) and stores the answer. A direct call to a known MCP tool loads it like any deferred tool.
  * **Gates**: `PermissionExtension.mcpGate` asks for every call regardless of folder access (once, the server for the
    lesson, or `AppSettings.mcpAlwaysAllow[folder]`). Sub-agents don't get MCP tools.
* **Instruction files** (`InstructionFiles.nested`): a subfolder's own CLAUDE.md / AGENTS.md rides on the code
  mentor's first `read` of a file under it. The prompt carries no CLAUDE.md / AGENTS.md block.

## Secrets (`Core/Secrets.swift`)
Secrets and data leaving the Mac, with the choke points that make each rule one place:
* **`Tool.runBounded`** is where every model-started call passes (`ChatSession.execute` and the sub-agent loop alike; sub-agents
  skip the extension host, this doesn't). It refuses `web_fetch`/`browser` URLs and `web_search` queries holding a secret
  (`Secrets.outbound`), runs the tool with `Secrets.$agentCall` set and the `WriteFence` profile composed with the credential
  deny-reads (`WriteFence.guarded`, over a mentor's write fence), and redacts the result (`Secrets.redacted`; `meta.redacted`
  lists the kinds and the card says so). `ReadOnlyShell.run` (sub-agents' direct path) sandboxes itself and is redacted at
  the sub-agent call site (`SubAgent.runTools`). A `write`/`edit` whose new text holds a `[redacted: …]` marker the file didn't
  have is refused (`Secrets.introducesMarker`): a redacted `read` must not be saved back over the real value. The outbound
  check reads every string of a `web_fetch`/`web_search`/`browser` input (`urls[]`, steps, typed text).
* **Environment.** `ProcessRunner.environment()` drops provider `envKeys` and names containing API_KEY, SECRET, TOKEN, PASSWORD
  or CREDENTIAL when `Secrets.agentCall` (allow list: `AppSettings.envAllow`). A caller that passes its own base (hooks) or
  `scrub: false` (MCP servers) is the user's own configuration and keeps the full environment.
* **Detection** (`Secrets.redact`): exact matches on saved keys (`KeyStore` mirrors them) and secret-named environment
  values (≥ 10 characters, no whitespace), plus shapes (`sk-` with a digit, `gh[pousr]_`, `github_pat_`, `AKIA`/`ASIA`, `xox?-`,
  `AIza`, `nvapi-`, PEM private key blocks). Also applied to every activity-log line and the plain log.
* **Credential files.** `Secrets.credentialPaths` (~/.ssh, ~/.aws, ~/.gnupg, ~/.netrc, ~/.config/gh, ~/.docker/config.json,
  Library/Keychains, `keys.json`). `read`/`grep`/`glob`/`ls`/`symbols`/`code`/`source` naming one (or a folder that holds one) ask
  once per lesson in `PermissionExtension` (`credential-read` grant; sub-agents are denied unless the lesson granted it).
  `ReadOnlyShell.allows` is false for a command naming one, so it asks. Commands are covered by `sandbox-exec` deny-read rules
  (Settings › Tools › Secrets turns it off). Project `.env` files stay readable; only dotenv-shaped secret lines are redacted
  (`NAME…PASSWORD|SECRET|TOKEN|API_KEY|CREDENTIAL=value`: no spaces around `=`, ≥ 8 characters, not numeric, not a short plain
  word; also after `read`'s row numbers and `grep -n`'s `file:line:`), other contents reach the model. `settings.json` (MCP
  tokens) is a credential path and its env/header values are exact-match secrets. Deny rules also cover writing, renaming and
  unlinking the credential paths and unlinking the folders that hold them (`mv ~/.ssh /tmp/s` fails). A file tool that names a credential
  location got there by approval, so `runBounded` runs it without the deny-reads (`rg` would otherwise be refused). The
  fence is a guard rail, not a hard boundary: the profile is `(allow default)` plus denies, and another process (`open`,
  `osascript`, a launchd job) is outside it. It breaks git over SSH, gh, docker, aws, and programs that sandbox themselves:
  `ProjectProfile.detect` returns its `swift build`/`swift test` with `--disable-sandbox` when the fence is on (`flagged`;
  a model-typed command is never rewritten). `Secrets.shellScript` only prepends an `unset` of the scrubbed names on the
  script's first line (`zsh -c` re-sources `~/.zshenv`); `Secrets.hint` explains a nested-sandbox error on `bash`,
  `run_tests` and `diagnostics` output.
* **Transcript images.** The page's CSP has no `http(s)` in `img-src`. DOMPurify's `afterSanitizeAttributes` moves any remote
  `<img src>` to `data-remote` (and drops `srcset`, svg `image`/`use` external hrefs); a processor shows “Image from host”; a
  click loads it through `RemoteImageSchemeHandler` (`teacher-remote://img/?k=<per-process key>&u=<https url>`, https only,
  images ≤ 8 MB, no cookies). The key is injected into the page, so model markup can't name the scheme.
* **MCP text.** Tool descriptions are one clamped sentence, server `instructions` 600 characters quoted on one line, at most 60
  tool lines, all labelled as the server's text. `MCPHub.remember` hashes each tool; one that is new or changed since the
  config last listed is `changedTools` until the user allows a call (`PermissionExtension.mcpGate` asks even under a
  lesson or folder grant, and the prompt says so).
* **Saved keys at rest**: `keys.json` is created 0600 and renamed into place (not chmod-ed after a default-mode write).

## Browser and computer use
`browser`, `mac` and `computer` are deferred tools of the `root` node, so every agent can load them; their usage line
(snapshot and act by ref, `mac` before `computer`, content is untrusted) is in the root guide, `Guides.root`.
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
  mentor mode also gets the coding tools (`symbols`, `diagnostics`, `project_tests`, `project_review` core), syntax
  checks after its writes, per-turn checkpoints of its scaffolding, and the project profile in its prompt.
* **Proving how good the tests and code are** (`Code/Mutation.swift`, `Tools/MutateTool.swift`, `Tools/CoverageTool.swift`,
  `CodeLab.assess` in `Tools/CodeLabTools.swift`). Three measurements, all information, none a gate: mutation score never
  touches a review's pass, a round's verdict or mastery (`project_review` start only quotes a one-line summary of the last run,
  and only when `ProjectStore.digest` shows the files and tests are as they were).
  * `mutate`: a scratch copy (`Scratch`, `aiteacher-scratch-*` under the temp folder, swept when older than 3 h; gitignore-aware
    listing, never `.teacher`, `.git`, `node_modules` (linked, read-only), `target`, `.build`; plus `.teacher/tests`) in as many
    as four worker copies. `CodeMask` blanks comments, strings, template literals, docstrings, char literals and JS regexes
    byte for byte across lines, so an operator is only ever found in code; `Mutator` makes one mutant per candidate (spaced
    `<`/`<=`/`>`/`>=`/`==`/`!=`/`&&`/`||`/`+`/`-`, `and`/`or`, true/false, an integer ±1, a negated `if`/`while`, an early
    `return` in dynamic languages, a dropped call statement) and `select` spreads them across functions (round-robin, kinds
    interleaved), the learner's changed lines first (`CodeImpact.parse` of the review diff). The baseline runs first in the copy
    and must be green. Each mutant runs the registered command (the learner's folder path swapped for the copy's) with a timeout
    from the baseline (3× + 5 s, 10–120 s) and the whole run a budget (300 s, max 900). Exit 0 survives, a timeout counts as caught,
    and a failure counts as killed only on positive evidence of a failing test: a build or syntax error is `invalid`, a crash, exit 127/137/139 or a port clash (`EADDRINUSE`) is `errored`, and both are left out of the score. Python runs with `PYTHONDONTWRITEBYTECODE=1` (a `.pyc` keyed on whole-second mtime and size would judge a same-size mutant on its predecessor's code); a mutant starts only with time for its full limit; the digest is taken before the copy; a `node_modules` with links resolving outside it, files the copy left out (listed by reason) and a 50 MB cap are reported, not blamed on the learner. `CodeMask` returns nil for a file it can't read confidently (unterminated string, C++ raw string). It joins
    `MentorGuard.commands` (the same `WriteFence`) and the `tests` grant (`PermissionExtension.runsTests`). Stop cancels the task
    group: `ProcessRunner` ends each process tree and the scratch folder goes in a `defer`.
  * `coverage`: the same scratch copy, the toolchain's own numbers and nothing installed: `go test -coverprofile`, `swift test
    --enable-code-coverage` (its JSON), `cargo llvm-cov` when installed, node's `--experimental-test-coverage` and jest/vitest/c8
    tables, coverage.py when importable and otherwise stdlib `trace --count --missing`. Per-file percent, never-run ranges (with
    the enclosing function from `SymbolsTool.outline`); a missing tool is named in the result.
  * `bench` growth: `CodeLab.assess` wraps `fit` with evidence (log-log slope ± its standard error, scatter, sizes and span) and a
    confidence, and refuses a claim under four timed sizes, under a tenfold span, with timings all under 20 µs (except a flat "O(1)",
    capped at low) or with scatter beyond about ±35%. The card hides the curve until the learner picks a growth class.
* **The debugger** (`Tools/DebugTool.swift`, `DebugSession.swift`, `DebugBuild.swift`, `DebugDriver.swift`; `debug`, deferred on
  `code-mentor`, `execute` risk). Chosen after trying the three ways of driving lldb from a child process on this Mac:
  `lldb --batch -o …` prints text to scrape, cannot interrupt a running program and ends with its commands; a long-lived
  `lldb` on stdin needs a sentinel and the same scraping; **lldb's Python API** (`/usr/bin/python3 -I driver.py
  <lldb -P>`, which imports `lldb` with the system Python) gives typed values (children, pointers, line entries,
  frames), a second thread that can `SendAsyncInterrupt` a runaway loop, and lets the program's stdio go to files. The
  driver reads one JSON command per line and answers `@@DBG@@{json}`; every bound (24 variables a frame, 8 children, depth
  2, 100-character strings, 12 frames, 3,000 backtrace depth) is applied there. One driver per session; a one-shot `run` or
  `crash` is a private session. No launch ever needs a task-port prompt **when Developer Mode is on**
  (`DevToolsSecurity -status`). When it is off, macOS shows an administrator-approval dialog the first time
  (remembered for a while); the tool then waits 75 s longer for the first stop and, if nobody approved, ends the
  session and says so, naming `sudo DevToolsSecurity -enable` (the app never changes system settings). Programs launch
  stopped at entry, so the wall-time timer (`seconds`, default 20, max 60) covers a loop that never reaches a breakpoint:
  the program is interrupted where it spins and reported there. Output is bounded the same way: a program's stdout and stderr
  go to files, and one that writes more than 4 MB is interrupted. Only crashes stop a program (SEGV, BUS, ILL, FPE, ABRT, TRAP,
  EXC_*); every other signal is delivered to it. `crash` also breaks on `rust_panic` and `rust_begin_unwind`, and an error exit
  is never reported as "did not crash". Core dumps are not an option (`/cores` is root-only).
  * *Actions*: `run` (breakpoints `file:line` or function, ` if <condition>`, `max_stops` ≤ 50, stops at `main` with none),
    `crash` (run to the crash: the signal in plain words — `DebugWords`, which says what happened and never the fix — the
    faulting frame, locals of the learner's frames up the stack; library frames are hidden, the count shown), and a stateful
    session: `start`, `step`, `next`, `finish`, `continue`, `print` (a variable path is read without running code; other
    expressions are evaluated in the program with a 3 s limit), `frame`, `stop`. One session per lesson (`DebugSessions`): `start`
    replaces it; Stop (`ChatSession.stop`, tested through a real `ChatSession`), a deleted lesson (`AppModel.delete` calls
    `DebugSessions.end`) and app quit (`killAll`, which waits) kill the driver, debugserver and the program: the program is
    SIGKILLed and the driver frozen at once, and the tree under it (`pgrep -P`) is walked and killed off the calling thread
    (a frozen parent keeps its children findable). A session idle 15 minutes is reaped at the next use; 500 stops at most.
    The program keeps the fence it started under: the session ends only when the current fence protects something it didn't
    (`WriteFence.covers`: every path now denied was denied then, and what the start opened up is still open), so a build writing
    `Cargo.lock` doesn't end it; a file created after the start is not counted, which means a running program is not fenced from
    a learner file saved during the session.
  * *Building*: `build` runs through `ProcessRunner` (the call's `WriteFence` applies; package installs are refused as in
    `bash`), then `program` is the executable; omitted, Cargo's `target/debug/<package>`, SwiftPM's `.build/debug/<product>` or
    `zig-out/bin/*`; not yet built, the project profile's build command runs once. A source file as `program` (c, cpp, rs,
    swift, zig, m) is compiled to a scratch folder with `-g -O0` (Swift in two steps so its object file keeps the debug info;
    Rust packed). A binary whose compile units name no readable source (stripped, `-O2`, `--release`) is reported before
    anything runs, with the commands that give symbols. Go is built with `go build -gcflags=all=-N -l`, then run as `dlv exec` scripted once (breakpoints, `continue`, `locals`,
    `stack`) inside `seconds` (the build is outside it; a timeout returns what was printed), text only; without `dlv` it says what is available instead of pretending.
  * *Guardrails*: `PermissionExtension` asks for a launch (`run`, `crash`, `start`) and for `print`, which evaluates an expression
    inside the program, and shows what will run: the build command, program and arguments, every breakpoint with its
    condition, the standard input, the expression. `step`, `next`, `finish`, `continue`, `frame` and `stop` add no code and are
    never asked. "Allow for this lesson" grants `debug` alone; a shell grant implies it; only a `build` (a shell command) needs
    the shell grant, and no command rule is offered. Breakpoints and expressions with a newline or other control character are
    refused (Go's breakpoints are written into a Delve script), `MentorGuard.commands` includes it so the driver runs under the project's
    `WriteFence` (`sandbox-exec` is inherited by debugserver and the program, so a debugged program can't write what `bash`
    couldn't), hooks see it, and `subAgentVariant` is nil: sub-agents get no debugger. The build string is checked for package
    installs. `print` can call functions in the program, which stays inside that fence.
  * *The card*: the result's `meta` is the `trace` card's shape (`files`, `steps`: `f l e s o note exc`, `output`,
    `language`), `TeacherUI.defineTool({name: 'debug'})` in `codelab.js` renders the same stepper; a session's card shows the
    whole history (80 steps), a crash ends in an `exception` step. Program output goes to a file and is shown when the program
    flushes it (usually at exit; C buffers a pipe). `DebugToolTests` check the protocol, bounds and clean-up against a
    stand-in driver, and C, Rust and Swift programs (breakpoint with locals, stepping, null dereference, stack overflow, bad
    address, runaway loop, the fence) against real lldb, skipping when none can be launched.
* **Learning a language or library from its source** (`Tools/SourceTool.swift`): `source` resolves a library by name
  to where it lives on this Mac — Zig's std (`zig env`, via `Toolchains`), Rust's std/core/alloc (`rustc --print
  sysroot` + rust-src), Go's GOROOT/src and module cache, Python's stdlib and any importable module (`importlib`;
  built-ins without Python source are named as such), npm packages under the folder's `node_modules`, Cargo registry
  crates, SwiftPM checkouts, or a folder path — then locates, finds files by name, outlines (`SymbolsTool.outline`),
  reads numbered line ranges and greps within it. Roots are cached per launch. Core in Code mentor mode, deferred in
  other lessons; the instructions make the installed source the textbook and the projects reimplementations of it.

* **The learner as an engineer** (`Study/EngineerProfile.swift`, `UI/EngineerProfileView.swift`). Project records stay in
  their folders, so the mentor used to forget that a learner missed empty input in four projects running. `project_review`
  findings take an optional `area` (`EngineerArea`: error handling, edge cases, testing, naming, design, performance,
  concurrency, memory, security, tooling); a keyword classifier covers old findings (`Finding.area` is optional, so old
  records decode) and replies that omit it, and a finding no keyword fits is left out rather than guessed. Recording a
  round rewrites that project's rows in `eng_reviews` and `eng_findings` (`teacher.sqlite`, never a project folder) whole
  from its record, in one transaction, so re-recording is idempotent; a one-time backfill (`Runtime.job`) reads the
  `project.json` and `projects/*.json` of the folders the app knows. No model call anywhere: the profile is computed at
  read time. Per area and language: reviews in the last five that raised it, findings by severity weight with a 60-day
  half-life, a trend (last three reviews against the three before), and fixes split into *on their own* and *after hints*
  (a revealed rung, or help reported in the round that checked it): hinted work is evidence and the profile never feeds
  mastery. A **pattern** needs three reviews of the last five (60%), in at least two projects, and not clean in the two
  latest; clean in both after three hits is *moving past*, and says nothing. `CodeMentorExtension` adds an ephemeral
  `<engineer_profile>` block (about 120 tokens, 480 characters at most, area names and counts only, never finding text)
  at a lesson's start, when no project is open and while a review is open; no pattern, no block. Progress › "How you work
  as an engineer" lists patterns with up to three linked findings; the learner can dismiss a pattern (`eng_dismissed`) or
  reset (`reset_at` keeps older reviews from returning through a backfill).

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

Sub-agents' report rules ask for full-depth, verified work. Reasoning
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
root ── files (read, write, batch edit, ls), web, load_tools, skill; sub-agents, past_lessons, browser and Mac control (runtime);
│        the user's MCP servers' tools (runtime, `mcp__<server>__<tool>`); the drawing set (`draw`: formats on demand)
│        skills: web-research, read-long-documents
└── teacher ── ask_learner, math, run_code, memory, lesson_plan; bash, mastery, flashcards… (runtime); vocab, practice, problem
    │          skills: lesson-design, quiz-writing, feedback-on-answers
    ├── tutor · socratic · explain · quiz · exam · eli5 · research   (instructions differ, tools don't)
    ├── language ── language, vocab; listen, gloss, dialogue, conjugation, tones, reading, correction
    │               skills: conversation-practice, grammar-drills, pronunciation-coaching
    └── code-mentor ── run_tests, project_tests, project_review, trace, symbols, diagnostics, bash; bench, mutate, coverage, source, lsp, glob, grep, code (runtime)
                       skills: debugging-coaching, code-review-feedback, project-scaffolding,
                               tdd-coaching, reading-unfamiliar-code, refactoring-safely, performance-investigation,
                               concurrency-bugs, secure-code-review, system-design-practice, technical-interview-practice
```

* **Three sets per node.** `core` tools go with every request; `deferred` ones load at runtime (one short line each in
  the prompt: the full description and typed schema arrive only once a tool is loaded, by `load_tools` or by calling it
  by name, which loads and runs it); `components` are the fences the agent may write. `ToolRegistry.active`,
  `load_tools` and a direct call to a tool all resolve against the agent's path, so a tutor can't load the code mentor's
  `run_tests`. Core is what an agent uses in most turns; everything else is deferred.
* **Skills follow the tree** (`Skills`, `SkillTool`), in Claude Code's and OpenCode's format: a folder with a `SKILL.md`
  (front matter `name`, `description`, optional `agents`, `disable-model-invocation`). The app's own live in
  `Resources/skills/<node>/` and an agent gets those on its path; then the user's (`~/.teacher/skills`,
  `~/.claude/skills`, `~/.config/opencode/skill(s)`, `~/.agents/skills`, for every agent unless `agents` names some);
  then the open folder's (`.teacher/skills`, `.claude/skills`, `.opencode/skill(s)`, `.agents/skills`), later winning
  on a name. A skill tagged for the old code agent (`agents: [code-agent]`) goes to the code mentor. The prompt's
  `# Skills` section names each in one line (at most 40; `skill` with `query` searches the rest); `skill` returns a body only when the agent loads it. Settings › Agents lists each agent's skills.
* **Components follow the same tree.** The page gets the agent's component list with each `T.reset`; a fence outside it
  renders as its source, never a widget. Changing the set clears the markdown caches.
* **Guides follow it too.** Each node has a guide (`Guides`, editable in Settings › Instructions as "App guide" and
  "Tools guide: …"); an agent's prompt joins the guides on its path, root first, with `{more_tools}` filled from its own
  loadable tools.
* **Drawings follow it too** (`Drawing`): `Resources/drawing/<node>/` holds a node's drawing kinds, so the code
  mentor's views reach only the code mentor. `draw` resolves against the agent's path and its page's components, and
  a sub-agent resolves against its lesson's branch (it inherits `agentNode`).
* **The course board is core** for teachers: it must never depend on another tool being loaded (it used to arrive with
  `mastery`, so switching quizzes off removed the board too).

## Instructions and limits
* Guides name what their node adds; formats live in references loaded at runtime (`draw` for drawings, `skill` for
  know-how, tool definitions after `load_tools`), never in the prompt.
* Every agent's standing instructions live in `Instructions` (teacher, each mode, board, app guide, tools
  guides, built-in sub-agents), short by default and editable in Settings → Instructions (stored in `AppSettings.instructions`;
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
* Code lessons get the installed toolchains (`Toolchains`: versions and standard-library paths,
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

## Past lessons
Memory keeps short episode summaries; `past_lessons` (deferred on the root node, so every agent) answers "what did we
decide last time" from the transcript. `search` (bm25 × a recency weight of 0.6–1.0, at most 3 hits per lesson), `read`
(a bounded window around a `lesson:seq` ref, each message cut), `recent` (lessons with their episode summaries); every
result opens with a notice that it is data, not instructions.
* **What the index holds.** `messages.text` (what `messages_fts` indexes) is `MessageIndex.text(of:)`: visible text and
  attached files, plus the commands and code `bash`/`run_code`/`diagnostics`/`run_tests` ran (≤1.5k chars) and the first
  400 characters of a failed result. Never hidden or ephemeral blocks (recalled memory, plans, loop notes: before this,
  they were indexed, and so shown by the sidebar search), thinking, images, or successful tool output (bulky, and the pages and
  files a lesson read are not what was said). Older databases are re-indexed once in the background
  (`MessageIndex.upgrade`, job `lessons.reindex:<db>`: 200 rows a transaction, `store_meta` cursor and `text_v2` marker; a
  crash resumes; each UPDATE is `WHERE data = <what was read>`, so a message saved meanwhile keeps its own text). Until a database is marked, a hit on a message with hidden blocks is re-read and its snippet taken
  from the visible text (or dropped), so nothing hidden surfaces from a database this build has not opened. Snippets and
  `read` output go through `PastLessons.scrub` (base64 and data URLs).
* **One query per folder.** The `messages_fts` seek that bounds a common word to its newest 2,000 matches (see
  `ConversationStore.search`) is kept, and the date and mode filters are part of that seek (the cap is on matches that
  qualify, so an older range behind 2,000 newer matches is still found); when the cap cut results the tool says so, and a
  search that did not finish never reports "no match". The ranked 200 are joined to `messages` and `conversations` in the same
  statement (`json_extract` for role, title and mode, run only on the survivors; the mode filter is a subquery over
  `conversations`). 60,000 messages: 11 ms for a word in every message.
* **Other folders.** Each search opens the folder's `state.sqlite` read-only on its own connection and a GCD thread
  (`PastLessons.off`), never from the main actor. Opening a file on a volume that went away blocks in the kernel, where `sqlite3_interrupt` does
  nothing, so `off` resumes its caller from the budget's timer or from cancellation (first resume wins) and leaves the thread to
  finish alone; unmounted `/Volumes/…` folders are skipped, and the path checks themselves (`databases(…, budget:)`) run
  there too, so nothing on the Sessions page waits on a disk. `scope: "all"` reads `SessionIndex.known` (recent folders, the default and the quick
  folder; the app keeps it current) deduplicated by real path, at most 16 databases, 4 at a time, 2.5 s each. Cancelling the task or
  the budget running out calls `Database.interrupt()` (`sqlite3_interrupt`) on the statement in flight. A folder with no
  database is dropped before opening (nothing is created); a corrupt or locked one is skipped and named in the result.
* **Gates.** The first `scope: "all"` in a lesson asks through `PermissionExtension` (grant `past-lessons-all`, "Allow for
  this lesson"; a refusal is not remembered). `subAgentVariant` is a folder-only tool without the `scope` property that
  ignores it if given: sub-agents work through untrusted pages and files. No built-in sub-agent type lists
  `past_lessons`; only a custom agent (`tools: past_lessons`) gets it, in that form. 
* **Sessions page.** The query is debounced (300 ms) in a `.task(id:)` (query and the All / Working / This folder picker),
  searches the folders the picker allows (Working keeps only lessons running or waiting) off the main actor
  and is cancelled by the next keystroke; a hit opens its lesson (the transcript has no hook to reveal one message).
* The agent hears of it in one root-guide clause and a deferred line; `MemoryHub.recall` adds a pointer when a "last
  time" cue brings back an episode. Prompt cost: +233 characters (≈58 tokens) in the system prompt (`--cli --measure
  --no-memory`: 7,403 → 7,636 chars, fixed prefix 6,430 → 6,488 tokens); the definition (≈420 tokens) loads only when used.

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
  the digest fallback), `agents` (sub-agent runs), `mcp` (MCP servers and language servers, one child per folder and
  server, each with its own OS process). Root never gives up; it restarts a supervisor that did, with backoff.
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

## Code research (the code mentor)

### Research: an index and a graph, not just grep

**What it is.** `CodeIndex` (an actor, one per folder) keeps, per source file:
* its definitions with the lines they span (`SymbolsTool.outline`, about 20 language families);
* what it imports, and the identifiers it uses.

From those it derives:
* where each name is defined;
* a weighted file graph: a file uses another when it names something only that file defines (names defined in more
  than 6 places link nothing), or imports it;
* PageRank over that graph, so central files rank higher (Aider's repo map).

**How search works.** BM25 over chunk words, with identifiers split (`parseHTTPHeader` → parse, http, header) and
lightly stemmed. The scoring then adjusts for:
* **Chunks:** a definition with its doc comment. A type's chunk ends at its first member, and a long function also gets
  40-line windows, reported at their own line.
* **Synonyms**, at 0.6 weight (approve ↔ allow, permission; run ↔ execute…).
* **Coverage:** the share of the question matched, squared.
* **Name and path boosts.**
* **Length** normalisation.
* **Centrality** boost; tests are halved unless the question is about tests.
* **Excluded:** vendored and minified files.

**Updates and cost.** Each query re-lists the folder (ripgrep, gitignore-aware) and re-reads only files whose size or
date changed. The index is saved in the app's support folder, never in the project. This repository's ~480 files index
cold in about 3 s.

**The `code` tool** gives `find`, `def`, `refs`/`callers` (exact, through `rg -w -F`, each use with its enclosing
definition), `callees`, `outline`, `related` and `map`. It is a deferred tool of the code mentor; `symbols` is core.

**Why not embeddings.** The only local model is Apple's sentence `NLEmbedding`: ~25 ms a chunk (minutes for a large
repository) and trained on prose, not code. BM25 over split identifiers with synonyms and the graph found the right
definition for the test questions, such as "ask the user to approve running a shell command", which ranks
`PermissionExtension.shouldRun`, at the line where the approval is built.

**Why grep stays.** Exact text (error messages, strings, config keys) is what an index can't rank, and models are
trained to reach for it. `grep` stays as that.

### The compiler's view: language servers (`Code/LSP/`)
The index and `symbols` are fast guesses (regular expressions, names): same-named symbols blur, there are no types and no
real errors. The `lsp` tool (deferred on the `code-mentor` node, sub-agents get it too) asks the language server for the
file's language instead.
* **Client** (`LSPClient.swift`): `LSPStdioTransport` spawns the server (`posix_spawn` in its own process group, only
  fds 0-2, stderr in an `MCPLog`) and `LSPFraming` parses `Content-Length` frames (any other header ignored, length in bytes,
  a message without one ends the link). `LSPConnection` is JSON-RPC 2.0 as `MCPConnection` is: responses matched by id,
  `timeout` → `$/cancelRequest`, cancellation likewise, every waiting call failed when the link ends. It answers the server's
  own requests (`workspace/configuration` with a null per item, `client/registerCapability`, `window/workDoneProgress/create`,
  `workspace/workspaceFolders`; `workspace/applyEdit` is refused: a server never changes files), tracks `$/progress` tokens
  and rust-analyzer's `experimental/serverStatus` (`activity`, `awaitIdle`), and keeps `publishDiagnostics` per file.
  `shutdown` → `exit` → close stdin → SIGTERM → SIGKILL.
* **Documents follow the disk.** Before every answer the file asked about is read and compared with what the server holds:
  new → `didOpen` (+ `didSave`, which is what makes rust-analyzer run `cargo check`); different → `didChange` (full text,
  next version) + `didSave`. Every other open document is checked by file stamp (`FileViews.stamp`) and re-sent or closed
  when deleted; 40 stay open at most. A file created after the server started is announced with
  `workspace/didChangeWatchedFiles` (sourcekit-lsp otherwise doesn't know it belongs to the package). So `write` and `edit`
  need no hook, and nothing trusts remembered state.
* **Supervision** (`LSPInstance` / `LSPHub`): one per folder and server, a transient child of Runtime › `mcp` (the
  supervisor of the app's external servers; ids `lsp:<server>@<folder>#n.g`), started by the first call that needs it,
  never because a lesson opened. A link that ends by itself is a crash: restart with backoff (3 in 60 s, 1 → 8 s), and
  `perform` waits through the restart and asks the question once more on the new link (documents are re-opened lazily). A
  first start that never gets ready fails at once with the server's last stderr lines and is not retried (a dangling rustup
  proxy exits 1 forever). At most 3 run: a start beyond that stops the one unused longest. 10 idle minutes stop one
  (it starts again on the next use); `applicationWillTerminate` → `LSPHub.shutdownNow`. The Tasks panel lists them
  (`BackgroundTask.Kind.lsp`, with what they are indexing) and Stop works.
* **Fence and Stop.** While a learner's project is open the server is spawned through `WriteFence.wrap` with
  `MentorGuard.fence(ws)`, the profile the mentor's own commands get (`LSPTool.fence(for:)`, decided from the folder, so
  a sub-agent's call is fenced too), so its build scripts, `cargo check` or `go list` can't change the learner's files or the
  locked tests. A different profile (project passed, tests unlocked) replaces the instance: the old one stops (`fenced`) and
  the next use starts one under the new. Why a server stopped is kept (`StopReason`: user, evicted, idle, fenced): Stop in the
  Tasks panel fails the call in flight with a clear message and the row stays stopped; only an idle stop is started again
  for a call that was waiting. The child is known from launch (`starting`), so quitting during a 90-s initialise still ends it.
* **Discovery** (`LSPServers`): extension → ordered candidates; each is found on `ProcessRunner.which` (the login shell's PATH)
  and its usual folders: rust-analyzer (`~/.cargo/bin`), gopls (`~/go/bin`), sourcekit-lsp and clangd (`/usr/bin`),
  typescript-language-server (`~/.lsp-servers/bin`), zls (`/opt/homebrew/bin`), pyright-langserver then pylsp. A `/usr/bin`
  Xcode shim or a `~/.cargo/bin` rustup proxy counts only if it works (`xcrun --find`, `--version`). No server: the error
  names the install command for the learner and says `code` and `symbols` still work; the app never installs anything.
* **Security.** A language server runs project code (rust-analyzer: build scripts and proc macros; gopls: `go list`;
  clangd and the TypeScript server: the project's configuration and plugins), so a cloned repository could get code
  execution just because the mentor looked at it. The first use of a server in a folder is therefore a question
  (`PermissionExtension.lspGate`, before the risk switch, chained like the other gates): allow in this folder
  (`AppSettings.lspApproved[folder]`, in the app, never in the folder), allow for this lesson, or no (the decline holds for
  the lesson). `LSPTool.run` checks the same approval itself, because sub-agents' calls skip the extension host: a
  sub-agent, or a headless run without the gate, gets an error saying so instead of starting anything. `--approve-lsp` on
  `--cli --tool lsp` approves for that process only and writes nothing. The child's environment is
  `ProcessRunner.environment()`, as the shell's. Hover text, diagnostics and symbol names come from the project's code: data,
  never instructions (the tool says so, as the app guide does for all output).
* **The tool.** Actions `definition`, `references`, `hover`, `type_definition`, `implementation`, `document_symbols`,
  `workspace_symbols`, `diagnostics`, `incoming_calls`, `outgoing_calls`, `rename_preview` (the edits as `- old / + new`
  lines; nothing is applied). Arguments are `file`, `line` and `symbol`: `LSPPosition.resolve` finds the whole-word symbol on
  the line (UTF-16 columns; `column` only picks among several; a qualified `a::b` puts the cursor on `b`; a line off by up to
  five finds the nearest line that has it and says so). Results are `path:line  source line`, sorted, de-duplicated, relative
  to the folder (outside it `~/…`), capped (`limit`, 40 by default). While the server indexes, a call waits at most 20 s
  (`LSPTool.indexWait`) for it to settle, asks anyway and appends "still indexing (n%)" with the partial answer;
  `ContentModified` / `ServerCancelled` are retried. `diagnostics` waits for the server's publish after the sync (an empty
  first publish is believed only after 1.5 s of quiet and while no progress is in flight). A file the server already has
  as it is on disk sends nothing, so a publish it already made stands (no 10-s wait); a publish naming an older document
  version is dropped; URIs are compared in one spelling (`LSPConnection.normalized`: `( ) + @` differ between servers);
  files over 2 MB are refused and at most 200 publishes are kept. The permission gate resolves the server off the main
  actor (`.pending`), because telling a working Xcode shim or rustup proxy from a dangling one runs it.
* **Tested** against a scripted fake server (framing, server requests, progress, version-matched diagnostics, timeouts,
  crash and restart, idle stop, the limit, the gate) and, skipped when absent, gopls, clangd and sourcekit-lsp on small
  temp projects (`LSPTests`). Measured here: gopls 0.6-1.3 s a question after start, sourcekit-lsp ~4 s for a first
  diagnostic, clangd ~2 s.

## Background tasks panel
`BackgroundTasks.snapshot()` gathers every background task into one list each second for `TasksView` (the sidebar's
Tasks page, and the side panel's Tasks tab, which shows the open lesson's tasks by default):
* `ShellJobs.all()`: commands and servers, with start and end, exit code, PID and URL;
* `SubAgentCenter.runs`: sub-agents, with type, model, steps, tokens and restarts;
* `MCPHub.all`: MCP servers, with phase, start, PID, restarts and the last error;
* `LSPHub.all`: language servers (kind `lsp`), the same and what they are indexing;
* `AppJobs`: the app's own `Runtime.job` and `Runtime.call` work. The wrappers record when a job was asked for, when it
  started (so the time it waited) and how it ended; the last 40 finished are kept.

Running tasks come first, oldest first; then the 50 most recent finished. `BackgroundTasks.stop` stops a command, a
sub-agent or an MCP server and logs it (`task.stop`). `AppModel.runningTasks` drives the sidebar's badge, checked every
2 s.

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
    `background.report` (and whether it woke the agent); `log` (every `AppLog` line).

  The level (`AppSettings.activityLog`: off, standard, full) is in Settings › General. `--log-summary [day]` totals a
  day per model and per tool.
* **Background work wakes the agent** (Claude Code's background tasks):
  * A background sub-agent's report and a background shell job's end reach the lesson through `AppModel.deliver`.
  * Mid-turn, the report is read at the next step. In an idle lesson it starts a new turn. A lesson that isn't loaded
    keeps it in `undelivered` until it is opened.
  * The root guide tells every agent not to poll: carry on, or end the turn saying what it is waiting for.
  * `ChatSession.awaitedWork` (background sub-agents, and shell jobs that aren't servers) drives the composer's
    "Waiting for…" strip.

## Testing
* `scripts/e2e.sh [--live]` — the whole loop: build, unit tests, renderer suite (light + dark), and with `--live`
  the scripted lessons. Run it after every change.
* `swift test` — unit tests (SSE/think-tag parsing, FSRS, BKT, grader, math equivalence, HTML→Markdown, workspaces,
  the drawing set's discovery and loading for every mentor and sub-agent (`DrawingTests`),
  memory, deadlines, sub-agent model choice / failure / cancellation). `RuntimeTests`: mailbox order, both restart
  strategies, intensity and per-child limits with backoff, restart policies, watchdog, stop without leaked tasks, links and
  monitors. `SubAgentTests` (a scripted fake model): budgets, types, read-only and grant ceilings, structured output with
  repair, steering, restart-and-resume, provider/model/effort choice (fuzzy, retired ids), nesting, memory bounds.
* `MyAITeacher --webtest Tests/web/renderer.test.js [--dark] [--only name]` — loads the real transcript page in the
  app's WebKit (offscreen) and runs ~165 tests: every fence and component, every example in the drawing references, streaming frame by frame, sanitising,
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

## Trust, custom commands and plugins

What a folder or a plugin supplies as *instructions* (skills, sub-agent definitions, commands, hooks, MCP servers) is
data until the user approves its exact files. The model is one: a SHA-256 fingerprint, the approval kept in
`AppSettings` (never in the folder), a change asks again.

* **A folder's own skills, agents and commands** (`ProjectTrust`): `.teacher|.claude|.opencode|.agents/skills`,
  `.teacher|.claude/agents`, `.teacher|.claude/commands`. `TreeDigest` hashes what reaches a prompt (each `SKILL.md`, agent and command file; at most 400 files, 1 MB each) and only
  lists the rest of a skill's folder by path and size (`node_modules` and `.git` are left out), so bundled assets can't trip
  the limit; `.DS_Store` and `._*` never count. Symlinks are followed and their content hashed; the card shows where each
  leads, and one resolving into a credential location (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.netrc`, `~/.config/gh`, Docker's
  config, Keychains, the app's keys file) blocks the folder. Too much to hash is `ProjectTrust.State.blocked(reason)`, shown in
  Settings › Agents and the command notice, never silence. File hashes are cached by path, size and time, and the prompt build
  warms them off the main actor; `AppSettings.approvedProjectContent[folder]` holds the approved
  fingerprint. Every seam receives the folder only through `ProjectTrust.approved(folder, settings)`, so unapproved content
  can't leak: `SystemPrompt.build` (skills), `AgentCatalog.all(settings:folder:)` (the five sites), `CustomCommands`. Until
  approved, the prompt's `# Skills` section carries one neutral line (`ProjectTrust.awaitingLine`) and nothing else. The
  prompt is frozen per lesson, so approval mid-lesson takes effect through `SkillTool`: a call that finds no such skill
  asks (`ProjectTrust.resolve`, an approval card under the call, one question per lesson and fingerprint, a decline holds
  for the lesson, a sub-agent never asks) and then reads the live files. The prompt itself stays frozen; `ChatSession.contentChangeNote` adds a one-time hidden
  ephemeral note on the next turn naming what became or stopped being available (an approval, a plugin switched off or updated).
  Settings › Agents › Skills approves or revokes too.
* **Custom commands** (`CustomCommands`): Markdown files in `~/.teacher/commands`, `~/.claude/commands` and the folder's
  `.teacher|.claude/commands` (folder ones under the trust above), front matter `description` and `argument-hint`;
  `$ARGUMENTS` and `$1`…`$9` expand in one pass (substituted text is never expanded again; arguments a command never
  mentions are appended). A command's expansion is sent as plain text (`send(_:literal:)`) and never parsed as a command again,
  so `/loop` whose body is `/loop` can't recurse. They join the `/` menu through `ProjectCommands.lessonSuggestions(current:custom:)` and expand
  into the message sent (`lessonCommand(_:custom:)`); a built-in's name is never taken, the folder's beats the user's.
  **Deliberately no `!` shell execution and no `@` file inclusion** (Claude Code's): a command file is text, so
  installing or approving one can never run anything; the agent reads or runs through its own tools, under the usual approvals.
* **Plugins** (`Plugins`, `Plugin`, `PluginInstaller`, `UI/PluginsSettings.swift`), Claude Code's layout:
  `.claude-plugin/plugin.json` plus `skills/`, `agents/`, `commands/`, `hooks/hooks.json`, `.mcp.json`. Installed in
  `AppPaths.support/plugins/<name>/`; `AppSettings.plugins[name]` is a `PluginRecord` (enabled, approved fingerprint,
  source, commit). A plugin is **active** only if enabled *and* its fingerprint (SHA-256 over every file) equals the approved
  one, so a new install and any update are quiet until the user reviews them (`Plugin.review()`: components, hook and MCP
  commands verbatim). Active plugins merge through the existing seams, tagged with their plugin: `Skills.available(plugins:)`,
  `AgentCatalog.all(plugins:)`, `HookSet` (`HookCommand.plugin/root`, `CLAUDE_PLUGIN_ROOT`; `HooksExtension.active`),
  `MCPConfig.entries` (servers named `plugin-server`, `${CLAUDE_PLUGIN_ROOT}` filled in) and `CustomCommands`. A plugin never
  shadows: a taken name becomes `plugin:name` (agents and servers `plugin-name`). Disabling or removing only stops
  being "active"; the components vanish from every seam and `MCPHub.stopPlugin` ends its servers. Hooks keep the existing rules
  (`allow` ignored, never widen permissions) and agents the lesson's grants (they only choose from the type's tools).
  **Install** is from a local folder (copied file by file: no `.git`, symlinks only if relative and inside) or a git URL
  (`validateGitURL`: https, ssh, `user@host:path` only; no `ext::`/`fd::`, options or shell characters), cloned shallow with
  `core.hooksPath=/dev/null`, `protocol.ext.allow=never`, `core.symlinks=false`, no submodules, `GIT_TERMINAL_PROMPT=0`, no
  global/system git config (no filters), `GIT_ALLOW_PROTOCOL=https:ssh`; the commit is recorded and `.git` removed. Bounds:
  500 files, 20 MB, 2 MB a file (a clone is also killed past 60 MB while running, `--filter=blob:limit=2m`); every symlink is
  resolved on the real filesystem (`realpath`) and must land inside the real plugin folder, else (or if dangling) it is rejected,
  as are special files, bad names and shipped caches (`__pycache__`, `.cache`, `*.pyc`, which are left out of the fingerprint so
  a plugin's own runtime caches don't un-approve it). The review lists hook and MCP commands first, word for word, with line breaks
  and control or bidi characters shown (↵, <U+202E>), and a short clamped description last. A plugin's MCP server never takes the
  name of one the user or the folder has. `/plugin` lists them
  and opens Settings. No registry, no auto-update. Author's guide: `docs/plugins.md`; example: `examples/plugins/study-kit`.

## Tool parity with Claude Code
| Claude Code tool | My AI Teacher | Notes |
|---|---|---|
| Bash | `bash` | zsh, persistent cwd per lesson, timeout (≤600 s), 30k-char head/tail truncation, huge output spilled to `.teacher/outputs` |
| Background jobs | `bash_jobs` | each command runs in its own process group (`ShellJob`); a server or watcher (a known command, or a printed localhost URL), a `cmd &`, or `background: true` moves to the background as B1… and the call returns; list, read new output, stop (the whole group); stopped when the lesson is deleted or the app quits |
| Read | `read` | `cat -n` lines, offset/limit, images (sent to the model), PDFs with page ranges, binary detection; the same range of an unchanged file answers "unchanged" while the earlier result is still sent whole (teacher only) |
| Write | `write` | creates parents; permission-gated by folder access; refuses a file not read, or changed since (`FileViews`) |
| Edit | `edit` | exact unique match or `replace_all`, helpful errors; notes a file changed since it was read |
| Glob | `glob` | `**` globs, newest first; `rg --files` (honours .gitignore), the folder walk when that finds nothing |
| Grep | `grep` | ripgrep when installed (fallback `grep`), files (by match count)/content (grouped by file)/count modes, paths relative to the folder searched, `-A`/`-B`/`-C`, `-i`, glob and `type` filters, `multiline`, `offset` + `head_limit` paging |
| Bash permission rules | `CommandRules` | "Always allow “npm test …” in this folder"; read-only commands never ask |
| Hooks | `HooksExtension` | PreToolUse (matcher; exit 2 or `decision: block` blocks, the reason goes to the model), PostToolUse (output reaches the model), UserPromptSubmit (context, or holds the message back), Stop (sends the agent back); Settings › Hooks and the project's `.claude/settings.json` in Claude Code's format, a project's only once approved for that folder and configuration; every lesson; command hooks only, `allow` decisions ignored, the main agent's calls only |
| CLAUDE.md | `InstructionFiles.nested` | only a subfolder's CLAUDE.md / AGENTS.md, on the code mentor's first read there; no prompt block |
| LS | `ls` | sizes, hidden-noise filtering |
| WebSearch | `web_search` | free & keyless: DuckDuckGo + Bing (+ Brave fallback), ranked by reciprocal-rank fusion × query-word coverage, two per site first, tracking parameters stripped; a slow engine gets 1.5 s once the other has answered; 10-min cache; news mode (falls back to the web); papers mode (OpenAlex: relevance overall and among works cited 25+ times, fused, a log-citation boost); `read` adds the top pages' best passages |
| WebFetch | `web_fetch` | HTML→Markdown (article extraction, MathML→TeX), PDF→text, images, 15-min cache; `query` returns the BM25-best passages (`Passages`), pages of 12k characters list their later sections' offsets, same-site link addresses left out; `urls` reads up to 4 more pages in parallel in a shared budget (local addresses skipped) |
| TodoWrite | `todo_write` | rendered as a live checklist |
| Task / Agent | `task` + `agents` | types (explore/general/coder/reviewer/tester + app, `.teacher/agents/*.md` and `.claude/agents/*.md` with Claude Code's tool names), provider/model/effort/budget per call, tool allow/deny, JSON-schema reports, steering notes, resume, nesting, supervised restarts; never above the lesson's grants |
| AskUserQuestion | `ask_learner` | 13 interactive component types, not just multiple choice |
| NotebookEdit | — | not needed for tutoring; `edit` works on `.ipynb` JSON |
| — (extra) | `draw` | the drawing set's formats on demand: a kind's fence format, example and limits; the catalog with no kinds |
| — (extra) | `run_code` | Python, JS, TS, Swift, C, C++, Go, Rust, Ruby, Bash, Java in a scratch dir |
| — (extra) | `diagnostics` | the project's check/test/lint command, output parsed to `file:line:col severity message`; syntax checks after every write/edit |
| — (extra) | `mutate` | mutation testing on a scratch copy: one textual change at a time to non-test code, the registered tests on each; survivors with `file:line`, was/now; bounded (20 default, 60 max, 4 at a time, time budget), cancellable; information, not a gate |
| — (extra) | `coverage` | never-run lines from the toolchain's own coverage (go, swift, cargo-llvm-cov, node/jest, coverage.py or stdlib trace) in a scratch copy; a missing tool is named, never installed |
| — (extra) | `debug` | lldb through its Python API for C, C++, Rust, Swift, Zig (Delve for Go): breakpoints with conditions, a crash explained, a stepping session; the `trace` stepper as its card; bash's approvals and write fence; deferred on the code mentor, no sub-agents |
| — (extra) | `symbols` | a file's outline, or where a name is defined (not mentioned), across the folder |
| LSP tool (Claude Code's `LSP`) | `lsp` | the compiler's view through the file's language server (rust-analyzer, gopls, sourcekit-lsp, clangd, TypeScript, zls, pyright/pylsp where installed): definition, references, hover, type definition, implementation, document and workspace symbols, diagnostics, call hierarchy, rename preview (applies nothing); position by `line` + `symbol`; deferred in the code mentor, sub-agents too; the first use of a server in a folder asks the learner (stored in the app), a sub-agent can't ask; supervised, at most 3, idle 10 min |
| /rewind | Undo this turn's changes | per-turn checkpoints of every file the agent changed, restored from the transcript, no git needed |
| /compact, /context | `ContextCommand`, `ContextReport` | `/compact [focus]` summarises now (focus to `Compaction.summarise`), says tokens before → after; `/context` opens the lesson info on the breakdown, no model call |
| /command | `ProjectCommands`, `CustomCommands` | the lesson's follow-ups (`/simpler`, `/quiz`…), mode switches and `/review`; Markdown command files from `~/.teacher|.claude/commands` and the folder's (once approved) with `description`, `argument-hint`, `$ARGUMENTS`, `$1`…`$9`; plugins' commands (`/plugin:name` on a clash). No `!` shell execution or `@` file inclusion, by decision |
| Skills | `Skills`, `SkillTool`, `ProjectTrust` | `SKILL.md` folders from the app, `~/.teacher|.claude|.config/opencode|.agents`, the folder's (only once approved, by fingerprint) and plugins'; listed in one line each, loaded on demand |
| Plugins (`.claude-plugin/plugin.json`) | `Plugins`, `PluginInstaller` | skills, agents, commands, hooks and `.mcp.json` from a local folder or a hardened git clone; nothing used until the exact fingerprint is approved; Settings › Plugins, `/plugin`. No marketplace or auto-update |
| MCP (`mcp__server__tool`, `.mcp.json`) | `MCPHub`, `MCPTool` | stdio and streamable HTTP; app-level servers (Settings → MCP) and the project's `.mcp.json`, which needs the user's approval of each server's exact config; deferred, one line per tool, `load_tools` by tool or server; every agent; every call asked (per-server "always allow" per folder); supervised (restart on crash, end with the app), stderr in Settings. Not yet: resources, prompts, OAuth, sub-agents, the old SSE transport |
| — (extra) | `math` | SymPy: evaluate/simplify/solve/diff/integrate/limit/series with assignments & tuples |
| — (extra) | graded `ask_learner`, `flashcards`, `mastery`, `lesson_plan` | graded quizzes, FSRS cards, BKT mastery, the course board |
| — (extra) | `past_lessons` (search/read/recent) | the real transcript of earlier lessons, deferred on the root node (every agent); see "Past lessons"; no built-in sub-agent type lists it, a custom agent that names it under `tools:` gets a folder-only variant |
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
