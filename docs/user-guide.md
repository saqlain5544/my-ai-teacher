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
* **Context.** Automatic by default: a lesson keeps up to half the model's window (at most 400k tokens) before older
  tool output is trimmed and earlier parts are summarised. You can set a fixed budget in Settings › General.
* **Plan and check substantial answers** (Settings › General, on by default).
  * A substantial request gets a hidden plan first: what you need, an outline, what to verify with tools, what to research.
  * A reviewer reads the reply before you do. If it finds a real problem (an error, an unchecked claim, a toy example, a
    solution you should have attempted), the teacher revises it.
  * The first draft stays in the transcript, collapsed; click it to see it and the review's notes.
* **Thinking.** The lightbulb in the toolbar sets reasoning effort for the lesson; **Max** is used where the model takes it
  (DeepSeek V4, Claude) and means High elsewhere. **Settings › General › Show the
  model's thinking** reveals it in the transcript in every mode: it opens while the model thinks, then collapses to a
  “Thought process” line you can toggle open or shut.

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
| Language mentor | Teaches a language: placement, glossed sentences, dialogues, dictation, speaking, your own vocabulary deck |
| ELI5 | Plain words, everyday analogies, one idea at a time |
| Research | Searches the web, compares sources and cites every claim |

**In the composer and transcript:**
* **Attach files.** Drop in images, PDFs or files; the teacher reads them. With a model that cannot see images (some free
  models are text-only), the picture is passed on as a note and the teacher asks you to describe it instead.
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

* **Quizzes on or off.** The **Quizzes** button in the lesson toolbar turns testing off from your next message, and it
  stays off until you turn it back on. With quizzes off the teacher teaches without questions, problems or practice
  cards. **Ask for a check** on the course board still works when you want one. Quiz and Exam prep modes always test.
* **Exam-style questions.** A quiz usually opens with a **Case**: a realistic scenario, piece of code, data set or
  passage. Its questions all refer to that case and need reading and reasoning, like a real exam.
* **Hints and certainty in quizzes.** Every graded question can have a hint ladder. Mark how sure you are (**Guessing**,
  **Unsure** or **Sure**) before submitting. **Don't know yet** tells the teacher to teach the idea rather than grade a
  guess, and it doesn't count as a mistake.
* **Skipping says why.** **Skip** asks for a reason, and the teacher acts on it:
  * **I need more explanation first**: it teaches the idea again from another angle before testing it later;
  * **Too easy for me**: it skips what you know and raises the level;
  * **Not now, keep going**: it carries on without testing you this turn;
  * **A question is unclear or wrong**: it checks the question instead of asking it again.
* **Only unaided success counts.** A right answer after a hint is logged but doesn't raise mastery. A guess counts for less.
* **Mistakes are corrected now, and checked again later.**
  * If a wrong option reveals a known misconception, the feedback names it ("Common mix-up: adds the denominators").
  * The teacher explains why it's tempting. If the mistake shows a gap, it teaches the idea again instead of asking
    another question, and checks it later in the lesson in a new context.
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

* **Setting it up.** The mentor creates the starter files in the lesson's folder and writes the tests to
  `.teacher/tests` (versioned with your project, listed by `.teacher/.gitignore`). There is no hidden test suite and no
  reference solution to prove: the tests are yours to read and run.
* **Lessons come first.** The mentor designs each lesson before teaching it: the real system, the concepts with
  analogies, research in the real docs and source, and two to four working examples it runs first. A full lesson can take
  several minutes on a fast model, and longer on free ones.
* **Your editor.** There is no built-in editor. Open the folder in Helix, VS Code, Zed, Xcode — whatever you use — edit,
  save, then tell the mentor to check (or just "check my work"). The agent runs the tests with `bash` and reads the files.
* **A language from its source.** "Teach me Zig's std", "how does Go's net/http serve a request", "walk me through
  Python's asyncio event loop": the mentor finds the installed source on your Mac, outlines it, reads the real
  implementation and teaches from it with file and line references. It works for standard libraries (Zig, Rust, Go,
  Python) and for packages in your project (npm, Cargo, pip, SwiftPM).
