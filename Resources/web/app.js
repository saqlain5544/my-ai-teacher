// Transcript renderer core for My AI Teacher. Swift drives it through window.T.*; it talks back via the `bridge` handler.
// Features plug in through window.TeacherUI (registry.js): nodes.js is the typed view of a message the renderer walks,
// components/*.js the rich blocks, components/tools/*.js the tool cards; components/manifest.js lists the modules.
(function () {
  'use strict';
  const R = window.TeacherUI;
  const thread = document.getElementById('thread');
  const statusEl = document.getElementById('status');
  const jumpEl = document.getElementById('jump');
  const post = (msg) => { if (window.__onPost) window.__onPost(msg); try { window.webkit.messageHandlers.bridge.postMessage(msg); } catch (e) { console.log('bridge', JSON.stringify(msg).slice(0, 200)); } };
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const hash = (s) => { let h = 2166136261 >>> 0; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return (h >>> 0).toString(36); };
  const darkMQ = window.matchMedia('(prefers-color-scheme: dark)');
  // Render caches are bounded by entries AND characters (one huge diagram or code block can't hold the page's memory),
  // oldest out first; `T.dropCaches` empties them all when the app is short of memory.
  const caches = [];
  class Cache extends Map {
    constructor(maxEntries, maxChars) { super(); this.maxEntries = maxEntries; this.maxChars = maxChars; this.chars = 0; caches.push(this); }
    static size(v) { return typeof v === 'string' ? v.length : v && typeof v.svg === 'string' ? v.svg.length : 64; }
    set(k, v) {
      this.delete(k);
      super.set(k, v); this.chars += Cache.size(v);
      for (const old of super.keys()) { if (this.size <= this.maxEntries && this.chars <= this.maxChars) break; this.delete(old); }
      return this;
    }
    delete(k) { if (!super.has(k)) return false; this.chars -= Cache.size(super.get(k)); return super.delete(k); }
    clear() { this.chars = 0; super.clear(); }
  }

  // ───────────────────────── State ─────────────────────────
  const S = {
    messages: [], byId: new Map(), results: new Map(), pending: new Map(), armedAt: new Map(), armMs: 700, progress: new Map(), cards: new Map(),
    openTools: new Set(), codeOutputs: new Map(), codeEpoch: 0, dirty: new Set(), streamingId: null, welcome: null,
    running: false, showThinking: true,
  };

  // ───────────────────────── Markdown ─────────────────────────
  const md = window.markdownit({ html: true, linkify: true, typographer: false, breaks: false });
  if (window.markdownitFootnote) md.use(window.markdownitFootnote);
  md.use(mathPlugin);
  md.use(taskLists);
  R.mdPlugins.forEach(p => p(md));
  md.renderer.rules.fence = (tokens, idx, opts, env) => renderFence(tokens[idx], idx, tokens, env);
  md.renderer.rules.code_block = (tokens, idx, opts, env) => renderCode(tokens[idx].content, '', env);
  // HTML the model writes may use plain tags (<span lang>, <ruby>, <details>, <b>…) but never the attributes the app's
  // own UI relies on: no style/class/id (no faking KaTeX or overlaying fake UI), no data-* (no app buttons), no on*.
  // Tokens the renderer creates itself are marked trusted.
  const UNSAFE_ATTR = /\s(?:style|class|id|data-[\w-]*|on\w+|slot|is|popover\w*|form\w*)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/gi;
  const cleanHTML = s => s.replace(/<[a-zA-Z][^>]*>/g, tag => tag.replace(UNSAFE_ATTR, ''));
  md.renderer.rules.html_inline = (tokens, idx) => tokens[idx].meta && tokens[idx].meta.trusted ? tokens[idx].content : cleanHTML(tokens[idx].content);
  md.renderer.rules.html_block = (tokens, idx) => cleanHTML(tokens[idx].content);
  md.linkify.set({ fuzzyEmail: false });

  const katexCache = new Cache(4000, 2e6);
  // KaTeX lacks the packages models write with (siunitx units, physics shorthands, \label/\ref): an unknown command
  // isn't an error box, it prints raw and red inside the formula. Fixed-arity ones are macros; the rest, whose meaning
  // depends on what follows, are rewritten by texCompat first.
  const U = (s) => s;   // unit symbols are plain text inside \mathrm{…}
  const katexMacros = {
    '\\RR': '\\mathbb{R}', '\\NN': '\\mathbb{N}', '\\ZZ': '\\mathbb{Z}', '\\QQ': '\\mathbb{Q}', '\\CC': '\\mathbb{C}',
    // physics
    '\\abs': '\\left\\lvert #1\\right\\rvert', '\\norm': '\\left\\lVert #1\\right\\rVert', '\\vb': '\\mathbf{#1}', '\\vu': '\\hat{\\mathbf{#1}}',
    '\\va': '\\vec{#1}', '\\dd': '\\mathrm{d}', '\\grad': '\\nabla', '\\curl': '\\nabla\\times', '\\laplacian': '\\nabla^2', '\\cross': '\\times',
    '\\vdot': '\\cdot', '\\tr': '\\operatorname{tr}', '\\Tr': '\\operatorname{Tr}', '\\rank': '\\operatorname{rank}', '\\erf': '\\operatorname{erf}',
    '\\Res': '\\operatorname{Res}', '\\order': '\\mathcal{O}\\left(#1\\right)', '\\comm': '\\left[#1,#2\\right]', '\\acomm': '\\left\\{#1,#2\\right\\}',
    '\\mel': '\\left\\langle #1\\middle\\vert #2\\middle\\vert #3\\right\\rangle',
    // siunitx (\qty and \num in texCompat)
    '\\SI': '#1\\,\\mathrm{#2}', '\\si': '\\mathrm{#1}', '\\unit': '\\mathrm{#1}', '\\ang': '#1^{\\circ}', '\\celsius': '{}^{\\circ}\\mathrm{C}',
    '\\degreeCelsius': '{}^{\\circ}\\mathrm{C}', '\\per': U('/'), '\\squared': '^{2}', '\\cubed': '^{3}', '\\percent': '\\%',
    '\\pico': U('p'), '\\nano': U('n'), '\\micro': '\\mu', '\\milli': U('m'), '\\centi': U('c'), '\\deci': U('d'), '\\kilo': U('k'),
    '\\mega': U('M'), '\\giga': U('G'), '\\tera': U('T'), '\\metre': U('m'), '\\meter': U('m'), '\\gram': U('g'), '\\kilogram': U('kg'),
    '\\second': U('s'), '\\minute': U('min'), '\\hour': U('h'), '\\ampere': U('A'), '\\kelvin': U('K'), '\\mole': U('mol'), '\\candela': U('cd'),
    '\\newton': U('N'), '\\joule': U('J'), '\\watt': U('W'), '\\pascal': U('Pa'), '\\hertz': U('Hz'), '\\volt': U('V'), '\\ohm': '\\Omega',
    '\\coulomb': U('C'), '\\farad': U('F'), '\\tesla': U('T'), '\\weber': U('Wb'), '\\litre': U('L'), '\\liter': U('L'), '\\electronvolt': U('eV'),
    '\\angstrom': '\\text{Å}', '\\becquerel': U('Bq'), '\\siemens': U('S'), '\\lux': U('lx'),
    // A chat has no equation numbering: a label disappears, a reference reads as its name.
    '\\label': ctx => { ctx.consumeArgs(1); return ''; }, '\\eqref': '\\text{(#1)}', '\\ref': '\\text{#1}',
  };
  /** One balanced `{…}` group at i (spaces skipped): [content, index after it], or null. */
  function brace(s, i) {
    while (s[i] === ' ') i++;
    if (s[i] !== '{') return null;
    for (let d = 0, k = i; k < s.length; k++) {
      if (s[k] === '\\') { k++; continue; }
      if (s[k] === '{') d++;
      else if (s[k] === '}' && --d === 0) return [s.slice(i + 1, k), k + 1];
    }
    return null;
  }
  function braces(s, i, max) { const out = []; for (let g; out.length < max && (g = brace(s, i)); ) { out.push(g[0]); i = g[1]; } return [out, i]; }
  /** The closing bracket matching s[i] (( [ |), or -1. */
  function closing(s, i) {
    const open = s[i], close = { '(': ')', '[': ']', '|': '|' }[open];
    for (let d = 0, k = i; k < s.length; k++) {
      if (s[k] === '\\') { k++; continue; }
      if (open !== '|' && s[k] === open) d++;
      else if (s[k] === close && (open === '|' ? k > i : --d === 0)) return k;
    }
    return -1;
  }
  const D = '\\mathrm{d}';
  function texCompat(src) {
    src = src.replace(/\\newcommand\b/g, '\\providecommand')   // redefining a built-in (\R) is an error in KaTeX
      .replace(/\\DeclareMathOperator(\*?)\s*\{\s*(\\[A-Za-z]+)\s*\}\s*\{([^{}]*)\}/g, (m, star, cmd, name) => '\\providecommand{' + cmd + '}{\\operatorname' + star + '{' + name + '}}');
    if (!/\\(?:qty|dv|pdv|expval|braket|eval|num)(?![A-Za-z])/.test(src)) return src;
    let out = '', i = 0;
    const re = /\\(qty|dv|pdv|expval|braket|eval|num)(?![A-Za-z])/g;
    for (let m; (m = re.exec(src)); ) {
      const cmd = m[1], at = m.index + m[0].length;
      let rep = null, end = at;
      if (cmd === 'qty') {
        let j = at; while (src[j] === ' ') j++;
        const c = closing(src, j);
        if ('([|'.includes(src[j]) && c > 0) {
          const L = { '(': '(', '[': '[', '|': '\\vert' }[src[j]], R = { '(': ')', '[': ']', '|': '\\vert' }[src[j]];
          rep = '\\left' + L + texCompat(src.slice(j + 1, c)) + '\\right' + R; end = c + 1;
        } else {
          const [g, e] = braces(src, at, 2);
          if (g.length === 2) { rep = texCompat(g[0]) + '\\,\\mathrm{' + g[1] + '}'; end = e; }        // siunitx \qty{3}{m}
          else if (g.length === 1) { rep = '\\left\\{' + texCompat(g[0]) + '\\right\\}'; end = e; }
        }
      } else if (cmd === 'dv' || cmd === 'pdv') {
        const d = cmd === 'dv' ? D : '\\partial ';   // the space: "\partial" + "x" would read as \partialx
        let j = at, n = '';
        const opt = /^\s*\[([^\]]*)\]/.exec(src.slice(j)); if (opt) { n = opt[1]; j += opt[0].length; }
        const [g, e] = braces(src, j, 3), pow = n ? '^{' + n + '}' : '';
        if (g.length === 1) rep = '\\frac{' + d + pow + '}{' + d + texCompat(g[0]) + pow + '}';
        else if (g.length === 2) rep = '\\frac{' + d + pow + ' ' + texCompat(g[0]) + '}{' + d + texCompat(g[1]) + pow + '}';
        else if (g.length === 3) rep = '\\frac{' + d + '^{2} ' + texCompat(g[0]) + '}{' + d + texCompat(g[1]) + '\\,' + d + texCompat(g[2]) + '}';
        if (rep) end = e;
      } else if (cmd === 'expval') {
        const [g, e] = braces(src, at, 2);
        if (g.length === 1) rep = '\\left\\langle ' + texCompat(g[0]) + '\\right\\rangle';
        else if (g.length === 2) rep = '\\left\\langle ' + g[1] + '\\middle\\vert ' + texCompat(g[0]) + '\\middle\\vert ' + g[1] + '\\right\\rangle';
        if (rep) end = e;
      } else if (cmd === 'braket') {
        const [g, e] = braces(src, at, 2);   // one argument is KaTeX's own \braket{φ|ψ}
        if (g.length === 2) { rep = '\\left\\langle ' + texCompat(g[0]) + '\\middle\\vert ' + texCompat(g[1]) + '\\right\\rangle'; end = e; }
      } else if (cmd === 'eval') {
        const [g, e] = braces(src, at, 1);
        if (g.length === 1) { rep = '\\left. ' + texCompat(g[0]) + '\\right\\vert'; end = e; }
      } else if (cmd === 'num') {
        const [g, e] = braces(src, at, 1);
        if (g.length === 1) { rep = g[0].replace(/^\s*([-+]?[\d.]+)\s*[eE]\s*([-+]?\d+)\s*$/, '$1\\times10^{$2}'); end = e; }
      }
      if (rep === null) continue;
      out += src.slice(i, m.index) + rep; i = end; re.lastIndex = end;
    }
    return out + src.slice(i);
  }
  function tex(src, display) {
    src = texCompat(src);
    const key = (display ? 'D' : 'I') + src;
    let html = katexCache.get(key);
    if (html === undefined) {
      try { html = katex.renderToString(src, { displayMode: display, throwOnError: false, strict: 'ignore', output: 'htmlAndMathml', macros: katexMacros, trust: false }); }
      catch (e) { html = '<span class="math-error">' + esc(src) + '</span>'; }
      katexCache.set(key, html);
    }
    return display ? '<div class="math-display">' + html + '</div>' : '<span class="math-inline">' + html + '</span>';
  }

  function mathPlugin(md) {
    md.inline.ruler.before('escape', 'math_inline', (state, silent) => {
      const src = state.src, pos = state.pos, ch = src[pos];
      if (ch === '\\') {
        const n = src[pos + 1];
        if (n !== '(' && n !== '[') return false;
        const close = n === '(' ? '\\)' : '\\]';
        const end = src.indexOf(close, pos + 2);
        if (end < 0) return false;
        if (!silent) { const t = state.push('math_inline', 'math', 0); t.content = src.slice(pos + 2, end); t.markup = n === '[' ? 'display' : ''; }
        state.pos = end + 2; return true;
      }
      if (ch !== '$') return false;
      if (src[pos + 1] === '$') {
        const end = src.indexOf('$$', pos + 2);
        if (end < 0) return false;
        if (!silent) { const t = state.push('math_inline', 'math', 0); t.content = src.slice(pos + 2, end); t.markup = 'display'; }
        state.pos = end + 2; return true;
      }
      const next = src[pos + 1];
      if (!next || /\s/.test(next)) return false;
      let end = pos + 1;
      while ((end = src.indexOf('$', end)) >= 0) {
        if (src[end - 1] === '\\') { end++; continue; }
        if (/\s/.test(src[end - 1])) { end++; continue; }
        if (/\d/.test(src[end + 1] || '')) { end++; continue; }
        break;
      }
      if (end < 0) return false;
      const content = src.slice(pos + 1, end);
      if (!content.trim() || /\n\s*\n/.test(content)) return false;
      if (!silent) { const t = state.push('math_inline', 'math', 0); t.content = content; }
      state.pos = end + 1; return true;
    });
    md.block.ruler.before('fence', 'math_block', (state, start, end, silent) => {
      let pos = state.bMarks[start] + state.tShift[start], max = state.eMarks[start];
      const line = state.src.slice(pos, max);
      let open, close;
      if (line.startsWith('$$')) { open = '$$'; close = '$$'; }
      else if (line.startsWith('\\[')) { open = '\\['; close = '\\]'; }
      else return false;
      if (silent) return true;
      let first = line.slice(open.length), content = '', next = start, found = false;
      if (first.trim().endsWith(close) && first.trim().length >= close.length) { content = first.trim().slice(0, -close.length); found = true; }
      else {
        content = first;
        while (++next < end) {
          pos = state.bMarks[next] + state.tShift[next]; max = state.eMarks[next];
          const l = state.src.slice(pos, max);
          if (l.trim().endsWith(close)) { content += '\n' + l.trim().slice(0, -close.length); found = true; break; }
          content += '\n' + state.src.slice(state.bMarks[next], max);
        }
      }
      if (!found && !state.env.streaming) return false;
      state.line = next + 1;
      const t = state.push('math_block', 'math', 0);
      t.block = true; t.content = content; t.map = [start, state.line]; t.meta = { open: !found };
      return true;
    }, { alt: ['paragraph', 'reference', 'blockquote', 'list'] });
    md.renderer.rules.math_inline = (tokens, idx) => tex(tokens[idx].content, tokens[idx].markup === 'display');
    md.renderer.rules.math_block = (tokens, idx) => tokens[idx].meta && tokens[idx].meta.open
      ? '<div class="math-display"><span class="diagram-pending">' + esc(tokens[idx].content) + '</span></div>'
      : tex(tokens[idx].content, true);
  }

  function taskLists(md) {
    md.core.ruler.after('inline', 'tasks', state => {
      const toks = state.tokens;
      for (let i = 2; i < toks.length; i++) {
        const t = toks[i];
        if (t.type !== 'inline' || toks[i - 1].type !== 'paragraph_open' || toks[i - 2].type !== 'list_item_open') continue;
        const m = /^\[([ xX])\]\s/.exec(t.content);
        if (!m || !t.children.length) continue;
        t.children[0].content = t.children[0].content.replace(/^\[[ xX]\]\s/, '');
        const box = new state.Token('html_inline', '', 0);
        box.content = '<input type="checkbox" disabled' + (m[1] !== ' ' ? ' checked' : '') + '>';
        box.meta = { trusted: true };
        t.children.unshift(box);
        toks[i - 2].attrJoin('class', 'task-list-item');
      }
    });
  }

  // ───────────────────────── Fences ─────────────────────────
  const RUNNABLE = new Set(['python', 'py', 'python3', 'javascript', 'js', 'node', 'typescript', 'ts', 'swift', 'c', 'cpp', 'c++', 'go', 'golang', 'rust', 'rs', 'ruby', 'rb', 'bash', 'sh', 'zsh', 'shell', 'java', 'zig']);
  const ALIAS = { js: 'javascript', ts: 'typescript', py: 'python', python3: 'python', rb: 'ruby', sh: 'bash', zsh: 'bash', shell: 'bash', console: 'bash', 'c++': 'cpp', cs: 'csharp', 'c#': 'csharp', kt: 'kotlin', rs: 'rust', golang: 'go', yml: 'yaml', md: 'markdown', html: 'xml', svg: 'xml', tex: 'latex', ps1: 'powershell', objc: 'objectivec', hs: 'haskell', ex: 'elixir', exs: 'elixir', erl: 'erlang', ml: 'ocaml', fs: 'fsharp', jl: 'julia', asm: 'x86asm', docker: 'dockerfile', make: 'makefile', proto: 'protobuf', vb: 'vbnet', clj: 'clojure', scm: 'scheme', el: 'lisp', tsx: 'typescript', jsx: 'javascript', mjs: 'javascript', cjs: 'javascript', h: 'c', hpp: 'cpp', m: 'objectivec', pl: 'perl', text: 'plaintext', txt: 'plaintext',
    // Languages highlight.js lacks: grammars of ours in langs/ (zig, solidity, hcl, gleam, odin, cobol), the rest by kinship.
    zon: 'zig', sol: 'solidity', terraform: 'hcl', tf: 'hcl', tfvars: 'hcl', opentofu: 'hcl', cob: 'cobol', cbl: 'cobol',
    toml: 'ini', pascal: 'delphi', pas: 'delphi', racket: 'scheme', rkt: 'scheme', cuda: 'cpp', cu: 'cpp', hlsl: 'cpp',
    metal: 'cpp', svelte: 'xml', vue: 'xml', mojo: 'python', fish: 'bash', ksh: 'bash', 'objective-c': 'objectivec' };
  const OWN_LANGS = ['zig', 'solidity', 'hcl', 'gleam', 'odin', 'cobol'];
  const hlCache = new Cache(2000, 4e6);
  const loadingLangs = new Set();
  const codeSources = new Cache(1500, 4e6);

  function highlight(code, lang) {
    const key = lang + '\u0000' + code;
    const hit = hlCache.get(key);
    if (hit) return hit;
    let out = null;
    const name = ALIAS[lang] || lang;
    if (name && name !== 'plaintext') {
      if (hljs.getLanguage(name)) { try { out = hljs.highlight(code, { language: name, ignoreIllegals: true }).value; } catch (_) {} }
      else if (OWN_LANGS.includes(name) || (window.HLJS_LANGS && window.HLJS_LANGS.includes(name))) loadLang(name);
    }
    if (out === null) return esc(code);
    hlCache.set(key, out);
    return out;
  }
  function loadLang(name) {
    if (loadingLangs.has(name)) return;
    loadingLangs.add(name);
    const s = document.createElement('script');
    s.src = OWN_LANGS.includes(name) ? 'langs/' + name + '.js' : 'vendor/hljs/languages/' + name + '.min.js';
    s.onload = () => document.querySelectorAll('.code-block[data-lang]').forEach(el => {
      const l = el.getAttribute('data-lang'); if ((ALIAS[l] || l) !== name) return;
      const c = el.querySelector('code'); const src = codeSources.get(el.getAttribute('data-key'));
      if (c && src != null) c.innerHTML = highlight(src, l);
    });
    document.head.appendChild(s);
  }

  function renderCode(code, lang, env) {
    code = code.replace(/\n$/, '');
    const key = 'c' + hash(lang + '|' + code);
    codeSources.set(key, code);
    const l = (lang || '').toLowerCase();
    const runnable = RUNNABLE.has(l) && !(env && env.streamingFence);
    // An open fence is re-rendered on every frame: highlighting the whole (growing) code each time is quadratic. Short
    // snippets still get colours; long ones stay plain until they close.
    const plain = env && env.live && code.length > 1600;
    const out = S.codeOutputs.get(key);
    return '<div class="code-block" dir="ltr" data-key="' + key + '" data-lang="' + esc(l) + '">' +
      '<div class="code-head"><span class="lang">' + esc(l || 'text') + '</span><span>' +
      (runnable ? '<button class="run" data-act="run">▶ Run</button>' : '') + '<button data-act="copy-code">Copy</button></span></div>' +
      '<pre><code class="hljs">' + (plain ? esc(code) : highlight(code, l)) + '</code></pre>' +
      (out ? '<div class="code-output' + (out.failed ? ' failed' : '') + '"><span class="label">Output</span>' + esc(out.text) + '</div>' : '') + '</div>';
  }

  const mermaidSvg = new Cache(300, 4e6), mermaidSrc = new Cache(600, 2e6);
  let mermaidLoading = null, mermaidSeq = 0;
  /** A component the reply ended inside of: what arrived, folded, instead of an error. */
  function unfinished(lang, code) {
    return '<details class="visual-source comp-unfinished"><summary>The ' + esc(lang) + ' stopped before it finished — show what arrived</summary>' +
      renderCode(code, '', { streamingFence: true }) + '</details>';
  }
  function renderFence(tok, idx, tokens, env) {
    // The language is the first word, without punctuation models add: ```visual: ```{chart} ```Mermaid, ```python3.
    const info = (tok.info || '').trim(), raw = info.split(/\s+/)[0];
    const lang = raw.replace(/^[{.(\[]+|[}:;,.)\]]+$/g, '').toLowerCase();
    let code = tok.content;
    // Models sometimes put a component's JSON on the fence line itself (```steps [{"title":…}]): that is its content.
    const rest = info.slice(raw.length).trim();
    const known = !!(R.components[lang] || R.lazy[lang]);
    if (rest && /^[\[{]/.test(rest) && known) code = rest + '\n' + code;
    else if (rest && !code.trim() && !known) code = rest;   // ```python print(1)```: the code is on the fence line
    const isLastOpen = env.streaming && env.openFence && idx === env.lastFenceIdx;
    // A stray or mid-line fence leaves an empty block: show nothing rather than an empty code box.
    if (!code.trim() && !isLastOpen) return '';
    // Reasoning drafts components (```visual, ```mermaid, quizzes): in a thinking block they are text, never live widgets
    // (a draft visual rendered there as a blank full-height frame where the reasoning should be).
    if (env.plain) return '<pre class="thinking-code"><code>' + esc(code.replace(/\n$/, '')) + '</code></pre>';
    // The reply ended inside this fence: a forgotten closing fence on complete content renders as usual, but content cut
    // off mid-way (stopped, or the token limit) shows what arrived instead of a parse error.
    const unclosed = !env.streaming && env.openFence && idx === env.lastFenceIdx;
    if (lang === 'ui') { const out = renderUI(code, isLastOpen, unclosed); if (out != null) return out; }
    const custom = R.components[lang];
    if (custom) {
      const out = renderComponent(custom, lang, code, isLastOpen, unclosed);
      if (out != null) return out;
    } else if (R.lazy[lang]) {
      loadComponent(lang);
      return '<div class="comp comp-loading" data-lazy="' + esc(lang) + '"><div class="diagram-pending">Loading ' + esc(lang) + '…</div></div>';
    }
    if (lang === 'mermaid' || lang === 'mmd') {
      const key = 'm' + hash(code.trim() + (darkMQ.matches ? 'd' : 'l'));
      mermaidSrc.set(key, code);
      const tools = '<div class="diagram-tools"><button data-act="copy-src" data-src-key="' + key + '">Copy source</button></div>';
      if (isLastOpen) return '<div class="mermaid-block" data-key="' + key + '-p"><div class="diagram-pending">Drawing diagram…</div></div>';
      const done = mermaidSvg.get(key);
      if (done && done.error) return unclosed ? unfinished(lang, code) : '<div class="mermaid-block" data-key="' + key + '">' + tools + '<div class="diagram-error">Diagram error: ' + esc(done.error) + '<pre>' + esc(code) + '</pre></div></div>';
      // The SVG never passes through the HTML sanitizer (it strips Mermaid's <style> and <foreignObject> labels, leaving
      // blank boxes): this is a placeholder that processMermaid fills, from the cache at once or after drawing.
      return '<div class="mermaid-block" data-key="' + key + '" data-pending="1"' + (unclosed ? ' data-unfinished="1"' : '') + '>' + (done ? '' : '<div class="diagram-pending">Drawing diagram…</div>') + '</div>';
    }
    if ((lang === 'svg' || ((lang === 'xml' || lang === 'html') && /^\s*<svg[\s>]/.test(code))) && !isLastOpen) {
      return '<div class="svg-block" data-key="s' + hash(code) + '">' + DOMPurify.sanitize(code, { USE_PROFILES: { svg: true, svgFilters: true }, ALLOW_DATA_ATTR: false, FORBID_ATTR: ['class', 'id'] }) + '</div>';
    }
    if (lang === 'math' || lang === 'katex') return tex(code.trim().replace(/^\$\$([\s\S]*)\$\$$/, '$1').replace(/^\\\[([\s\S]*)\\\]$/, '$1'), true);
    // Models usually write interactive widgets (sliders, selects, canvases) as ```html: run them like a ```visual, in
    // the sandbox, with the source one click away. Plain markup examples stay code.
    if ((lang === 'html' || lang === 'htm') && R.fences.visual && /<(script|canvas)\b/i.test(code)) {
      if (isLastOpen) return R.fences.visual(code, ctx, { open: true });
      return '<div class="html-live">' + R.fences.visual(code, ctx, {}) +
        '<details class="visual-source"><summary>Show HTML</summary>' + renderCode(code, 'html', { streamingFence: true }) + '</details></div>';
    }
    return renderCode(code, lang, isLastOpen ? { streamingFence: true, live: true } : env);
  }

  // ── Components: the one path every rich block takes ──
  const compError = (name, e, code) => '<div class="comp comp-error"><div class="diagram-error">' + esc(name) + ': ' + esc((e && e.message) || e) + (code != null ? '<pre>' + esc(code) + '</pre>' : '') + '</div></div>';
  const compPending = name => '<div class="comp"><div class="diagram-pending">Building ' + esc(name) + '…</div></div>';
  /** Parse (lenient JSON unless `raw`), validate (`schema`, `validate`), render — inside an error boundary: a component
   *  that throws shows a readable box with its source, never a blank or a broken reply. `null` means "not mine": the
   *  fence falls through to a code block. */
  function renderComponent(d, lang, code, open, unclosed) {
    try {
      if (d.raw) {
        const out = d.render(code, ctx, { open, lang });
        if (out == null) return null;
        return unclosed && /comp-error|diagram-error/.test(out) ? unfinished(lang, code) : out;
      }
      if (open) return d.pending ? d.pending(ctx, lang) : compPending(lang);
      let props;
      try { props = d.parse ? d.parse(code, ctx) : R.parseLoose(code); }
      catch (e) {
        // Prose instead of a spec (the model wrote the content itself): show it as written, not an error.
        if (d.prose && !/^\s*[\[{]/.test(code)) return '<div class="comp md" data-key="tx' + hash(code) + '">' + markdown(code, false) + '</div>';
        throw e;
      }
      return renderProps(d, lang, props, code, unclosed);
    } catch (e) {
      if (unclosed) return unfinished(lang, code);
      return d.fallback ? d.fallback(code, ctx, e) : compError(lang, e, code);
    }
  }
  function renderProps(d, lang, props, code, unclosed) {
    try {
      if (d.schema) R.check(props, d.schema);
      if (d.validate) { const v = d.validate(props, ctx); if (v !== undefined) props = v; }
      const out = d.render(props, ctx, { code, lang });
      return out == null ? null : out;
    } catch (e) {
      if (unclosed) return unfinished(lang, code);
      return d.fallback ? d.fallback(code, ctx, e) : compError(lang, e, code);
    }
  }
  /** ```ui {"component": "chart", "props": {…}}: a component by name. Unknown names render their props readably. */
  function renderUI(code, open, unclosed) {
    if (open) return compPending('component');
    let spec;
    try { spec = R.parseLoose(code); } catch (e) { return unclosed ? unfinished('ui', code) : compError('ui', e, code); }
    const name = spec && typeof spec === 'object' ? String(spec.component || spec.type || spec.name || '') : '';
    const props = spec && spec.props !== undefined ? spec.props : spec;
    const d = R.components[name];
    if (!d) {
      if (R.lazy[name]) { loadComponent(name); return '<div class="comp comp-loading" data-lazy="' + esc(name) + '"><div class="diagram-pending">Loading ' + esc(name) + '…</div></div>'; }
      return '<div class="comp comp-unknown"><div class="label">' + (name ? esc(name) : 'component') + '</div><pre>' + esc(JSON.stringify(props, null, 2)) + '</pre></div>';
    }
    if (d.raw) return renderComponent(d, name, typeof props === 'string' ? props : JSON.stringify(props), false, unclosed);
    return renderProps(d, name, props, code, unclosed);
  }
  // A lazy module (components/manifest.js marks them) loads the first time a reply uses one of its components; the
  // placeholder is replaced when every message renders again. A module that fails, or doesn't define the name, leaves
  // the fence to the code-block fallback.
  const loadingModules = new Set();
  function loadComponent(name) {
    const src = R.lazy[name];
    if (!src || loadingModules.has(src)) return;
    loadingModules.add(src);
    const done = ok => {
      Object.keys(R.lazy).forEach(k => { if (R.lazy[k] === src && (!ok || !R.components[k])) delete R.lazy[k]; });
      invalidate();
    };
    if (R.loadModule) R.loadModule(src).then(done, () => done(false));
    else { const s = document.createElement('script'); s.src = src; s.onload = () => done(true); s.onerror = () => done(false); document.head.appendChild(s); }
  }
  /** Rendered HTML is stale (a theme change, a module that just loaded): every message renders again on the next frame. */
  function invalidate() {
    mdCache.clear(); segCache.clear();
    for (const m of S.messages) {
      const r = S.byId.get(m.id); if (!r || !r.el) continue;
      r.el.querySelectorAll('.md').forEach(n => { n._src = null; n._segs = null; });
      r.el.querySelectorAll('[data-tool-id]').forEach(n => { n._sig = null; });
      schedule(m.id);
    }
  }

  // Diagrams in the app's own palette (light/dark), rounded, roomy, system font — not Mermaid's stock look.
  function mermaidConfig() {
    const dark = darkMQ.matches;
    const P = dark
      ? { bg: '#1e1e20', node: '#232b3d', border: '#5b8def', text: '#ececee', line: '#8b919c', c2: '#3b2c22', c3: '#1f3529', cluster: '#25252a', clusterB: '#3a3a42', note: '#3a3422',
          scale: ['#2c4a8a', '#7a3b52', '#2f6b4f', '#7a5a1f', '#4b3b8a', '#1f6670', '#8a3f2c', '#5b6b2a', '#6b2f6b', '#2f5b8a', '#8a6a2f', '#3b6b6b'] }
      : { bg: '#ffffff', node: '#eef3ff', border: '#7aa2f0', text: '#1d1d1f', line: '#8a8f98', c2: '#fdf0e6', c3: '#eaf7ef', cluster: '#f7f7fa', clusterB: '#e3e3ea', note: '#fff6d6',
          scale: ['#dbe7ff', '#ffdfe7', '#d9f2e3', '#fff0cc', '#e7e0ff', '#d6f2f4', '#ffe2d6', '#eef3d2', '#f6dcf6', '#dcebff', '#fbe9d0', '#dff0ee'] };
    const vars = {
      fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif', fontSize: '15px', darkMode: dark,
      background: P.bg, primaryColor: P.node, primaryBorderColor: P.border, primaryTextColor: P.text, secondaryColor: P.c2, tertiaryColor: P.c3,
      lineColor: P.line, textColor: P.text, mainBkg: P.node, nodeBorder: P.border, clusterBkg: P.cluster, clusterBorder: P.clusterB,
      edgeLabelBackground: P.bg, titleColor: P.text, noteBkgColor: P.note, noteTextColor: P.text, noteBorderColor: P.clusterB,
      actorBkg: P.node, actorBorder: P.border, actorTextColor: P.text, signalColor: P.line, signalTextColor: P.text, labelBoxBkgColor: P.node,
      pie1: P.scale[0], pie2: P.scale[1], pie3: P.scale[2], pie4: P.scale[3], pie5: P.scale[4], pie6: P.scale[5], pieStrokeColor: P.bg, pieOuterStrokeWidth: '0px',
      pieTitleTextColor: P.text, pieSectionTextColor: P.text, pieLegendTextColor: P.text,
    };
    P.scale.forEach((c, i) => { vars['cScale' + i] = c; vars['cScaleLabel' + i] = P.text; });
    return {
      startOnLoad: false, securityLevel: 'strict', theme: 'base', look: 'neo', themeVariables: vars, suppressErrorRendering: true,
      fontFamily: vars.fontFamily,
      flowchart: { htmlLabels: true, curve: 'basis', padding: 14, nodeSpacing: 44, rankSpacing: 52, useMaxWidth: true },
      sequence: { mirrorActors: false, actorMargin: 56, boxMargin: 8, messageFontSize: 14, noteFontSize: 13, useMaxWidth: true },
      state: { useMaxWidth: true }, er: { useMaxWidth: true }, gantt: { useMaxWidth: true, barHeight: 24, fontSize: 14, sectionFontSize: 14 },
      mindmap: { padding: 14, useMaxWidth: true }, pie: { textPosition: 0.72, useMaxWidth: true },
      themeCSS: '.node rect, .node polygon, .node path, .cluster rect, rect.actor, .note { rx: 10px; ry: 10px; } ' +
        '.node rect, .node polygon, .node circle, rect.actor, .mindmap-node rect, .mindmap-node path { filter: drop-shadow(0 1px 1.5px rgba(0,0,0,' + (dark ? '.45' : '.10') + ')); } ' +
        '.mindmap-node line { stroke: transparent; } .label, .nodeLabel, .edgeLabel { font-weight: 500; } .flowchart-link, .relation, .messageLine0, .messageLine1, .transition { stroke-width: 1.6px; }',
    };
  }
  function ensureMermaid() {
    if (window.mermaid) return Promise.resolve();
    if (mermaidLoading) return mermaidLoading;
    mermaidLoading = new Promise((resolve, reject) => {
      const s = document.createElement('script');
      s.src = 'vendor/mermaid.min.js';
      s.onload = () => {
        mermaid.initialize(mermaidConfig());
        resolve();
      };
      s.onerror = reject;
      document.head.appendChild(s);
    });
    return mermaidLoading;
  }
  // Models often leave flowchart labels with (), :, ", ; unquoted, which Mermaid rejects. On a parse error, quote those
  // labels (what the author meant) and try once more; the first error stands if that fails too.
  function quoteLabels(src) {
    const KINDS = /^\s*(flowchart|graph|sequenceDiagram|classDiagram|stateDiagram|erDiagram|gantt|pie|mindmap|journey|gitGraph|timeline|quadrantChart|xychart|sankey|block|packet|architecture|kanban|requirementDiagram|C4\w+|zenuml|radar|treemap)\b/;
    // No header (just "A --> B"): it's a flowchart.
    if (!KINDS.test(src) && /-->|---/.test(src)) src = 'flowchart TD\n' + src;
    if (!/^\s*(flowchart|graph)\b/i.test(src)) return src;
    const unsafe = /[()"':;#&|<>]/;
    const q = (inner) => /^\s*".*"\s*$/.test(inner) || !unsafe.test(inner) ? inner : '"' + inner.replace(/"/g, '#quot;') + '"';
    // Inside [ ]: the shapes [(cylinder)] [[subroutine]] [/parallelogram/] [\trapezoid/] keep their delimiters outside the
    // quotes, but only when the label really ends with the closing one: F[(a + b)² = c²] is a box whose text starts with "(".
    const balanced = (t) => { let d = 0; for (const ch of t) { if (ch === '(') d++; else if (ch === ')' && --d < 0) return false; } return d === 0; };
    const shaped = (inner) => {
      const m = /^([(\[\/\\])([^]*)([)\]\/\\])$/.exec(inner.trim());
      if (m && ((m[1] === '(' && m[3] === ')' && balanced(m[2])) || (m[1] === '[' && m[3] === ']') || ('/\\'.includes(m[1]) && '/\\'.includes(m[3]))))
        return m[1] + q(m[2]) + m[3];
      return q(inner);
    };
    return src.split('\n').map(line => {
      if (/^\s*subgraph\b/.test(line)) return line.replace(/^(\s*subgraph\s+\S+\s*\[)([^\]]*)(\])\s*$/, (m, a, inner, c) => a + q(inner) + c)
        .replace(/^(\s*subgraph\s+)([^\[\n]*[()][^\[\n]*)$/, (m, a, t) => a + '"' + t.trim().replace(/"/g, '#quot;') + '"');
      return line
        // Edge labels: -->|f(x) = 2x| B
        .replace(/\|([^|\n]+)\|/g, (m, inner) => '|' + q(inner) + '|')
        // [text], {text}, and (text) whose text itself has parentheses — greedy to the last bracket before an arrow.
        .replace(/(\b[\w-]+)\[(?!")([^\n]*?)\](?=\s*(?:$|;|-|=|\.|&|:::))/g, (m, id, inner) => id + '[' + shaped(inner) + ']')
        .replace(/(\b[\w-]+)\{(?![{"])([^}\n]*)\}/g, (m, id, inner) => id + '{' + q(inner) + '}')
        .replace(/(\b[\w-]+)\((?![(\["])([^\n]*\))\)(?=\s*(?:$|;|-|=|\.|&))/g, (m, id, inner) => id + '(' + q(inner) + ')')
        // A node called "end" breaks Mermaid's parser.
        .replace(/(^|[\s>|-])end(?=\s*(?:-->|---|\[|\(|\{|$))/g, (m, pre) => line.trim() === 'end' ? m : pre + 'End');
    }).join('\n');
  }
  // Mermaid draws in a hidden, laid-out sandbox (it needs real text metrics) that is emptied after every attempt, so a
  // failed parse never leaves its error graphic in the page.
  // Renders are queued: Mermaid keeps global state and breaks when two diagrams render at once (a reply with several).
  let mermaidSandbox = null, mermaidQueue = Promise.resolve();
  function renderOnce(src) {
    const run = mermaidQueue.then(async () => {
      if (!mermaidSandbox) {
        mermaidSandbox = document.createElement('div');
        mermaidSandbox.setAttribute('aria-hidden', 'true');
        mermaidSandbox.style.cssText = 'position:absolute;left:-12000px;top:0;width:820px;visibility:hidden;pointer-events:none';
        document.body.appendChild(mermaidSandbox);
      }
      const id = 'mmd' + (++mermaidSeq);
      try { return await mermaid.render(id, src, mermaidSandbox); }
      finally { document.querySelectorAll('#d' + id + ', #' + id + ', body > [id^="d' + id + '"]').forEach(n => n.remove()); }
    });
    mermaidQueue = run.catch(() => {});
    return run;
  }
  async function renderMermaid(src) {
    try { return await renderOnce(src); }
    catch (e) {
      const fixed = quoteLabels(src);
      if (fixed === src) throw e;
      try { return await renderOnce(fixed); } catch (_) { throw e; }
    }
  }
  // Wide diagrams scroll at a readable size instead of shrinking their text below 90%. A min-width does it in CSS: reading
  // the block's width instead forced a layout of the whole lesson per diagram (most of the CPU of opening a long one).
  function fitDiagram(el) {
    const svg = el.querySelector('svg'); if (!svg || !svg.viewBox || !svg.viewBox.baseVal) return;
    const natural = svg.viewBox.baseVal.width;
    if (natural) svg.style.minWidth = Math.round(natural * 0.9) + 'px';
  }
  // A diagram, chart or plot that fails in the latest finished reply is reported once to the app, which passes it to the
  // teacher with the learner's next message (a broken visual does the same from components/visuals.js).
  const reported = new Set();
  function reportRenderErrors() {
    if (S.running) return;
    const msgs = document.querySelectorAll('.msg.assistant'), last = msgs[msgs.length - 1];
    if (!last) return;
    last.querySelectorAll('.diagram-error').forEach(e => {
      const text = (e.firstChild && e.firstChild.textContent || e.textContent || '').trim().slice(0, 300);
      const kind = e.closest('.mermaid-block') ? 'mermaid' : e.closest('.plot-block') ? 'plot' : 'chart';
      const k = last.id + '|' + text;
      if (!text || reported.has(k)) return;
      reported.add(k);
      post({ type: 'visualError', kind, title: kind + ' block', msg: text });
    });
  }
  let fillSeq = 0;
  function fillMermaid(el, key) {
    const r = mermaidSvg.get(key), code = mermaidSrc.get(key) || '';
    el.removeAttribute('data-pending');
    const tools = '<div class="diagram-tools"><button data-act="copy-src" data-src-key="' + key + '">Copy source</button></div>';
    // The same diagram twice needs distinct SVG ids (its styles are scoped by id).
    const svg = r.error ? '' : r.replace(/\bmmd(\d+)\b/g, 'mmd$1x' + (++fillSeq));
    if (r.error && el.hasAttribute('data-unfinished')) { el.innerHTML = unfinished('mermaid', code); return; }
    el.innerHTML = r.error ? tools + '<div class="diagram-error">Diagram error: ' + esc(r.error) + '<pre>' + esc(code) + '</pre></div>' : tools + svg;
    if (!r.error) fitDiagram(el);
  }
  async function processMermaid(root) {
    let blocks = Array.from(root.querySelectorAll('.mermaid-block[data-pending]'));
    if (root.matches && root.matches('.mermaid-block[data-pending]')) blocks.unshift(root);
    // Already drawn: fill synchronously, before the browser paints the placeholder.
    blocks = blocks.filter(el => { const k = el.getAttribute('data-key'); if (!mermaidSvg.has(k)) return true; fillMermaid(el, k); return false; });
    if (!blocks.length) return;
    await ensureMermaid();
    for (const el of blocks) {
      const key = el.getAttribute('data-key');
      if (!el.isConnected || !el.hasAttribute('data-pending')) continue;
      const code = mermaidSrc.get(key);
      if (!mermaidSvg.has(key)) {
        try { const { svg } = await renderMermaid(code.trim()); mermaidSvg.set(key, svg); }
        catch (e) {
          mermaidSvg.set(key, { error: String((e && (e.message || e.str)) || e).split('\n')[0].slice(0, 300) });
        }
      }
      if (el.isConnected && el.hasAttribute('data-pending')) fillMermaid(el, key);
    }
  }

  const PURIFY = { ADD_ATTR: ['data-act', 'data-key', 'data-lang', 'data-src-key', 'data-pending', 'data-text', 'data-raw', 'target', 'lang', 'dir'], FORBID_TAGS: ['style', 'form', 'script', 'iframe', 'object', 'embed'], FORBID_ATTR: ['style'], ALLOW_DATA_ATTR: true, ADD_TAGS: ['semantics', 'annotation', 'ruby', 'rt', 'rp', 'bdi'] };
  DOMPurify.addHook('uponSanitizeAttribute', (node, data) => {
    if (data.attrName === 'style' && node.closest && (node.closest('.katex') || node.closest('svg'))) data.forceKeepAttr = true;
  });
  // Finished markdown is cached by content, so re-rendering a lesson (paging, a theme change, a card refresh) parses each
  // block once. The key carries the run outputs' count: a block's HTML gains its output when the learner runs it.
  const mdCache = new Cache(600, 6e6);
  function markdown(text, streaming, plain) {
    text = String(text == null ? '' : text);
    if (streaming || text.length > 20000) return renderMarkdown(text, streaming, plain);
    const key = (plain ? 'p' : '') + S.codeEpoch + '\u0000' + text;
    const hit = mdCache.get(key);
    if (hit !== undefined) return hit;
    const html = renderMarkdown(text, false, plain);
    mdCache.set(key, html);
    return html;
  }
  function renderMarkdown(text, streaming, plain) {
    const env = { streaming, plain: !!plain };
    // An odd number of fence markers: the last fence is still open (streaming), or the reply ended inside it (stopped).
    if (text.indexOf('```') >= 0 || text.indexOf('~~~') >= 0) { const f = text.match(/^\s{0,3}(```|~~~)/gm); env.openFence = !!(f && f.length % 2 === 1); }
    try {
      const tokens = md.parse(text, env);
      if (env.openFence) { for (let i = tokens.length - 1; i >= 0; i--) if (tokens[i].type === 'fence') { env.lastFenceIdx = i; break; } }
      return DOMPurify.sanitize(md.renderer.render(tokens, md.options, env), PURIFY);
    } catch (e) { return '<p>' + esc(text) + '</p>'; }
  }
  const inline = s => markdown(String(s == null ? '' : s), false).replace(/^\s*<p>|<\/p>\s*$/g, '');
  /** Single newlines as hard breaks (outside fences), for text that was written as lines, not markdown paragraphs. */
  function hardLines(text) {
    const out = []; let fence = false;
    for (const line of String(text == null ? '' : text).split('\n')) {
      if (/^\s{0,3}(```|~~~)/.test(line)) fence = !fence;
      out.push(!fence && line.trim() ? line + '  ' : line);
    }
    return out.join('\n');
  }

  // ── Streaming: render only what changed ──
  // A streaming reply is split at blank lines that can't change meaning (outside fences and $$ blocks, not before a
  // list item or an indented continuation). Finished sections come from a cache, so a frame costs O(the tail), not
  // O(the whole reply). Short replies and replies with footnotes/reference links render whole.
  const segCache = new Cache(400, 4e6);
  function segments(text) {
    const lines = text.split('\n'), segs = [];
    let cur = [], fence = null, math = false;
    for (let i = 0; i < lines.length; i++) {
      const l = lines[i], f = /^\s{0,3}(`{3,}|~{3,})/.exec(l);
      if (f) { if (!fence) fence = f[1]; else if (l.trim().startsWith(fence)) fence = null; }
      else if (!fence && /^\s*\$\$\s*$/.test(l)) math = !math;
      cur.push(l);
      const next = lines[i + 1];
      if (!fence && !math && !l.trim() && next !== undefined && next.trim() && !/^\s/.test(next) && !/^([-*+]|\d+[.)])\s/.test(next) && !/^\|/.test(next)) {
        segs.push(cur.join('\n') + '\n'); cur = [];
      }
    }
    segs.push(cur.join('\n'));
    return segs;
  }
  /** The reply's HTML as a list of segments (see `morph`): finished ones come from the cache as the same strings. */
  function markdownLive(text, plain) {
    if (text.length < 3000 || /\[\^|^\s{0,3}\[[^\]]+\]:/m.test(text)) return [markdown(text, true, plain)];
    const segs = segments(text), html = [], tag = plain ? '\u0002' : '';
    for (let i = 0; i < segs.length - 1; i++) {
      let h = segCache.get(tag + segs[i]);
      if (h === undefined) { h = markdown(segs[i], false, plain); segCache.set(tag + segs[i], h); }
      html.push(h);
    }
    html.push(markdown(segs[segs.length - 1], true, plain));
    return html;
  }
  /** Run component processors (language, tables, canvases…) on freshly inserted DOM. */
  function processNode(node) {
    if (node.nodeType !== 1) return;
    quietInputs(node);
    for (const p of R.processors) { try { p(node, ctx); } catch (e) { console.log('processor', e); } }
    processMermaid(node);
  }
  /** A learner's answer is theirs: macOS writing suggestions would otherwise complete it, and its Math Results turn
   *  "180.156/3=" into "180.156/3=60.052" as they type — the arithmetic an attempt-first problem asks them to do.
   *  Every text box the page renders opts out (set on insert, before it can take focus). */
  const QUIET = { writingsuggestions: 'false', autocomplete: 'off', autocorrect: 'off', autocapitalize: 'off' };
  function quietInputs(root) {
    const list = root.matches && root.matches('textarea, input') ? [root] : Array.from(root.querySelectorAll('textarea, input'));
    for (const el of list) {
      if (el.type && !/^(text|search|number|)$/.test(el.type) && el.tagName === 'INPUT') continue;
      for (const k in QUIET) if (el.getAttribute(k) !== QUIET[k]) el.setAttribute(k, QUIET[k]);
    }
  }
  /** Replace children of `el` with new HTML, keeping unchanged top-level nodes so diagrams, selection and processed DOM survive streaming.
   *  `html` may be a list of segments (a streaming reply): segments unchanged since the last frame keep their nodes without being
   *  parsed and serialised again, so a frame costs O(the tail) instead of O(the reply). */
  function morph(el, html) {
    const parts = Array.isArray(html) ? html : [html], prev = (Array.isArray(html) && el._segs) || [];
    const cur = Array.from(el.childNodes), segs = [];
    let s = 0, i = 0;
    for (; s < parts.length - 1 && s < prev.length && prev[s].html === parts[s] && prev[s].nodes.every((n, j) => cur[i + j] === n); s++) {
      i += prev[s].nodes.length; segs.push(prev[s]);
    }
    for (; s < parts.length; s++) {
      const tpl = document.createElement('template');
      tpl.innerHTML = parts[s];
      const nodes = [];
      for (const n of Array.from(tpl.content.childNodes)) {
        const c = cur[i++], src = n.nodeType === 1 ? n.outerHTML : n.nodeValue;
        if (c && c._src === src) { nodes.push(c); continue; }
        n._src = src;
        if (c) el.replaceChild(n, c); else el.appendChild(n);
        processNode(n); nodes.push(n);
      }
      segs.push({ html: parts[s], nodes });
    }
    for (let j = cur.length - 1; j >= i; j--) if (cur[j].parentNode === el) el.removeChild(cur[j]);
    el._segs = Array.isArray(html) ? segs : null;
  }
  // Re-rendering a card must never steal the learner's caret: remember the focused field (by its data-* key), restore
  // it after, and while an IME composition is in progress (Arabic, Japanese…) defer the update until it ends.
  const FOCUS_KEYS = ['data-q-input', 'data-q-blank', 'data-q-other', 'data-ask-text', 'data-focus'];
  let composing = false;
  const deferred = new Set();
  document.addEventListener('compositionstart', () => { composing = true; }, true);
  document.addEventListener('compositionend', () => {
    composing = false;
    const nodes = [...deferred]; deferred.clear();
    setTimeout(() => nodes.forEach(n => { if (n._pending != null) { const h = n._pending; n._pending = null; setHTML(n, h); } }), 0);
  }, true);
  function captureFocus(node) {
    const a = document.activeElement;
    if (!a || a === document.body || !node.contains(a)) return null;
    const key = FOCUS_KEYS.map(k => a.hasAttribute(k) ? '[' + k + '="' + CSS.escape(a.getAttribute(k)) + '"]' : '').find(Boolean);
    if (!key) return null;
    let start = null, end = null; try { start = a.selectionStart; end = a.selectionEnd; } catch (_) {}
    return { key, start, end, scroll: a.scrollTop };
  }
  function restoreFocus(node, f) {
    if (!f) return;
    const el = node.querySelector(f.key); if (!el) return;
    el.focus({ preventScroll: true });
    try { if (f.start != null) el.setSelectionRange(f.start, f.end); } catch (_) {}
    el.scrollTop = f.scroll;
  }
  function setHTML(node, html) {
    if (node._html === html) return;
    const f = captureFocus(node);
    if (f && composing) { node._pending = html; deferred.add(node); return; }
    node.innerHTML = html; node._html = html;
    processNode(node);
    restoreFocus(node, f);
  }

  // ───────────────────────── Messages ─────────────────────────
  const isHidden = b => b.meta && b.meta.hidden;
  const visibleText = m => (m.blocks || []).filter(b => b.kind === 'text' && !isHidden(b)).map(b => b.text || '').join('\n');
  const isToolResultOnly = m => m.role === 'user' && m.blocks.length > 0 && m.blocks.every(b => b.kind === 'toolResult');

  // ───────────────────────── Nodes ─────────────────────────
  // A reply renders through its AST (nodes.js): each node type has one renderer (R.nodes), keyed DOM, an error boundary
  // and an unmount. Rich content is a component inside a text leaf or a tool card, never a node type of its own.
  const lookup = { result: id => S.results.get(id) || null, pending: id => S.pending.get(id) || null, progress: id => S.progress.get(id) || '' };
  const nodeError = text => '<div class="node-error">' + text + '</div>';
  function renderNode(el, n, env) {
    const d = R.nodes[n.type];
    el._node = n;
    if (!d) { el.className = 'node-error'; setHTML(el, nodeError(esc(n.type) + ' cannot be shown by this version of the app.')); return; }
    try { d.render(el, n, ctx, env); }
    catch (e) {
      console.log('node', n.type, e);
      el.className = 'node-error'; el._src = null; el._html = null;
      setHTML(el, nodeError('This ' + esc(n.type) + ' could not be shown: ' + esc((e && e.message) || e)));
    }
  }
  function unmountEl(el) {
    const n = el._node, d = n && R.nodes[n.type];
    if (d && d.unmount) { try { d.unmount(el, n, ctx); } catch (e) { console.log('unmount', n.type, e); } }
    el._node = null;
    unmountComponents(el);
  }
  /** Components with an `unmount` (iframes, timers) inside `root`, root included. */
  function unmountComponents(root) {
    if (!root || root.nodeType !== 1) return;
    for (const name in R.components) {
      const d = R.components[name];
      if (d.name !== name || !d.unmount || !d.selector) continue;
      const list = (root.matches(d.selector) ? [root] : []).concat(Array.from(root.querySelectorAll(d.selector)));
      for (const el of list) { try { d.unmount(el, ctx); } catch (e) { console.log('unmount', name, e); } }
    }
  }
  /** Everything under `root` leaves the page: node and component unmounts run once each. */
  function unmountTree(root) {
    root.querySelectorAll('.blocks > div').forEach(el => {
      const n = el._node, d = n && R.nodes[n.type];
      if (d && d.unmount) { try { d.unmount(el, n, ctx); } catch (e) { console.log('unmount', n.type, e); } }
      el._node = null;
    });
    unmountComponents(root);
  }
  function agentReportHTML(p) {
    return '<div class="agent-report"><div class="ar-head"><span class="ar-icon">◈</span><span>Background agent <b>' + esc(p.handle || '') + '</b> · ' +
      esc(p.title || '') + ' — ' + (p.state === 'done' ? 'finished' : esc(p.state || 'finished')) + '</span>' +
      '<button class="btn mini" data-act="agent-open" data-agent="' + esc(p.agent) + '">Open</button></div>' +
      '<details><summary>Report</summary><div class="md">' + markdown(p.text || '', false) + '</div></details></div>';
  }
  R.defineNode({ type: 'text', render(el, n, c, env) {
    el.className = 'md';
    // Keyed on the streaming flag as well: when the stream ends, an unclosed fence must render as finished.
    const src = (env.live ? '\u0001' : '') + n.props.markdown;
    if (el._src !== src) { morph(el, env.live ? markdownLive(n.props.markdown) : markdown(n.props.markdown, false)); el._src = src; }
  } });
  R.defineNode({ type: 'thinking', render(el, n, c, env) { renderThinking(el, { text: n.props.text }, env.live); } });
  R.defineNode({ type: 'tool',
    render(el, n, c, env) {
      el.className = 'tool-wrap';
      el._block = n.block; el._msgId = env.message.id;
      el.setAttribute('data-tool-id', n.props.callId); S.cards.set(n.props.callId, el);
      renderToolCard(el, n.block);
    },
    unmount(el, n) { if (S.cards.get(n.props.callId) === el) S.cards.delete(n.props.callId); } });
  R.defineNode({ type: 'attachment', render(el, n) {
    el.className = 'attachments';
    const p = n.props;
    setHTML(el, p.kind === 'image' ? '<img src="' + esc(imageSrc(p)) + '" alt="">' : '<span class="file-chip">📄 ' + esc(p.name || 'file') + '</span>');
  } });
  R.defineNode({ type: 'agentReport', render(el, n) { el.className = ''; setHTML(el, agentReportHTML(n.props)); } });
  R.defineNode({ type: 'error', render(el, n) { el.className = 'node-error'; setHTML(el, nodeError(esc(n.props.message))); } });

  function ensureEl(m) {
    let rec = S.byId.get(m.id);
    if (rec && rec.el) return rec.el;
    const el = document.createElement('div');
    el.className = 'msg ' + m.role;
    el.id = 'm-' + m.id;
    if (!rec) { rec = { msg: m, el }; S.byId.set(m.id, rec); } else rec.el = el;
    const idx = S.messages.findIndex(x => x.id === m.id);
    let before = null;
    for (let i = idx + 1; i < S.messages.length; i++) { const r = S.byId.get(S.messages[i].id); if (r && r.el && r.el.parentNode) { before = r.el; break; } }
    thread.insertBefore(el, before);
    return el;
  }

  function renderMessage(m) {
    if (isToolResultOnly(m)) {
      for (const b of m.blocks) {
        S.results.set(b.id, b);
        const card = S.cards.get(b.id);
        if (card && card.isConnected) renderToolCard(card, card._block);
      }
      return;
    }
    const el = ensureEl(m);
    if (m.role === 'user') return renderUser(m, el);
    renderAssistant(m, el);
  }

  function renderUser(m, el) {
    if (el._editing) return;
    // A background sub-agent's report: a compact notice (the teacher reads it; the learner can open it).
    const rep = R.ast.toNodes(m).children.find(n => n.type === 'agentReport');
    if (rep) { el.className = 'msg agent-note'; return setHTML(el, agentReportHTML(rep.props)); }
    const imgs = m.blocks.filter(b => b.kind === 'image'), files = m.blocks.filter(b => b.kind === 'file');
    const text = visibleText(m);
    let html = '';
    // Only hidden context (the app nudging the model on): nothing to show, not even an empty row with Edit and Copy.
    el.hidden = !text && !imgs.length && !files.length;
    if (imgs.length || files.length) {
      html += '<div class="attachments">' + imgs.map(imageSrc).filter(Boolean).map(s => '<img src="' + esc(s) + '" alt="">').join('') +
        files.map(b => '<span class="file-chip">📄 ' + esc(b.name || 'file') + '</span>').join('') + '</div>';
    }
    if (text) html += '<div class="bubble"><div class="md">' + markdown(text, false) + '</div></div>';
    if (!el.hidden) html += '<div class="msg-actions"><button data-act="edit">Edit</button><button data-act="copy-msg">Copy</button></div>';
    setHTML(el, html);
  }

  /** Assistant messages of the turn that ends with `id`, plus the learner message that started it. */
  function turnOf(id) {
    const i = S.messages.findIndex(x => x.id === id);
    const msgs = []; let user = null;
    for (let j = i; j >= 0; j--) {
      const m = S.messages[j];
      if (m.role === 'assistant') msgs.unshift(m);
      else if (!isToolResultOnly(m)) { user = m; break; }
    }
    return { msgs, user };
  }

  function renderAssistant(m, el) {
    let blocksEl = el.querySelector(':scope > .blocks');
    if (!blocksEl) { el.innerHTML = '<div class="blocks"></div>'; blocksEl = el.firstChild; }
    // A draft the self-check sent back: kept, collapsed, with what the review found; the corrected reply follows it.
    const sup = !!(m.meta && m.meta.superseded);
    el.classList.toggle('superseded', sup);
    let note = el.querySelector(':scope > .draft-note');
    if (sup) {
      if (!note) { note = document.createElement('div'); note.className = 'draft-note'; el.insertBefore(note, blocksEl); }
      const issues = (m.meta.reviewIssues || []).map(i => '<li>' + esc(i) + '</li>').join('');
      note.innerHTML = '<button class="btn link" data-act="draft-toggle">First draft · revised after a self-check</button>' +
        (issues ? '<ul class="draft-issues">' + issues + '</ul>' : '');
    } else if (note) note.remove();
    const streaming = S.streamingId === m.id;
    const kids = blocksEl.children;
    const msgNode = R.ast.toNodes(m, lookup);
    const lastIndex = (m.blocks || []).length - 1;
    let vi = 0;
    for (const n of msgNode.children) {
      if (n.type === 'thinking' && (!n.props.text.trim() || !S.showThinking)) continue;
      if (n.type === 'text' && !n.props.markdown.length) continue;
      let node = kids[vi];
      // Keyed by node id and type: a block that changes kind at the same position gets a fresh element.
      if (!node || node._key !== n.id || node._type !== n.type) {
        const fresh = document.createElement('div');
        fresh._key = n.id; fresh._type = n.type;
        if (node) blocksEl.insertBefore(fresh, node); else blocksEl.appendChild(fresh);
        node = fresh;
      }
      renderNode(node, n, { live: streaming && n.index === lastIndex, streaming, message: m });
      vi++;
    }
    while (kids.length > vi) { const last = kids[kids.length - 1]; unmountEl(last); blocksEl.removeChild(last); }
    let tail = el.querySelector(':scope > .tail');
    if (!tail) { tail = document.createElement('div'); tail.className = 'tail'; el.appendChild(tail); }
    let th = '';
    // Stopping is the learner's choice, not an error: a quiet note with a way to try again.
    if (m.error === 'Stopped.') th += '<div class="msg-stopped"><span>⏹ Stopped before the reply began.</span><button class="btn link" data-act="retry">Try again</button></div>';
    else if (m.error) th += '<div class="msg-error"><span>⚠️ ' + esc(m.error) + '</span><button data-act="retry">Retry</button></div>';
    if (!streaming && m.turn) {
      const { msgs, user } = turnOf(m.id);
      th += R.footers.map(f => f(m, msgs, user, ctx)).join('');
    }
    if (!streaming && endsTurn(m) && msgNode.children.some(n => n.type === 'text' && n.props.markdown.trim())) {
      th += '<div class="msg-actions"><button data-act="copy-msg">Copy</button><button data-act="speak">Read aloud</button>' +
        '<button data-act="regenerate">Regenerate</button>' +
        '<button class="chip" data-act="quick" data-q="simpler">Explain simpler</button>' +
        '<button class="chip" data-act="quick" data-q="deeper">Go deeper</button>' +
        '<button class="chip" data-act="quick" data-q="example">Another example</button>' +
        '<button class="chip" data-act="quick" data-q="quiz">Quiz me</button>' +
        '<button class="chip" data-act="quick" data-q="flashcards">Make flashcards</button></div>';
    }
    if (tail._html !== th) { tail.innerHTML = th; tail._html = th; }
  }

  function endsTurn(m) {
    if (m.turn) return true;
    const i = S.messages.findIndex(x => x.id === m.id);
    for (let j = i + 1; j < S.messages.length; j++) {
      const n = S.messages[j];
      if (n.role === 'assistant') return false;
      if (!isToolResultOnly(n)) return true;
    }
    return !S.running;
  }

  /** Thinking cut off inside a code block (an output limit) would render the rest as prose, its regex as broken math. */
  function closedFences(text) {
    text = text || '';
    return (text.match(/^\s*```/gm) || []).length % 2 ? text + '\n```' : text;
  }

  /** Thinking streams the way the reply does: markdown rendered by segments (finished ones cached, so a frame costs only
   *  the tail), fences as plain code. It reads the same while it streams and after; it stays pinned to its newest line
   *  unless the learner scrolls up in it. */
  function renderThinking(node, b, live) {
    node.className = '';
    let d = node.querySelector('details');
    if (!d) {
      node.innerHTML = '<details class="thinking"><summary></summary><div class="thinking-body md"></div></details>';
      d = node.querySelector('details');
      d.addEventListener('toggle', () => {
        if (d._prog) { d._prog = false; return; }
        d._user = true;
        if (d.open && d._b && !d._live) renderThinkingMarkdown(d, d._b);
      });
    }
    const setOpen = v => { if (d.open !== v) { d._prog = true; d.open = v; } };
    d._b = b;
    d._live = live;
    d.classList.toggle('live', live);
    if (!d._user) setOpen(live);
    const words = (b.text || '').trim().split(/\s+/).length;
    d.querySelector('summary').textContent = live ? 'Thinking…' : 'Thought process · ' + words + ' words';
    const body = d.querySelector('.thinking-body');
    if (!live) d.classList.remove('raw');
    if (!d.open) return;
    if (live) {
      const t = (b.text || '').replace(/\s+$/, '');   // trailing blank lines would scroll the text out of view
      if (body._live !== t) {
        const pinned = body.scrollHeight - body.scrollTop - body.clientHeight < 24;
        morph(body, markdownLive(t, true));
        body._live = t; body._src = null; body._plain = null;
        if (pinned) body.scrollTop = body.scrollHeight;
      }
    } else {
      renderThinkingMarkdown(d, b);
    }
  }

  function renderThinkingMarkdown(d, b) {
    const body = d.querySelector('.thinking-body');
    const text = closedFences(b.text || '');
    if (body._src === text) return;
    morph(body, markdown(text, false, true));
    body._src = text; body._plain = null; body._live = null;
  }

  // Large images live on disk (Swift's blob store) and load by reference; small ones may still be inline.
  const imageSrc = b => /^[0-9a-f]{64}$/.test(b.blob || '') ? 'teacher-blob://img/' + b.blob
    : b.data && /^[A-Za-z0-9+/=\s]*$/.test(b.data) ? 'data:' + (/^image\/[\w.+-]+$/.test(b.mime || '') ? b.mime : 'image/png') + ';base64,' + b.data : '';

  // ───────────────────────── Tool cards ─────────────────────────
  // Presentation lives in components/tools/*.js: `R.tool(name)` merges a tool's descriptor (icon, title, summary, body,
  // open, compact, headActions, card) over the generic default below. The core draws only the frame.
  const pre = (t, max = 20000) => '<pre>' + esc(t.length > max ? t.slice(0, max) + '\n…' : t) + '</pre>';
  const fmtMs = ms => ms < 1000 ? Math.round(ms) + ' ms' : (ms / 1000).toFixed(1) + ' s';
  R.defineTool({ name: 'default', icon: '🔧', title: n => n.props.name, summary: () => '',
    body(n, c) {
      const i = n.props.input || {}, out = n.props.output || '';
      return (Object.keys(i).length ? '<div class="label">Input</div>' + c.pre(JSON.stringify(i, null, 2)) : '') + (out ? '<div class="label">Result</div>' + c.pre(out) : '');
    } });
  /** The tool node for a card's block (the message id is remembered on the element, so a refresh needs no message). */
  function toolNode(el, b) {
    const msgEl = el.closest ? el.closest('.msg') : null;
    return R.ast.toNodes({ id: el._msgId || (msgEl ? msgEl.id.slice(2) : ''), blocks: [b] }, lookup).children[0];
  }
  /** One failing descriptor must not blank the card or the reply. */
  function guard(what, fn, fallback) {
    try { return fn(); }
    catch (e) { console.log('tool', what, e); return fallback !== undefined ? fallback : nodeError(esc(what) + ' could not be shown: ' + esc((e && e.message) || e)); }
  }

  /** Everything a card's HTML depends on, cheaply: an unchanged card must not be rebuilt while a reply streams (the plan
   *  markdown, a 20k-character output and its escaping would otherwise run on every frame). */
  function toolSignature(b) {
    const r = S.results.get(b.id), pend = S.pending.get(b.id);
    const meta = r && r.meta ? [r.meta.ms, r.meta.running ? 1 : 0, r.meta.handle, r.meta.agentID, r.meta.background ? 1 : 0,
      r.meta.state, r.meta.latex, r.meta.title, r.meta.agentReport].join(',') : '';
    return [b.id, b.name, S.openTools.has(b.id) ? 1 : 0, b.meta && b.meta.pending ? 1 : 0,
      r ? (r.text || '').length + ':' + (r.isError ? 1 : 0) + ':' + meta : 'running',
      pend ? pend.kind + ':' + ((pend.payload && (pend.payload.title || '')) || '') : '',
      (S.progress.get(b.id) || '').length].join('|');
  }

  function renderToolCard(node, b, force) {
    if (!b) return;
    const sig = toolSignature(b);
    if (!force && node._sig === sig) return;
    node._sig = sig;
    const tn = toolNode(node, b), p = tn.props, d = R.tool(b.name);
    const r = p.result, pend = p.interaction;
    const pendingCall = p.status === 'pending';
    if (d.card && !pendingCall && !(pend && pend.kind === 'permission')) {
      const out = guard(b.name, () => d.card(b, r, pend, ctx));
      if (out != null) return setHTML(node, out);
    }
    const icon = d.icon || '🔧';
    const title = typeof d.title === 'function' ? guard(b.name, () => d.title(tn), b.name) : (d.title || b.name);
    const running = pendingCall || p.status === 'running';
    const isErr = p.status === 'error';
    const compact = !!d.compact && !pend;
    const open = S.openTools.has(b.id) || !!(d.open && guard(b.name, () => d.open(tn), false));
    let state = running ? '<span class="spinner"></span>' : (isErr ? 'failed' : (r && r.meta && r.meta.ms ? fmtMs(r.meta.ms) : '✓'));
    if (pend && pend.kind === 'permission') state = 'needs approval';
    let html = '';
    if (pend && pend.kind === 'permission') html += renderApproval(b, pend);
    const acts = d.headActions ? guard(b.name, () => d.headActions(tn, ctx) || '', '') : '';
    const summary = d.summary ? guard(b.name, () => d.summary(tn) || '', '') : '';
    html += '<div class="tool' + (open ? ' open' : '') + (isErr ? ' error' : '') + (compact && !open ? ' compact' : '') + '">' +
      '<div class="head" data-act="toggle-tool"><span class="icon">' + icon + '</span><span class="name">' + esc(title) + '</span>' +
      '<span class="sum">' + esc(summary) + '</span>' + acts + '<span class="state">' + state + '</span></div>' +
      '<div class="body">' + (open ? guard(b.name, () => (d.body || R.tools.default.body)(tn, ctx)) : '') + '</div></div>';   // bodies (up to 20k characters each) only when opened
    setHTML(node, html);
  }

  function renderApproval(b, pend) {
    const p = pend.payload || {};
    const opts = p.options || [{ id: 'once', label: 'Allow', style: 'primary' }, { id: 'deny', label: 'Deny', style: 'danger' }];
    return '<div class="approval"><div class="q">' + esc(p.title || ('Allow Teacher to use ' + b.name + '?')) + '</div>' + (p.detail ? '<pre>' + esc(String(p.detail).slice(0, 4000)) + '</pre>' : '') +
      '<div class="btn-row">' + opts.map(o => '<button class="btn ' + (o.style === 'primary' ? 'primary' : o.style === 'danger' ? 'danger' : '') + '" data-act="approve" data-v="' + esc(o.id) + '">' + esc(o.label) + '</button>').join('') + '</div></div>';
  }

  // ───────────────────────── Context for components ─────────────────────────
  function refreshCard(toolId) {
    const el = document.querySelector('[data-tool-id="' + CSS.escape(toolId) + '"]');
    if (!el) return;
    el._html = null; renderToolCard(el, el._block, true);   // setHTML keeps focus and caret
  }
  const ctx = {
    esc, hash, tex, post, inline, pre, hardLines, fmtMs,
    check: R.check,
    pending: id => S.pending.get(id),
    result: id => S.results.get(id) || null,
    progress: id => S.progress.get(id) || '',
    imageSrc: b => imageSrc(b || {}),
    code: (code, lang) => renderCode(String(code == null ? '' : code), lang || '', { streamingFence: true }),
    md: (s) => markdown(String(s == null ? '' : s), false),
    flash(el, text) { const t = el.textContent; el.textContent = text; setTimeout(() => { el.textContent = t; }, 1100); },
    refreshCard,
    rerender(msgId) { const rec = S.byId.get(msgId); if (rec && rec.el) { const tail = rec.el.querySelector('.tail'); if (tail) tail._html = null; renderMessage(rec.msg); } },
    message(id) { const r = S.byId.get(id); return r && r.msg; },
    turnMessages(id) { return turnOf(id).msgs; },
  };
  R._ctx = ctx;

  // ───────────────────────── Events ─────────────────────────
  document.addEventListener('click', (e) => {
    const a = e.target.closest('a[href]');
    if (a) {
      const href = a.getAttribute('href');
      e.preventDefault();
      if (href.startsWith('#')) {
        const t = document.getElementById(href.slice(1)) || document.querySelector('[id="' + CSS.escape(href.slice(1)) + '"]');
        if (t) t.scrollIntoView({ behavior: 'smooth', block: 'center' });
        return;
      }
      post({ type: 'open', url: a.href }); return;
    }
    const el = e.target.closest('[data-act]');
    if (!el) return;
    const act = el.getAttribute('data-act');
    if (!act) return;
    // A question that has just appeared (and scrolled into view) ignores clicks for a moment: a click aimed at the card
    // it replaced must not answer, submit or dismiss it unseen.
    const qcard = el.closest('[data-tool-id]'), armed = qcard && S.armedAt.get(qcard.getAttribute('data-tool-id'));
    if (armed && performance.now() - armed < S.armMs) { e.preventDefault(); return; }
    if (R.actions[act]) { R.actions[act](el, e, ctx); return; }
    const msgEl = el.closest('.msg');
    const msgId = msgEl ? msgEl.id.slice(2) : null;
    const toolEl = el.closest('[data-tool-id]');
    const toolId = toolEl ? toolEl.getAttribute('data-tool-id') : null;
    switch (act) {
      case 'toggle-tool':
        if (S.openTools.has(toolId)) S.openTools.delete(toolId); else S.openTools.add(toolId);
        toolEl._html = null; renderToolCard(toolEl, toolEl._block, true); break;
      case 'copy-code': { const k = el.closest('.code-block').getAttribute('data-key'); post({ type: 'copy', text: codeSources.get(k) || '' }); ctx.flash(el, 'Copied'); break; }
      case 'copy-src': post({ type: 'copy', text: mermaidSrc.get(el.getAttribute('data-src-key')) || '' }); ctx.flash(el, 'Copied'); break;
      case 'run': {
        const blk = el.closest('.code-block'); const k = blk.getAttribute('data-key');
        el.textContent = 'Running…'; el.disabled = true;
        post({ type: 'run', key: k, lang: blk.getAttribute('data-lang'), code: codeSources.get(k) || '' }); break;
      }
      case 'draft-toggle': { const msg = el.closest('.msg'); if (msg) msg.classList.toggle('open'); break; }
      case 'copy-msg': { const rec = S.byId.get(msgId); post({ type: 'copy', text: rec ? visibleText(rec.msg) : '' }); ctx.flash(el, 'Copied'); break; }
      case 'speak': { const rec = S.byId.get(msgId); post({ type: 'speak', text: rec ? visibleText(rec.msg) : '' }); break; }
      case 'regenerate': post({ type: 'regenerate' }); break;
      case 'retry': post({ type: 'retry' }); break;
      case 'quick': post({ type: 'quick', q: el.getAttribute('data-q'), id: msgId }); break;
      case 'suggest': post(Object.assign({ type: 'suggest', text: el.getAttribute('data-text') }, el.getAttribute('data-board') ? { board: el.getAttribute('data-board') } : {})); break;
      case 'edit': startEdit(msgId); break;
      case 'edit-save': { const ta = msgEl.querySelector('textarea'); msgEl._editing = false; post({ type: 'edit', id: msgId, text: ta.value }); break; }
      case 'edit-cancel': { msgEl._editing = false; msgEl._html = null; renderMessage(S.byId.get(msgId).msg); break; }
      case 'approve': post({ type: 'answer', id: toolId, value: { decision: el.getAttribute('data-v') } }); break;
      case 'older': el.disabled = true; el.textContent = 'Loading…'; post({ type: 'older' }); break;
      case 'newer': el.disabled = true; el.textContent = 'Loading…'; post({ type: 'newer' }); break;
      case 'agent-open': post({ type: 'agent', op: 'open', id: el.getAttribute('data-agent') || toolId }); break;
      case 'agent-stop': post({ type: 'agent', op: 'stop', id: el.getAttribute('data-agent') || toolId }); el.disabled = true; el.textContent = 'Stopping…'; break;
    }
  });
  const onInput = (e) => { for (const f of R.inputs) { try { f(e, ctx); } catch (err) { console.log(err); } } };
  document.addEventListener('input', onInput);
  document.addEventListener('change', onInput);
  document.addEventListener('keydown', (e) => {
    const t = e.target;
    if (e.isComposing || e.keyCode === 229) return;   // Enter that confirms an IME candidate (Japanese, Chinese…) sends nothing
    if (t.matches && t.matches('[data-ask-text]') && e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault(); const btns = t.closest('.ask').querySelectorAll('[data-act="ask-submit"]'); btns[btns.length - 1].click();
    }
    if (t.matches && t.matches('.edit-box textarea')) {
      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); t.closest('.msg').querySelector('[data-act="edit-save"]').click(); }
      if (e.key === 'Escape') t.closest('.msg').querySelector('[data-act="edit-cancel"]').click();
    }
  });
  function startEdit(id) {
    const rec = S.byId.get(id); if (!rec || S.running) return;
    const el = rec.el; el._editing = true; el._html = null;
    el.innerHTML = '<div class="edit-box"><textarea>' + esc(visibleText(rec.msg)) + '</textarea><div class="row"><button class="btn" data-act="edit-cancel">Cancel</button><button class="btn primary" data-act="edit-save">Send</button></div></div>';
    quietInputs(el);
    const ta = el.querySelector('textarea'); ta.focus(); ta.setSelectionRange(ta.value.length, ta.value.length);
  }

  // ───────────────────────── Scrolling ─────────────────────────
  let stick = true;
  const nearBottom = () => window.innerHeight + window.scrollY >= document.body.scrollHeight - 90;
  window.addEventListener('scroll', () => { stick = nearBottom(); jumpEl.hidden = stick || !S.messages.length; }, { passive: true });
  jumpEl.addEventListener('click', () => { stick = true; scrollBottom(true); });
  function scrollBottom(smooth) { window.scrollTo({ top: document.body.scrollHeight, behavior: smooth ? 'smooth' : 'auto' }); }
  new ResizeObserver(() => { if (stick && S.messages.length) scrollBottom(false); }).observe(thread);

  // ───────────────────────── Render loop ─────────────────────────
  // rAF is paused while the window is hidden/occluded, so a timer backs it up.
  let rafPending = false, fallbackTimer = 0;
  function schedule(id) {
    S.dirty.add(id);
    if (!rafPending) { rafPending = true; requestAnimationFrame(flush); fallbackTimer = setTimeout(flush, 120); }
  }
  function flush() {
    if (!rafPending) return;
    rafPending = false; clearTimeout(fallbackTimer);
    const ids = Array.from(S.dirty); S.dirty.clear();
    for (const id of ids) { const rec = S.byId.get(id); if (rec) renderMessage(rec.msg); }
    markLast();
  }
  function markLast() {
    const prev = thread.querySelector('.msg.last'); if (prev) prev.classList.remove('last');
    for (let i = S.messages.length - 1; i >= 0; i--) {
      const m = S.messages[i];
      if (m.role === 'assistant') { const r = S.byId.get(m.id); if (r && r.el) r.el.classList.add('last'); break; }
      if (!isToolResultOnly(m)) break;
    }
  }

  function renderWelcome() {
    const w = S.welcome || {};
    const sug = (w.suggestions || []).map(s => '<div class="suggestion' + (s.board ? ' continue' : '') + '" data-act="suggest" data-text="' + esc(s.prompt) + '"' + (s.board ? ' data-board="' + esc(s.board) + '"' : '') + '><div class="t">' + esc(s.title) + '</div><div class="d">' + esc(s.subtitle || '') + '</div></div>').join('');
    const stats = (w.stats || []).map(s => '<span class="pill">' + esc(s) + '</span>').join('');
    thread.innerHTML = '<div class="welcome"><div class="logo">🎓</div><h1>' + esc(w.title || 'What would you like to learn?') + '</h1><p>' + esc(w.subtitle || '') + '</p><div class="suggestions">' + sug + '</div>' + (stats ? '<div class="stats">' + stats + '</div>' : '') + '</div>';
  }

  /** The reply now streaming. When a new step starts in a new message, the previous one renders once more as finished:
   *  otherwise its thinking stayed open in live mode, scrolled to its end — often just trailing blank lines, so the
   *  learner saw a tall empty box with a border. */
  function streamTo(id) {
    const prev = S.streamingId;
    S.streamingId = id;
    if (prev && prev !== id) schedule(prev);
  }

  // ───────────────────────── API for Swift ─────────────────────────
  window.T = {
    reset(messages, opts) {
      if (R.pauseVisuals) R.pauseVisuals(opts && opts.pauseVisuals);
      document.body.classList.toggle('agent-mode', !!(opts && opts.agent));   // a coding session: no teaching chips
      S.messages = []; S.byId.clear(); S.results.clear(); S.dirty.clear(); S.progress.clear(); S.cards.clear();
      S.streamingId = null; S.welcome = (opts && opts.welcome) || null;
      S.showThinking = !opts || opts.showThinking !== false;
      unmountTree(thread);
      thread.innerHTML = '';
      // Empty with older messages on disk (the first loaded message was edited away): the way back, not the welcome.
      if (!messages.length && opts && opts.earlier > 0) { T.earlier(opts.earlier); return; }
      if (!messages.length) { stick = false; renderWelcome(); window.scrollTo(0, 0); return; }
      for (const m of messages) { S.messages.push(m); S.byId.set(m.id, { msg: m, el: null }); if (isToolResultOnly(m)) m.blocks.forEach(b => S.results.set(b.id, b)); }
      // A long lesson arrives as a window: older messages load on request.
      if (opts && opts.earlier > 0) {
        const more = document.createElement('div');
        more.className = 'earlier';
        more.innerHTML = '<button class="btn" data-act="older">Show earlier messages (' + Number(opts.earlier).toLocaleString() + ' more)</button>';
        thread.appendChild(more);
      }
      for (const m of messages) renderMessage(m);
      // Reading back through a long lesson: newer messages are on disk, a click away (the page holds a bounded window).
      if (opts && opts.newer > 0) {
        const nb = document.createElement('div');
        nb.className = 'earlier newer';
        nb.innerHTML = '<button class="btn" data-act="newer">Show newer messages (' + Number(opts.newer).toLocaleString() + ' more)</button>';
        thread.appendChild(nb);
      }
      markLast();
      const anchor = opts && opts.anchor && document.getElementById('m-' + opts.anchor);
      if (anchor) { stick = false; anchor.scrollIntoView({ block: 'start' }); return; }
      if (opts && opts.newer > 0) { stick = false; window.scrollTo(0, 0); return; }
      stick = true; scrollBottom(false);
      requestAnimationFrame(() => scrollBottom(false));
    },
    upsert(m) {
      if (thread.querySelector('.welcome')) { thread.innerHTML = ''; stick = true; }
      const rec = S.byId.get(m.id);
      if (rec) { const i = S.messages.findIndex(x => x.id === m.id); if (i >= 0) S.messages[i] = m; rec.msg = m; }
      else {
        S.messages.push(m); S.byId.set(m.id, { msg: m, el: null });
        if (m.role === 'assistant') streamTo(m.id);
        if (m.role === 'user' && !isToolResultOnly(m)) stick = true;
      }
      if (isToolResultOnly(m)) m.blocks.forEach(b => S.results.set(b.id, b));
      schedule(m.id);
    },
    delta(id, index, kind, text) {
      const rec = S.byId.get(id); if (!rec) return;
      const blocks = rec.msg.blocks;
      while (blocks.length <= index) blocks.push({ kind, text: '' });
      if (blocks[index].kind !== kind) blocks[index] = { kind, text: '' };
      blocks[index].text = (blocks[index].text || '') + text;
      streamTo(id);
      schedule(id);
    },
    toolProgress(toolId, text) {
      S.progress.set(toolId, ((S.progress.get(toolId) || '') + text).slice(-20000));
      const el = document.querySelector('[data-tool-id="' + CSS.escape(toolId) + '"]');
      if (el && S.openTools.has(toolId)) renderToolCard(el, el._block);
    },
    armDelay(ms) { S.armMs = ms; },   // tests click instantly
    interaction(p, active) {
      if (active) { if (!S.pending.has(p.id)) S.armedAt.set(p.id, performance.now()); S.pending.set(p.id, p); } else { S.pending.delete(p.id); S.armedAt.delete(p.id); }
      const el = document.querySelector('[data-tool-id="' + CSS.escape(p.id) + '"]');
      if (el) { el._html = null; renderToolCard(el, el._block, true); if (active) el.scrollIntoView({ block: 'nearest', behavior: 'smooth' }); }
    },
    status(text, running) {
      if (S.running && !running) setTimeout(reportRenderErrors, 1500);   // after async diagrams have drawn
      S.running = !!running;
      if (!running) { const sid = S.streamingId; S.streamingId = null; if (sid) schedule(sid); }
      statusEl.hidden = !text;
      statusEl.querySelector('.label').textContent = text || '';
    },
    codeOutput(key, text, failed) {
      S.codeOutputs.set(key, { text, failed }); S.codeEpoch++;
      document.querySelectorAll('.code-block[data-key="' + key + '"]').forEach(el => {
        let o = el.querySelector('.code-output');
        if (!o) { o = document.createElement('div'); el.appendChild(o); }
        o.className = 'code-output' + (failed ? ' failed' : '');
        o.innerHTML = '<span class="label">Output</span>' + esc(text);
        const btn = el.querySelector('[data-act="run"]'); if (btn) { btn.textContent = '▶ Run'; btn.disabled = false; }
      });
    },
    notice(text) { if (window.TeacherToast) window.TeacherToast(text); },
    // The app is short of memory: everything here re-renders on demand.
    dropCaches() { caches.forEach(c => c.clear()); },
    // The lesson's window moved on: everything before `id` is on disk only now, so its DOM goes (the page's memory stays
    // bounded however long the lesson runs) and the "earlier" button says how many there are.
    trimBefore(id, earlier) {
      const i = S.messages.findIndex(m => m.id === id);
      if (i <= 0) return;
      for (const m of S.messages.splice(0, i)) {
        const el = document.getElementById('m-' + m.id); if (el) { unmountTree(el); el.remove(); }
        S.byId.delete(m.id);
        (m.blocks || []).forEach(b => { S.cards.delete(b.id); S.progress.delete(b.id); });
        if (isToolResultOnly(m)) m.blocks.forEach(b => S.results.delete(b.id));
      }
      T.earlier(earlier);
    },
    /** The "Show earlier" button, for `n` messages before the page (also restores it after a refused click). */
    earlier(n) {
      let more = thread.querySelector('.earlier');
      if (!n) { if (more) more.remove(); return; }
      if (!more) { more = document.createElement('div'); more.className = 'earlier'; thread.prepend(more); }
      more.innerHTML = '<button class="btn" data-act="older">Show earlier messages (' + Number(n).toLocaleString() + ' more)</button>';
    },
    setFontSize(px) { document.documentElement.style.setProperty('--font-size', px + 'px'); },
    /** The lesson's languages ({target, native, name, …}): the on-screen keyboard follows the target. */
    setLanguage(state) { if (R.setLanguage) R.setLanguage(state || null); },
    /** Recognised speech for a `speak` question ("toolId:qi"), partial until `final`. */
    dictation(key, text, final) { if (R.dictation) R.dictation(key, text, !!final); },
    card(front, back, show) {
      document.body.classList.add('card-mode');
      unmountTree(thread);
      thread.innerHTML = '<div class="flashcard"><div class="face md">' + markdown(front || '', false) + '</div>' +
        (show ? '<div class="divider"></div><div class="face back md">' + markdown(back || '', false) + '</div>' : '') + '</div>';
      processNode(thread);
    },
    scrollToBottom() { stick = true; scrollBottom(true); },
  };
  darkMQ.addEventListener('change', () => {
    mermaidSvg.clear();   // diagram placeholders are keyed by the theme
    if (window.mermaid) mermaid.initialize(mermaidConfig());
    invalidate();
  });
  post({ type: 'ready' });
})();
