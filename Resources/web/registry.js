// Extension points for the transcript renderer. Component files register here; app.js (the core) calls them.
// Adding a feature = adding a file under components/ (the generated manifest picks it up) — the core does not change.
//
// Three registries, three vocabularies:
//   nodes      — semantic node renderers (text, thinking, tool, attachment, …): small, stable, owned by app.js
//   tools      — one descriptor per tool name (icon, title, summary, body, open/compact), with a generic default
//   components — rich blocks by name (chart, timeline, practice, visual, …): parse → validate → render, lazy-loadable
// The older registerFence / registerToolCard calls still work: they are adapters onto components and tools.
(function () {
  'use strict';
  const R = {
    fences: {},        // fence language -> (code, ctx, env) => html          (adapter view of components; see below)
    toolCards: {},     // tool name -> (block, result, pending, ctx) => html | null   (adapter view of tools[name].card)
    questionTypes: {}, // question type -> { render(q, qi, state, ctx), read(el, q, qi, state), review(q, grade, given, ctx) }
    processors: [],    // (rootElement, ctx) => void, run on freshly inserted DOM
    mdPlugins: [],     // (markdownIt) => void
    actions: {},       // data-act value -> (element, event, ctx) => void
    inputs: [],        // (event, ctx) => void for input/change events
    footers: [],       // (message, turnMessages, ctx) => html   rendered under a finished reply
    lessonHooks: [],   // () => void, when the page shows another lesson: components drop their per-page state
    nodes: {},         // node type -> { type, render(el, node, ctx, env), unmount(el, node) }
    tools: {},         // tool name -> descriptor (see defineTool)
    components: {},    // component name -> descriptor (see defineComponent)
    lazy: {},          // component name -> module src, for components whose module loads on first use
    registerQuestionType(names, impl) { [].concat(names).forEach(n => { this.questionTypes[n] = impl; }); },
    registerProcessor(fn) { this.processors.push(fn); },
    registerMarkdown(fn) { this.mdPlugins.push(fn); },
    registerAction(names, fn) { [].concat(names).forEach(n => { this.actions[n] = fn; }); },
    registerInput(fn) { this.inputs.push(fn); },
    registerFooter(fn) { this.footers.push(fn); },
    /** State a component keeps between renders (revealed answers, marks, outputs) belongs to one lesson: keyed by
     *  content, it would reappear in another lesson that shows the same fence. `fn` clears it on a lesson change. */
    onLessonChange(fn) { this.lessonHooks.push(fn); },

    /** A semantic node renderer: `render(el, node, ctx, env)` fills `el` for a node of `type`; `unmount(el, node)` runs
     *  when the node's element leaves the page (a trimmed lesson, a reset, a block that changed type). */
    defineNode(desc) {
      if (!desc || !desc.type || typeof desc.render !== 'function') throw new Error('defineNode needs type and render');
      this.nodes[desc.type] = Object.assign({ version: 1 }, desc);
      return desc;
    },

    /** A tool's presentation. `names` (or `name`): the tool name(s). Everything else is optional and falls back to the
     *  generic card: `icon`, `title` (string or node => string), `summary(node)`, `body(node, ctx)` (the opened card),
     *  `open(node)` (open by default), `compact` (a one-line card when closed), `card(block, result, pending, ctx)` (the
     *  whole card, as registerToolCard did; return null to fall back). Descriptors merge, so a module may add a body to a
     *  tool another module gave a card. */
    defineTool(desc) {
      const names = [].concat(desc.names || desc.name || []);
      if (!names.length) throw new Error('defineTool needs a name');
      names.forEach(n => {
        const cur = this.tools[n] || { name: n, version: 1 };
        this.tools[n] = Object.assign(cur, desc, { name: n, names: undefined });
        if (this.tools[n].card) this.toolCards[n] = this.tools[n].card;
      });
      return desc;
    },
    /** The descriptor for a tool, merged over the generic default (`R.tools.default` when a module defines one). */
    tool(name) {
      const base = this.tools.default || {};
      return Object.assign({}, base, this.tools[name] || { name, generic: true });
    },

    /** A component (a rich block the model writes as a fence, or the app renders by name).
     *  `names`: fence languages / component names. `render(props, ctx, env)` → html.
     *  `raw: true` hands `render` the fence text; otherwise the text is parsed as lenient JSON and checked with `validate`
     *  (`validate(props)` returns the props to render or throws; `schema` is a shape for R.check). On a parse or render
     *  error the core shows a readable fallback (`fallback(code, ctx, error)` when given), never a blank.
     *  `pending(ctx)` → html while the fence is still streaming; `prose: true` renders non-JSON text as markdown
     *  instead of an error (the model wrote the content itself). `styles`: CSS injected once, scoped by convention to
     *  the component's root class. */
    defineComponent(desc) {
      const names = [].concat(desc.names || desc.name || []);
      if (!names.length || typeof desc.render !== 'function') throw new Error('defineComponent needs names and render');
      const d = Object.assign({ version: 1 }, desc, { name: names[0], names });
      names.forEach(n => { this.components[n] = d; delete this.lazy[n]; });
      if (d.styles) this.injectStyles(d.name, d.styles);
      if (d.mount && d.selector) this.registerProcessor((root, ctx) => {
        const list = (root.matches && root.matches(d.selector) ? [root] : []).concat(Array.from(root.querySelectorAll(d.selector)));
        for (const el of list) { try { d.mount(el, ctx); } catch (e) { console.log('mount', d.name, e); } }
      });
      return d;
    },
    component(name) { return this.components[name] || null; },
    /** Declares that `names` come from `src`, loaded on first use (the manifest generator writes these). */
    defineLazy(names, src) { [].concat(names).forEach(n => { if (!this.components[n]) this.lazy[n] = src; }); },

    injectStyles(name, css) {
      if (document.querySelector('style[data-component="' + name + '"]')) return;
      const st = document.createElement('style'); st.setAttribute('data-component', name); st.textContent = css;
      document.head.appendChild(st);
    },

    // Adapters for the older API.
    registerFence(names, fn) {
      this.defineComponent({ names, raw: true, render: fn, legacy: true });
    },
    registerToolCard(names, fn) { this.defineTool({ names, card: fn }); },
  };
  // `R.fences[lang]` keeps working for readers (the core's fence rule, components that call each other).
  R.fences = new Proxy(R.fences, { get: (t, k) => { const d = typeof k === 'string' ? R.components[k] : null; return d && d.raw ? d.render : t[k]; },
    has: (t, k) => typeof k === 'string' && !!R.components[k] });

  /** A tiny shape check for component props: `{ type: 'object'|'array'|'string'|'number'|'boolean', required: [...],
   *  props: { key: shape | 'string' | 'array' … }, items: shape, min, max, enum }`. Throws a readable error. */
  R.check = function (value, shape, path) {
    path = path || 'props';
    if (typeof shape === 'string') shape = { type: shape };
    if (!shape) return value;
    const t = Array.isArray(value) ? 'array' : value === null ? 'null' : typeof value;
    if (shape.type && t !== shape.type && !(shape.type === 'number' && t === 'string' && value !== '' && !isNaN(+value))) {
      throw new Error(path + ' should be ' + (/^[aeiou]/.test(shape.type) ? 'an ' : 'a ') + shape.type + ', not ' + t);
    }
    if (shape.enum && !shape.enum.includes(value)) throw new Error(path + ' should be one of ' + shape.enum.join(', '));
    if (t === 'array') {
      if (shape.min != null && value.length < shape.min) throw new Error(path + ' needs at least ' + shape.min + ' item' + (shape.min === 1 ? '' : 's'));
      if (shape.max != null && value.length > shape.max) throw new Error(path + ' has more than ' + shape.max + ' items');
      if (shape.items) value.forEach((v, i) => R.check(v, shape.items, path + '[' + i + ']'));
    }
    if (t === 'object') {
      (shape.required || []).forEach(k => { if (value[k] == null) throw new Error(path + '.' + k + ' is required'); });
      if (shape.props) Object.keys(shape.props).forEach(k => { if (value[k] != null) R.check(value[k], shape.props[k], path + '.' + k); });
    }
    if (t === 'string' && shape.max != null && value.length > shape.max) throw new Error(path + ' is longer than ' + shape.max + ' characters');
    return value;
  };

  window.TeacherUI = R;

  // Lenient JSON for model-written component data: strict JSON first (fast path), then a small JSON5-style parser —
  // comments, unquoted keys, 'single' and “curly” quotes, trailing commas, NaN/Infinity, True/False/None, hex — and
  // text after the first complete value is ignored — or, with `{ all: true }`, every top-level value is returned as an
  // array (one object per line is how models often write a list). One pass, O(n).
  R.parseLoose = function (src, opts) {
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
    const first = value();
    if (!opts || !opts.all) return first;
    const out = [first];
    for (;;) {
      ws(); if (src[i] === ',') { i++; ws(); }
      if (i >= n || !/[[{]/.test(src[i])) return out;
      out.push(value());
    }
  };
})();
