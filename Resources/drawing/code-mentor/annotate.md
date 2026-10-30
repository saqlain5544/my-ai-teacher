---
name: annotate
summary: Code with numbered notes pinned to its lines: a walk-through of their code or a library's.
aliases: annotated, walkthrough, annotations
order: 120
---
```annotate
{"title": "Binary search", "file": "search.py", "language": "python", "start": 1,
 "code": "def find(xs, target):\n    lo, hi = 0, len(xs) - 1\n    while lo <= hi:\n        mid = (lo + hi) // 2\n        if xs[mid] == target:\n            return mid\n        if xs[mid] < target:\n            lo = mid + 1\n        else:\n            hi = mid - 1\n    return -1",
 "notes": [{"lines": "2", "text": "Both ends inclusive: `hi` is the last index."},
           {"lines": "3-4", "text": "`<=`, so a one-element range is still searched."},
           {"lines": "7-10", "text": "Each branch drops `mid`, so the range always shrinks."}]}
```

Fields: `code`, `language`, `notes` (`[{"lines": "3" | "3-5" | "3,7", "text": inline Markdown}]`), and optionally `file`, `title` and `start` (the first line's number, so an excerpt of a real file shows its real line numbers; cite those). Clicking a note highlights its lines.
