"""The perf report: one self-contained HTML file (inline CSS/JS, no network) built from a run's data.json."""
import json

PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Perf report</title>
<style>
:root { color-scheme: light; --bg: #fcfcfb; --panel: #ffffff; --ink: #0b0b0b; --ink2: #52514e; --ink3: #8a8983; --line: #e4e3df; --grid: #efeeea;
  --s1: #2a78d6; --s2: #eb6834; --s3: #1baf7a; --s4: #eda100; --s5: #e87ba4; --s6: #008300; --s7: #6250d6; --s8: #e34948;
  --bad: #c62828; --good: #1b7f3a; --q0: #f3f6fb; --q1: #cde2fb; --q2: #86b6ef; --q3: #3987e5; --q4: #1c5cab; --q5: #0d366b; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { color-scheme: dark; --bg: #141413; --panel: #1a1a19; --ink: #f0efec; --ink2: #c3c2b7; --ink3: #8f8e86;
  --line: #2e2e2b; --grid: #262624; --s1: #3987e5; --s2: #d95926; --s3: #199e70; --s4: #c98500; --s5: #d55181; --s6: #008300; --s7: #9085e9; --s8: #e66767;
  --bad: #ef6b6b; --good: #4cc27a; --q0: #1e2228; --q1: #184f95; --q2: #256abf; --q3: #3987e5; --q4: #86b6ef; --q5: #cde2fb; } }
:root[data-theme="dark"] { color-scheme: dark; --bg: #141413; --panel: #1a1a19; --ink: #f0efec; --ink2: #c3c2b7; --ink3: #8f8e86;
  --line: #2e2e2b; --grid: #262624; --s1: #3987e5; --s2: #d95926; --s3: #199e70; --s4: #c98500; --s5: #d55181; --s6: #008300; --s7: #9085e9; --s8: #e66767;
  --bad: #ef6b6b; --good: #4cc27a; --q0: #1e2228; --q1: #184f95; --q2: #256abf; --q3: #3987e5; --q4: #86b6ef; --q5: #cde2fb; }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--ink); font: 14px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif; }
main { max-width: 1280px; margin: 0 auto; padding: 24px 16px 64px; }
h1 { font-size: 22px; margin: 0 0 4px; } h2 { font-size: 16px; margin: 0 0 10px; } .sub { color: var(--ink2); font-size: 13px; }
section { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 16px; margin-top: 16px; overflow: hidden; }
.bar { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; margin: 16px 0 0; position: sticky; top: 0; background: var(--bg); padding: 8px 0; z-index: 5; }
.bar button, .seg button { border: 1px solid var(--line); background: var(--panel); color: var(--ink); border-radius: 999px; padding: 4px 12px; font: inherit; font-size: 13px; cursor: pointer; }
.bar button.on, .seg button.on { background: var(--ink); color: var(--bg); border-color: var(--ink); }
.seg { display: inline-flex; gap: 4px; margin-left: 8px; } .seg button { padding: 2px 10px; font-size: 12px; }
.tiles { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 10px; }
.tile { border: 1px solid var(--line); border-radius: 8px; padding: 10px 12px; }
.tile .k { font-size: 12px; color: var(--ink2); } .tile .v { font-size: 22px; font-weight: 600; font-variant-numeric: tabular-nums; } .tile .d { font-size: 12px; color: var(--ink3); }
table { border-collapse: collapse; width: 100%; font-size: 12.5px; font-variant-numeric: tabular-nums; }
th, td { text-align: left; padding: 5px 8px; border-bottom: 1px solid var(--grid); vertical-align: top; }
th { color: var(--ink2); font-weight: 600; cursor: pointer; user-select: none; white-space: nowrap; } td.n, th.n { text-align: right; }
.scroll { overflow-x: auto; max-height: 520px; overflow-y: auto; }
.stack { font: 11.5px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--ink2); white-space: pre-wrap; word-break: break-all; }
.chart { position: relative; } .chart svg, .chart canvas { display: block; width: 100%; }
.tip { position: fixed; pointer-events: none; background: var(--panel); color: var(--ink); border: 1px solid var(--line); border-radius: 6px; padding: 6px 8px;
  font-size: 12px; box-shadow: 0 4px 16px rgba(0,0,0,.15); max-width: 520px; z-index: 20; display: none; }
.legend { display: flex; flex-wrap: wrap; gap: 12px; font-size: 12px; color: var(--ink2); margin: 6px 0; } .legend i { display: inline-block; width: 10px; height: 10px; border-radius: 2px; margin-right: 5px; vertical-align: -1px; }
.bad { color: var(--bad); font-weight: 600; } .good { color: var(--good); font-weight: 600; } .muted { color: var(--ink3); }
input[type=search] { border: 1px solid var(--line); border-radius: 6px; padding: 4px 8px; background: var(--panel); color: var(--ink); font: inherit; font-size: 13px; }
.row { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; margin-bottom: 8px; }
details summary { cursor: pointer; color: var(--ink2); }
</style></head><body><main>
<h1 id="title">Perf report</h1><div class="sub" id="meta"></div>
<div class="bar" id="filters"></div>
<section id="sec-summary"><h2>Workloads</h2><div class="tiles" id="tiles"></div><div class="scroll" style="margin-top:12px"><table id="metrics"></table></div></section>
<section id="sec-compare" hidden><h2>Against the baseline</h2><div class="sub" id="cmp-sum"></div><div class="scroll"><table id="cmp"></table></div></section>
<section><h2>Memory (phys_footprint) per process</h2><div class="legend" id="mem-legend"></div><div class="chart" id="mem"></div>
  <h2 style="margin-top:14px">CPU per process (% of one core)</h2><div class="chart" id="cpu"></div></section>
<section><h2>CPU flame graph <span class="seg" id="fg-proc"></span></h2>
  <div class="row"><input type="search" id="fg-q" placeholder="Highlight frames…"><button class="btnreset" id="fg-reset" style="display:none">Reset zoom</button><span class="sub" id="fg-info"></span></div>
  <div class="legend" id="fg-legend"></div><div class="chart"><canvas id="fg"></canvas></div><div class="sub">Root at the top; width is sampled CPU time. Click a frame to zoom, click the root to zoom out.</div></section>
<section><h2>CPU heatmap <span class="seg" id="hm-mode"></span></h2><div class="chart"><canvas id="hm"></canvas></div><div class="sub" id="hm-info"></div></section>
<section><h2>Signposts</h2><div class="scroll"><table id="sp"></table></div><details style="margin-top:10px"><summary>Slowest intervals</summary><div class="scroll"><table id="sp-slow"></table></div></details></section>
<section><h2>Main-thread hangs</h2><div class="sub" id="hang-sum"></div><div class="scroll"><table id="hangs"></table></div></section>
<section><h2>Allocations (live heap by call stack)</h2><div id="alloc"></div></section>
</main><div class="tip" id="tip"></div>
<script type="application/json" id="data">/*DATA*/</script>
<script>
'use strict';
const D = JSON.parse(document.getElementById('data').textContent);
const $ = s => document.querySelector(s), esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const css = v => getComputedStyle(document.documentElement).getPropertyValue(v).trim();
const fmt = (v, d = 1) => v == null ? '—' : (typeof v === 'number' ? (Math.abs(v) >= 100 ? Math.round(v).toLocaleString() : (+v.toFixed(d)).toLocaleString()) : esc(v));
const pct = (xs, p) => { const s = xs.slice().sort((a, b) => a - b); return s.length ? s[Math.min(s.length - 1, Math.floor(p * s.length))] : 0; };
const tip = $('#tip');
function showTip(e, html) { tip.innerHTML = html; tip.style.display = 'block'; const w = tip.offsetWidth, h = tip.offsetHeight;
  tip.style.left = Math.min(innerWidth - w - 8, e.clientX + 14) + 'px'; tip.style.top = Math.min(innerHeight - h - 8, e.clientY + 14) + 'px'; }
const hideTip = () => { tip.style.display = 'none'; };
const W = D.workloads || [];
let sel = 'all';
const inSel = t => sel === 'all' || W.some(w => w.name === sel && t >= w.t0 && t <= w.t1);
const KINDS = ['app', 'WebContent', 'GPU', 'Networking', 'render', 'render:WebContent', 'render:GPU', 'render:Networking'];
const kindColor = k => css('--s' + (KINDS.indexOf(k) + 1 || 8));

// Header and filters
$('#title').textContent = 'Perf report · ' + D.meta.label;
$('#meta').innerHTML = [D.meta.date, D.meta.machine, 'model ' + esc(D.meta.provider) + (D.meta.provider === 'mock' ? '' : ' / ' + esc(D.meta.model)),
  'CPU: ' + esc(D.meta.cpu) + (D.meta.cpu_note ? ' (' + esc(D.meta.cpu_note) + ')' : ''), D.meta.allocations ? 'allocations recorded' : 'no allocation stacks (run with --allocations)']
  .filter(Boolean).map(esc).join(' · ');
const filters = $('#filters');
filters.innerHTML = '<span class="sub" style="margin-right:4px">Workload</span>' + ['all'].concat(W.map(w => w.name)).map(n => '<button data-w="' + esc(n) + '">' + (n === 'all' ? 'Whole run' : esc(n)) + '</button>').join('');
filters.addEventListener('click', e => { const b = e.target.closest('button'); if (!b) return; sel = b.dataset.w; renderAll(); });

// Summary tiles + metrics
const procPts = kind => (D.processes || []).filter(p => p.kind === kind).flatMap(p => p.points);
function peak(kind, w) { const pts = procPts(kind).filter(p => !w || (p[0] >= w.t0 && p[0] <= w.t1)); return pts.length ? Math.max(...pts.map(p => p[1])) : null; }
function tiles() {
  const ws = sel === 'all' ? W : W.filter(w => w.name === sel);
  $('#tiles').innerHTML = ws.map(w => {
    const app = w.name === 'render' ? peak('render', w) : peak('app', w), web = w.name === 'render' ? peak('render:WebContent', w) : peak('WebContent', w);
    const hangs = (D.hangs || []).filter(h => h.t >= w.t0 && h.t <= w.t1 && h.ms >= 250).length;
    return '<div class="tile"><div class="k">' + esc(w.name) + (w.error ? ' <span class="bad">failed</span>' : '') + '</div><div class="v">' + fmt(app) + ' MB</div>' +
      '<div class="d">app peak · WebContent ' + fmt(web) + ' MB · ' + fmt(w.t1 - w.t0) + ' s · ' + hangs + ' hang' + (hangs === 1 ? '' : 's') + ' ≥250 ms</div></div>';
  }).join('');
  const rows = ws.flatMap(w => Object.entries(w.metrics).map(([k, v]) => [w.name, k, v]));
  $('#metrics').innerHTML = '<tr><th>workload</th><th>metric</th><th class="n">value</th></tr>' + rows.map(r => '<tr><td>' + esc(r[0]) + '</td><td>' + esc(r[1]) + '</td><td class="n">' + fmt(r[2], 2) + '</td></tr>').join('') +
    ws.filter(w => w.error).map(w => '<tr><td>' + esc(w.name) + '</td><td class="bad">error</td><td>' + esc(w.error) + '</td></tr>').join('');
}
function compare() {
  if (!D.compare) return;
  $('#sec-compare').hidden = false;
  const c = D.compare;
  $('#cmp-sum').innerHTML = '<span class="' + (c.regressions ? 'bad' : 'good') + '">' + c.regressions + ' regression' + (c.regressions === 1 ? '' : 's') + '</span> · ' + c.improved + ' improved · lower is better for every metric';
  const rows = c.rows.filter(r => r.status !== 'same' || sel === 'all').filter(r => sel === 'all' || r.metric.startsWith(sel + '.'));
  const order = { regression: 0, improved: 1, missing: 2, new: 3, same: 4 };
  rows.sort((a, b) => order[a.status] - order[b.status] || a.metric.localeCompare(b.metric));
  $('#cmp').innerHTML = '<tr><th>metric</th><th class="n">baseline</th><th class="n">this run</th><th class="n">change</th><th>status</th></tr>' + rows.map(r =>
    '<tr><td>' + esc(r.metric) + '</td><td class="n">' + fmt(r.base, 2) + '</td><td class="n">' + fmt(r.new, 2) + '</td><td class="n">' + (r.pct == null ? fmt(r.delta, 2) : (r.pct > 0 ? '+' : '') + r.pct + '%') +
    '</td><td class="' + (r.status === 'regression' ? 'bad' : r.status === 'improved' ? 'good' : 'muted') + '">' + (r.status === 'regression' ? '▲ ' : r.status === 'improved' ? '▼ ' : '') + r.status + '</td></tr>').join('');
}

// Line charts (memory, CPU): one axis each, workload bands, crosshair tooltip
function lineChart(el, valueIdx, unit, height) {
  const procs = (D.processes || []).filter(p => p.points.length);
  const kinds = KINDS.filter(k => procs.some(p => p.kind === k));
  const t0 = sel === 'all' ? 0 : (W.find(w => w.name === sel) || { t0: 0 }).t0, t1 = sel === 'all' ? Math.max(1, ...procs.map(p => p.points[p.points.length - 1][0])) : W.find(w => w.name === sel).t1;
  // One line per process (a kind can have several: the lesson's page and a sub-agent's, or a restarted one), coloured by kind.
  const series = procs.filter(p => kinds.includes(p.kind)).map(p => ({ k: p.kind, pid: p.pid, pts: p.points.filter(q => q[0] >= t0 && q[0] <= t1) })).filter(s => s.pts.length);
  const w = el.clientWidth || 900, h = height, m = { l: 52, r: 12, t: 10, b: 24 };
  const ymax = Math.max(1, ...series.flatMap(s => s.pts.map(p => p[valueIdx]))) * 1.08;
  const x = t => m.l + (t - t0) / Math.max(1e-6, t1 - t0) * (w - m.l - m.r), y = v => h - m.b - v / ymax * (h - m.t - m.b);
  const ticks = n => { const step = Math.pow(10, Math.floor(Math.log10(n / 4))); const s = [1, 2, 5, 10].map(f => f * step).find(s => n / s <= 6); return s; };
  const ys = ticks(ymax), xs = ticks(t1 - t0);
  let svg = '<svg width="' + w + '" height="' + h + '" viewBox="0 0 ' + w + ' ' + h + '">';
  for (const wl of W) { if (wl.t1 < t0 || wl.t0 > t1) continue; const a = x(Math.max(t0, wl.t0)), b = x(Math.min(t1, wl.t1));
    svg += '<rect x="' + a + '" y="' + m.t + '" width="' + Math.max(1, b - a) + '" height="' + (h - m.t - m.b) + '" fill="var(--grid)" opacity="0.6"/><text x="' + (a + 4) + '" y="' + (m.t + 12) + '" font-size="11" fill="var(--ink3)">' + esc(wl.name) + '</text>'; }
  for (let v = 0; v <= ymax; v += ys) svg += '<line x1="' + m.l + '" x2="' + (w - m.r) + '" y1="' + y(v) + '" y2="' + y(v) + '" stroke="var(--grid)"/><text x="' + (m.l - 6) + '" y="' + (y(v) + 4) + '" font-size="11" text-anchor="end" fill="var(--ink3)">' + Math.round(v) + '</text>';
  for (let t = Math.ceil(t0 / xs) * xs; t <= t1; t += xs) svg += '<text x="' + x(t) + '" y="' + (h - 6) + '" font-size="11" text-anchor="middle" fill="var(--ink3)">' + Math.round(t) + ' s</text>';
  svg += '<text x="4" y="' + (m.t + 10) + '" font-size="11" fill="var(--ink3)">' + unit + '</text>';
  for (const s of series) {
    let d = '', prev = null;
    for (const p of s.pts) { d += (prev == null || p[0] - prev > 3 ? 'M' : 'L') + x(p[0]).toFixed(1) + ',' + y(p[valueIdx]).toFixed(1); prev = p[0]; }
    svg += '<path d="' + d + '" fill="none" stroke="' + kindColor(s.k) + '" stroke-width="2" stroke-linejoin="round"/>';
  }
  svg += '<line id="xh" y1="' + m.t + '" y2="' + (h - m.b) + '" stroke="var(--ink3)" stroke-dasharray="3 3" visibility="hidden"/></svg>';
  el.innerHTML = svg;
  const s = el.querySelector('svg'), xh = s.querySelector('#xh');
  s.addEventListener('mousemove', e => {
    const r = s.getBoundingClientRect(), px = (e.clientX - r.left) * (w / r.width); if (px < m.l) { hideTip(); xh.setAttribute('visibility', 'hidden'); return; }
    const t = t0 + (px - m.l) / (w - m.l - m.r) * (t1 - t0);
    xh.setAttribute('x1', px); xh.setAttribute('x2', px); xh.setAttribute('visibility', 'visible');
    const wl = W.find(z => t >= z.t0 && t <= z.t1);
    showTip(e, '<b>' + t.toFixed(1) + ' s</b>' + (wl ? ' · ' + esc(wl.name) : '') + '<br>' + series.map(sr => { let best = sr.pts[0]; for (const p of sr.pts) if (Math.abs(p[0] - t) < Math.abs(best[0] - t)) best = p;
      return Math.abs(best[0] - t) < 2 ? '<i style="display:inline-block;width:8px;height:8px;border-radius:2px;background:' + kindColor(sr.k) + '"></i> ' + esc(sr.k) + ' <span class="muted">' + sr.pid + '</span>: <b>' + fmt(best[valueIdx]) + '</b> ' + unit : ''; }).filter(Boolean).join('<br>'));
  });
  s.addEventListener('mouseleave', () => { hideTip(); xh.setAttribute('visibility', 'hidden'); });
  return [...new Set(series.map(s => s.k))];
}
function charts() {
  const ks = lineChart($('#mem'), 1, 'MB', 280); lineChart($('#cpu'), 2, '%', 170);
  $('#mem-legend').innerHTML = ks.map(k => '<span><i style="background:' + kindColor(k) + '"></i>' + esc(k) + ' · peak ' + fmt(Math.max(...procPts(k).filter(p => inSel(p[0])).map(p => p[1]), 0)) + ' MB</span>').join('');
}

// Flame graph (icicle, root on top)
let fgProc = 'app', fgZoom = null;
const ST = D.stacks || { stacks: [], samples: [] };
// Colour by the binary a frame lives in (from the profiler or atos).
const BIN = ST.bins || {};
const CATS = [['app (MyAITeacher)', '--s1', b => b === 'MyAITeacher'], ['WebKit / WebCore / JavaScriptCore (incl. JIT)', '--s2', b => /^(WebKit|WebCore|JavaScriptCore|WebGPU|ANGLE|libANGLE|WebKitLegacy|libwebrtc)/.test(b)],
  ['Swift runtime / SwiftUI / AppKit / Foundation', '--s3', b => /^(SwiftUI|SwiftUICore|AttributeGraph|AppKit|Foundation|FoundationEssentials|CoreFoundation|libswift|Combine|QuartzCore|CoreText|CoreGraphics|libobjc)/.test(b)],
  ['system and other', '--s7', () => true]];
const cat = n => n.startsWith('??? (JIT') ? 1 : CATS.findIndex(c => c[2](BIN[n] || ''));
const isRender = k => k.startsWith('render');
function fgTree() {
  const root = { name: 'all', v: 0, kids: new Map() };
  for (const [t, kind, th, sid, ms] of ST.samples) {
    if (!inSel(t) || (fgProc === 'render') !== isRender(kind)) continue;
    let n = root; n.v += ms;
    for (const f of [kind, th].concat(ST.stacks[sid])) { let c = n.kids.get(f); if (!c) { c = { name: f, v: 0, kids: new Map(), parent: n }; n.kids.set(f, c); } c.v += ms; n = c; }
  }
  return root;
}
let fgRoot = null, fgRects = [];
function flame() {
  $('#fg-proc').innerHTML = ['app', 'render'].map(p => '<button data-p="' + p + '" class="' + (p === fgProc ? 'on' : '') + '">' + (p === 'app' ? 'App and its WebKit processes' : 'Renderer stress') + '</button>').join('');
  $('#fg-legend').innerHTML = CATS.map(c => '<span><i style="background:' + css(c[1]) + '"></i>' + c[0] + '</span>').join('');
  fgRoot = fgTree(); fgZoom = null; drawFlame();
}
function drawFlame() {
  const cv = $('#fg'), q = $('#fg-q').value.toLowerCase(), base = fgZoom || fgRoot, dpr = devicePixelRatio || 1, RH = 17;
  const MAXD = 64;   // deeper recursion is reached by zooming
  let depth = 0; (function d(n, k) { depth = Math.max(depth, k); if (k < MAXD) for (const c of n.kids.values()) if (c.v / base.v > 0.002) d(c, k + 1); })(base, 0);
  const w = cv.parentElement.clientWidth || 900, h = Math.max(60, (depth + 1) * RH + 4);
  cv.width = w * dpr; cv.height = h * dpr; cv.style.height = h + 'px';
  const g = cv.getContext('2d'); g.scale(dpr, dpr); g.font = '11px -apple-system, sans-serif'; g.textBaseline = 'middle';
  fgRects = [];
  const surface = css('--panel'), ink = css('--ink');
  function draw(n, x0, wd, k) {
    if (wd < 0.6 || k > MAXD) return;
    const y = k * RH, c = cat(n.name), hit = q && n.name.toLowerCase().includes(q);
    g.fillStyle = css(CATS[c][1]); g.globalAlpha = q ? (hit ? 0.95 : 0.18) : 0.32 + 0.5 * ((hash(n.name) % 100) / 100);
    g.fillRect(x0, y, Math.max(0.5, wd - 1), RH - 1); g.globalAlpha = 1;
    if (wd > 36) { g.fillStyle = ink; g.save(); g.beginPath(); g.rect(x0, y, wd - 2, RH); g.clip(); g.fillText(n.name, x0 + 4, y + RH / 2); g.restore(); }
    fgRects.push([x0, y, wd, RH, n]);
    let cx = x0;
    for (const ch of [...n.kids.values()].sort((a, b) => b.v - a.v)) { const cw = ch.v / n.v * wd; draw(ch, cx, cw, k + 1); cx += cw; }
  }
  g.fillStyle = surface; g.fillRect(0, 0, w, h);
  draw(base, 0, w, 0);
  const total = fgRoot.v;
  $('#fg-info').textContent = total ? fmt(total / 1000, 2) + ' s of samples' + (fgZoom ? ' · zoomed: ' + fgZoom.name.slice(0, 80) + ' (' + fmt(fgZoom.v / total * 100) + '%)' : '') : 'No CPU samples in this selection.';
  $('#fg-reset').style.display = fgZoom ? '' : 'none';
}
const hash = s => { let h = 2166136261; for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619); return h >>> 0; };
const fgAt = e => { const r = $('#fg').getBoundingClientRect(), x = e.clientX - r.left, y = e.clientY - r.top; return fgRects.find(q => x >= q[0] && x < q[0] + q[2] && y >= q[1] && y < q[1] + q[3]); };
$('#fg').addEventListener('mousemove', e => { const r = fgAt(e); if (!r) return hideTip(); const n = r[4];
  showTip(e, '<b>' + esc(n.name) + '</b><br>' + fmt(n.v, 1) + ' ms · ' + fmt(n.v / fgRoot.v * 100, 2) + '% of the selection'); });
