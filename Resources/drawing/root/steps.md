---
name: steps
summary: Numbered steps; with "reveal", a worked example the learner steps through one step at a time.
aliases: procedure, worked-example, walkthrough-steps
order: 61
---
```steps
{"reveal": true, "steps": [
  {"title": "Write the equation", "text": "$2x + 3 = 11$"},
  {"title": "Take 3 from both sides", "text": "$2x = 8$"},
  {"title": "Halve both sides", "text": "$x = 4$. Check: $2 \\cdot 4 + 3 = 11$ ✓"}
]}
```

- A plain array `[{"title", "text"}]` (or of strings) shows every step at once; `{"reveal": true, "steps": […]}` shows one at a time, with Next step and Show all.
- `text` is Markdown with maths (backslashes doubled in JSON).
