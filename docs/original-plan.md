# My AI Teacher — architecture plan

A native macOS tutor app with its own agent harness. Swift 6 / SwiftUI + AppKit, no third‑party Swift
dependencies, no Node/Electron runtime. Target: < 300 ms cold launch, ~60–120 MB RSS while chatting.

## Why a custom harness (not opencode / pi)
opencode and pi are good designs but need a Node/Bun runtime (200 MB+ RSS, slower start) and are
built around coding, not teaching. We borrow their best ideas (small orthogonal tool set,
provider‑normalised event stream, compaction) and implement them natively.

## Layers
| Layer | What | Files |
|---|---|---|
| Providers | 3 wire protocols — **Anthropic Messages**, **OpenAI Chat Completions**, **Google Gemini** — normalised into one `StreamEvent` stream (text, thinking+signature, tool calls, usage, stop). 15+ presets (Anthropic, OpenAI, Gemini, MiniMax, DeepSeek, Mistral, Groq, OpenRouter, NVIDIA, Ollama cloud/local, LM Studio, OpenCode Zen, xAI, Together, Cerebras, custom). Models fetched live from `/models`. `<think>` tag parsing for OpenAI‑compat models. | `Providers/` |
| Keys | Env vars (process env + login‑shell env, since Finder‑launched apps don't inherit the shell) → overridden by runtime keys saved in the Keychain. | `Core/ShellEnv.swift`, `Core/KeyStore.swift` |
| Agent loop | stream → collect tool calls → permission check → run tools (read‑only in parallel) → feed results → repeat. Cancellable, max‑turn guard, auto compaction when context gets large. | `Agent/` |
| Tools | Claude‑Code parity: `bash`, `read`, `write`, `edit`, `glob`, `grep`, `ls`, `web_search`, `web_fetch`, `todo_write`, `task` (sub‑agent). Extra: `run_code`, `calculate`, memory tools, teaching tools. | `Tools/` |
| Web search | Free, keyless: DuckDuckGo HTML + Bing RSS (+ Brave HTML fallback) in parallel, merged/deduped; Wikipedia API; Bing News RSS. `web_fetch` converts HTML → Markdown with Foundation's `XMLDocument(.documentTidyHTML)`. | `Tools/Web*.swift` |
| Memory | SQLite + FTS5 + on‑device `NLEmbedding` vectors (hybrid BM25 + cosine). Kinds: profile, preference, goal, knowledge, misconception, episode, fact. Core memory injected every turn; relevant memories retrieved per message; background *reflection* pass after each lesson extracts/updates/merges memories; importance × recency decay. Viewer/editor UI. | `Memory/` |
| Teaching | Modes (Tutor/Socratic, Explain, Quiz me, Exam prep, Code mentor, ELI5). Tools: interactive `quiz` (rendered in chat, waits for answers, auto‑graded, results → mastery), `ask_learner` (multiple‑choice prompt), `flashcards` with **FSRS** spaced repetition + review screen, `lesson_plan` (curriculum + progress), `update_mastery` (concept mastery tracking), `plot` blocks. Voice: read aloud (AVSpeech) + dictation. Attach images / PDFs / files. | `Teaching/`, `Study/` |
| Rendering | One `WKWebView` per window renders the whole transcript from bundled offline JS: markdown‑it (GFM, footnotes, tasks), **KaTeX** (+mhchem) for `$…$ $$…$$ \(…\) \[…\]`, **highlight.js** (190+ languages, lazy‑loaded), **Mermaid** (lazy‑loaded, cached SVG), DOMPurify sanitising, function‑plot blocks, copy/run buttons on code. Streaming via rAF‑batched top‑level DOM diff so earlier nodes (diagrams, selection) are never re‑rendered. | `Resources/web`, `web-src/` |
| Storage | One SQLite DB (WAL) in `~/Library/Application Support/MyAITeacher`: conversations, messages (JSON blocks), memories(+fts,+vec), flashcards, reviews, mastery, plans. | `Core/Database.swift` |

## Performance rules
* Release build, `-O` + whole‑module optimisation, arm64 only.
* Stream deltas coalesced to ≤ 1 UI update per frame; JS renders on `requestAnimationFrame`.
* Caches for KaTeX / highlight / Mermaid output keyed by source.
* Mermaid (5 MB) and highlight languages load only when first used.
* Embeddings & reflection run off the main actor at utility QoS.

## Testing
Live tests use only MiniMax (Anthropic‑style + OpenAI‑style endpoints) and OpenCode Zen `-free`
models. Unit tests for SSE parsing, FSRS, HTML→Markdown, edit tool. UI verified with computer use.
