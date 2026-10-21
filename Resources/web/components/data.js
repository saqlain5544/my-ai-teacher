// Smart data components: ```chart ```timeline ```steps ```cards ```compare ```kv ```json ```csv ```vocab,
// GitHub-style callouts (> [!NOTE]) and sortable tables.
(function () {
  'use strict';
  const R = window.TeacherUI;
  const COLORS = ['#2f6fec', '#e5484d', '#30a46c', '#f76b15', '#8e4ec6', '#0d9488', '#d6409f', '#946800', '#5b5bd6', '#12a594'];

  function parse(code) {
    try { return JSON.parse(code); }
    catch (e) {
      // Tolerate trailing commas and single quotes.
      try { return JSON.parse(code.replace(/,\s*([\]}])/g, '$1').replace(/'/g, '"')); } catch (_) { throw new Error('Invalid JSON: ' + e.message); }
    }
  }
  const box = (cls, key, inner) => '<div class="comp ' + cls + '" data-key="' + key + '">' + inner + '</div>';
  const err = (ctx, name, e, code) => '<div class="comp comp-error"><div class="diagram-error">' + ctx.esc(name) + ': ' + ctx.esc(e.message) + '<pre>' + ctx.esc(code) + '</pre></div></div>';
  function safe(name, fn) {
    return (code, ctx, env) => {
      if (env && env.open) return '<div class="comp"><div class="diagram-pending">Building ' + name + '…</div></div>';
      try { return fn(parse(code), ctx, code); } catch (e) { return err(ctx, name, e, code); }
    };
  }

  // ── Charts ─────────────────────────────────────────────────────────────
  function nice(range, target) {
    const raw = range / target, mag = Math.pow(10, Math.floor(Math.log10(raw || 1))), n = raw / mag;
    return (n < 1.5 ? 1 : n < 3 ? 2 : n < 7 ? 5 : 10) * mag;
  }
  const fmt = v => Math.abs(v) >= 1e6 ? (v / 1e6).toFixed(1) + 'M' : Math.abs(v) >= 1e4 ? (v / 1e3).toFixed(0) + 'k' : String(+(+v).toFixed(3));

  function chart(spec, ctx) {
    const esc = ctx.esc;
    const type = (spec.type || 'bar').toLowerCase();
    let series = spec.series || (spec.data ? [{ name: spec.name || '', data: spec.data }] : []);
    series = series.filter(s => s && Array.isArray(s.data) && s.data.length);
    if (!series.length) return '<div class="comp-error">This chart has no data.</div>';
    const labels = spec.labels || (series[0] ? series[0].data.map((_, i) => String(i + 1)) : []);
    const W = 640, H = 360, M = { l: 52, r: 16, t: spec.title ? 34 : 14, b: 46 };
    let svg = '<svg class="chart" viewBox="0 0 ' + W + ' ' + H + '" xmlns="http://www.w3.org/2000/svg" role="img">';
    if (spec.title) svg += '<text class="plot-title" x="' + W / 2 + '" y="20" text-anchor="middle">' + esc(spec.title) + '</text>';
    if (type === 'pie' || type === 'donut' || type === 'doughnut') {
      const vals = series[0] ? series[0].data.map(Number) : [];
      const total = vals.reduce((a, b) => a + Math.max(0, b), 0) || 1;
      const cx = 220, cy = (H + M.t) / 2, r = Math.min(150, (H - M.t - 20) / 2), inner = type === 'pie' ? 0 : r * 0.55;
      let a0 = -Math.PI / 2;
      vals.forEach((v, i) => {
        const a1 = a0 + (Math.max(0, v) / total) * Math.PI * 2;
        const large = a1 - a0 > Math.PI ? 1 : 0;
        const p = (a, rr) => [cx + rr * Math.cos(a), cy + rr * Math.sin(a)];
        const [x0, y0] = p(a0, r), [x1, y1] = p(a1, r), [x2, y2] = p(a1, inner), [x3, y3] = p(a0, inner);
        const d = inner ? 'M' + x0 + ' ' + y0 + 'A' + r + ' ' + r + ' 0 ' + large + ' 1 ' + x1 + ' ' + y1 + 'L' + x2 + ' ' + y2 + 'A' + inner + ' ' + inner + ' 0 ' + large + ' 0 ' + x3 + ' ' + y3 + 'Z'
          : 'M' + cx + ' ' + cy + 'L' + x0 + ' ' + y0 + 'A' + r + ' ' + r + ' 0 ' + large + ' 1 ' + x1 + ' ' + y1 + 'Z';
        svg += '<path d="' + d + '" fill="' + COLORS[i % COLORS.length] + '" stroke="var(--bg)" stroke-width="2"><title>' + esc(labels[i]) + ': ' + v + '</title></path>';
        a0 = a1;
      });
      let ly = M.t + 20;
      vals.forEach((v, i) => {
        svg += '<rect x="420" y="' + (ly - 10) + '" width="12" height="12" rx="3" fill="' + COLORS[i % COLORS.length] + '"/><text class="chart-legend" x="440" y="' + ly + '">' + esc(labels[i]) + ' — ' + fmt(v) + ' (' + Math.round(v / total * 100) + '%)</text>';
        ly += 22;
      });
      return svg + '</svg>';
    }
    if (type === 'scatter') {
      const pts = series.flatMap(s => s.data);
      const xs = pts.map(p => +p[0]), ys = pts.map(p => +p[1]);
      let x0 = Math.min(...xs), x1 = Math.max(...xs), y0 = Math.min(0, ...ys), y1 = Math.max(...ys);
      const px = (x1 - x0) * 0.06 || 1, py = (y1 - y0) * 0.08 || 1; x0 -= px; x1 += px; y1 += py;
      const sx = x => M.l + (x - x0) / (x1 - x0) * (W - M.l - M.r), sy = y => H - M.b - (y - y0) / (y1 - y0) * (H - M.t - M.b);
      svg += axes(x0, x1, y0, y1, sx, sy, W, H, M, true);
      series.forEach((s, i) => s.data.forEach(p => { svg += '<circle cx="' + sx(+p[0]) + '" cy="' + sy(+p[1]) + '" r="4" fill="' + (s.color || COLORS[i % COLORS.length]) + '" fill-opacity=".8"><title>' + esc((s.name ? s.name + ': ' : '') + '(' + p[0] + ', ' + p[1] + ')') + '</title></circle>'; }));
      return svg + legend(series, W, M, esc) + labelsXY(spec, W, H, M, esc) + '</svg>';
    }
    // bar / line / area share a categorical x axis.
    const stacked = !!spec.stacked && type === 'bar';
    const n = labels.length;
    const allVals = stacked ? labels.map((_, i) => series.reduce((a, s) => a + (+s.data[i] || 0), 0)) : series.flatMap(s => s.data.map(Number));
    let y0 = Math.min(0, ...allVals), y1 = Math.max(...allVals);
    if (y1 === y0) y1 = y0 + 1;
    y1 += (y1 - y0) * 0.08;
    const bandW = (W - M.l - M.r) / Math.max(1, n);
    const sx = i => M.l + bandW * (i + 0.5), sy = y => H - M.b - (y - y0) / (y1 - y0) * (H - M.t - M.b);
    svg += axes(0, 1, y0, y1, null, sy, W, H, M, false);
    labels.forEach((l, i) => { svg += '<text class="chart-tick" x="' + sx(i) + '" y="' + (H - M.b + 16) + '" text-anchor="middle">' + esc(String(l).length > 12 ? String(l).slice(0, 11) + '…' : l) + '</text>'; });
    if (type === 'bar') {
      const k = series.length, gw = bandW * 0.72, bw = stacked ? gw : gw / k;
      const base = labels.map(() => 0);
      series.forEach((s, si) => s.data.forEach((v, i) => {
        v = +v || 0;
        const x = stacked ? sx(i) - gw / 2 : sx(i) - gw / 2 + si * bw;
        const yTop = stacked ? sy(base[i] + v) : sy(Math.max(0, v)), yBot = stacked ? sy(base[i]) : sy(Math.min(0, v));
        svg += '<rect x="' + x + '" y="' + yTop + '" width="' + Math.max(1, bw - 2) + '" height="' + Math.max(0.5, yBot - yTop) + '" rx="3" fill="' + (s.color || COLORS[si % COLORS.length]) + '"><title>' + esc((s.name ? s.name + ' · ' : '') + labels[i] + ': ' + v) + '</title></rect>';
        if (stacked) base[i] += v;
      }));
    } else {
      series.forEach((s, si) => {
        const c = s.color || COLORS[si % COLORS.length];
        const d = s.data.map((v, i) => (i ? 'L' : 'M') + sx(i).toFixed(1) + ' ' + sy(+v).toFixed(1)).join('');
        if (type === 'area') svg += '<path d="' + d + 'L' + sx(s.data.length - 1) + ' ' + sy(Math.max(0, y0)) + 'L' + sx(0) + ' ' + sy(Math.max(0, y0)) + 'Z" fill="' + c + '" fill-opacity=".15"/>';
        svg += '<path d="' + d + '" fill="none" stroke="' + c + '" stroke-width="2.4" stroke-linejoin="round"/>';
        s.data.forEach((v, i) => { svg += '<circle cx="' + sx(i) + '" cy="' + sy(+v) + '" r="3.2" fill="' + c + '"><title>' + esc((s.name ? s.name + ' · ' : '') + labels[i] + ': ' + v) + '</title></circle>'; });
      });
    }
    return svg + legend(series, W, M, esc) + labelsXY(spec, W, H, M, esc) + '</svg>';
  }
  function axes(x0, x1, y0, y1, sx, sy, W, H, M, xNumeric) {
    let s = '<g class="plot-grid">';
    const ys = nice(y1 - y0, 6);
    for (let y = Math.ceil(y0 / ys) * ys; y <= y1 + 1e-9; y += ys) s += '<line x1="' + M.l + '" x2="' + (W - M.r) + '" y1="' + sy(y) + '" y2="' + sy(y) + '"/>';
    s += '</g><g class="plot-ticks">';
    for (let y = Math.ceil(y0 / ys) * ys; y <= y1 + 1e-9; y += ys) s += '<text x="' + (M.l - 6) + '" y="' + (sy(y) + 4) + '" text-anchor="end">' + fmt(y) + '</text>';
    if (xNumeric) {
      const xs = nice(x1 - x0, 8);
      for (let x = Math.ceil(x0 / xs) * xs; x <= x1 + 1e-9; x += xs) s += '<text x="' + sx(x) + '" y="' + (H - M.b + 16) + '" text-anchor="middle">' + fmt(x) + '</text>';
    }
    s += '</g><g class="plot-axis"><line x1="' + M.l + '" x2="' + (W - M.r) + '" y1="' + sy(Math.max(y0, 0)) + '" y2="' + sy(Math.max(y0, 0)) + '"/></g>';
    return s;
  }
  function legend(series, W, M, esc) {
    if (series.length < 2) return '';
    let x = M.l, s = '<g class="chart-legend">';
    series.forEach((se, i) => {
      s += '<rect x="' + x + '" y="' + (M.t - 2) + '" width="10" height="10" rx="2" fill="' + (se.color || COLORS[i % COLORS.length]) + '"/><text x="' + (x + 14) + '" y="' + (M.t + 7) + '">' + esc(se.name || '') + '</text>';
      x += 24 + String(se.name || '').length * 6.5;
    });
    return s + '</g>';
  }
  const labelsXY = (spec, W, H, M, esc) => (spec.xlabel ? '<text class="plot-axislabel" x="' + (W / 2) + '" y="' + (H - 6) + '" text-anchor="middle">' + esc(spec.xlabel) + '</text>' : '') +
    (spec.ylabel ? '<text class="plot-axislabel" transform="rotate(-90)" x="' + (-(H / 2)) + '" y="13" text-anchor="middle">' + esc(spec.ylabel) + '</text>' : '');

  R.registerFence(['chart', 'bar', 'barchart', 'piechart'], safe('chart', (spec, ctx, code) => box('chart-block', 'ch' + ctx.hash(code), chart(spec, ctx))));

  // ── Timeline / steps / cards / compare / kv ───────────────────────────
  R.registerFence('timeline', safe('timeline', (items, ctx, code) => {
    items = Array.isArray(items) ? items : items.events || [];
    return box('timeline', 'tl' + ctx.hash(code), items.map(it =>
      '<div class="tl-item"><div class="tl-dot"></div><div class="tl-date">' + ctx.esc(it.date || it.year || it.time || '') + '</div>' +
      '<div class="tl-body"><div class="tl-title">' + ctx.inline(it.title || '') + '</div>' + (it.text || it.description ? '<div class="md">' + ctx.md(it.text || it.description) + '</div>' : '') + '</div></div>').join(''));
  }));

  R.registerFence('steps', safe('steps', (items, ctx, code) => {
    items = Array.isArray(items) ? items : items.steps || [];
    return box('steps', 'st' + ctx.hash(code), items.map((it, i) => {
      const o = typeof it === 'string' ? { text: it } : it;
      return '<div class="step"><div class="step-n">' + (i + 1) + '</div><div class="step-body">' + (o.title ? '<div class="step-title">' + ctx.inline(o.title) + '</div>' : '') +
        (o.text ? '<div class="md">' + ctx.md(o.text) + '</div>' : '') + '</div></div>';
    }).join(''));
  }));

  R.registerFence('cards', safe('cards', (items, ctx, code) => {
    items = Array.isArray(items) ? items : items.cards || [];
    return box('cards', 'cd' + ctx.hash(code), items.map(it =>
      '<div class="card">' + (it.icon ? '<div class="card-icon">' + ctx.esc(it.icon) + '</div>' : '') + '<div class="card-title">' + ctx.inline(it.title || '') + '</div>' +
      '<div class="md">' + ctx.md(it.text || it.body || '') + '</div></div>').join(''));
  }));

  R.registerFence(['compare', 'comparison'], safe('comparison', (spec, ctx, code) => {
    const cols = spec.columns || [], rows = spec.rows || [];
    let h = '<table class="compare-table"><thead><tr><th></th>' + cols.map(c => '<th>' + ctx.inline(c) + '</th>').join('') + '</tr></thead><tbody>';
    rows.forEach(r => { h += '<tr><th>' + ctx.inline(r[0]) + '</th>' + r.slice(1).map(c => '<td>' + ctx.inline(String(c)) + '</td>').join('') + '</tr>'; });
    return box('compare md', 'cp' + ctx.hash(code), h + '</tbody></table>');
  }));

  R.registerFence(['kv', 'facts', 'definitions'], safe('facts', (spec, ctx, code) => {
    const entries = Array.isArray(spec) ? spec.map(e => Array.isArray(e) ? e : [e.key || e.term, e.value || e.definition]) : Object.entries(spec);
    return box('kv', 'kv' + ctx.hash(code), '<dl>' + entries.map(([k, v]) => '<dt>' + ctx.inline(String(k)) + '</dt><dd>' + ctx.inline(typeof v === 'string' ? v : JSON.stringify(v)) + '</dd>').join('') + '</dl>');
  }));

  // ── JSON tree & CSV ───────────────────────────────────────────────────
  function tree(v, ctx, depth) {
    if (v === null) return '<span class="j-null">null</span>';
    if (typeof v === 'string') return '<span class="j-str">"' + ctx.esc(v) + '"</span>';
    if (typeof v === 'number') return '<span class="j-num">' + v + '</span>';
    if (typeof v === 'boolean') return '<span class="j-bool">' + v + '</span>';
    const isArr = Array.isArray(v), keys = isArr ? v.map((_, i) => i) : Object.keys(v);
    if (!keys.length) return isArr ? '[]' : '{}';
    const inner = keys.map(k => '<div class="j-row">' + (isArr ? '' : '<span class="j-key">' + ctx.esc(k) + '</span>: ') + tree(v[k], ctx, depth + 1) + '</div>').join('');
    return '<details' + (depth < 2 ? ' open' : '') + '><summary>' + (isArr ? '[' + keys.length + ']' : '{' + keys.length + '}') + '</summary><div class="j-children">' + inner + '</div></details>';
  }
  R.registerFence('json', (code, ctx, env) => {
    if (env && env.open) return null;
    try { return box('json-tree', 'js' + ctx.hash(code), '<div class="code-head"><span class="lang">json</span><span><button data-act="copy-raw" data-raw="' + ctx.esc(code) + '">Copy</button></span></div><div class="j-root">' + tree(JSON.parse(code), ctx, 0) + '</div>'); }
    catch (_) { return null; } // not valid JSON: fall back to a code block
  });

  function parseCSV(text) {
    const rows = []; let row = [], cell = '', q = false;
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (q) { if (c === '"') { if (text[i + 1] === '"') { cell += '"'; i++; } else q = false; } else cell += c; }
      else if (c === '"') q = true;
      else if (c === ',' || c === '\t') { row.push(cell); cell = ''; }
      else if (c === '\n') { row.push(cell); rows.push(row); row = []; cell = ''; }
      else if (c !== '\r') cell += c;
    }
    if (cell || row.length) { row.push(cell); rows.push(row); }
    return rows.filter(r => r.some(c => c.trim()));
  }
  R.registerFence(['csv', 'tsv'], (code, ctx, env) => {
    if (env && env.open) return null;
    const rows = parseCSV(code);
    if (rows.length < 2) return null;
    return box('md csv', 'cv' + ctx.hash(code), '<table class="sortable"><thead><tr>' + rows[0].map(h => '<th>' + ctx.esc(h) + '</th>').join('') + '</tr></thead><tbody>' +
      rows.slice(1, 1001).map(r => '<tr>' + r.map(c => '<td>' + ctx.esc(c) + '</td>').join('') + '</tr>').join('') + '</tbody></table>');
  });

  // ── Vocabulary cards (language learning) ──────────────────────────────
  R.registerFence(['vocab', 'vocabulary', 'words'], safe('vocabulary', (items, ctx, code) => {
    items = Array.isArray(items) ? items : items.words || [];
    return box('vocab', 'vc' + ctx.hash(code), items.map(w => {
      const lang = w.lang || w.language || '';
      const rtl = /^(ar|he|fa|ur|ps|yi)/.test(lang);
      const say = (t, l) => t ? '<button class="say" data-act="say" data-lang="' + ctx.esc(l) + '" data-text="' + ctx.esc(t) + '" title="Listen">🔊</button>' : '';
      return '<div class="vocab-card"><div class="vocab-term"' + (lang ? ' lang="' + ctx.esc(lang) + '"' : '') + (rtl ? ' dir="rtl"' : '') + '>' + ctx.esc(w.term || w.word || '') + '</div>' +
        say(w.term || w.word, lang) +
        (w.reading || w.transliteration ? '<div class="vocab-reading">' + ctx.esc(w.reading || w.transliteration) + '</div>' : '') +
        '<div class="vocab-meaning">' + ctx.inline(w.meaning || w.translation || '') + '</div>' +
        (w.example ? '<div class="vocab-example"><span' + (lang ? ' lang="' + ctx.esc(lang) + '"' : '') + (rtl ? ' dir="rtl"' : '') + '>' + ctx.esc(w.example) + '</span>' + say(w.example, lang) +
          (w.example_meaning ? '<div class="vocab-ex-meaning">' + ctx.inline(w.example_meaning) + '</div>' : '') + '</div>' : '') +
        (w.notes ? '<div class="vocab-notes">' + ctx.inline(w.notes) + '</div>' : '') + '</div>';
    }).join(''));
  }));
  R.registerAction('say', (el, e, ctx) => { e.stopPropagation(); ctx.post({ type: 'speak', text: el.getAttribute('data-text'), lang: el.getAttribute('data-lang') || null }); });
  R.registerAction('copy-raw', (el, e, ctx) => { ctx.post({ type: 'copy', text: el.getAttribute('data-raw') }); ctx.flash(el, 'Copied'); });

  // ── Callouts: > [!NOTE] … ─────────────────────────────────────────────
  const CALLOUTS = { note: 'ℹ️ Note', tip: '💡 Tip', important: '❗ Important', warning: '⚠️ Warning', caution: '🛑 Caution', example: '🧪 Example',
    definition: '📘 Definition', theorem: '📐 Theorem', proof: '✍️ Proof', summary: '📝 Summary', question: '❓ Question', info: 'ℹ️ Info', success: '✅ Success' };
  R.registerMarkdown(md => {
    md.core.ruler.after('inline', 'callouts', state => {
      const t = state.tokens;
      for (let i = 0; i < t.length - 2; i++) {
        if (t[i].type !== 'blockquote_open' || t[i + 1].type !== 'paragraph_open' || t[i + 2].type !== 'inline') continue;
        const m = /^\[!(\w+)\][+-]?\s*(.*)$/m.exec(t[i + 2].content);
        if (!m || !CALLOUTS[m[1].toLowerCase()]) continue;
        const kind = m[1].toLowerCase();
        t[i].attrJoin('class', 'callout callout-' + kind);
        const inl = t[i + 2];
        // The first line ("[!NOTE] optional title") becomes the callout title.
        let k = 0, line = '';
        while (k < inl.children.length && !/break$/.test(inl.children[k].type)) { line += inl.children[k].content; k++; }
        const custom = ((/^\[!\w+\][+-]?\s*(.*)$/.exec(line) || [])[1] || '').trim();
        const title = new state.Token('html_inline', '', 0);
        if (custom && custom.length <= 60) {
          // Short text after the marker is a title.
          inl.children.splice(0, Math.min(inl.children.length, k + 1));
          title.content = '<span class="callout-title">' + CALLOUTS[kind].split(' ')[0] + ' ' + md.renderInline(custom) + '</span>';
        } else {
          // Long text is the body: drop only the marker.
          const first = inl.children[0];
          if (first && first.type === 'text') first.content = first.content.replace(/^\[!\w+\][+-]?\s*/, '');
          if (!custom) inl.children.splice(0, Math.min(inl.children.length, k + 1));
          title.content = '<span class="callout-title">' + CALLOUTS[kind] + '</span>';
        }
        inl.children.unshift(title);
      }
    });
  });

  // ── Sortable tables ───────────────────────────────────────────────────
  R.registerProcessor((root) => {
    root.querySelectorAll('table').forEach(table => {
      if (table._sortable || !table.tHead || table.closest('.quiz, .compare')) return;
      table._sortable = true;
      Array.from(table.tHead.rows[0] ? table.tHead.rows[0].cells : []).forEach((th, col) => {
        th.classList.add('sort-th');
        th.title = 'Sort';
        th.addEventListener('click', () => {
          const body = table.tBodies[0]; if (!body) return;
          const dir = th._dir = -(th._dir || -1);
          const rows = Array.from(body.rows);
          const val = r => { const t = (r.cells[col] ? r.cells[col].textContent : '').trim(); const n = parseFloat(t.replace(/[^0-9.\-eE]/g, '')); return isNaN(n) || !/\d/.test(t) ? t.toLowerCase() : n; };
          rows.sort((a, b) => { const x = val(a), y = val(b); return (x > y ? 1 : x < y ? -1 : 0) * dir; });
          rows.forEach(r => body.appendChild(r));
          table.querySelectorAll('.sort-th').forEach(h => h.removeAttribute('data-dir'));
          th.setAttribute('data-dir', dir > 0 ? 'asc' : 'desc');
        });
      });
    });
  });
})();
