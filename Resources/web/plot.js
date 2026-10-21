// Tiny, safe function plotter for ```plot blocks. No eval: expressions are compiled from a parsed AST.
(function () {
  'use strict';
  const FUNCS = {
    sin: Math.sin, cos: Math.cos, tan: Math.tan, asin: Math.asin, acos: Math.acos, atan: Math.atan,
    arcsin: Math.asin, arccos: Math.acos, arctan: Math.atan, sinh: Math.sinh, cosh: Math.cosh, tanh: Math.tanh,
    asinh: Math.asinh, acosh: Math.acosh, atanh: Math.atanh,
    sec: x => 1 / Math.cos(x), csc: x => 1 / Math.sin(x), cot: x => 1 / Math.tan(x),
    exp: Math.exp, ln: Math.log, log: Math.log10, log10: Math.log10, log2: Math.log2, sqrt: Math.sqrt, cbrt: Math.cbrt,
    abs: Math.abs, floor: Math.floor, ceil: Math.ceil, round: Math.round, sign: Math.sign, sgn: Math.sign,
    min: Math.min, max: Math.max, pow: Math.pow, atan2: Math.atan2, hypot: Math.hypot,
    gamma: x => gamma(x), fact: x => gamma(x + 1), heaviside: x => (x < 0 ? 0 : 1),
  };
  const CONSTS = { pi: Math.PI, 'π': Math.PI, e: Math.E, tau: 2 * Math.PI, phi: (1 + Math.sqrt(5)) / 2 };

  function gamma(z) {
    if (z < 0.5) return Math.PI / (Math.sin(Math.PI * z) * gamma(1 - z));
    z -= 1;
    const g = 7, c = [0.99999999999980993, 676.5203681218851, -1259.1392167224028, 771.32342877765313,
      -176.61502916214059, 12.507343278686905, -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7];
    let x = c[0];
    for (let i = 1; i < g + 2; i++) x += c[i] / (z + i);
    const t = z + g + 0.5;
    return Math.sqrt(2 * Math.PI) * Math.pow(t, z + 0.5) * Math.exp(-t) * x;
  }

  function tokenize(s) {
    const out = [];
    s = s.replace(/\*\*/g, '^').replace(/·|×/g, '*').replace(/÷/g, '/').replace(/−/g, '-');
    let i = 0;
    while (i < s.length) {
      const c = s[i];
      if (/\s/.test(c)) { i++; continue; }
      if (/[0-9.]/.test(c)) {
        let j = i; while (j < s.length && /[0-9.]/.test(s[j])) j++;
        if (s[j] === 'e' && /[-+0-9]/.test(s[j + 1] || '') && !/[a-z]/i.test(s[j + 2] || '')) { j += 2; while (j < s.length && /[0-9]/.test(s[j])) j++; }
        out.push({ t: 'num', v: parseFloat(s.slice(i, j)) }); i = j; continue;
      }
      if (/[a-zA-Zπθ_]/.test(c)) {
        let j = i; while (j < s.length && /[a-zA-Z0-9_πθ]/.test(s[j])) j++;
        out.push({ t: 'id', v: s.slice(i, j) }); i = j; continue;
      }
      if ('+-*/^(),|!'.includes(c)) { out.push({ t: 'op', v: c }); i++; continue; }
      throw new Error('Unexpected character ' + c);
    }
    return out;
  }

  // Split identifiers like "xsin" or "2pix" into known parts.
  function splitIds(tokens, vars) {
    const known = Object.keys(FUNCS).concat(Object.keys(CONSTS), vars).sort((a, b) => b.length - a.length);
    const out = [];
    for (const tk of tokens) {
      if (tk.t !== 'id' || FUNCS[tk.v] || CONSTS[tk.v] !== undefined || vars.includes(tk.v)) { out.push(tk); continue; }
      let s = tk.v, ok = true; const parts = [];
      while (s.length) {
        const k = known.find(n => s.startsWith(n));
        if (!k) { ok = false; break; }
        parts.push({ t: 'id', v: k }); s = s.slice(k.length);
      }
      if (ok) out.push(...parts); else out.push(tk);
    }
    return out;
  }

  function compile(expr, vars = ['x']) {
    let toks = splitIds(tokenize(expr), vars);
    // Insert implicit multiplication: 2x, 2(…), )(…), x(…) when x is not a function, )x
    const t2 = [];
    for (let i = 0; i < toks.length; i++) {
      const a = toks[i - 1], b = toks[i];
      if (a && b) {
        const aEnd = a.t === 'num' || (a.t === 'id' && !FUNCS[a.v]) || (a.t === 'op' && (a.v === ')' || a.v === '!'));
        const bStart = b.t === 'num' || b.t === 'id' || (b.t === 'op' && b.v === '(');
        if (aEnd && bStart) t2.push({ t: 'op', v: '*' });
      }
      t2.push(b);
    }
    toks = t2;
    let p = 0;
    const peek = () => toks[p], next = () => toks[p++];
    const expect = v => { const t = next(); if (!t || t.v !== v) throw new Error('Expected ' + v); };
    function parseExpr() {
      let n = parseTerm();
      while (peek() && peek().t === 'op' && (peek().v === '+' || peek().v === '-')) {
        const op = next().v, r = parseTerm(), l = n;
        n = op === '+' ? (s => l(s) + r(s)) : (s => l(s) - r(s));
      }
      return n;
    }
    function parseTerm() {
      let n = parseUnary();
      while (peek() && peek().t === 'op' && (peek().v === '*' || peek().v === '/')) {
        const op = next().v, r = parseUnary(), l = n;
        n = op === '*' ? (s => l(s) * r(s)) : (s => l(s) / r(s));
      }
      return n;
    }
    function parseUnary() {
      if (peek() && peek().t === 'op' && peek().v === '-') { next(); const u = parseUnary(); return s => -u(s); }
      if (peek() && peek().t === 'op' && peek().v === '+') { next(); return parseUnary(); }
      return parsePow();
    }
    function parsePow() {
      let base = parsePostfix();
      if (peek() && peek().t === 'op' && peek().v === '^') { next(); const ex = parseUnary(), b = base; return s => Math.pow(b(s), ex(s)); }
      return base;
    }
    function parsePostfix() {
      let n = parseAtom();
      while (peek() && peek().t === 'op' && peek().v === '!') { next(); const m = n; n = s => gamma(m(s) + 1); }
      return n;
    }
    function parseAtom() {
      const t = next();
      if (!t) throw new Error('Unexpected end');
      if (t.t === 'num') { const v = t.v; return () => v; }
      if (t.t === 'op' && t.v === '(') { const e = parseExpr(); expect(')'); return e; }
      if (t.t === 'op' && t.v === '|') { const e = parseExpr(); expect('|'); return s => Math.abs(e(s)); }
      if (t.t === 'id') {
        if (FUNCS[t.v]) {
          const f = FUNCS[t.v];
          if (peek() && peek().v === '^') { // sin^2(x)
            next(); const pw = parseAtom();
            const arg = parseFuncArgs();
            return s => Math.pow(f(...arg.map(a => a(s))), pw(s));
          }
          const args = parseFuncArgs();
          return s => f(...args.map(a => a(s)));
        }
        if (CONSTS[t.v] !== undefined) { const v = CONSTS[t.v]; return () => v; }
        if (vars.includes(t.v)) { const name = t.v; return s => s[name]; }
        throw new Error('Unknown name ' + t.v);
      }
      throw new Error('Unexpected ' + t.v);
    }
    function parseFuncArgs() {
      if (peek() && peek().v === '(') {
        next();
        const args = [parseExpr()];
        while (peek() && peek().v === ',') { next(); args.push(parseExpr()); }
        expect(')');
        return args;
      }
      return [parseUnary()]; // sin x
    }
    const f = parseExpr();
    if (p < toks.length) throw new Error('Unexpected ' + toks[p].v);
    return f;
  }

  function parseSpec(src) {
    src = src.trim();
    try { const j = JSON.parse(src); return normalizeSpec(Array.isArray(j) ? { functions: j } : j); } catch (_) {}
    const spec = { functions: [] };
    for (let line of src.split('\n')) {
      line = line.trim(); if (!line || line.startsWith('#') || line.startsWith('//')) continue;
      let m;
      if ((m = line.match(/^title\s*[:=]\s*(.+)$/i))) spec.title = m[1].replace(/^["']|["']$/g, '');
      else if ((m = line.match(/^(x|y)(?:range|lim)?\s*[:=]\s*\[?\s*([-\d.eπpi*/ ]+)\s*,\s*([-\d.eπpi*/ ]+)\s*\]?$/i)))
        spec[m[1].toLowerCase()] = [evalConst(m[2]), evalConst(m[3])];
      else if ((m = line.match(/^(?:y|[a-z]\(x\))\s*=\s*(.+)$/i))) spec.functions.push(withRange(m[1], spec));
      else spec.functions.push(withRange(line, spec));
    }
    return normalizeSpec(spec);
  }
  // "x^2 from -3 to 3" / "x^2 for x in [-3, 3]" → expression + x range.
  function withRange(expr, spec) {
    const m = expr.match(/^(.*?)\s*(?:,\s*)?(?:from\s+(\S+)\s+to\s+(\S+)|for\s+x\s+in\s*\[\s*([^,\]]+)\s*,\s*([^\]]+)\])\s*$/i);
    if (!m) return expr;
    if (!spec.x) spec.x = [evalConst(m[2] || m[4]), evalConst(m[3] || m[5])];
    return m[1];
  }
  // Accept the range spellings models use: xmin/xmax, x_min/x_max, xlim/ylim, {min,max} objects.
  function normalizeSpec(spec) {
    for (const a of ['x', 'y']) {
      const lo = spec[a + 'min'] ?? spec[a + '_min'], hi = spec[a + 'max'] ?? spec[a + '_max'];
      if (!spec[a] && lo != null && hi != null) spec[a] = [+lo, +hi];
      if (!spec[a] && Array.isArray(spec[a + 'lim'])) spec[a] = spec[a + 'lim'];
      if (spec[a] && !Array.isArray(spec[a]) && spec[a].min != null) spec[a] = [+spec[a].min, +spec[a].max];
    }
    return spec;
  }
  function evalConst(s) { try { return compile(String(s), [])({}); } catch (_) { return parseFloat(s); } }

  function niceStep(range, target) {
    const raw = range / target, mag = Math.pow(10, Math.floor(Math.log10(raw))), n = raw / mag;
    return (n < 1.5 ? 1 : n < 3 ? 2 : n < 7 ? 5 : 10) * mag;
  }
  const fmt = v => {
    if (Math.abs(v) < 1e-10) return '0';
    const a = Math.abs(v);
    if (a >= 1e4 && a < 1e9) return +(v / (a >= 1e6 ? 1e6 : 1e3)).toFixed(2) + (a >= 1e6 ? 'M' : 'k');   // 20k, 1.5M
    if (a >= 1e9 || a < 1e-3) return v.toExponential(1);
    return String(+v.toFixed(4));
  };
  const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const COLORS = ['#2f6fec', '#e5484d', '#30a46c', '#f76b15', '#8e4ec6', '#0d9488', '#d6409f', '#946800'];

  function render(src) {
    const spec = parseSpec(src);
    const W = 640, H = 400, M = { l: 48, r: 16, t: spec.title ? 34 : 14, b: 36 };
    const fns = (spec.functions || spec.fns || []).map((f, i) => {
      const o = typeof f === 'string' ? { expr: f } : f;
      const expr = String(o.expr || o.fn || o.f || '').replace(/^\s*(y|[a-z]\(x\))\s*=\s*/i, '');
      return { expr, label: o.label || expr, color: o.color || COLORS[i % COLORS.length], fn: compile(expr, ['x']), dashed: !!o.dashed };
    });
    const series = (spec.series || []).map((s, i) => ({
      name: s.name || ('series ' + (i + 1)), type: s.type || 'line', color: s.color || COLORS[(fns.length + i) % COLORS.length],
      pts: (s.points || s.data || []).map(p => Array.isArray(p) ? p : [p.x, p.y]),
    }));
    const points = (spec.points || []).map(p => Array.isArray(p) ? { x: p[0], y: p[1], label: p[2] } : p);
    let [x0, x1] = spec.x || spec.xrange || spec.domain || [-10, 10];
    if (!spec.x && !spec.domain && series.length) {
      const xs = series.flatMap(s => s.pts.map(p => p[0])); x0 = Math.min(...xs); x1 = Math.max(...xs);
      const pad = (x1 - x0) * 0.05 || 1; x0 -= pad; x1 += pad;
    }
    const N = 800, samples = fns.map(f => {
      const arr = [];
      for (let i = 0; i <= N; i++) { const x = x0 + (x1 - x0) * i / N; let y; try { y = f.fn({ x }); } catch (_) { y = NaN; } arr.push([x, y]); }
      return arr;
    });
    let y0, y1;
    if (spec.y || spec.yrange) [y0, y1] = spec.y || spec.yrange;
    else {
      const ys = samples.flat().map(p => p[1]).concat(series.flatMap(s => s.pts.map(p => p[1])), points.map(p => p.y)).filter(Number.isFinite).sort((a, b) => a - b);
      if (!ys.length) { y0 = -10; y1 = 10; }
      else {
        y0 = ys[Math.floor(ys.length * 0.02)]; y1 = ys[Math.ceil(ys.length * 0.98) - 1];
        if (y1 - y0 < 1e-9) { y0 -= 1; y1 += 1; }
        const pad = (y1 - y0) * 0.1; y0 -= pad; y1 += pad;
      }
    }
    const sx = x => M.l + (x - x0) / (x1 - x0) * (W - M.l - M.r);
    const sy = y => H - M.b - (y - y0) / (y1 - y0) * (H - M.t - M.b);
    let svg = `<svg class="plot" viewBox="0 0 ${W} ${H}" xmlns="http://www.w3.org/2000/svg" role="img">`;
    svg += `<defs><clipPath id="pc"><rect x="${M.l}" y="${M.t}" width="${W - M.l - M.r}" height="${H - M.t - M.b}"/></clipPath></defs>`;
    if (spec.title) svg += `<text class="plot-title" x="${W / 2}" y="20" text-anchor="middle">${esc(spec.title)}</text>`;
    const xs = niceStep(x1 - x0, 10), ys = niceStep(y1 - y0, 8);
    svg += '<g class="plot-grid">';
    for (let x = Math.ceil(x0 / xs) * xs; x <= x1 + 1e-9; x += xs) svg += `<line x1="${sx(x)}" x2="${sx(x)}" y1="${M.t}" y2="${H - M.b}"/>`;
    for (let y = Math.ceil(y0 / ys) * ys; y <= y1 + 1e-9; y += ys) svg += `<line x1="${M.l}" x2="${W - M.r}" y1="${sy(y)}" y2="${sy(y)}"/>`;
    svg += '</g><g class="plot-axis">';
    const ax = (0 >= y0 && 0 <= y1) ? sy(0) : H - M.b, ay = (0 >= x0 && 0 <= x1) ? sx(0) : M.l;
    svg += `<line x1="${M.l}" x2="${W - M.r}" y1="${ax}" y2="${ax}"/><line x1="${ay}" x2="${ay}" y1="${M.t}" y2="${H - M.b}"/>`;
    svg += '</g><g class="plot-ticks">';
    for (let x = Math.ceil(x0 / xs) * xs; x <= x1 + 1e-9; x += xs) svg += `<text x="${sx(x)}" y="${H - M.b + 16}" text-anchor="middle">${fmt(x)}</text>`;
    for (let y = Math.ceil(y0 / ys) * ys; y <= y1 + 1e-9; y += ys) svg += `<text x="${M.l - 6}" y="${sy(y) + 4}" text-anchor="end">${fmt(y)}</text>`;
    svg += '</g><g clip-path="url(#pc)">';
    const span = y1 - y0;
    samples.forEach((arr, i) => {
      let d = '', pen = false, prev = null;
      for (const [x, y] of arr) {
        if (!Number.isFinite(y) || (prev !== null && Math.abs(y - prev) > span * 2)) { pen = false; prev = Number.isFinite(y) ? y : null; if (!Number.isFinite(y)) continue; }
        const Y = Math.max(-1e4, Math.min(1e4, sy(y)));
        d += (pen ? 'L' : 'M') + sx(x).toFixed(2) + ' ' + Y.toFixed(2);
        pen = true; prev = y;
      }
      svg += `<path d="${d}" fill="none" stroke="${fns[i].color}" stroke-width="2.2" ${fns[i].dashed ? 'stroke-dasharray="6 4"' : ''} stroke-linejoin="round"/>`;
    });
    series.forEach(s => {
      if (s.type !== 'scatter') svg += `<path d="${s.pts.map((p, j) => (j ? 'L' : 'M') + sx(p[0]).toFixed(2) + ' ' + sy(p[1]).toFixed(2)).join('')}" fill="none" stroke="${s.color}" stroke-width="2"/>`;
      s.pts.forEach(p => { svg += `<circle cx="${sx(p[0])}" cy="${sy(p[1])}" r="3" fill="${s.color}"/>`; });
    });
    points.forEach(p => {
      svg += `<circle cx="${sx(p.x)}" cy="${sy(p.y)}" r="4.5" class="plot-point"/>`;
      if (p.label) svg += `<text class="plot-label" x="${sx(p.x) + 7}" y="${sy(p.y) - 7}">${esc(p.label)}</text>`;
    });
    svg += '</g>';
    const legend = fns.map(f => ({ name: f.label, color: f.color })).concat(series.map(s => ({ name: s.name, color: s.color })));
    // One curve needs a legend only when it was given a name (its raw expression is noise next to the title).
    const named = legend.length === 1 && (series.length || (fns[0] && fns[0].label !== fns[0].expr));
    if (legend.length > 1 || (named && spec.legend !== false)) {
      let ly = M.t + 8;
      svg += '<g class="plot-legend">';
      legend.forEach(l => {
        svg += `<rect x="${W - M.r - 170}" y="${ly - 9}" width="12" height="3" fill="${l.color}"/><text x="${W - M.r - 152}" y="${ly - 4}">${esc(l.name.length > 22 ? l.name.slice(0, 21) + '…' : l.name)}</text>`;
        ly += 16;
      });
      svg += '</g>';
    }
    if (spec.xlabel) svg += `<text class="plot-axislabel" x="${W - M.r}" y="${H - 4}" text-anchor="end">${esc(spec.xlabel)}</text>`;
    if (spec.ylabel) svg += `<text class="plot-axislabel" x="${M.l + 4}" y="${M.t + 12}">${esc(spec.ylabel)}</text>`;
    return svg + '</svg>';
  }

  window.Plot = { render, compile };
})();
