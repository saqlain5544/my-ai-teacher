---
name: chart
summary: Data charts: bar (grouped or stacked), line, area, pie, donut, scatter.
aliases: bar, barchart, piechart, linechart, data-chart
order: 30
---
```chart
{"type": "bar", "title": "LRU and LFU cut the tail more than the median",
 "labels": ["no cache", "LRU", "LFU"],
 "series": [{"name": "p50 ms", "data": [42, 18, 21]}, {"name": "p95 ms", "data": [120, 47, 39]}],
 "ylabel": "milliseconds"}
```

- `type`: `bar` | `line` | `area` | `pie` | `donut` | `scatter`.
- `labels`: the categories along x (bar, line, area) or the slices (pie, donut).
- `series`: `[{"name", "data": [numbers], "color"}]`, up to 10 (more are dropped). `data` may also be `[{"x", "y"}]` or `[[label, value]]`.
- `"stacked": true` stacks the bars; `title`, `xlabel`, `ylabel`.
- `pie`/`donut`: the first series only, no negative values; the legend shows each value and its percentage.
- `scatter`: each series' `data` is points `[[x, y], …]` on numeric axes.

```chart
{"type": "scatter", "title": "More practice, higher scores", "xlabel": "hours practised", "ylabel": "score",
 "series": [{"name": "class A", "data": [[1, 52], [2, 61], [3, 70], [5, 83]]},
            {"name": "class B", "data": [[1, 48], [3, 66], [4, 71]]}]}
```

**Limits:** drawn at 640×360 and scaled; about 14 x labels are shown (the rest thinned) and labels past 12 characters are cut, so keep them short. Static: for hover, toggling series, live updates or radar and bubble charts use a ```visual with Chart.js (`draw` chartjs). A function belongs in a ```plot. Compute the numbers first; never invent data.
