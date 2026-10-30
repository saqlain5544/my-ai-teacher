---
name: katex
title: KaTeX in a ```visual (libs: katex)
summary: KaTeX 0.19 for typeset maths inside a visual: labels and formulas that change with a slider (global katex).
aliases: katex.js, tex-in-visual
needs: visual
order: 55
---
Maths in your prose needs no visual: `$…$`, `$$…$$` and ```math already render. Inside a visual, typeset with MathML output: the frame has no KaTeX stylesheet, so the default HTML output comes out garbled.

```visual
<!-- title: How a changes the parabola; libs: katex; height: 140 -->
<label>a <input id="a" type="range" min="-3" max="3" step="0.5" value="1"></label>
<div id="f" style="font-size: 1.4em; margin-top: 8px"></div>
<script>
function show() {
  const a = +document.getElementById('a').value;
  katex.render('f(x) = ' + a + 'x^2 - 2x + 1', document.getElementById('f'), { output: 'mathml', throwOnError: false });
}
document.getElementById('a').addEventListener('input', show);
show();
</script>
```

- `katex.render(tex, element, { output: 'mathml' })`, or `katex.renderToString(tex, { output: 'mathml', displayMode: true })` for HTML you place yourself.
- Double the backslashes in JavaScript strings: `'\\frac{a}{b}'`.
- Frame, sandbox and errors: `draw` visual.