* **Proven tests.** When the mentor registers the test command, the app runs the suite on the starter: it must fail.
  A suite that already passes is refused, one that cannot run goes back to the mentor. The mentor tells you the command
  so you can run it yourself.
* **The review.** Say "check my work" (or ask for a review): the app runs the tests, works out exactly what you changed
  since the last review, and hands both to the mentor with the findings still open from last time. The review comes back
  as a card: findings by file and line, marked **must** (blocks a pass), **should** or **nit**, with the ones you fixed
  struck through, and a verdict. Fix what it points at and ask again; rounds build on each other. A pass with green
  tests records the project's concept as mastered.
* **What the mentor won't do.**
  * It won't write the solution: the starter is scaffolding and TODOs, and it teaches with questions, hints and concepts.
  * It won't hide tests or solutions from you: the tests are in `.teacher/tests` and you can run them yourself.
* **Mastery.** A clean test run after your own work is the checkpoint: the mentor records the concept with `mastery` and
  makes the next project harder.

## Language mentor

In **Language mentor** mode, say which language you want to learn and where you are ("I did two years of Spanish at
school"). The mentor places you with a few questions, sets your profile, and from then on knows the language, your level
and which words are due.

* **The keyboard for the script.** Once the language is known, a **⌨ 日本語** (or العربية, Русский…) button sits next
  to every answer field and in the message box; the panel opens by itself when you click into a field that asks for the
  language (not for questions you answer in your own language). It has the same layouts and modes in both places:
  * **Tap** the keys, or **Mac keys**: your own keyboard types the script in its standard layout (Arabic PC, ЙЦУКЕН,
    2-set Korean, InScript Hindi, Thai Kedmanee, Greek, Hebrew), and the key you pressed lights up on the panel.
  * Japanese: a gojūon table (゛ ゜ and 小 for voiced and small kana, カナ for katakana) or **ローマ字** — type romaji,
    get kana. Kana that spell a word you saved offer its kanji (たべる → 食べる).
  * Chinese pinyin: type the syllable then its tone — a tone key or simply the digit (ni3 → nǐ).
  * Hindi and Bengali: a vowel typed after a consonant becomes its vowel sign (क + आ → का); Arabic harakat attach to the
    letter before them; Korean jamo join into syllables and backspace removes one jamo.
  * **Compact** keeps only the helper keys (marks, tones) when you type with your own keyboard; **✕** hides the panel.
  * **Use Mac input** switches the Mac to its own input source for the language (kanji/hanzi conversion, the full
    layout) when it is installed, and back when you close the keyboard; **Add Mac input…** opens Keyboard settings.
  * Spell-check and autocorrect are off in every answer field: your mistakes are yours to make and the teacher's to find.
* **Reading.** Passages come as a reading card: click any word for its reading, meaning and dictionary entry
  (Wiktionary, or your Mac's dictionaries), **Translate sentence** (Apple's on-device translation when the language pair
  is installed in System Settings › General › Language & Region › Translation Languages, else Apple's on-device model,
  marked as such), and **＋ Save with this sentence** to keep it in your words. Readings over kanji/hanzi show for every
  word, only for words you don't know yet, or not at all. **▶ Read aloud** plays sentence by sentence (the sentence
  being read is highlighted), **🗣 Shadow** pauses after each one for you to repeat it, and **✓ Done reading** counts the
  passage toward what you read this week.
* **In the lesson:** glossed sentences (click a word to see where it lands in the translation; click any foreign
  word anywhere to hear it), listening cards with **Slowly** and hidden text for dictation, role-play dialogues where
  your lines stay hidden until you reveal them, conjugation tables with the stem and the ending in different colours,
  and tone diagrams for Mandarin.
* **Tests are real work:** dictation (checked word by word — a wrong word struck through with the right one beside it;
  Japanese is compared by reading, so kana for kanji counts), **Say it** (the microphone; the card shows what was heard
  against the sentence, word by word, which engine heard you and whether the audio left your Mac, and the pitch of your
  voice against a synthetic voice saying the same sentence — the melody only, not your vowels or consonants),
  translation both ways, rewriting a text in another register, one sentence from given words, a paradigm table to fill,
  and essays marked on a rubric. Accents are graded strictly where the mentor says they matter; Arabic short vowels and
  Hebrew points are optional unless it does.
