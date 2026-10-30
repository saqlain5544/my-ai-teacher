---
name: visual
summary: Interactive HTML/JS in a sandboxed frame: simulations, sliders, animation, 3D (three.js), d3, Chart.js, physics (Matter.js), KaTeX.
aliases: html, live, html-live, interactive, simulation, animation, canvas, widget
order: 50
---
The body of a small HTML page: markup, `<style>`, `<script>`. The first line is a header comment.

```visual
<!-- title: Launch angle and range; height: 280 -->
<label>Angle <input id="ang" type="range" min="5" max="85" value="45"> <b id="angv">45°</b></label>
<canvas id="cv" width="560" height="220" style="max-width: 100%"></canvas>
<script>
const cv = document.getElementById('cv'), g = cv.getContext('2d');
const css = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
function draw() {
  const deg = +document.getElementById('ang').value, a = deg * Math.PI / 180, v = 20, G = 9.81, s = 9.5;
  document.getElementById('angv').textContent = deg + '°';
  g.clearRect(0, 0, cv.width, cv.height);
  g.strokeStyle = css('--accent'); g.lineWidth = 2; g.beginPath();
  for (let t = 0; t <= 2 * v * Math.sin(a) / G; t += 0.02) {
    const x = v * Math.cos(a) * t, y = v * Math.sin(a) * t - G * t * t / 2;
    g.lineTo(10 + x * s, cv.height - 10 - y * s);
  }
  g.stroke();
  g.fillStyle = css('--fg'); g.font = '13px sans-serif';
  g.fillText('range ' + (v * v * Math.sin(2 * a) / G).toFixed(1) + ' m', 10, 18);
}
document.getElementById('ang').addEventListener('input', draw);
draw();
</script>
```

**Header** `<!-- title: …; libs: …; height: … -->`: `title` is shown above the frame; `libs` loads libraries before your script, as globals: `three` (THREE), `d3`, `chart` (Chart), `matter` (Matter), `katex`; `height` is the starting height in px (the frame then fits its content, 80 to 900 px).

**The sandbox**
- Offline: fetch, XHR, external `src`/`href`, CDNs and web fonts are blocked. Libraries only through `libs`; images as `data:` URIs or drawn.
- Classic scripts, run in order after the markup: no `import` or modules (libraries are globals).
- No `localStorage` (it throws), cookies, `alert`/`prompt`, pop-ups or navigation: keep state in variables.
- Theme: the CSS variables `--fg --bg --accent --muted --card --border` follow the learner's light/dark switch; use them in CSS, and read them (`getComputedStyle(document.documentElement)`) each time a canvas redraws. The background is transparent; buttons, inputs and sliders are already styled; the body has 8 px padding.
- Width is the reply's (about 600 to 900 px): `max-width: 100%` on canvases, or size them from `document.body.clientWidth`.
- An uncaught error, in a callback too, shows the learner its message with a **Fix** button, and reaches you with their next message.

**Write it to run as written:** declare before use, unique element ids, no placeholders or "…", no reasoning or prose inside the fence. Plain canvas, SVG and DOM cover most 2D ideas; load a library only when it does real work. Give the learner a control that matters (a slider for the parameter you are explaining) and say what to try.

Libraries: `draw` with `three`, `d3`, `chartjs`, `matter` or `katex` gives each one's notes and an example. To keep a visual for later lessons, save it with the `visual` tool (the same HTML, `persist: true`). A ```html fence with a `<script>` runs this way too, but write ```visual.
