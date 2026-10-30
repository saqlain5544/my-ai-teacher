---
name: trace
summary: A hand-made stepper: the line about to run, every frame's variables, the output so far and a note per step (any language).
aliases: stepper, step-through, steps-through-code
order: 130
---
For Python, the `trace` tool records a real run (and steps into their modules); prefer it. For other languages, run the code first, then write the steps from what really happens:

```trace
{"language": "javascript", "title": "Closures share a var",
 "code": "let fns = [];\nfor (var i = 0; i < 2; i++) {\n  fns.push(() => i);\n}\nconsole.log(fns[0]());",
 "steps": [
  {"line": 1, "vars": {}, "note": "An empty array comes next."},
  {"line": 2, "vars": {"fns": [], "i": 0}, "note": "`var i`: one variable for the whole loop."},
  {"line": 3, "vars": {"fns": [], "i": 0}},
  {"line": 3, "vars": {"fns": ["<fn>"], "i": 1}, "note": "The closure captured the variable `i`, not its value."},
  {"line": 5, "vars": {"fns": ["<fn>", "<fn>"], "i": 2}},
  {"line": 5, "vars": {"fns": ["<fn>", "<fn>"], "i": 2}, "out": "2\n", "note": "Both closures read the same `i`, now 2."}
 ]}
```

Each step: `line` (1-based, the line about to run); the variables as `vars` for one frame, or `stack: [{"fn", "vars"}]` (outermost first) for calls; `out`, all the output so far; `note`, inline Markdown. Values that change between steps are lit up.