$('#fg').addEventListener('mouseleave', hideTip);
$('#fg').addEventListener('click', e => { const r = fgAt(e); if (!r) return; fgZoom = r[4] === (fgZoom || fgRoot) ? (r[4].parent || null) : r[4]; if (fgZoom === fgRoot) fgZoom = null; drawFlame(); });
$('#fg-reset').addEventListener('click', () => { fgZoom = null; drawFlame(); });
$('#fg-q').addEventListener('input', drawFlame);
$('#fg-proc').addEventListener('click', e => { const b = e.target.closest('button'); if (b) { fgProc = b.dataset.p; flame(); } });

// Heatmap: time × thread, or time × function (self time of the leaf frame)
let hmMode = 'thread';
function heatmap() {
  $('#hm-mode').innerHTML = ['thread', 'function'].map(m => '<button data-m="' + m + '" class="' + (m === hmMode ? 'on' : '') + '">' + (m === 'thread' ? 'by thread' : 'by function') + '</button>').join('');
  const samples = ST.samples.filter(s => inSel(s[0]));
  const cv = $('#hm'), dpr = devicePixelRatio || 1, w = cv.parentElement.clientWidth || 900;
  if (!samples.length) { cv.width = w; cv.height = 30; cv.style.height = '30px'; $('#hm-info').textContent = 'No CPU samples in this selection.'; return; }
  const key = s => hmMode === 'thread' ? (s[1] === 'app' ? '' : s[1] + ' · ') + s[2] : ST.stacks[s[3]][ST.stacks[s[3]].length - 1];
  const tot = new Map(); for (const s of samples) tot.set(key(s), (tot.get(key(s)) || 0) + s[4]);
  const rows = [...tot.entries()].sort((a, b) => b[1] - a[1]).slice(0, hmMode === 'thread' ? 14 : 20).map(e => e[0]);
  const tmin = Math.min(...samples.map(s => s[0])), tmax = Math.max(...samples.map(s => s[0])) + ST.bucket;
  const cols = Math.min(240, Math.max(20, Math.ceil(tmax - tmin))), dt = (tmax - tmin) / cols;
  const grid = rows.map(() => new Float64Array(cols));
  for (const s of samples) { const r = rows.indexOf(key(s)); if (r >= 0) grid[r][Math.min(cols - 1, Math.floor((s[0] - tmin) / dt))] += s[4]; }
  const L = 260, RH = 16, h = rows.length * RH + 24;
  cv.width = w * dpr; cv.height = h * dpr; cv.style.height = h + 'px';
  const g = cv.getContext('2d'); g.scale(dpr, dpr); g.font = '11px -apple-system, sans-serif'; g.textBaseline = 'middle';
  g.fillStyle = css('--panel'); g.fillRect(0, 0, w, h);
  const max = Math.max(1, ...grid.flatMap(r => [...r])), ramp = ['--q0', '--q1', '--q2', '--q3', '--q4', '--q5'].map(css), cw = (w - L - 8) / cols;
  rows.forEach((name, r) => {
    g.fillStyle = css('--ink2'); g.save(); g.beginPath(); g.rect(0, r * RH, L - 8, RH); g.clip(); g.fillText(name, 4, r * RH + RH / 2); g.restore();
    for (let c = 0; c < cols; c++) { const v = grid[r][c]; g.fillStyle = ramp[v <= 0 ? 0 : Math.min(5, 1 + Math.floor(Math.sqrt(v / max) * 4.999))]; g.fillRect(L + c * cw, r * RH + 1, Math.max(1, cw - 1), RH - 2); }
  });
  g.fillStyle = css('--ink3');
  for (let c = 0; c < cols; c += Math.ceil(cols / 10)) g.fillText(Math.round(tmin + c * dt) + ' s', L + c * cw, rows.length * RH + 12);
  $('#hm-info').textContent = 'Column = ' + dt.toFixed(1) + ' s; darker = more CPU (ms of samples per cell, square-root scale, max ' + fmt(max) + ' ms).';
  cv.onmousemove = e => { const rc = cv.getBoundingClientRect(), x = e.clientX - rc.left, y = e.clientY - rc.top, r = Math.floor(y / RH), c = Math.floor((x - L) / cw);
    if (r < 0 || r >= rows.length || c < 0 || c >= cols) return hideTip();
    showTip(e, '<b>' + esc(rows[r]) + '</b><br>' + (tmin + c * dt).toFixed(1) + '–' + (tmin + (c + 1) * dt).toFixed(1) + ' s: ' + fmt(grid[r][c]) + ' ms'); };
  cv.onmouseleave = hideTip;
}
$('#hm-mode').addEventListener('click', e => { const b = e.target.closest('button'); if (b) { hmMode = b.dataset.m; heatmap(); } });

