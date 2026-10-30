---
name: plot
summary: Graphs of functions y = f(x), with marked points and measured data beside them; no code.
aliases: graph, function-plot, function, functions
order: 20
---
JSON, or one expression per line. Each function is sampled 800 times across `x`; asymptotes are cut, and `y` comes from the data when you leave it out.

```plot
{"title": "x³ against eˣ", "x": [0, 5], "y": [0, 120],
 "functions": ["x^3", {"expr": "exp(x)", "label": "eˣ", "dashed": true}],
 "points": [[1.857, 6.41, "first crossing"], [4.536, 93.35, "second crossing"]],
 "xlabel": "x", "ylabel": "y"}
```

- `functions`: expressions in `x`, or `{"expr", "label", "color", "dashed"}`. Operators `+ - * / ^` (or `**`), implied multiplication (`2x`, `3sin(x)`), `|x|`, `x!` (through gamma, so it is smooth). Functions: `sin cos tan asin acos atan` (also `arcsin`…), `sinh cosh tanh`, `sec csc cot`, `exp ln log` (base 10) `log2 sqrt cbrt abs floor ceil round sign min max pow atan2 hypot gamma fact heaviside`. Constants: `pi` (π), `e`, `tau`, `phi`.
- `x`, `y`: ranges `[min, max]` (`x` defaults to [-10, 10]; `xmin`/`xmax` also work).
- `points`: `[[x, y, "label"]]` or `{"x", "y", "label"}`, marked and labelled.
- `series`: `[{"name", "type": "line" | "scatter", "points": [[x, y], …]}]`, measured data beside the model.
- `title`, `xlabel`, `ylabel`; `"legend": false` hides the legend.

The line form, for a quick look:

```plot
title: Doubling the frequency
y = sin(x)
y = sin(2x)
x: [-6.3, 6.3]
```

**Limits:** one variable, `x`. No parametric, polar or implicit curves, surfaces, sliders or animation: use a ```visual (canvas or d3) for those. Colours cycle through 8; give `color` to tell more apart.