* **Corrections.** Your writing comes back as a correction card: your text against the corrected one, word by word, each
  error with its type and why, the rubric scores, a more natural version, and a box to write it again — **Check**
  compares your new attempt on the spot, **Send to teacher** sends it.
* **Dictation in the target language.** With a target language set, the microphone button in the message box offers to
  dictate in it as well as in your own language.
* **Your words.** Every vocabulary card has **＋ Save**. Saved words (and the words the mentor saves for you) are
  flashcards in a "<Language> vocabulary" deck, reviewed in Flashcards; the mentor opens lessons with the ones due.
  **Progress › Languages** shows each language's level and how many words are new, learning and known.
* **Your own texts.** Paste a passage, attach a text file or PDF (or a photo of a page), or paste a link to a web page,
  then click **📖 Read** under your message: it opens as a reading card with every word clickable. Anywhere in a lesson,
  select a word (or a short phrase) and click **Look up**.
* **Real audio.** Attach an audio or video file (or paste a direct link to an audio file, then **🎧 Listen with a
  transcript**). The app transcribes it with times — with Whisper on your Mac if you installed it in Settings › Voice,
  otherwise with Apple's recognizer — and gives you a player: each sentence on its own, **Loop**, slower speeds that
  keep the pitch, the text hidden or shown, and **Write what you hear**, checked word by word. Use recordings you're
  allowed to use (podcasts with an open licence, your own).
* **Talk.** **Talk** in the message box starts a spoken conversation in the language: you speak, the mentor answers
  aloud, turn by turn, and keeps its corrections until you press **End conversation** — then it goes through them. Nothing is
  recorded until you press Talk; the bar says which engine is listening and whether audio leaves your Mac.
* **Pronunciation.** After **Say it**, besides the melody chart: for Mandarin, each syllable's tone — the shape your
  pitch had against the tone in the dictionary (syllables the measurement can't judge even on the synthetic voice are
  shown as –); for Japanese words, where your pitch falls (ꜜ) against where the synthetic voice's falls; for a single
  word in other languages, which syllable you stressed. These are measurements of pitch and loudness, not of your
  vowels and consonants, and a single miss is a hint rather than a verdict.
* **Levels and grammar.** The mentor places you per skill (reading, listening, writing, speaking, vocabulary, grammar)
  from real work and notes the evidence; a level marked **?** is provisional until you've done a task in that skill. It
  keeps a grammar syllabus by CEFR level, and a point counts as learned when you use it right in what you write or say.
  **Progress › Languages** shows the levels (hover for the evidence) and the grammar per level (click a level).