// Signposts
let spSort = 'total';
function signposts() {
  const by = new Map();
  for (const s of (D.signposts || [])) { if (!inSel(s.t)) continue; (by.get(s.name) || by.set(s.name, []).get(s.name)).push(s.ms); }
  const rows = [...by.entries()].map(([n, ms]) => ({ name: n, count: ms.length, p50: pct(ms, 0.5), p95: pct(ms, 0.95), max: Math.max(...ms), total: ms.reduce((a, b) => a + b, 0) }));
  rows.sort((a, b) => spSort === 'name' ? a.name.localeCompare(b.name) : b[spSort] - a[spSort]);
  const cols = [['name', 'interval'], ['count', 'count'], ['p50', 'p50 ms'], ['p95', 'p95 ms'], ['max', 'max ms'], ['total', 'total ms']];
  $('#sp').innerHTML = '<tr>' + cols.map(c => '<th data-k="' + c[0] + '" class="' + (c[0] === 'name' ? '' : 'n') + '">' + c[1] + (spSort === c[0] ? ' ↓' : '') + '</th>').join('') + '</tr>' +
    (rows.length ? rows.map(r => '<tr><td>' + esc(r.name) + '</td><td class="n">' + r.count + '</td><td class="n">' + fmt(r.p50, 2) + '</td><td class="n">' + fmt(r.p95, 2) + '</td><td class="n">' + fmt(r.max, 1) + '</td><td class="n">' + fmt(r.total) + '</td></tr>').join('')
      : '<tr><td colspan="6" class="muted">No signposts in this selection.</td></tr>');
  const slow = (D.signposts || []).filter(s => inSel(s.t)).sort((a, b) => b.ms - a.ms).slice(0, 25);
  $('#sp-slow').innerHTML = '<tr><th>interval</th><th class="n">at</th><th class="n">ms</th><th>detail</th></tr>' + slow.map(s => '<tr><td>' + esc(s.name) + '</td><td class="n">' + fmt(s.t) + ' s</td><td class="n">' + fmt(s.ms, 1) + '</td><td>' + esc(s.detail) + '</td></tr>').join('');
}
$('#sp').addEventListener('click', e => { const th = e.target.closest('th'); if (th) { spSort = th.dataset.k; signposts(); } });

