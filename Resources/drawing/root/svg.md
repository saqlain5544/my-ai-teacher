---
name: svg
summary: Hand-drawn static figures in SVG: geometry, labelled diagrams, number lines, circuits, anything that must be exact.
aliases: vector, figure, geometry
needs: none
order: 40
---
Write the `<svg>` element itself, nothing around it. It is sanitised, then drawn inline at the reply's width.

```svg
<svg viewBox="0 0 320 240" xmlns="http://www.w3.org/2000/svg" font-family="-apple-system, sans-serif" font-size="14">
  <polygon points="40,210 280,210 40,30" fill="none" stroke="currentColor" stroke-width="2"/>
  <polyline points="40,196 54,196 54,210" fill="none" stroke="currentColor"/>
  <text x="160" y="230" text-anchor="middle">a = 4</text>
  <text x="24" y="124" text-anchor="middle">b = 3</text>
  <text x="168" y="112" style="fill: var(--accent)">c = 5</text>
  <line x1="200" y1="40" x2="250" y2="40" stroke="currentColor"/>
  <polygon points="250,35 260,40 250,45" fill="currentColor"/>
</svg>
```

- **Always a `viewBox`**; width and height are optional (it scales to fit).
- **Colours that read in light and dark:** `currentColor` (the text colour, and the default fill); theme colours in a `style`: `style="fill: var(--accent)"`, also `var(--fg)`, `var(--muted)`, `var(--border)`, `var(--card)`, `var(--bg)`. Mid-tone fixed colours read on both: #2f6fec, #e5484d, #30a46c, #f76b15, #8e4ec6.
- **The sanitiser removes** `id` and `class` attributes, `<style>`, `<script>`, event handlers and `<foreignObject>`. So nothing that needs an id works: no gradients, markers, clip paths, patterns or `<use>`. Draw arrowheads as small polygons (above); shade with `fill-opacity`.
- **Kept:** shapes, paths, `<g transform>`, `<text>` and `<tspan>`, `style="…"`, `<title>` tooltips, `<image href="data:…">`, `<a href>` links (they open in the app).
- Static only. For motion, sliders or anything the learner moves, use a ```visual (where ids and `<style>` work).
