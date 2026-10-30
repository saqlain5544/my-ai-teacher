---
name: compare
summary: A side-by-side comparison: options against criteria.
aliases: comparison, versus
order: 63
---
```compare
{"columns": ["", "Array", "Linked list"],
 "rows": [["Index access", "O(1)", "O(n)"], ["Insert at the front", "O(n)", "O(1)"], ["Memory", "contiguous", "a pointer per node"]]}
```

- Each row starts with its label. `columns` has one header per value column, or the corner header first (as here).
- Cells are inline Markdown (`code`, **bold**, $maths$).
- Also accepted: a Markdown table, or two or more `Label: value` lines.
