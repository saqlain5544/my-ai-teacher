---
name: mermaid
summary: Diagrams from text: flowcharts, sequences, classes, states, ER, gantt, mind maps, timelines, quadrants, xy charts, sankey, git graphs and more (Mermaid 12).
aliases: mmd, diagram, flowchart, graph-diagram, sequence, sequencediagram, classdiagram, statediagram, erdiagram, gantt, mindmap, quadrantchart, xychart, sankey, gitgraph
order: 10
---
The first line names the diagram type. The app draws it in its own light and dark theme: don't set colours, themes or `%%{init}%%`.

| First line | For |
|---|---|
| `flowchart TD` or `LR` (also `graph`) | processes, decisions, architectures, pipelines |
| `sequenceDiagram` | messages between actors over time (protocols, APIs) |
| `classDiagram` | types, fields, inheritance, composition |
| `stateDiagram-v2` | state machines, lifecycles |
| `erDiagram` | tables and their relations |
| `gantt` | schedules and plans |
| `mindmap` | a topic's branches |
| `timeline` | periods and the events in them |
| `pie` | shares of a whole (few slices) |
| `quadrantChart` | two-axis comparisons (impact against effort) |
| `xychart` | quick bars and lines over categories |
| `sankey` | flows between stages (`source,target,value` rows) |
| `gitGraph` | commits, branches, merges |
| `journey` | steps scored by experience |
| `block`, `packet` | block layouts; the bit fields of a header |
| `architecture-beta` | services and their links |
| `radar-beta`, `treemap`, `kanban`, `requirementDiagram`, `C4Context`, `venn-beta`, `ishikawa` | as named |

Not available: zenuml, and `architecture` without `-beta`.

**Labels: the rule that breaks most diagrams.** Quote any label with brackets, parentheses, quotes, colons, `<br/>`, `#` or `;`: `A["f(x) = x² (min)"]`, `A -->|"loss: halve"| B`, `subgraph g ["Group (1)"]`. Node ids are plain words (`step1`, not `step 1`); `end` is reserved (write `End`).

```mermaid
flowchart LR
  input["Input x"] --> test{"x > 0?"}
  test -->|"yes"| pos["Return x"]
  test -->|"no"| neg["Return −x"]
  subgraph result ["Result: the absolute value"]
    pos
    neg
  end
```
Shapes: `[box]` `(rounded)` `([stadium])` `[[subroutine]]` `[(database)]` `((circle))` `{decision}` `{{hexagon}}` `[/parallelogram/]`. Edges: `-->`, `---`, `-.->` dotted, `==>` thick, `--o`, `--x`, `<-->`; `A --> B & C` fans out.

```mermaid
sequenceDiagram
  autonumber
  participant C as Client
  participant S as Server
  C->>S: SYN
  S-->>C: SYN-ACK
  C->>S: ACK
  Note over C,S: Connection open
  loop every 30 s
    C->>S: keep-alive
  end
```
Arrows: `->>` call, `-->>` reply, `-x` lost, `-)` async. Also `activate`/`deactivate`, `alt … else … end`, `opt … end`, `par … and … end`.

```mermaid
classDiagram
  class Shape {
    <<abstract>>
    +area() float
  }
  Shape <|-- Circle
  Circle : +float r
```

```mermaid
stateDiagram-v2
  [*] --> Idle
  Idle --> Running : start
  Running --> Idle : stop
  Running --> [*] : crash
```

```mermaid
erDiagram
  STUDENT ||--o{ ENROLLMENT : has
  COURSE ||--o{ ENROLLMENT : includes
  STUDENT {
    int id PK
    string name
  }
```

```mermaid
xychart
  title "Requests per second"
  x-axis [1, 2, 4, 8]
  y-axis "req/s" 0 --> 8000
  bar [900, 1700, 3100, 3800]
  line [900, 1800, 3600, 7200]
```

```mermaid
quadrantChart
  title Study tasks
  x-axis Low effort --> High effort
  y-axis Low impact --> High impact
  Flashcards: [0.2, 0.7]
  Past papers: [0.7, 0.9]
```

```mermaid
gantt
  dateFormat YYYY-MM-DD
  section Revision
  Algebra :a1, 2026-11-02, 5d
  Geometry :after a1, 4d
```

```mermaid
mindmap
  root((Cell))
    Membrane
    Nucleus
      DNA
    Mitochondria
```

**Limits:** about 7 nodes per rank and 25 in all stay readable; split a bigger idea into two diagrams. Break long labels with `<br/>` inside quotes. A diagram that doesn't parse shows the learner the error and its source, and the error reaches you with their next message.
