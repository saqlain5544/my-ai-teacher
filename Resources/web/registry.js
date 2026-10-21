// Extension points for the transcript renderer. Component files register here; app.js (the core) calls them.
// Adding a feature = adding a file under components/ — the core does not change.
(function () {
  'use strict';
  const R = {
    fences: {},        // fence language -> (code, ctx, env) => html          (```chart, ```vocab, …)
    toolCards: {},     // tool name -> (block, result, pending, ctx) => html | null
    questionTypes: {}, // question type -> { render(q, qi, state, ctx), read(el, q, qi, state), review(q, grade, given, ctx) }
    processors: [],    // (rootElement, ctx) => void, run on freshly inserted DOM
    mdPlugins: [],     // (markdownIt) => void
    actions: {},       // data-act value -> (element, event, ctx) => void
    inputs: [],        // (event, ctx) => void for input/change events
    footers: [],       // (message, turnMessages, ctx) => html   rendered under a finished reply
    registerFence(names, fn) { [].concat(names).forEach(n => { this.fences[n] = fn; }); },
    registerToolCard(names, fn) { [].concat(names).forEach(n => { this.toolCards[n] = fn; }); },
    registerQuestionType(names, impl) { [].concat(names).forEach(n => { this.questionTypes[n] = impl; }); },
    registerProcessor(fn) { this.processors.push(fn); },
    registerMarkdown(fn) { this.mdPlugins.push(fn); },
    registerAction(names, fn) { [].concat(names).forEach(n => { this.actions[n] = fn; }); },
    registerInput(fn) { this.inputs.push(fn); },
    registerFooter(fn) { this.footers.push(fn); },
  };
  window.TeacherUI = R;

  // Lenient JSON for model-written component data: strict JSON first (fast path), then a small JSON5-style parser —
  // comments, unquoted keys, 'single' and “curly” quotes, trailing commas, NaN/Infinity, True/False/None, hex — and
  // text after the first complete value is ignored. One pass, O(n).
  R.parseLoose = function (src) {
    src = String(src);
    try { return JSON.parse(src); } catch (_) {}
    let i = 0;
    const n = src.length;
    const fail = msg => { const e = new Error('Invalid JSON: ' + msg + ' at ' + i); throw e; };
    const ws = () => {
      for (;;) {
        while (i < n && /[\s\u00a0\ufeff]/.test(src[i])) i++;
        if (src[i] === '/' && src[i + 1] === '/') { while (i < n && src[i] !== '\n') i++; continue; }
        if (src[i] === '/' && src[i + 1] === '*') { const e = src.indexOf('*/', i + 2); i = e < 0 ? n : e + 2; continue; }
        if (src[i] === '#') { while (i < n && src[i] !== '\n') i++; continue; }
        return;
      }
    };
    const CLOSE = { '"': '"', "'": "'", '“': '”', '”': '”', '‘': '’', '’': '’', '`': '`' };
    const str = () => {
      const q = src[i], end = CLOSE[q]; i++;
      let out = '';
      while (i < n && src[i] !== end && !(q === '“' && src[i] === '“')) {
        let c = src[i++];
        if (c === '\\') {
          const e = src[i++];
          if (e === 'u') { out += String.fromCharCode(parseInt(src.substr(i, 4), 16)); i += 4; continue; }
          c = { n: '\n', t: '\t', r: '\r', b: '\b', f: '\f', '\n': '' }[e] ?? e;
        }
        out += c;
      }
      if (i >= n) fail('unterminated string');
      i++;
      return out;
    };
    const word = () => { const m = /^[A-Za-z_$\u00c0-\uffff][\w$\u00c0-\uffff-]*/.exec(src.slice(i, i + 200)); if (!m) fail('unexpected ' + JSON.stringify(src[i])); i += m[0].length; return m[0]; };
    const value = () => {
      ws();
      const c = src[i];
      if (c === '{') {
        i++; const o = {};
        for (;;) {
          ws(); if (src[i] === '}') { i++; return o; }
          const k = CLOSE[src[i]] ? str() : /[\d-]/.test(src[i]) ? String(num()) : word();
          ws(); if (src[i] === ':' || src[i] === '=') i++; else fail('expected :');
          o[k] = value(); ws();
          if (src[i] === ',' || src[i] === ';') { i++; continue; }
          if (src[i] === '}') { i++; return o; }
          if (i >= n) return o;   // unclosed at the end: keep what we have
          fail('expected , or }');
        }
      }
      if (c === '[') {
        i++; const a = [];
        for (;;) {
          ws(); if (src[i] === ']') { i++; return a; }
          if (i >= n) return a;
          a.push(value()); ws();
          if (src[i] === ',') { i++; continue; }
          if (src[i] === ']') { i++; return a; }
          if (i >= n) return a;
          fail('expected , or ]');
        }
      }
      if (CLOSE[c]) return str();
      if (/[\d+.-]/.test(c)) return num();
      const w = word();
      const lit = { true: true, True: true, false: false, False: false, null: null, None: null, NaN: null, Infinity: null, undefined: null };
      if (w in lit) return lit[w];
      return w;   // a bare word is a string (models write  {type: bar})
    };
    const num = () => {
      const m = /^[+-]?(0x[\da-f]+|(\d+\.?\d*|\.\d+)(e[+-]?\d+)?|Infinity)/i.exec(src.slice(i, i + 64));
      if (!m) fail('bad number');
      i += m[0].length;
      const v = /^[+-]?0x/i.test(m[0]) ? parseInt(m[0], 16) : Number(m[0]);
      return Number.isFinite(v) ? v : null;
    };
    ws();
    if (i >= n) fail('empty');
    // Prose before the data ("Here is the chart: {…}"): start at the first bracket.
    if (!/[[{"'“‘\d-]/.test(src[i])) { const j = src.search(/[[{]/); if (j < 0) fail('no data'); i = j; }
    return value();
  };
})();
