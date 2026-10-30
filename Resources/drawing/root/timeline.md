---
name: timeline
summary: Events in order: a date, a title and a line of Markdown each.
aliases: history, events
order: 62
---
```timeline
[{"date": "1905", "title": "Special relativity", "text": "Simultaneity depends on the observer."},
 {"date": "1915", "title": "General relativity", "text": "Gravity as curved spacetime."},
 {"date": "2015", "title": "Gravitational waves", "text": "LIGO hears two black holes merge."}]
```

Fields: `date` (or `year`, `time`), `title`, `text`; `{"events": […]}` works too. For periods that overlap, a Mermaid `gantt` or `timeline`.