* **Kanji and hanzi.** Looking up a word written in kanji (hanzi) shows each character with the other saved words that
  use it. **Progress › Languages** shows the characters of your saved words in the order you met them, green once a word
  with them is known. (Stroke order and components aren't included yet.)
* **Words in and out.** **Progress › Languages › Import words…** takes an Anki package (.apkg — from Anki 2.1.50 on,
  export with "Support older Anki versions" ticked), Anki's "Notes in Plain Text", or a spreadsheet saved as CSV/TSV
  (term and meaning, optionally reading, example, tags…). **Export words** writes a file for Anki (File › Import puts it
  in the "<Language> vocabulary" deck with tags) or a CSV for spreadsheets. Review history stays in the app.
* **After a test** the mentor gives its feedback and stops there: you answer, ask, or say you're ready before the next
  questions.

## Practice tools

* **Quizzes and forms** come in 14 question types, graded instantly where possible:
  * choice: single choice, multiple choice, true/false;
  * typed: short text, long text, numeric (units and ranges), fill in the blanks;
  * structured: ordering, matching, scale;
  * work: code, math (checked symbolically with SymPy, with a live preview), drawing, and **say it** (speech, in the language being learned).
* **Practice cards** are quick self-checks: try, reveal, then mark **Got it** or **Missed**.
* **Worked examples** are revealed one step at a time.
* **Flashcards** (⌥⌘1) use FSRS spaced repetition. Ask the teacher to "make flashcards" from any lesson. While
  reviewing, Space shows the answer and keys 1–4 rate it (Again, Hard, Good, Easy). A card you forget comes back later
  in the same session, and in your next lesson.
* **Course board.** Ask for a plan for a bigger goal ("I want to be ready for my calculus exam in six weeks"). The
  teacher keeps it on a board of cards: one **focus** card with the concrete next action, what comes next, what is
  done (only with evidence: a quiz, an exercise, an explanation), and **parked** questions. A detour doesn't lose
  the thread: the teacher answers, parks it if it's worth returning to, and comes back to the focus. The board is
  the **Plan** tab of the right panel and the one-line strip above the message box; there you can save a question
  for later or ask for a check on a card. Boards appear in Progress too, where **Continue this course** starts a
  new lesson that picks up exactly where the board says. Code mentor has no board: its project (tests, reviews, what's
  left) keeps track there.

## Memory

**Memory** (⌥⌘3) is the teacher's model of you. You can edit or delete anything in it.
  Each card can carry an outline of sections and subsections, so the course reads like a book's table of contents; the
  board marks sections as you finish them and always knows which one you're on, across detours, summaries and lessons.
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
* course boards, recent quizzes and model usage.

## Code sessions

A code session (⇧⌘K) is an autonomous software engineer working in the open folder.

* **Folder access.** The agent can read anywhere. Each folder starts **read-only**, and you grant *Read & write* or
  *Full access* per folder; grants live in **Settings › Tools**. Writes and commands outside what you granted ask
  first. You can allow once or for the lesson, grant the folder write or full access, or deny. Fetching a page from your
  own Mac or local network (localhost, 192.168.…, a `.local` name) asks too, once or for the lesson; sub-agents can't ask,
  so they fetch from there only after you allowed it in the lesson.
  * Commands that only look (`ls`, `cat`, `rg`, `git status`, `git diff`, `git log`…) never ask. They run without a
    shell, and git runs with hooks, fsmonitor and diff drivers off, so a cloned repository's config can't start a program.
  * **Always allow “npm test …” in this folder** on an approval makes a rule like Claude Code's `Bash(npm test:*)`:
    that command, with any arguments, runs without asking again in that folder. A rule only matches one plain command
    (no `;`, `&&`, pipes, redirections or `$(…)`). Rules are listed in **Settings › Tools**, where you can remove them.
    git commands other than the looking ones ask each time.
  * Installing packages (`pip install`, `brew install`…) asks every time; in lessons it stays off.
* **Plan mode** (⇧⌘P, or **Plan mode** under the message box). The agent researches with read-only tools and presents
  a plan: the changes file by file, the order, how it will verify them. Nothing in the folder changes until you click
  **Approve and start**; **Keep planning** lets you say what to change first. (A background sub-agent already running
  when you turn plan mode on carries on; stop it from the Agents panel if needed.)
* **Message it while it works.** Press Return while the agent is busy: the message waits above the box and joins the
  conversation at the agent's next step, so you can steer without stopping it. Take one back with its ×; if you stop
  the agent, waiting messages return to the box.
* **It never overwrites what it hasn't seen.** `write` refuses to replace a file the agent hasn't read, or one that
  changed since it last looked (you saved it in your editor, a formatter ran), as Claude Code does. `edit` still
  applies (it matches exact text) and tells the agent the file had changed.
* **Tools.**
  * Files and search: read, write, edit, ls, glob, grep (ripgrep when installed: both honour `.gitignore`; grep takes
    `-A`/`-B`/`-C`, `type`, `multiline` and `offset`), and `symbols` (a file's outline, or where a name is defined).
    Models used to Claude Code's tools may call them by its argument names (`file_path`, `run_in_background`).
  * Commands: bash (with `background: true` for long builds and test suites, whose output arrives as a message), and
    run_code in 12 languages.
  * `diagnostics`: the project's build check, tests or lint, with the problems parsed into file, line and message.
  * Planning: a todo checklist.
* **MCP servers.** Tools from Model Context Protocol servers, as in Claude Code: a program the app starts and talks to
  over its input and output (`npx -y @modelcontextprotocol/server-memory`, `uvx mcp-server-git`…), or a URL speaking
  streamable HTTP. (The old HTTP+SSE transport isn't supported.)
  * **Your servers**, for every folder: **Settings › MCP › Add server**, or **Add from JSON…** with the snippet from a
    server's README (`{"mcpServers": {…}}`). `${VAR}` and `${VAR:-default}` in a command, argument, variable, URL or
    header read your shell environment, so a token can stay out of the settings.
  * **The project's servers**: a `.mcp.json` at the top of the folder, in Claude Code's format
    (`{"mcpServers": {"name": {"command", "args", "env"}}}` or `{"type": "http", "url", "headers"}`). A server from it
    never starts until you approve it, when the agent first loads it or in Settings › MCP: a cloned repository can't run
    programs by itself. The approval is for exactly what you saw: if the file later changes its command, arguments or
    environment, you're asked again. A project server wins over one of yours with the same name.
  * The agent sees each tool as `mcp__<server>__<tool>`, one line each in its instructions, and loads the ones it needs.
    **Every call asks**, whatever the folder's access: allow once, the server for the lesson, or **Always allow
    “server” in this folder**. In plan mode only the tools a server marks read-only run.
  * Servers start the first time a code session needs them, restart by themselves after a crash (three times a minute
    at most), and end when you quit the app. **Settings › MCP** shows each one's state for the open folder (running,
    pid, tools, restarts, the last error) and what it wrote to its error output, with Start, Stop and Restart.
* **It knows your project.** The agent's instructions carry a profile read from your manifests: the build system, how
  to build, check, test and lint, the languages, the git state. Every file it writes or edits is syntax-checked on the
  spot, and it is told to run the project's check and tests before it reports.
* **Undo.** Under each reply that changed files: **Undo this turn's changes** puts every file back as it was before that
  turn (the app keeps a checkpoint per turn in `.teacher/checkpoints`, no git needed). The agent is told you did.
* **Commands.** Built in: `/init` writes an `AGENTS.md` for the project (or improves the one there), `/review [what]`
  reviews your uncommitted changes (or what you name) without changing files, and `/compact [what to keep]` summarises
  the session so far so the next request starts small.
  * Your own: `review.md` in the project's `.teacher/commands/` or `.claude/commands/`, or in `~/.teacher/commands/` or
    `~/.claude/commands/` for every project, becomes `/review`; a subfolder makes a namespace (`frontend/test.md` is
    `/frontend:test`). Type `/review src/app.py` and the file's text, with `$ARGUMENTS` (and `$1`, `$2`…) filled in,
    goes to the agent with your message. A file named like a built-in replaces it.
* **Hooks.** Shell commands that run at steps of the agent's work, in Claude Code's format, so its hooks work as they
  are. Put your own in **Settings › Hooks**; a project's go in its `.claude/settings.json` (or `settings.local.json`)
  under `hooks`.
  * **PreToolUse** runs before a tool call its `matcher` picks (`Edit|Write`, `Bash`, a regular expression like
    `Web.*`, or `*` for all; this app's names such as `edit` work too). Exit code 2 blocks the call, and what the hook
    printed to stderr tells the agent why (so does `{"decision": "block", "reason": "…"}` on stdout). A hook can't
    approve a call: the usual approvals still apply.
  * **PostToolUse** runs after a call that succeeded: a formatter after an edit, say. What it prints reaches the agent,
    and if it rewrote the file the agent is told to read it again.
  * **UserPromptSubmit** runs when your message starts a turn: what it prints goes to the agent with your message;
    exit 2 holds the message back (its text returns to the box, and you see why).
  * **Stop** runs when the agent would finish: exit 2 sends it back to work with the hook's reason, three times at
    most per turn.
  * Each hook gets the event as JSON on stdin (`tool_name`, `tool_input` with `file_path`, `tool_response`, `prompt`,
    `session_id`, `cwd`), runs in the folder with `$CLAUDE_PROJECT_DIR` set, and is stopped after its `timeout`
    (60 seconds unless set). A hook that fails otherwise is reported to you and the work goes on.
  * **A project's hooks never run by themselves.** At the agent's first step in a lesson in that folder, a card lists
    every command; they run only once you choose **Run this folder's hooks**. The approval is kept for that folder and
    that exact configuration: if the hooks change (a pull, or the agent editing the file), you're asked again.
    **Settings › Hooks** lists approved folders, with **Revoke**.
  * Hooks run for the agent's own tool calls, not its sub-agents'.
* **Project instructions.** `project_memory` keeps build commands, conventions and gotchas in
  `.teacher/code-memory.md`. The agent also follows the instruction files Claude Code and other agents use: your own
  `~/.claude/CLAUDE.md` or `~/.teacher/AGENTS.md`; `CLAUDE.md` or `AGENTS.md` in each folder above the project (a
  package in a monorepo gets the repository's); the project's `CLAUDE.md`, `.claude/CLAUDE.md`, `AGENTS.md`,
  `CLAUDE.local.md` and `.github/copilot-instructions.md`. `@docs/style.md` in one of them pulls that file in. A
  subfolder's own `CLAUDE.md` or `AGENTS.md` reaches the agent the first time it reads a file there.
* **Changes panel.** A git diff of what changed, with checkpoints.
* **Sub-agents.** The agent can delegate to `explore`, `coder`, `reviewer` (read-only) and `tester` agents, or to your
  own types: add them in **Settings › Agents**, or as Markdown files in `.teacher/agents/` or Claude Code's
  `.claude/agents/` (its tool names, like `Read, Grep, Bash`, are understood; `model: sonnet` means the lesson's model).
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
| General | Your name and level, reasoning effort, show thinking, Python policy (run without asking / ask / off), the course board system for the teaching modes (book outlines, cards only, or off; each is explained under the picker), text size, an optional limit on tool steps per reply (none by default: the teacher works until the reply is done; ⌘. stops it), context budget, Insights telemetry |
| Providers | Keys, where each comes from, model lists, custom providers |
| Tools | Folder access grants, default folder, enabled tools, browser and Mac app permissions, always-allowed sites and apps |
| Agents | Sub-agent defaults, limits and custom agent types |
| MCP | Your MCP servers for code sessions (add, edit, import from JSON, switch off); the open folder's `.mcp.json` servers (approve, decline, revoke); each server's state, log and Start / Stop / Restart; "always allow" per server and folder |
| Hooks | Your own hooks for the code agent (Claude Code's JSON, checked as you type, with an example), and the folders whose own hooks you approved |
| Instructions | Every agent's standing instructions — the teacher, each teaching mode, the course board, the app guide (shared by every agent), each branch's tools guide (teacher, code mentor, code agent), the code agent and the built-in sub-agents. Short by default; edit any of them, and **Reset to default** brings it back. Edits apply to lessons started afterwards. |
| Memory | Automatic learning after lessons, the model used for memory, stored count |
| Voice | Read-aloud voice and speed; for each language you're learning, the Mac's best voice and its quality (compact voices are robotic — **Get better Mac voices…** opens Spoken Content to download Enhanced or Premium ones) and how you're heard (Apple's on-device model, downloadable here, or Apple's servers); which engine speaks and listens; optional open-source engines — Supertonic 3 voices (129 MB) and Whisper large-v3-turbo recognition (1 GB), with the sherpa-onnx runtime (20 MB) — downloaded only on request, checked against published checksums, run on your Mac |

## Your data

| What | Where |
|---|---|
| Learner model, flashcards, mastery, plans, usage | `~/Library/Application Support/MyAITeacher/teacher.sqlite` |
| API keys you paste in | `~/Library/Application Support/MyAITeacher/keys.json` (owner-only) |
| A folder's lessons and memory | `<folder>/.teacher/` |
| Quick questions | `~/.teacher/no-dir-conversations/` |
| Default folder | `~/AI Teacher Workspace/` |
| Log | `~/Library/Logs/MyAITeacher.log` |

* **Network traffic.** Messages go only to the provider you choose. Web search and fetching are keyless (searches go to
  DuckDuckGo and Bing, paper searches to OpenAlex).
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
