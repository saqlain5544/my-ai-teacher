---
name: visual-explanations
description: Choose and build the right diagram, chart, plot or interactive visual for an explanation (mermaid, plot, chart, steps, compare, timeline, visual).
---

# Visual explanations

**Pick the form from the idea, not the other way round:**

| The idea is… | Use |
|---|---|
| a process, flow, protocol, state machine, architecture | ```mermaid (flowchart, sequence, state, class) |
| a function or how a parameter changes a curve | ```plot |
| quantities to compare or a trend in data | ```chart (bar for categories, line for time, scatter for relations) |
| a procedure or worked example | ```steps (`"reveal": true` to show one step at a time) |
| two or more options side by side | ```compare |
| events in order | ```timeline |
| something to play with (a simulation, a geometry, a physical system) | ```visual (self-contained HTML/JS) |

**Make it read at a glance**
- One idea per figure; a title that states the point ("Throughput halves after each loss"), not the topic.
- Label axes with units; keep labels short; no more than ~7 nodes per mermaid layer or ~6 series per chart.
- Mermaid: quote any label with brackets, parentheses, quotes or `<br/>` — `A["f(x) = x²"]`, `A -->|"yes"| B`.
- Real numbers only: compute them (`math`, `run_code`) before you plot; never invent data.

**Interactive visuals (```visual)**
- First line `<!-- title: …; libs: three, d3, chart, matter; height: 360 -->`; fully offline; declare before use;
  element ids that don't clash; colours that read on light and dark backgrounds.
- Give the learner a control that matters (a slider for the parameter you are explaining) and a caption saying what
  to try.
- Test the logic in your head line by line: a visual that throws shows nothing.

After the figure, say in one or two sentences what to notice. Don't describe what the figure already shows.