// Hangs, with the main thread's heaviest stacks during each
const ROOTS = /^(start|main|static Main|specialized static Main|static App\.main|runApp|specialized runApp|NSApplicationMain|-\[NSApplication|_DPS|_?BlockUntilNext|ReceiveNextEventCommon|RunCurrentEventLoopInMode|_?CFRunLoop|__CFRunLoop|__CFRUNLOOP|_dispatch_main_queue|_dispatch_client_callout|<deduplicated_symbol>)/;
const trim = fr => { let i = 0; while (i < fr.length - 1 && ROOTS.test(fr[i])) i++; return fr.slice(i); };
function hangs() {
  const hs = (D.hangs || []).filter(h => inSel(h.t)).sort((a, b) => b.ms - a.ms);
  const wl = t => (W.find(w => t >= w.t0 && t <= w.t1) || {}).name || '—';
  $('#hang-sum').textContent = hs.length ? hs.length + ' stall' + (hs.length === 1 ? '' : 's') + ' ≥100 ms (' + hs.filter(h => h.ms >= 250).length + ' ≥250 ms, the hang threshold); longest ' + fmt(hs[0].ms) + ' ms. Sources: xctrace potential-hangs and the app’s own HangWatch.' : 'No main-thread stalls of 100 ms or more in this selection.';
  $('#hangs').innerHTML = hs.length ? '<tr><th class="n">ms</th><th class="n">at</th><th>workload</th><th>source</th><th>main thread during the hang (heaviest stack, innermost last)</th></tr>' + hs.slice(0, 60).map(h =>
    '<tr><td class="n ' + (h.ms >= 250 ? 'bad' : '') + '">' + fmt(h.ms) + '</td><td class="n">' + fmt(h.t) + ' s</td><td>' + esc(wl(h.t)) + '</td><td>' + esc(h.source) + '</td><td>' +
    ((h.stacks || []).length ? h.stacks.map((s, i) => (i ? '<details><summary>' + fmt(s.ms) + ' ms</summary>' : '<div>' + fmt(s.ms) + ' ms</div>') + '<div class="stack">' + esc(trim(s.frames).slice(-14).join('\n')) + '</div>' + (i ? '</details>' : '')).join('') : '<span class="muted">no samples</span>') + '</td></tr>').join('') : '';
}

// Allocations
function allocs() {
  const hs = (D.heaps || []).filter(h => sel === 'all' || h.workload === sel);
  if (!hs.length) { $('#alloc').innerHTML = '<div class="sub">' + (D.meta.allocations ? 'No heap snapshot for this selection.' : 'Not recorded: run with --allocations (MallocStackLogging=lite, then heap, malloc_history -allBySize, vmmap --summary and leaks after each workload).') + '</div>'; return; }
  const mb = b => fmt(b / 1048576, 2);
  $('#alloc').innerHTML = hs.map(h => '<h2 style="margin-top:12px">After ' + esc(h.workload) + (h.footprint_mb ? ' · footprint ' + fmt(h.footprint_mb) + ' MB' : '') + (h.leaks ? ' · leaks: ' + h.leaks.count + ' (' + mb(h.leaks.bytes) + ' MB)' : '') + '</h2>' +
    '<div class="scroll"><table><tr><th class="n">live MB</th><th class="n">allocations</th><th>allocating stack (innermost last)</th></tr>' + (h.stacks || []).slice(0, 25).map(s =>
      '<tr><td class="n">' + mb(s.bytes) + '</td><td class="n">' + s.count.toLocaleString() + '</td><td class="stack">' + esc(trim(s.stack).slice(-10).join('\n')) + '</td></tr>').join('') + '</table></div>' +
    '<details><summary>Heap by type (' + (h.types || []).length + ')</summary><table><tr><th class="n">MB</th><th class="n">count</th><th>type</th></tr>' + (h.types || []).map(t => '<tr><td class="n">' + mb(t.bytes) + '</td><td class="n">' + t.count.toLocaleString() + '</td><td>' + esc(t.name) + '</td></tr>').join('') + '</table></details>' +
    '<details><summary>VM regions by dirty + swapped size</summary><table><tr><th>region</th><th class="n">virtual</th><th class="n">resident</th><th class="n">dirty</th><th class="n">swapped</th></tr>' + (h.regions || []).map(r => '<tr><td>' + esc(r.region) + '</td><td class="n">' + esc(r.virtual) + '</td><td class="n">' + esc(r.resident) + '</td><td class="n">' + esc(r.dirty) + '</td><td class="n">' + esc(r.swapped || '') + '</td></tr>').join('') + '</table></details>').join('');
}

function renderAll() {
  filters.querySelectorAll('button').forEach(b => b.classList.toggle('on', b.dataset.w === sel));
  tiles(); compare(); charts(); flame(); heatmap(); signposts(); hangs(); allocs();
}
renderAll();
let rt; addEventListener('resize', () => { clearTimeout(rt); rt = setTimeout(() => { charts(); drawFlame(); heatmap(); }, 150); });
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', renderAll);
</script></body></html>
"""


def write(data, path):
    blob = json.dumps(data, separators=(",", ":")).replace("</", "<\\/")
    path.write_text(PAGE.replace("/*DATA*/", blob))
