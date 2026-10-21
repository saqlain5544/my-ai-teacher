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
  Memory/      MemoryStore/MemoryHub (hybrid FTS5 + on-device embeddings), Reflection
  Study/       FSRS-5 flashcards, BKT mastery, plans, quizzes, activity
  Workspace/   Folder workspaces (.teacher state), GlobalStore, Services
  UI/          SwiftUI views + TranscriptView bridge
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

## Adding features
| You want to… | Do this | Core changes |
|---|---|---|
| React to the agent loop (inject context, gate tools, observe results, act after a turn) | Implement `AgentExtension` (all hooks optional) and register it in `AppModel.registerExtensions()` | none |
| Listen to app events (UI badges, logging, sync) | `EventBus.subject.sink { … }` (`AppEvent`) | none |
| Add a tool | Conform to `Tool` (name, description, JSON schema, `risk`, `run`) and add it to `ToolRegistry.all`. `risk` drives permissions; interactive tools await `ctx.interactions.request(…)` | none |
| Add a provider | Add a `ProviderConfig` preset (Anthropic/OpenAI/Gemini wire format + quirks) to `ProviderCatalog`, or add a custom provider in Settings | none |
| Add a wire protocol | Implement `LLMClient` (emit `StreamEvent`s) and a case in `APIKind` | 1 switch |
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

## Testing
* `swift test` — unit tests (SSE/think-tag parsing, FSRS, BKT, grader, math equivalence, HTML→Markdown, workspaces, memory).
* `MyAITeacher --cli "prompt" [--provider minimax] [--model …] [--thinking low] [--dump]` — headless provider call.
* `MyAITeacher --cli --tool web_search '{"query":"…"}'` — run any tool headlessly.
* `open --env MYAITEACHER_DEBUG=1 "build/My AI Teacher.app"` then `scripts/debug.sh '{"action":"snapshot","path":"/tmp/a.png"}'`
  (also `send`, `pending`, `answer` by id/title, `eval`, `select`, `newLesson`, `openFolder`, `status`, `sessions`).
  Logs: `~/Library/Logs/MyAITeacher.log` (includes web-view JS errors).
* Renderer harness: serve the repo (`.claude/launch.json` → `web-renderer`), open `/Resources/web/index.html`,
  load `/web-src/fixture.js`.

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
| Task / Agent | `task` | sub-agent with its own context (read-only + web + math tools), parallelisable |
| AskUserQuestion | `ask_learner` | 13 interactive component types, not just multiple choice |
| NotebookEdit | — | not needed for tutoring; `edit` works on `.ipynb` JSON |
| — (extra) | `run_code` | Python, JS, TS, Swift, C, C++, Go, Rust, Ruby, Bash, Java in a scratch dir |
| — (extra) | `math` | SymPy: evaluate/simplify/solve/diff/integrate/limit/series with assignments & tuples |
| — (extra) | `quiz`, `flashcards`, `mastery`, `lesson_plan` | graded quizzes, FSRS cards, BKT mastery, curricula |
| — (extra) | `memory_search/save/update/forget` | scoped (learner/folder) long-term memory |

## Measured (Apple Silicon, macOS 27)
* Cold launch → rendered transcript: **1.07 s**; app process footprint **~68–73 MB** + one WebKit content process (~90 MB).
* Same-machine comparison (RSS of all bundle processes): My AI Teacher 135 MB (+~90 MB WebKit) vs MiniMax Code 662 MB, Claude 1,418 MB.
* Streaming render: p50 3 ms / p95 8 ms per frame for a 3k-char mixed Markdown/KaTeX/Mermaid stream.
* Free web search: 12/12 varied queries returned ≥5 results (engines fall back for each other).
