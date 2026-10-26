// Views that show what code does, for code lessons (the code mentor's branch of the agent tree):
//   ```trace    — a stepper: the line about to run, every frame's variables (changes lit, shared objects badged), output
//                 so far, a note per step. The `trace` tool's card is the same stepper over a real Python run.
//   ```annotate — code with numbered notes pinned to its lines (a walkthrough of their code or a library's).
//   ```predict  — read the code, write what it prints, then compare line by line (attempt first: no Run button).
// The `bench` tool's card charts timings over input sizes with the fitted growth.
// State (the step shown, a prediction) lives here, keyed by block, so re-renders while streaming never reset it.
(function () {
  'use strict';
  const R = window.TeacherUI;
  const traces = new Map();   // data-key -> normalized trace
  const state = new Map();    // data-key -> { step } | { text, checked, gaveUp, sent }
  R.onLessonChange(() => { state.clear(); });
  const S = (k, init) => { let s = state.get(k); if (!s) { s = Object.assign({}, init); state.set(k, s); } return s; };

  /** highlight.js output split into lines, each with its open spans closed and reopened (a string or comment that spans
   *  lines keeps its colour). */
  function lines(code, lang, ctx) {
    const html = ctx.highlight ? ctx.highlight(code, lang || '') : ctx.esc(code);
    const out = []; let cur = '', open = [];
    const re = /(<span[^>]*>)|(<\/span>)|(\n)|([^<\n]+|<)/g; let m;
    while ((m = re.exec(html))) {
      if (m[1]) { open.push(m[1]); cur += m[1]; }
      else if (m[2]) { open.pop(); cur += m[2]; }
      else if (m[3]) { out.push(cur + '</span>'.repeat(open.length)); cur = open.join(''); }
      else cur += m[4];
    }
    out.push(cur + '</span>'.repeat(open.length));
    return out;
  }
  const codeLines = (code, lang, ctx, start, extra) => lines(code, lang, ctx).map((h, i) =>
    '<div class="cl-line" data-l="' + (i + start) + '"><span class="cl-ln">' + (i + start) + '</span>' + (extra ? extra(i + start) : '') + '<code>' + (h || ' ') + '</code></div>').join('');

  // ── Trace ───────────────────────────────────────────────────────────────
  const val = v => v == null ? { v: 'None', t: '' } : typeof v === 'object' && !Array.isArray(v) && 'v' in v ? { v: String(v.v), t: v.t || '', r: v.r } : { v: typeof v === 'string' ? v : JSON.stringify(v), t: '' };
  const vars = o => { const out = {}; Object.keys(o || {}).forEach(k => { out[k] = val(o[k]); }); return out; };

  /** The tool's trace (short keys, output offsets) or a hand-written one ({language, code, steps:[{line, vars | stack,
   *  out, note}]}) → { files, lang, steps:[{f, l, e, s:[{fn, f, l, v}], out, ret, exc, note}], error, truncated }. */
  function normalize(spec) {
    const files = spec.files || { [spec.file || 'main']: String(spec.code || '') };
    const first = Object.keys(files)[0];
    const output = typeof spec.output === 'string' ? spec.output : null;
    let lastOut = '';
    const steps = (spec.steps || []).map(st => {
      const f = st.f || st.file || first, l = +(st.l || st.line) || 1;
      const s = st.s ? st.s.map(fr => ({ fn: fr.fn || '', f: fr.f || f, l: fr.l || l, v: vars(fr.v), b: fr.b }))
        : st.stack ? st.stack.map(fr => ({ fn: fr.fn || fr.name || '', f, l, v: vars(fr.vars || fr.v) }))
        : [{ fn: '', f, l, v: vars(st.vars || st.v) }];
      if (typeof st.out === 'string') lastOut = st.out;
      const out = output != null && st.o != null ? output.slice(0, st.o) : lastOut;
      return { f, l, e: st.e || 'line', s, out, ret: st.ret ? val(st.ret) : null, exc: st.exc || null, note: st.note || '' };
    });
    if (!steps.length) throw new Error('a trace needs steps: [{"line", "vars", "note"}]');
    return { files, lang: spec.language || spec.lang || (spec.files ? 'python' : ''), steps, error: spec.error || null, truncated: !!spec.truncated, title: spec.title };
  }

  function stepper(spec, ctx, key) {
    const t = normalize(spec);
    traces.set(key, t);
    const multi = Object.keys(t.files).length > 1;
    const files = Object.keys(t.files).map(name => '<div class="tr-file" data-file="' + ctx.esc(name) + '">' + (multi ? '<div class="tr-fname">' + ctx.esc(name) + '</div>' : '') +
      '<div class="tr-src">' + codeLines(t.files[name], /\.py$/.test(name) ? 'python' : t.lang, ctx, 1) + '</div></div>').join('');
    const n = t.steps.length;
    return '<div class="comp trace" tabindex="0" data-key="' + key + '" data-n="' + n + '">' +
      '<div class="tr-head"><b>' + R.icon('play') + ctx.esc(t.title || 'Step through') + '</b><span class="tr-pos"></span></div>' +
      '<div class="tr-body"><div class="tr-code">' + files + '</div><div class="tr-state"><div class="tr-frames"></div>' +
      '<div class="tr-out"><span class="label">Output</span><pre></pre></div></div></div>' +
      '<div class="tr-banner" hidden></div><div class="tr-note md" hidden></div>' +
      '<div class="tr-ctrl"><button class="btn" data-act="tr-go" data-to="first" title="First step">⏮</button><button class="btn" data-act="tr-go" data-to="prev">◀ Back</button>' +
      '<input type="range" class="tr-range" min="0" max="' + (n - 1) + '" value="0" aria-label="Step">' +
      '<button class="btn primary" data-act="tr-go" data-to="next">Next ▶</button><button class="btn" data-act="tr-go" data-to="last" title="Last step">⏭</button></div></div>';
  }

  function frameHTML(fr, before, esc) {
    const keys = Object.keys(fr.v);
    const rows = keys.map(k => {
      const v = fr.v[k], changed = before && (!before.v[k] || before.v[k].v !== v.v);
      return '<tr class="' + (changed ? 'chg' : '') + (v.t === 'function' || v.t === 'class' ? ' def' : '') + '"><td>' + esc(k) + '</td><td><code>' + esc(v.v) + '</code>' +
        (v.r ? '<span class="tr-ref" data-ref="' + v.r + '" title="Same badge = same object">#' + v.r + '</span>' : '') + '</td></tr>';
    }).join('');
    const name = fr.fn === '<module>' || !fr.fn ? (fr.fn ? 'Global' : 'Variables') : fr.fn + (fr.b ? ' (class body)' : '()');
    return '<div class="tr-frame"><div class="tr-fn">' + esc(name) + '<span>' + esc(fr.f) + ':' + fr.l + '</span></div>' +
      (rows ? '<table>' + rows + '</table>' : '<div class="tr-empty">no variables yet</div>') + '</div>';
  }

  function applyTrace(el, ctx) {
    const key = el.getAttribute('data-key'), t = traces.get(key);
    if (!t) return;
    const s = S(key, { step: 0 }), n = t.steps.length;
    s.step = Math.max(0, Math.min(n - 1, s.step));
    const st = t.steps[s.step], prev = s.step > 0 ? t.steps[s.step - 1] : null;
    el.querySelector('.tr-pos').textContent = 'Step ' + (s.step + 1) + ' of ' + n + (st.e === 'end' ? ' · finished' : '');
    el.querySelectorAll('.tr-file').forEach(f => { f.hidden = f.getAttribute('data-file') !== st.f && el.querySelectorAll('.tr-file').length > 1; });
    el.querySelectorAll('.cl-line.cur, .cl-line.ran').forEach(l => l.classList.remove('cur', 'ran'));
    const file = Array.from(el.querySelectorAll('.tr-file')).find(f => f.getAttribute('data-file') === st.f) || el.querySelector('.tr-file');
    const cur = file && file.querySelector('.cl-line[data-l="' + st.l + '"]');
    if (prev && prev.f === st.f && prev.l !== st.l) { const ran = file.querySelector('.cl-line[data-l="' + prev.l + '"]'); if (ran) ran.classList.add('ran'); }
    if (cur) {
      cur.classList.add('cur');
      const box = file.querySelector('.tr-src');
      if (box && (cur.offsetTop < box.scrollTop || cur.offsetTop + cur.offsetHeight > box.scrollTop + box.clientHeight)) box.scrollTop = Math.max(0, cur.offsetTop - box.clientHeight / 3);
    }
    // Changes are against the same frame (depth and function) in the step before.
    el.querySelector('.tr-frames').innerHTML = st.s.slice().reverse().map((fr, i, all) => {
      const depth = all.length - 1 - i, was = prev && prev.s[depth] && prev.s[depth].fn === fr.fn ? prev.s[depth] : null;
      return frameHTML(fr, prev ? was : null, ctx.esc);
    }).join('');
    const out = el.querySelector('.tr-out pre');
    out.textContent = st.out || '';
    el.querySelector('.tr-out').classList.toggle('empty', !st.out);
    const banner = el.querySelector('.tr-banner');
    const text = st.e === 'return' && st.ret ? '↩ ' + (st.s.length ? st.s[st.s.length - 1].fn : '') + ' returned ' + st.ret.v
      : st.e === 'exception' ? '⚠ raised ' + st.exc
      : st.e === 'end' ? (t.error ? '⚠ ' + t.error : t.truncated ? 'Stopped at the step limit' : '✓ Program finished') : '';
    banner.hidden = !text; banner.textContent = text;
    banner.className = 'tr-banner' + (st.e === 'exception' || (st.e === 'end' && t.error) ? ' bad' : st.e === 'end' ? ' good' : '');
    const note = el.querySelector('.tr-note');
    note.hidden = !st.note; note.innerHTML = st.note ? ctx.inline(st.note) : '';
    el.querySelector('.tr-range').value = String(s.step);
    el.querySelector('[data-to="prev"]').disabled = el.querySelector('[data-to="first"]').disabled = s.step === 0;
    el.querySelector('[data-to="next"]').disabled = el.querySelector('[data-to="last"]').disabled = s.step === n - 1;
  }

  function go(el, to, ctx) {
    const key = el.getAttribute('data-key'), s = S(key, { step: 0 }), n = +el.getAttribute('data-n');
    s.step = to === 'first' ? 0 : to === 'last' ? n - 1 : to === 'next' ? s.step + 1 : to === 'prev' ? s.step - 1 : +to;
    applyTrace(el, ctx);
  }
  R.registerAction('tr-go', (b, e, ctx) => go(b.closest('.comp.trace'), b.getAttribute('data-to'), ctx));
  R.registerInput((e, ctx) => { const r = e.target.closest && e.target.closest('.tr-range'); if (r) go(r.closest('.comp.trace'), r.value, ctx); });
  document.addEventListener('keydown', e => {
    const el = e.target.closest && e.target.closest('.comp.trace');
    if (!el || e.target.matches('input, textarea') || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') { e.preventDefault(); go(el, e.key === 'ArrowRight' ? 'next' : 'prev', R._ctx); }
  });
  // Shared objects: pointing at one badge lights every name bound to the same object.
  document.addEventListener('mouseover', e => {
    const b = e.target.closest && e.target.closest('.tr-ref');
    const el = e.target.closest && e.target.closest('.comp.trace');
    if (!el) return;
    el.querySelectorAll('.tr-ref.same').forEach(x => x.classList.remove('same'));
    if (b) el.querySelectorAll('.tr-ref[data-ref="' + b.getAttribute('data-ref') + '"]').forEach(x => x.classList.add('same'));
  });

  R.defineComponent({ names: ['trace', 'stepper', 'step-through'], version: 1, selector: '.comp.trace', mount: (el, ctx) => applyTrace(el, ctx || R._ctx),
    pending: () => '<div class="comp"><div class="diagram-pending">Building the stepper…</div></div>',
    validate: spec => { R.check(spec, 'object'); return spec; },
    render: (spec, ctx, env) => stepper(spec, ctx, 'tr' + ctx.hash(env.code)) });

  R.defineTool({ name: 'trace', icon: 'play', tone: 'blue', title: 'Step through',
    summary: n => { const m = (n.props.result && n.props.result.meta) || {}; return m.steps ? m.steps.length + ' steps' + (m.error ? ' · ' + m.error.split(':')[0] : '') : 'Python'; },
    open: n => !!(n.props.result && n.props.result.meta && n.props.result.meta.steps),
    body(n, ctx) {
      const m = (n.props.result && n.props.result.meta) || null;
      if (!m || !m.steps) return n.props.output ? ctx.pre(n.props.output) : '';
      try { return stepper(m, ctx, 'trt' + ctx.hash(n.props.callId || JSON.stringify(m.files))); }
      catch (e) { return ctx.pre(n.props.output || e.message); }
    } });

  // ── Annotate ────────────────────────────────────────────────────────────
  /** "3", 3, "3-5", [3, 5], "3,7" → the line numbers a note covers. */
  function range(v) {
    if (Array.isArray(v)) return v.length === 2 && +v[1] > +v[0] + 1 ? range(v[0] + '-' + v[1]) : v.map(Number).filter(x => x > 0);
    const out = [];
    String(v == null ? '' : v).split(',').forEach(part => {
      const m = part.trim().match(/^(\d+)\s*[-–]\s*(\d+)$/);
      if (m) { for (let i = +m[1]; i <= Math.min(+m[2], +m[1] + 400); i++) out.push(i); }
      else if (+part > 0) out.push(+part);
    });
    return out;
  }

  R.defineComponent({ names: ['annotate', 'annotated', 'walkthrough'], version: 1,
    pending: () => '<div class="comp"><div class="diagram-pending">Annotating…</div></div>',
    validate: spec => {
      R.check(spec, 'object');
      if (!String(spec.code || '').trim()) throw new Error('needs "code" and "notes": [{"lines":"3-5","text":"…"}]');
      return spec;
    },
    render(spec, ctx, env) {
      const start = Math.max(1, +spec.start || 1), key = 'an' + ctx.hash(env.code);
      const notes = (Array.isArray(spec.notes) ? spec.notes : Object.keys(spec.notes || {}).map(k => ({ lines: k, text: spec.notes[k] })))
        .map(nt => ({ lines: range(nt.lines != null ? nt.lines : nt.line != null ? nt.line : nt.at), text: String(nt.text || nt.note || '') }))
        .filter(nt => nt.lines.length && nt.text);
      const owner = {}, firstOf = {};
      notes.forEach((nt, i) => { nt.lines.forEach(l => { if (owner[l] == null) owner[l] = i; }); if (firstOf[nt.lines[0]] == null) firstOf[nt.lines[0]] = i; });
      const body = codeLines(String(spec.code).replace(/\n$/, ''), spec.language || spec.lang, ctx, start,
        l => firstOf[l] != null ? '<button class="an-mark" data-act="an-pick" data-n="' + firstOf[l] + '">' + (firstOf[l] + 1) + '</button>' : '<span class="an-mark-gap"></span>');
      return '<div class="comp annotate" data-key="' + key + '">' +
        ((spec.title || spec.file) ? '<div class="an-head">' + (spec.title ? '<b>' + ctx.esc(spec.title) + '</b>' : '') + (spec.file ? '<code>' + ctx.esc(spec.file) + '</code>' : '') + '</div>' : '') +
        '<div class="an-body"><div class="an-code">' + body + '</div><ol class="an-notes">' +
        notes.map((nt, i) => '<li data-n="' + i + '" data-lines="' + nt.lines.join(',') + '" data-act="an-pick"><span class="an-num">' + (i + 1) + '</span><span class="an-at">' +
          (nt.lines.length > 1 ? 'lines ' + nt.lines[0] + '–' + nt.lines[nt.lines.length - 1] : 'line ' + nt.lines[0]) + '</span><div class="md">' + ctx.inline(nt.text) + '</div></li>').join('') +
        '</ol></div></div>';
    } });

  function pick(el, i) {
    el.querySelectorAll('.cl-line.hl, .an-notes li.sel, .an-mark.sel').forEach(x => x.classList.remove('hl', 'sel'));
    const li = el.querySelector('.an-notes li[data-n="' + i + '"]');
    if (!li) return;
    li.classList.add('sel');
    const ls = li.getAttribute('data-lines').split(',');
    ls.forEach(l => { const line = el.querySelector('.cl-line[data-l="' + l + '"]'); if (line) line.classList.add('hl'); });
    const mark = el.querySelector('.an-mark[data-n="' + i + '"]'); if (mark) mark.classList.add('sel');
    const first = el.querySelector('.cl-line[data-l="' + ls[0] + '"]'), box = el.querySelector('.an-code');
    if (first && box && (first.offsetTop < box.scrollTop || first.offsetTop > box.scrollTop + box.clientHeight - 30)) box.scrollTop = Math.max(0, first.offsetTop - 20);
  }
  R.registerAction('an-pick', b => pick(b.closest('.comp.annotate'), b.getAttribute('data-n')));

  // ── Predict the output ──────────────────────────────────────────────────
  const outLines = s => String(s == null ? '' : s).replace(/\r/g, '').split('\n').map(l => l.replace(/\s+$/, '')).join('\n').replace(/\n+$/, '').split('\n');

  R.defineComponent({ names: ['predict', 'predict-output', 'whatprints'], version: 1,
    pending: () => '<div class="comp"><div class="diagram-pending">Setting a prediction…</div></div>',
    validate: spec => {
      if (Array.isArray(spec)) spec = spec[0] || {};
      R.check(spec, 'object');
      if (!String(spec.code || '').trim() || spec.output == null) throw new Error('needs "code" and the "output" it prints (run it first)');
      return spec;
    },
    render(spec, ctx, env) {
      const key = 'pd' + ctx.hash(env.code);
      return '<div class="comp predict" data-key="' + key + '" data-out="' + ctx.esc(String(spec.output)) + '">' +
        '<div class="pd-head"><b>' + R.icon('target') + ctx.esc(spec.title || 'Predict the output') + '</b><span>Read it, then write what it prints, exactly</span></div>' +
        (spec.q ? '<div class="pd-q md">' + ctx.inline(String(spec.q)) + '</div>' : '') +
        ctx.code(String(spec.code), spec.language || spec.lang || '') +
        '<textarea class="q-text pd-text" rows="3" spellcheck="false" placeholder="What it prints, line by line…"></textarea>' +
        '<div class="pd-actions"><button class="btn primary" data-act="pd-check" disabled>Check</button><button class="btn link" data-act="pd-give">Show me</button></div>' +
        '<div class="pd-result" hidden></div>' +
        (spec.explain ? '<div class="pd-explain md" hidden>' + ctx.md(String(spec.explain)) + '</div>' : '') + '</div>';
    } });

  function applyPredict(el, ctx) {
    const key = el.getAttribute('data-key'), s = S(key, { text: '', checked: false, gaveUp: false, sent: false });
    const ta = el.querySelector('.pd-text');
    if (ta.value !== s.text && document.activeElement !== ta) ta.value = s.text;
    const done = s.checked || s.gaveUp;
    ta.readOnly = done;
    el.querySelector('[data-act="pd-check"]').disabled = done || !s.text.trim();
    el.querySelector('[data-act="pd-check"]').hidden = done;
    el.querySelector('[data-act="pd-give"]').hidden = done;
    const res = el.querySelector('.pd-result'), ex = el.querySelector('.pd-explain');
    res.hidden = !done; if (ex) ex.hidden = !done;
    if (!done) return;
    const want = outLines(el.getAttribute('data-out')), got = s.gaveUp ? [] : outLines(s.text);
    const n = Math.max(want.length, got.length);
    let right = 0;
    const rows = Array.from({ length: n }, (_, i) => {
      const ok = got[i] === want[i]; if (ok) right++;
      return '<tr class="' + (s.gaveUp ? '' : ok ? 'ok' : 'bad') + '">' + (s.gaveUp ? '' : '<td>' + (ok ? '✓' : '✗') + '</td><td><code>' + ctx.esc(got[i] == null ? '' : got[i]) + '</code></td>') +
        '<td><code>' + ctx.esc(want[i] == null ? '' : want[i]) + '</code></td></tr>';
    }).join('');
    const exact = !s.gaveUp && right === n;
    res.innerHTML = '<div class="pd-verdict ' + (s.gaveUp ? '' : exact ? 'good' : 'bad') + '">' + (s.gaveUp ? 'The output:' : exact ? '✓ Exactly right' : right + ' of ' + n + ' lines match') + '</div>' +
      '<table class="pd-table">' + (s.gaveUp ? '' : '<tr><th></th><th>You</th><th>It printed</th></tr>') + rows + '</table>' +
      (!exact ? '<button class="btn" data-act="pd-why"' + (s.sent ? ' disabled' : '') + '>' + (s.sent ? 'Asked ✓' : 'Why does it print that?') + '</button>' : '');
  }
  const pdHost = b => b.closest('.comp.predict');
  R.registerInput((e, ctx) => {
    const ta = e.target.closest && e.target.closest('.pd-text'); if (!ta) return;
    const el = pdHost(ta); S(el.getAttribute('data-key'), { text: '' }).text = ta.value;
    el.querySelector('[data-act="pd-check"]').disabled = !ta.value.trim();
  });
  R.registerAction('pd-check', (b, e, ctx) => { const el = pdHost(b), s = S(el.getAttribute('data-key'), {}); s.checked = true; applyPredict(el, ctx); });
  R.registerAction('pd-give', (b, e, ctx) => { const el = pdHost(b), s = S(el.getAttribute('data-key'), {}); s.gaveUp = true; applyPredict(el, ctx); });
  R.registerAction('pd-why', (b, e, ctx) => {
    const el = pdHost(b), s = S(el.getAttribute('data-key'), {});
    if (s.sent) return;
    const code = (el.querySelector('.code-block code') || {}).textContent || '';
    ctx.post({ type: 'suggest', text: (s.gaveUp ? 'I couldn\'t predict what this prints' : 'I predicted it prints:\n' + s.text.trim() + '\n\nbut it printed:\n' + el.getAttribute('data-out').trim()) +
      '\n\nfor:\n```\n' + code.trim().slice(0, 1200) + '\n```\nWhy?' });
    s.sent = true; applyPredict(el, ctx);
  });
  R.registerProcessor((root, ctx) => {
    (root.matches && root.matches('.comp.predict') ? [root] : []).concat(Array.from(root.querySelectorAll('.comp.predict'))).forEach(el => applyPredict(el, ctx || R._ctx));
  });

  // ── bench: timings over input sizes ─────────────────────────────────────
  const COLORS = ['#2f6fec', '#e5484d', '#30a46c', '#f76b15', '#8e4ec6', '#0d9488'];
  const fmtN = v => v >= 1e6 ? (v / 1e6) + 'M' : v >= 1e3 ? (v / 1e3) + 'k' : String(v);
  const fmtT = s => { const ms = s * 1000; return ms >= 100 ? ms.toFixed(0) + ' ms' : ms >= 1 ? ms.toFixed(1) + ' ms' : (ms * 1000).toFixed(ms * 1000 >= 10 ? 0 : 1) + ' µs'; };

  function benchChart(m, log) {
    const W = 560, H = 260, M = { l: 62, r: 14, t: 12, b: 36 };
    const sizes = m.sizes || [], series = (m.series || []).map((s, i) => ({ name: s.name, c: COLORS[i % COLORS.length], pts: sizes.map((n, j) => [n, s.times[j]]).filter(p => p[1] != null && p[1] > 0) }));
    const all = series.flatMap(s => s.pts);
    if (!all.length) return '';
    const tx = v => log ? Math.log10(v) : v;
    const xs = sizes.map(tx), ys = all.map(p => tx(p[1]));
    const x0 = Math.min(...xs), x1 = Math.max(...xs), y0 = log ? Math.min(...ys) : 0, y1 = Math.max(...ys);
    const sx = v => M.l + (tx(v) - x0) / ((x1 - x0) || 1) * (W - M.l - M.r), sy = v => H - M.b - (tx(v) - y0) / ((y1 - y0) || 1) * (H - M.t - M.b);
    let svg = '<svg class="bench-svg" viewBox="0 0 ' + W + ' ' + H + '" role="img">';
    const ticks = log ? Array.from({ length: Math.floor(y1) - Math.ceil(y0) + 1 }, (_, i) => Math.pow(10, Math.ceil(y0) + i)) : [0, 0.25, 0.5, 0.75, 1].map(f => f * Math.max(...all.map(p => p[1])));
    ticks.forEach(v => { if (log && v <= 0) return; const y = sy(log ? v : v || 1e-12); svg += '<line class="grid" x1="' + M.l + '" x2="' + (W - M.r) + '" y1="' + y + '" y2="' + y + '"/><text class="tick" x="' + (M.l - 6) + '" y="' + (y + 4) + '" text-anchor="end">' + (v ? fmtT(v) : '0') + '</text>'; });
    // Size labels that would collide (small n on a linear axis) give way, from the largest down.
    let lastX = Infinity;
    sizes.slice().reverse().forEach(n => { const x = sx(n); if (lastX - x < 34) return; lastX = x; svg += '<text class="tick" x="' + x + '" y="' + (H - M.b + 16) + '" text-anchor="middle">' + fmtN(n) + '</text>'; });
    svg += '<text class="tick" x="' + ((W + M.l) / 2) + '" y="' + (H - 4) + '" text-anchor="middle">input size n</text>';
    series.forEach(s => {
      svg += '<path d="' + s.pts.map((p, i) => (i ? 'L' : 'M') + sx(p[0]).toFixed(1) + ',' + sy(p[1]).toFixed(1)).join('') + '" fill="none" stroke="' + s.c + '" stroke-width="2.2"/>';
      s.pts.forEach(p => { svg += '<circle cx="' + sx(p[0]).toFixed(1) + '" cy="' + sy(p[1]).toFixed(1) + '" r="3.2" fill="' + s.c + '"><title>' + s.name + ': n=' + p[0] + ', ' + fmtT(p[1]) + '</title></circle>'; });
    });
    return svg + '</svg>';
  }

  R.defineTool({ name: 'bench', icon: 'activity', tone: 'green', title: 'Timings',
    summary: n => { const m = (n.props.result && n.props.result.meta) || {}; return (m.series || []).map(s => s.name + (s.fit ? ' ' + s.fit : '')).join(' · ') || (n.props.input && n.props.input.language) || ''; },
    open: n => !!(n.props.result && n.props.result.meta && n.props.result.meta.series),
    body(n, ctx) {
      const m = (n.props.result && n.props.result.meta) || null;
      if (!m || !m.series) return n.props.output ? ctx.pre(n.props.output) : '';
      const key = 'bn' + ctx.hash(n.props.callId || JSON.stringify(m));
      const log = !!S(key, { log: false }).log;
      return '<div class="bench" data-key="' + key + '"><div class="bench-legend">' + m.series.map((s, i) => '<span><i data-c="' + COLORS[i % COLORS.length] + '"></i>' + ctx.esc(s.name) +
        (s.fit ? ' <b>' + ctx.esc(s.fit) + '</b>' : '') + '</span>').join('') +
        '<button class="btn link" data-act="bench-log">' + (log ? 'Linear scale' : 'Log scale') + '</button></div>' + benchChart(m, log) + '</div>';
    } });
  R.registerAction('bench-log', (b, e, ctx) => {
    const box = b.closest('.bench'); const s = S(box.getAttribute('data-key'), { log: false }); s.log = !s.log;
    const card = b.closest('[data-tool-id]'); if (card && ctx.refreshCard) ctx.refreshCard(card.getAttribute('data-tool-id'));
  });
  R.registerProcessor(root => { root.querySelectorAll && root.querySelectorAll('.bench-legend i[data-c]').forEach(i => { i.style.background = i.getAttribute('data-c'); }); });

  R.injectStyles('codelab', `
    .cl-line { display: flex; align-items: baseline; min-height: 1.45em; }
    .cl-line code, .md .cl-line > code { font-family: var(--mono); background: none; border: 0; border-radius: 0; padding: 0 6px 0 0; white-space: pre; font-size: .86em; }
    .cl-ln { flex: none; width: 2.6em; padding-right: 8px; text-align: right; color: var(--muted); font-size: .76em; user-select: none; font-variant-numeric: tabular-nums; }
    .comp.trace [hidden], .comp.predict [hidden] { display: none !important; }   /* .btn and flex rows set display */
    .comp.trace, .comp.annotate { container-type: inline-size; }
    .comp.trace { padding: 10px 12px; outline: none; }
    .comp.trace:focus-visible { box-shadow: 0 0 0 2px var(--accent-soft, rgba(47,111,236,.35)); }
    .tr-head, .an-head, .pd-head { display: flex; justify-content: space-between; align-items: baseline; gap: 10px; flex-wrap: wrap; margin-bottom: 8px; }
    .tr-head b, .pd-head b { display: inline-flex; align-items: center; gap: 6px; }
    .tr-pos, .pd-head span { color: var(--muted); font-size: .85em; font-variant-numeric: tabular-nums; }
    .tr-body { display: grid; grid-template-columns: minmax(0, 1.25fr) minmax(0, 1fr); gap: 10px; }
    @container (max-width: 560px) { .tr-body, .an-body { grid-template-columns: 1fr; } }
    .tr-code { border: 1px solid var(--border); border-radius: 8px; overflow: hidden; }
    .tr-fname { font-size: .78em; color: var(--muted); padding: 4px 8px; border-bottom: 1px solid var(--border); font-family: var(--mono, monospace); }
    .tr-src, .an-code { max-height: 340px; overflow: auto; padding: 4px 0; position: relative; }
    .cl-line.cur { background: color-mix(in srgb, #f5b100 26%, transparent); box-shadow: inset 3px 0 0 #f5b100; }
    .cl-line.ran { background: color-mix(in srgb, var(--accent, #2f6fec) 9%, transparent); }
    .tr-state { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
    .tr-frames { display: flex; flex-direction: column; gap: 6px; }
    .tr-frame { border: 1px solid var(--border); border-radius: 8px; padding: 4px 8px 6px; }
    .tr-frame:first-child { border-color: color-mix(in srgb, #f5b100 60%, var(--border)); }
    .tr-fn { font-weight: 600; font-size: .86em; display: flex; justify-content: space-between; gap: 8px; }
    .tr-fn span { color: var(--muted); font-weight: 400; font-size: .9em; }
    .tr-frame table { width: 100%; font-size: .84em; margin: 2px 0 0; border: 0; }
    .tr-frame td { padding: 1px 4px; border: 0; vertical-align: top; }
    .tr-frame td:first-child { color: var(--muted); width: 32%; word-break: break-all; }
    .tr-frame td code { background: none; padding: 0; word-break: break-all; }
    .tr-frame tr.chg td { background: color-mix(in srgb, var(--good, #30a46c) 16%, transparent); }
    .tr-frame tr.def td { opacity: .6; }
    .tr-empty { color: var(--muted); font-size: .82em; }
    .tr-ref { margin-left: 6px; font-size: .74em; padding: 0 5px; border-radius: 8px; background: color-mix(in srgb, var(--accent, #2f6fec) 16%, transparent); cursor: default; }
    .tr-ref.same { background: var(--accent, #2f6fec); color: #fff; }
    .tr-out { border: 1px solid var(--border); border-radius: 8px; padding: 4px 8px; }
    .tr-out .label { font-size: .74em; color: var(--muted); text-transform: uppercase; letter-spacing: .04em; }
    .tr-out pre { margin: 2px 0 0; font-size: .84em; white-space: pre-wrap; max-height: 120px; overflow: auto; background: none; padding: 0; }
    .tr-out.empty pre::before { content: 'nothing yet'; color: var(--muted); }
    .tr-banner { margin-top: 8px; font-size: .88em; padding: 4px 8px; border-radius: 6px; background: color-mix(in srgb, var(--accent, #2f6fec) 10%, transparent); }
    .tr-banner.good { background: var(--good-soft); } .tr-banner.bad { background: var(--bad-soft); }
    .tr-note { margin-top: 8px; font-size: .92em; border-left: 3px solid var(--accent, #2f6fec); padding: 2px 10px; }
    .tr-ctrl { display: flex; align-items: center; gap: 6px; margin-top: 10px; }
    .tr-range { flex: 1; min-width: 60px; }
    .comp.annotate { padding: 10px 12px; }
    .an-head code { color: var(--muted); font-size: .85em; }
    .an-body { display: grid; grid-template-columns: minmax(0, 1.3fr) minmax(0, 1fr); gap: 12px; align-items: start; }
    .an-code { border: 1px solid var(--border); border-radius: 8px; max-height: 420px; }
    .an-mark, .an-mark-gap { flex: none; width: 20px; margin-right: 4px; }
    .an-mark { height: 18px; border-radius: 9px; border: 0; padding: 0; font-size: .72em; font-weight: 600; cursor: pointer; color: #fff; background: var(--accent, #2f6fec); }
    .an-mark.sel { box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent, #2f6fec) 40%, transparent); }
    .cl-line.hl { background: color-mix(in srgb, var(--accent, #2f6fec) 14%, transparent); }
    .an-notes { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 6px; }
    .an-notes li { border: 1px solid var(--border); border-radius: 8px; padding: 6px 8px; cursor: pointer; font-size: .92em; }
    .an-notes li.sel { border-color: var(--accent, #2f6fec); background: color-mix(in srgb, var(--accent, #2f6fec) 6%, transparent); }
    .an-num { display: inline-flex; width: 18px; height: 18px; border-radius: 9px; align-items: center; justify-content: center; font-size: .75em; font-weight: 600; color: #fff; background: var(--accent, #2f6fec); margin-right: 6px; }
    .an-at { color: var(--muted); font-size: .8em; }
    .an-notes .md { margin-top: 3px; }
    .comp.predict { padding: 10px 12px; }
    .pd-q { margin-bottom: 6px; }
    .pd-text { width: 100%; font-family: var(--mono, monospace); margin-top: 8px; }
    .pd-actions { display: flex; gap: 8px; align-items: center; margin-top: 6px; }
    .pd-result { margin-top: 8px; }
    .pd-verdict { font-weight: 600; margin-bottom: 4px; } .pd-verdict.good { color: var(--good); } .pd-verdict.bad { color: var(--bad); }
    .pd-table { font-size: .86em; margin-bottom: 6px; }
    .pd-table td, .pd-table th { padding: 2px 8px; }
    .pd-table tr.ok td:first-child { color: var(--good); } .pd-table tr.bad td:first-child { color: var(--bad); }
    .pd-table tr.bad td:nth-child(2) code { text-decoration: line-through; text-decoration-color: var(--bad); }
    .pd-explain { margin-top: 6px; border-left: 3px solid var(--accent, #2f6fec); padding: 2px 10px; }
    .bench-legend { display: flex; flex-wrap: wrap; gap: 12px; align-items: center; font-size: .86em; margin-bottom: 4px; }
    .bench-legend i { display: inline-block; width: 10px; height: 10px; border-radius: 3px; margin-right: 5px; vertical-align: -1px; }
    .bench-legend .btn { margin-left: auto; }
    .bench-svg { width: 100%; height: auto; max-height: 300px; }
    .bench-svg .grid { stroke: var(--border); stroke-width: 1; }
    .bench-svg .tick { fill: var(--muted); font-size: 11px; }
  `);
})();
