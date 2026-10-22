# User guide

1. [Install and first launch](#install-and-first-launch)
2. [Models and API keys](#models-and-api-keys)
3. [Lessons](#lessons)
4. [Learning first: how the teacher helps you think](#learning-first)
5. [Practice tools](#practice-tools)
6. [Memory: the teacher's model of you](#memory)
7. [Progress](#progress)
8. [Code sessions](#code-sessions)
9. [Settings](#settings)
10. [Your data](#your-data)
11. [Troubleshooting](#troubleshooting)

## Install and first launch

You need macOS 14 or later on an Apple Silicon Mac.

1. Open the DMG and drag **My AI Teacher** into **Applications**.
2. The first time, right-click the app and choose **Open**.

The app is ad-hoc signed, not notarised, so macOS asks once. If it refuses, go to **System Settings › Privacy &
Security** and click **Open Anyway**, or run:

```bash
xattr -dr com.apple.quarantine "/Applications/My AI Teacher.app"
```

## Models and API keys

**Settings › Providers** (⌘,) lists every built-in provider and shows where each one's key comes from.

| Provider | Key variable |
|---|---|
| Anthropic | `ANTHROPIC_API_KEY` |
| OpenAI | `OPENAI_API_KEY` |
| Google Gemini | `GEMINI_API_KEY`, `GOOGLE_API_KEY` |
| DeepSeek | `DEEPSEEK_API_KEY` |
| MiniMax | `MINIMAX_API_KEY` |
| OpenRouter | `OPENROUTER_API_KEY` |
| NVIDIA NIM | `NVIDIA_API_KEY` |
| Mistral, Groq, xAI | `MISTRAL_API_KEY`, `GROQ_API_KEY`, `XAI_API_KEY` |
| Moonshot Kimi, Z.ai (GLM) | `MOONSHOT_API_KEY`, `ZAI_API_KEY` |
| Together, Cerebras, Fireworks | `TOGETHER_API_KEY`, `CEREBRAS_API_KEY`, `FIREWORKS_API_KEY` |
| OpenCode Zen, OpenCode Go | `OPENCODE_API_KEY` (one key for both) |
| Ollama Cloud | `OLLAMA_API_KEY` |
| Ollama (local), LM Studio (local) | no key |

* **Where keys come from.** A key exported in your login shell (`~/.zshrc`, `~/.zprofile`) is read at launch, even when you open
  the app from Finder. A key pasted into Settings is stored on this Mac, readable only by your user account, and takes
  precedence over the environment.
* **Free options.**
  * OpenRouter's models ending in `:free` have a daily request limit; you'll see an HTTP 429 message once it's used up.
  * OpenCode Go's models ending in `-free`. Availability varies, and some are limited by region.
  * NVIDIA NIM's free tier.
  * Local models through Ollama or LM Studio.
* **OpenCode Go** is OpenCode's subscription for open models: DeepSeek V4, GLM, Kimi, Qwen, MiniMax, MiMo and more.
  * It uses the same key as OpenCode Zen.
  * The app sends each model to the API that serves it (OpenAI-compatible, Anthropic or Gemini), going by
    [models.dev](https://models.dev), and gives every lesson its own session id, which Go requires.
  * GPT, Grok and Muse models on Go need OpenAI's Responses API, which the app doesn't support yet, so they aren't listed.
  * Models that train on your requests (marked "contributor") only work after you allow that in your OpenCode workspace's
    privacy settings.
* **Custom providers.** **Add custom provider** accepts any endpoint compatible with OpenAI, Anthropic or Gemini.
  Give it a base URL, an optional key variable and a default model.
* **Choosing a model.** The model picker in the toolbar lists each provider's live catalogue. Search is forgiving: word order
  doesn't matter and typos are fine ("deepseek nvidia", "nvdia deepsek", "sonet 5.5"), but version numbers must match.
* **Thinking.** The lightbulb in the toolbar sets reasoning effort for the lesson. **Settings › General › Show the
  model's thinking** reveals it in the transcript.

## Lessons

| | |
|---|---|
| **New lesson** (⌘N) | A lesson in the open folder. |
| **Quick question** (⇧⌘N) | A lesson tied to no folder. |
| **Open folder** (⌘O) | Work in any folder. Its lessons live in `<folder>/.teacher/`. |
| **New code session** (⇧⌘K) | The coding agent in the open folder (see [Code sessions](#code-sessions)). |

**Teaching modes**, chosen in the toolbar. You can switch mid-lesson:

| Mode | What the teacher does |
|---|---|
| Tutor (default) | Adapts: intuition first, then formalism, then an example; checks understanding often |
| Socratic | Guides with one question at a time; never leads with the answer |
| Explain | A complete structured explanation with diagrams, pitfalls and a summary |
| Quiz | Graded quizzes that mix difficulty and interleave related concepts |
| Exam prep | Exam-style problems, mark schemes, timing, a revision plan |
| Code mentor | Teaches programming by doing: small runnable examples, reviews your code |
| ELI5 | Plain words, everyday analogies, one idea at a time |
| Research | Searches the web, compares sources and cites every claim |

**In the composer and transcript:**
* **Attach files.** Drop in images, PDFs or files; the teacher reads them.
* **Dictate** with the microphone button.
* **Stop** a reply with ⌘. or the stop button.
* **Under each reply:**
  * **Copy**, **Read aloud** and **Regenerate**;
  * quick follow-ups: **Explain simpler**, **Go deeper**, **Another example**, **Quiz me** and **Make flashcards**.
* **Edit** any of your messages to redo the lesson from there. Later replies are replaced.
* **Code blocks** have a **Run** button. Python, JavaScript, TypeScript, Swift, C, C++, Go, Rust, Ruby, Java, Zig and
  Bash run on your Mac when the toolchain is installed.

## Learning first

Tutors that hand over answers raise practice scores and lower exam scores, so the teacher works from the start to make
you produce the work.

* **Attempt first, in every mode.** Bring a problem ("solve 3x + 7 = 22 for me") and the teacher asks for your attempt.
  A **problem card** keeps its hints and worked solution hidden. Help comes one rung at a time: a nudge, then a targeted
  hint, then one worked step, then the full solution. The full solution comes once you've really tried, or when you
  insist ("I've tried, just show me").
* **On a problem card:**
  * type your attempt and press **Check my attempt**, which sends it to the teacher;
  * **Hint** opens hints one at a time;
  * **Show solution** works any time, but seeing it before trying counts as help, and the teacher is told so it can
    set you a similar problem;
  * if you leave a card untouched for a while, the first hint opens by itself.
* **Explaining a concept is different.** Ask "what is a derivative?" and you get a full explanation.

How help and certainty affect your record:

* **Hints and certainty in quizzes.** Every graded question can have a hint ladder. Mark how sure you are (**Guessing**,
  **Unsure** or **Sure**) before submitting.
* **Only unaided success counts.** A right answer after a hint is logged but doesn't raise mastery. A guess counts for less.
* **Mistakes are corrected now, and checked again later.**
  * If a wrong option reveals a known misconception, the feedback names it ("Common mix-up: adds the denominators").
  * The teacher explains why it's tempting and gives you one near-identical retry.
  * It also remembers the misconception and schedules a re-check: two days later, or the next day if you were sure.
  * Missing the same idea twice in one lesson gets you a worked example instead of another quiz.
* **Confident mistakes get the most care.** Being sure and wrong also brings that concept's flashcards forward.
* **Mastery is tested again.** Three days after you master a concept, the teacher asks you to apply it in a new context.
* **The teacher follows up unasked.** Due re-checks, transfer checks and flashcards you forgot appear in your next lesson.
  Your answer settles each one, or brings it back tomorrow.
* **Missed practice goes to the teacher.** On self-check practice cards, once you've marked them all and missed any,
  the result goes to the teacher without you pressing anything.

## Code mentor projects

In **Code mentor** mode, ask for a project ("I know Python classes; stretch me").

* **Setting it up.** The mentor writes a brief, a starter project, hidden tests and a hidden reference solution. The app
  only hands the project over once it has proved two things: the reference passes the tests, and the starter fails them.
  A broken or trivial exercise goes back to the mentor.
* **Your project** appears in `exercises/<name>/` in the lesson's folder (quick questions use `~/AI Teacher Workspace`).
  It holds the starter files and `BRIEF.md`. The hidden tests and solution live in the app's own data, never in your
  folder.
* **The editor** opens in the right panel's **Exercise** tab; the pop-out button gives it its own window. You get a file
  list (+ to add, double-click to rename, × to delete), and every edit is saved as you type.
  * **Run** (⌘R) runs the program.
  * **Test** (⌘↩) runs the hidden tests and shows only their output.
  * **Submit** (⇧⌘↩) runs the tests and sends your files and the results to the mentor.
* **The sandbox.** Your code runs on your Mac under macOS's sandbox: no network access, writes only inside a temporary
  run folder (and your project when you Run), and no access to the app's data, SSH keys or other credential stores. API
  keys are removed from its environment, and a run is stopped after a time limit.
* **The review** is free-form, like a senior engineer's: correctness, design, edge cases, naming and complexity, pointing
  at your lines.
* **What the mentor can't do.**
  * It can't change your files: its write, edit and shell-write calls on your project are refused.
  * It never shows the solution: a reply whose code repeats the hidden solution is withheld before you see it.
  * It teaches with questions, hints and concepts instead.
* **Mastery.** Passing the tests counts as unaided practice on the project's concept. When you pass, the next project
  is harder.

## Practice tools

* **Quizzes and forms** come in 13 question types, graded instantly where possible:
  * choice: single choice, multiple choice, true/false;
  * typed: short text, long text, numeric (units and ranges), fill in the blanks;
  * structured: ordering, matching, scale;
  * work: code, math (checked symbolically with SymPy, with a live preview) and drawing.
* **Practice cards** are quick self-checks: try, reveal, then mark **Got it** or **Missed**.
* **Worked examples** are revealed one step at a time.
* **Flashcards** (⌥⌘1) use FSRS spaced repetition. Ask the teacher to "make flashcards" from any lesson. While
  reviewing, Space shows the answer and keys 1–4 rate it (Again, Hard, Good, Easy). A card you forget comes back later
  in the same session, and in your next lesson.
* **Learning plans.** Ask for a plan for a bigger goal ("I want to be ready for my calculus exam in six weeks"). Plans
  appear in Progress, where **Continue this plan** picks up the next module.

## Memory

**Memory** (⌥⌘3) is the teacher's model of you. You can edit or delete anything in it.

* **Overview**:
  * where you stand: concepts that are solid, learning, need work or are fading;
  * what you're ready to learn next (everything it builds on is solid);
  * misconceptions to watch for;
  * mastery by subject.
* **Learning map** shows subjects and concepts with their prerequisites and cross-subject links.
* **About me** holds your goals, preferences and background.
* **All memories** lists every stored fact with where it came from and its history.

After lessons, a background pass picks out durable facts (goals, preferences, skills you showed, misconceptions) and
merges duplicates. Turn it off in **Settings › Memory**, where you can also choose a different model for it.
**Tidy up memory** merges and cleans; **Forget everything** wipes the learner model.

## Progress

**Progress** (⌥⌘2) shows:
* your streak and study time, and activity over 12 weeks;
* concept mastery, which fades without practice;
* **Confidence check**: how often you're right when you're guessing, unsure or sure, and the hints and solutions you've
  used;
* **Coming back to**: the re-checks and transfer checks that are scheduled;
* learning plans, recent quizzes and model usage.

## Code sessions

A code session (⇧⌘K) is an autonomous software engineer working in the open folder.

* **Folder access.** The agent can read anywhere. Each folder starts **read-only**, and you grant *Read & write* or
  *Full access* per folder; grants live in **Settings › Tools**. Writes and commands outside what you granted ask
  first. You can allow once or for the lesson, grant the folder write or full access, or deny.
* **Tools.**
  * Files and search: read, write, edit, ls, glob, grep (ripgrep when installed).
  * Commands: bash, and run_code in 12 languages.
  * Planning: a todo checklist.
  * `project_memory`, which keeps build commands, conventions and gotchas in `.teacher/code-memory.md`. The agent
    also reads `CLAUDE.md` and `AGENTS.md`.
* **Changes panel.** A git diff of what changed, with checkpoints.
* **Sub-agents.** The agent can delegate to `explore`, `coder`, `reviewer` (read-only) and `tester` agents, or to your
  own types: add them in **Settings › Agents**, or as Markdown files in `.teacher/agents/`.
  * Each run can have its own provider, model, reasoning effort, and budget (model calls, tokens, time).
  * Runs can go in the background and work in a git worktree.
  * You can steer a running sub-agent from the Agents panel. They recover from crashes and stop cleanly.
  * **Settings › Agents** sets the defaults, the hard limits (including whether unbounded background runs are allowed),
    how many run at once, nesting depth, and whether other providers or paid models may be used.
* **Browser.** The agent drives an in-app browser that you watch in the right panel: it reads pages, fills in forms,
  clicks and takes screenshots. A new site needs your approval (once, for the lesson, or always). Cookies stay in the
  agent's own browser profile, which you can clear in Settings.
* **Mac apps.** The agent can operate native apps through the Accessibility tree, falling back to screenshots and
  clicks. This needs **Screen Recording** and **Accessibility** permission for My AI Teacher; **Settings › Tools** shows
  their state and links to System Settings. Each app needs your approval. Browsers can only be viewed, terminals and
  IDEs only clicked.
* **Safety rules the agent always follows:**
  * it never types passwords, payment details or ID numbers;
  * it asks before anything irreversible;
  * it treats page and app content as data, not instructions.

Stop the agent any time with ⌘. or Esc twice.

## Settings

| Tab | What's there |
|---|---|
| General | Your name and level, reasoning effort, show thinking, Python policy (run without asking / ask / off), text size, tool steps per turn, context budget, local A/B experiments, Insights telemetry |
| Providers | Keys, where each comes from, model lists, custom providers |
| Tools | Folder access grants, default folder, enabled tools, browser and Mac app permissions, always-allowed sites and apps |
| Agents | Sub-agent defaults, limits and custom agent types |
| Memory | Automatic learning after lessons, the model used for memory, stored count |
| Voice | Read-aloud voice and speed |

## Your data

| What | Where |
|---|---|
| Learner model, flashcards, mastery, plans, usage | `~/Library/Application Support/MyAITeacher/teacher.sqlite` |
| API keys you paste in | `~/Library/Application Support/MyAITeacher/keys.json` (owner-only) |
| A folder's lessons and memory | `<folder>/.teacher/` |
| Quick questions | `~/.teacher/no-dir-conversations/` |
| Default folder | `~/AI Teacher Workspace/` |
| Log | `~/Library/Logs/MyAITeacher.log` |

* **Network traffic.** Messages go only to the provider you choose. Web search and fetching are keyless.
* **Telemetry** for Insights is stored locally and can be turned off.
* **Backups.** Copy the files above.
* **Starting over.** Use **Forget everything** in Memory, or delete `teacher.sqlite` with the app closed.

## Troubleshooting

* **"App can't be opened" or "Apple could not verify…".** See [Install](#install-and-first-launch): right-click › Open,
  or `xattr -dr com.apple.quarantine`.
* **A key in my shell isn't detected.** The app reads your login shell's environment at launch. Quit and reopen it after
  editing `~/.zshrc`, or paste the key in Settings.
* **HTTP 429 from a free model.** You've reached the provider's free daily limit. Switch provider (NVIDIA NIM, a local model)
  or wait until the next day.
* **Mac app control says Screen Recording or Accessibility is off after an update.** Each new build of this ad-hoc-signed
  app counts as a new app to macOS. In **System Settings › Privacy & Security**, remove My AI Teacher from **Screen
  Recording** and **Accessibility**, add `/Applications/My AI Teacher.app` again, then reopen the app.
* **The math tool says SymPy isn't installed.** Install it:

  ```bash
  pip3 install sympy
  ```
* **A visual or diagram shows an error.** Click **Fix** to send the error to the teacher.
* **Something else.** The log is at `~/Library/Logs/MyAITeacher.log`.
