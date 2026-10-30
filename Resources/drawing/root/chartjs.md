---
name: chartjs
title: Chart.js in a ```visual (libs: chart)
summary: Chart.js 4 for interactive charts: tooltips, legends that toggle series, live updates, radar, bubble and mixed charts (global Chart).
aliases: chart.js, chart-js, chartjs4, interactive-chart
needs: visual
order: 53
---
Chart.js 4.5 as the global `Chart`, with every chart type registered. A static chart is lighter as a ```chart; use this when the learner hovers, toggles or changes the data.

```visual
<!-- title: Compound against simple interest; libs: chart; height: 340 -->
<label>Rate <input id="r" type="range" min="1" max="12" value="5"> <b id="rv">5%</b></label>
<canvas id="c"></canvas>
<script>
const css = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
Chart.defaults.color = css('--muted');
Chart.defaults.borderColor = css('--border');
const years = Array.from({ length: 21 }, (_, i) => i);
const compound = r => years.map(y => +(1000 * Math.pow(1 + r / 100, y)).toFixed(2));
const simple = r => years.map(y => 1000 + 1000 * r / 100 * y);
const chart = new Chart(document.getElementById('c'), {
  type: 'line',
  data: { labels: years, datasets: [
    { label: 'compound', data: compound(5), borderColor: css('--accent'), tension: 0.25 },
    { label: 'simple', data: simple(5), borderColor: '#f76b15', borderDash: [6, 4] },
  ] },
  options: {
    animation: false, interaction: { mode: 'index', intersect: false },
    scales: { x: { title: { display: true, text: 'years' } }, y: { title: { display: true, text: 'balance (£)' } } },
  },
});
document.getElementById('r').addEventListener('input', e => {
  const r = +e.target.value;
  document.getElementById('rv').textContent = r + '%';
  chart.data.datasets[0].data = compound(r);
  chart.data.datasets[1].data = simple(r);
  chart.update();
});
</script>
```

- Set `Chart.defaults.color` and `borderColor` from the theme before the first chart (the defaults are made for white pages).
- Charts are responsive: the canvas takes the frame's width; `options.aspectRatio` (default 2) sets its height.
- Update in place (change `chart.data`, then `chart.update()`) rather than building a new chart on every input.
- Frame, sandbox and errors: `draw` visual.
