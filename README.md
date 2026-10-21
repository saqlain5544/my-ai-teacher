# My AI Teacher

A fast, native macOS AI tutor with its own agent harness. Swift/SwiftUI, one WKWebView for the transcript,
SQLite for state — no Electron, no Node, no third-party Swift packages.

## Features
- **Any provider**: Anthropic, OpenAI, Google Gemini, MiniMax, DeepSeek, OpenRouter, Mistral, Groq, NVIDIA, Ollama
  (cloud/local), LM Studio, OpenCode Zen, xAI, Moonshot, Z.ai, Together, Cerebras, Fireworks, or any custom
  Anthropic/OpenAI/Gemini-compatible endpoint. Model lists, context windows, output limits and reasoning support
  come from each provider (cached for a day). Streaming with thinking/reasoning.
- **Keys** from your shell environment (read from your login shell even when launched from Finder) or added at
  runtime in Settings → Providers (stored locally, owner-only).
- **Rich rendering**: Markdown (GFM, footnotes, task lists, callouts), KaTeX math + chemistry, 190+ languages of code
  highlighting with Run buttons, Mermaid diagrams, function plots, charts, timelines, steps, cards, comparisons,
  vocabulary cards, JSON trees, CSV tables, sortable tables, **live interactive visuals** (HTML/JS in a sandbox with
  offline three.js, d3, Chart.js, Matter.js, KaTeX), self-check **practice cards** and step-by-step worked examples.
- **Languages**: mixed-language replies (e.g. English + Arabic) with per-block direction, per-run script detection,
  proper fonts, ruby (furigana/pinyin), click any foreign word to hear it, and read-aloud that switches voices per language.
- **Memory**: a learner model, not a log: subjects and concepts with prerequisites and cross-subject links, mastery,
  goals, preferences and misconceptions; durable facts only, merged instead of duplicated; 0–2 relevant items recalled
  per turn; learning-map viewer and editor with provenance.
- **Tools**: read, write, edit, ls, glob, grep, bash, run_code (Python/JS/TS/Swift/C/C++/Go/Rust/Ruby/Java),
  math (SymPy), web_search (free, keyless), web_fetch, todo_write, task (sub-agents), memory tools.
- **Teaching**: interactive question forms (13 types incl. ordering, matching, fill-in-the-blanks, math with live
  preview, drawing), graded quizzes with mastery tracking (BKT), FSRS flashcards with a review screen, learning plans,
  teaching modes (Tutor, Socratic, Explain, Quiz, Exam prep, Code mentor, ELI5, Research), dictation.
- **Folders**: open any folder (⌘O). Teacher keeps its state in `<folder>/.teacher/`, can read anywhere, and starts
  read-only in each folder — you grant *Read & write* or *Full access*. **Quick questions** (⇧⌘N) need no folder.
- **Everything in the app**: a files inspector with previews and an in-app page viewer for links.
- **Lean context**: on-demand tools, trimmed old tool output, summaries only when needed, cache-friendly prompts;
  lesson titles from the on-device model. Python runs without asking by default (or ask/off in Settings), and
  packages can't be installed.
- **Metrics**: per reply — model, time, first-token latency, decode tok/s, tokens (cached/reasoning), tool timings,
  steps waterfall, memories used, languages; per lesson stats; and an **Insights** dashboard (local-only telemetry:
  latency, cache hits, errors, tools, context, learning outcomes, app performance, A/B experiments).

## Build & run
```bash
scripts/build-app.sh
```
```bash
open "build/My AI Teacher.app"
```
Requirements: macOS 14+, Xcode command-line tools (Swift 6). Optional: `python3` with `sympy` for the math tool,
`rg` for faster grep, language toolchains for run_code.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design, extension points and testing tools.
