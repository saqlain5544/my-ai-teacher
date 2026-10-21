# Development

My AI Teacher is a single Swift package with no third-party dependencies. [ARCHITECTURE.md](../ARCHITECTURE.md)
explains the design. This page covers the day-to-day work.

## Layout

```
Sources/MyAITeacher/
  Agent/        the agent loop, system prompts, context policy, sub-agents, extensions (hooks)
  App/          app model, menus, debug hooks, CLI
  Browser/      the code agent's in-app browser
  ComputerUse/  Mac app control (Accessibility tree, screenshots, safety gate)
  Core/         SQLite, blob store, memory governor, supervised runtime, SSE, speech, fuzzy search
  Extensions/   memory, permissions, teaching context, languages
  Memory/       learner model: memory store, concept graph, reflection
  Providers/    Anthropic, OpenAI-compatible and Gemini clients; provider catalogue
  Study/        FSRS flashcards, BKT mastery, answers log, follow-ups, plans
  Tools/        every tool the models can call (files, shell, web, quiz, math, memory…)
  UI/           SwiftUI views and the transcript web view host
Resources/web/  the transcript page: app.js, components/*.js, styles, vendored KaTeX/Mermaid/highlight.js
Tests/          XCTest suites, plus Tests/web/renderer.test.js run inside the app's own WebKit
scripts/        build, DMG, test loops, live harness, profiler
docs/           user guide, memory design, this page
```

## Build

```bash
swift build
```
```bash
scripts/build-app.sh
```
```bash
scripts/make-dmg.sh
```

`swift build` makes a debug binary in `.build/debug/MyAITeacher`. `build-app.sh` builds the optimised bundle at
`build/My AI Teacher.app` (arm64, ad-hoc signed). `make-dmg.sh` packages that bundle as `build/My-AI-Teacher-<VERSION>.dmg`.

Ad-hoc signing gives each build a new identity, so macOS forgets the Screen Recording and Accessibility permissions it
had. Re-add the app in **System Settings › Privacy & Security** after rebuilding if you use Mac app control.

## Test

The whole loop: build, unit tests, the renderer suite in light and dark mode, and frozen-page recovery. It takes about a
minute:

```bash
scripts/e2e.sh
```

* **Unit tests:**

  ```bash
  swift test
  ```

  About 240 tests. They run against a temporary profile and never open your real database.
* **Renderer suite:** about 100 tests that load the real transcript page in WebKit and cover every component,
  streaming, quizzes, problem cards and performance:

  ```bash
  .build/debug/MyAITeacher --webtest Tests/web/renderer.test.js
  ```
* **Live lessons:** 31 scripted lessons against a real model, in a throwaway profile under `/tmp/myaiteacher-e2e`:

  ```bash
  python3 scripts/e2e-live.py --provider openrouter --model minimax/minimax-m3.1-flash:free
  ```

  The harness starts a second, test-profile instance of the app bundle. It sends prompts, answers quizzes and approvals
  by clicking the rendered cards, and checks each turn: page errors, stuck spinners, failed tools, files on disk, and the
  learner database. It covers the learning-first behaviour too: attempt first, misconception tags, follow-ups. Use
  `--only <name>` for one scenario and `--keep` to leave the app open. The harness accepts only free or prepaid
  providers: OpenRouter `:free` models, OpenCode Go `-free` models (`--provider opencode-go`), `--provider nvidia`, or `--provider minimax`. When OpenRouter's daily free
  quota runs out, use NVIDIA:

  ```bash
  python3 scripts/e2e-live.py --provider nvidia --model deepseek-ai/deepseek-v4.1-flash
  ```

Run `scripts/e2e.sh` after every change, and the live suite before a release.

## Debugging

* `MYAITEACHER_HOME=/some/dir` gives the app its own database, settings, folders and log.
* `MYAITEACHER_DEBUG=1` turns on the debug hooks, which a second process drives:

  ```bash
  .build/debug/MyAITeacher --post '{"action":"report","path":"/tmp/r.json"}'
  ```

  Actions include `snapshot`, `send`, `answer`, `eval`, `newLesson`, `openFolder`, `select` and `stop`
  (see ARCHITECTURE.md › Testing).
* `MyAITeacher --cli "prompt" --provider … --model …` calls a provider headless. `--cli --tool web_search '{"query":"…"}'`
  runs any tool.
* The log is at `~/Library/Logs/MyAITeacher.log`, or `$MYAITEACHER_HOME/MyAITeacher.log` for a test profile.

## Performance

`scripts/perf/perf.py` runs the release bundle under real workloads (lessons, streaming, recall, fetching, agents,
rendering). It records CPU heatmaps, call stacks, allocations and memory over time into an HTML report. See
ARCHITECTURE.md › Performance for the workloads and the numbers measured so far.

## Releasing

1. Bump `VERSION`.
2. Run `scripts/e2e.sh` and the live suite.
3. Build the bundle and the disk image:

   ```bash
   scripts/build-app.sh && scripts/make-dmg.sh
   ```
4. Install it locally:

   ```bash
   ditto "build/My AI Teacher.app" "/Applications/My AI Teacher.app"
   ```
5. Commit, then publish a release with the DMG attached (here for 1.0.1):

   ```bash
   gh release create v1.0.1 build/My-AI-Teacher-1.0.1.dmg --title "My AI Teacher 1.0.1" --notes "…"
   ```

## Conventions

* No third-party Swift packages. JavaScript libraries are vendored under `Resources/web/vendor` and work offline.
* Memory is bounded by design. Windowed transcripts, capped caches and an on-disk index keep the app's footprint flat
  however much history you have (ARCHITECTURE.md › Bounded memory).
* Model-facing text is short and concrete, and tool errors say exactly what to send instead.
* Tests use free models only, with thinking off, and never touch your real profile.
