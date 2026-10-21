# My AI Teacher

A native macOS tutor that makes you do the thinking, plus a coding agent for your projects. It works with almost
any AI provider, free ones included, and keeps everything it learns about you on your Mac.

![A problem card: the tutor holds back the answer until you try](docs/images/attempt-first.jpg)

Built in Swift and SwiftUI with a single web view for the lesson transcript, and SQLite for state. It has no Electron,
no Node runtime and no third-party Swift packages. The app is about 21 MB and shows a lesson about a second after a
cold launch. It runs at roughly 70 MB plus one WebKit process (about 90 MB), a fraction of Electron-based AI apps.

## Install

1. Download **My-AI-Teacher-<version>.dmg** from [Releases](../../releases/latest). It needs macOS 14 or later on Apple Silicon.
2. Open the DMG and drag **My AI Teacher** into **Applications**.
3. The first time, right-click the app and choose **Open**, then **Open** again. The app is signed but not notarised by
   Apple, so macOS asks once. If macOS says it can't verify the app, go to **System Settings › Privacy & Security** and
   click **Open Anyway**, or run:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/My AI Teacher.app"
   ```

## Get started

1. **Choose a model.** Open **Settings › Providers** (⌘,) and paste a key for any provider. Keys already exported in
   your shell (for example `ANTHROPIC_API_KEY` in `~/.zshrc`) are picked up automatically. No key yet? These cost nothing:
   * [OpenRouter](https://openrouter.ai) `:free` models, with a daily request limit;
   * [NVIDIA NIM](https://build.nvidia.com)'s free tier;
   * a local model through [Ollama](https://ollama.com) or [LM Studio](https://lmstudio.ai).
2. **Start a lesson** with ⌘N and say what you want to learn: "Teach me the chain rule", "Quiz me on the French
   Revolution", "I have an exam on organic chemistry in two weeks". Pick a teaching mode from the toolbar.
3. **Ask a quick question** with ⇧⌘N. It isn't tied to a folder.
4. **Work on code** with ⇧⌘K. This opens a code session in a folder you choose.

The [user guide](docs/user-guide.md) covers everything in detail.

## What makes it different

### Teaching that makes you think
AI tutors that hand out answers raise practice scores and lower exam scores ([Bastani et al., PNAS 2025](https://www.pnas.org/doi/10.1073/pnas.2422633122)).
Tutors that make students attempt and explain show large gains. So My AI Teacher is **attempt first** in every mode:

* **Problem cards.** Problems you bring, or that the teacher sets, come as cards. The teacher's hints and worked solution
  stay hidden until you try. Your attempt goes to the teacher, who gives one hint at a time, from a nudge to a full
  solution. If you're stuck for a while, the first hint opens by itself.
* **Quizzes with 13 question types**, graded instantly, including symbolic math checked with SymPy. Before seeing the
  result you mark how sure you were (Guessing, Unsure or Sure). A confident mistake gets extra attention.
* **Wrong answers name the misconception behind them.** The teacher explains it, gives you one near-identical retry,
  remembers it, and checks it again in a later lesson.
* **Mastery counts only what you do unaided.** Answers after a hint are logged but earn no credit. A fresh mastery is
  tested again a few days later, in a new context.
* **The teacher brings things back.** Due re-checks, forgotten flashcards and concepts that are fading come up in your
  next lesson without you asking.

### Lessons that show, not just tell
* Markdown with math (KaTeX, including chemistry) and highlighting for 190+ programming languages, Zig included.
* Mermaid diagrams, function plots, charts, timelines, comparison tables and vocabulary cards.
* Live interactive visuals: simulations in a sandbox, with three.js, d3, Chart.js and Matter.js available offline.
* Self-check practice cards, worked examples revealed step by step, and flashcards scheduled with FSRS.
* Read-aloud and dictation, and mixed-language lessons (for example English with Arabic or Japanese) with the right
  text direction, fonts, furigana and pinyin, plus click-to-hear pronunciation.

### A teacher that remembers you
A learner model rather than a chat log:
* subjects and concepts with prerequisites, and mastery that fades without practice;
* your goals, preferences and misconceptions;
* "ready to learn next", which lists what your solid knowledge unlocks.

You can see and edit all of it in **Memory**. **Progress** shows your activity, mastery, a confidence check (how often
you're right when you're sure) and what's coming back for review.

### A coding agent too
**Code sessions** work in a folder, much like Claude Code:
* read, edit and search files, and run commands, with your approval;
* a plan checklist, and project memory kept in `.teacher/code-memory.md`, `CLAUDE.md` or `AGENTS.md`;
* a git diff panel with checkpoints.

The agent can also:
* **Delegate to sub-agents** (explore, coder, reviewer, tester, or your own definitions in `.teacher/agents/`). Each can
  have its own model, effort level and token or time budget. They run in the background, you can steer them, and they
  can work in git worktrees.
* **Drive an in-app browser**, to read pages, fill in forms and take screenshots.
* **Use Mac apps**, through the Accessibility tree and screenshots, with a permission gate for each app.

### Any model
Anthropic, OpenAI, Google Gemini, DeepSeek (V4 Flash and Pro), MiniMax, OpenRouter, NVIDIA NIM, Mistral, Groq, xAI,
Moonshot Kimi, Z.ai, Together, Cerebras, Fireworks, OpenCode Zen, Ollama (cloud or local) and LM Studio. Any
OpenAI-, Anthropic- or Gemini-compatible endpoint can be added as a custom provider.
* Model lists come live from each provider, and the model picker searches loosely: "deepsek nvidia" finds NVIDIA's
  DeepSeek models.
* Thinking effort can be set per lesson.
* Prompts are cache-friendly, and each reply shows its model, time, tokens and speed.

## Screenshots

| A lesson | After a repeated mistake |
|---|---|
| ![Lesson with a table, a callout and practice cards](docs/images/lesson.jpg) | ![A worked example contrasting the learner's move with the right one](docs/images/worked-example.jpg) |
| **Memory: the teacher's model of you** | **Progress: mastery, confidence check, what's coming back** |
| ![Memory overview with misconceptions to watch for](docs/images/memory.jpg) | ![Progress screen](docs/images/progress.jpg) |

## Keyboard shortcuts

| | |
|---|---|
| ⌘N | New lesson |
| ⇧⌘N | Quick question (no folder) |
| ⇧⌘K | New code session |
| ⌘O | Open a folder |
| ⌥⌘1 / ⌥⌘2 / ⌥⌘3 | Flashcards / Progress / Memory |
| ⌘. | Stop the reply (Esc twice also stops an agent) |
| ⌘+ / ⌘− / ⌘0 | Text size |
| Space, then 1–4 | Show a flashcard's answer, then rate it |

## Your data stays on your Mac

* **What's stored where:**
  * your learner model, flashcards, mastery and plans: `~/Library/Application Support/MyAITeacher/teacher.sqlite`;
  * each folder's lessons: `<folder>/.teacher/`;
  * quick questions: `~/.teacher/no-dir-conversations/`.
* **API keys** you paste in are stored on this Mac, readable only by your user account.
* **Where messages go:** only to the provider you choose. Web search is keyless (DuckDuckGo and Bing). Lesson titles
  come from Apple's on-device model when it's available.
* **Telemetry:** the Insights dashboard is local only. Nothing is sent anywhere.
* **Permissions:** folders start read-only, and you grant *Read & write* or *Full access* for each one. Commands, writes
  outside what you granted, browser sites and Mac apps all ask first.

## Build from source

You need macOS 14+ and the Xcode command-line tools (Swift 6). Optional extras: `python3` with `sympy` (math checking),
`rg` (faster search), and the toolchains of the languages you want `run_code` to run.

```bash
scripts/build-app.sh
```
```bash
open "build/My AI Teacher.app"
```

To make a release disk image:

```bash
scripts/make-dmg.sh
```

Tests, the live end-to-end harness and the profiler are described in [docs/development.md](docs/development.md).

## Documentation

* [User guide](docs/user-guide.md): every feature, setting and permission.
* [Development](docs/development.md): building, testing, the live harness, releases.
* [Architecture](ARCHITECTURE.md): design, invariants, extension points, bounded memory, runtime.
* [Memory design](docs/memory-design.md): how the learner model works and the evidence behind it.
