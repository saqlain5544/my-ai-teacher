// Transcript renderer core for My AI Teacher. Swift drives it through window.T.*; it talks back via the `bridge` handler.
// Features plug in through window.TeacherUI (registry.js) — see components/*.js.
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

  // ───────────────────────── State ─────────────────────────
  const S = {
    messages: [], byId: new Map(), results: new Map(), pending: new Map(), progress: new Map(),
    openTools: new Set(), codeOutputs: new Map(), dirty: new Set(), streamingId: null, welcome: null,
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

  const katexCache = new Map();
  const katexMacros = { '\\RR': '\\mathbb{R}', '\\NN': '\\mathbb{N}', '\\ZZ': '\\mathbb{Z}', '\\QQ': '\\mathbb{Q}', '\\CC': '\\mathbb{C}' };
  function tex(src, display) {
    const key = (display ? 'D' : 'I') + src;
    let html = katexCache.get(key);
    if (html === undefined) {
      try { html = katex.renderToString(src, { displayMode: display, throwOnError: false, strict: 'ignore', output: 'htmlAndMathml', macros: katexMacros, trust: false }); }
      catch (e) { html = '<span class="math-error">' + esc(src) + '</span>'; }
      if (katexCache.size > 4000) katexCache.clear();
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
  const RUNNABLE = new Set(['python', 'py', 'python3', 'javascript', 'js', 'node', 'typescript', 'ts', 'swift', 'c', 'cpp', 'c++', 'go', 'golang', 'rust', 'rs', 'ruby', 'rb', 'bash', 'sh', 'zsh', 'shell', 'java']);
  const ALIAS = { js: 'javascript', ts: 'typescript', py: 'python', python3: 'python', rb: 'ruby', sh: 'bash', zsh: 'bash', shell: 'bash', console: 'bash', 'c++': 'cpp', cs: 'csharp', 'c#': 'csharp', kt: 'kotlin', rs: 'rust', golang: 'go', yml: 'yaml', md: 'markdown', html: 'xml', svg: 'xml', tex: 'latex', ps1: 'powershell', objc: 'objectivec', hs: 'haskell', ex: 'elixir', exs: 'elixir', erl: 'erlang', ml: 'ocaml', fs: 'fsharp', jl: 'julia', asm: 'x86asm', docker: 'dockerfile', make: 'makefile', proto: 'protobuf', vb: 'vbnet', clj: 'clojure', scm: 'scheme', el: 'lisp', tsx: 'typescript', jsx: 'javascript', mjs: 'javascript', cjs: 'javascript', h: 'c', hpp: 'cpp', m: 'objectivec', pl: 'perl', text: 'plaintext', txt: 'plaintext' };
  const hlCache = new Map();
  const loadingLangs = new Set();
  const codeSources = new Map();

  function highlight(code, lang) {
    const key = lang + '\u0000' + code;
    const hit = hlCache.get(key);
    if (hit) return hit;
    let out = null;
    const name = ALIAS[lang] || lang;
    if (name && name !== 'plaintext') {
      if (hljs.getLanguage(name)) { try { out = hljs.highlight(code, { language: name, ignoreIllegals: true }).value; } catch (_) {} }
      else if (window.HLJS_LANGS && window.HLJS_LANGS.includes(name)) loadLang(name);
    }
    if (out === null) return esc(code);
    if (hlCache.size > 2000) hlCache.clear();
    hlCache.set(key, out);
    return out;
  }
  function loadLang(name) {
    if (loadingLangs.has(name)) return;
    loadingLangs.add(name);
    const s = document.createElement('script');
    s.src = 'vendor/hljs/languages/' + name + '.min.js';
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
    codeSources.set(key, code); cap(codeSources, 1500);
    const l = (lang || '').toLowerCase();
    const runnable = RUNNABLE.has(l) && !(env && env.streamingFence);
    const out = S.codeOutputs.get(key);
    return '<div class="code-block" dir="ltr" data-key="' + key + '" data-lang="' + esc(l) + '">' +
      '<div class="code-head"><span class="lang">' + esc(l || 'text') + '</span><span>' +
      (runnable ? '<button class="run" data-act="run">▶ Run</button>' : '') + '<button data-act="copy-code">Copy</button></span></div>' +
      '<pre><code class="hljs">' + highlight(code, l) + '</code></pre>' +
      (out ? '<div class="code-output' + (out.failed ? ' failed' : '') + '"><span class="label">Output</span>' + esc(out.text) + '</div>' : '') + '</div>';
  }

  const mermaidSvg = new Map(), mermaidSrc = new Map();
  let mermaidLoading = null, mermaidSeq = 0;
  function renderFence(tok, idx, tokens, env) {
    // The language is the first word, without punctuation models add: ```visual: ```{chart} ```Mermaid, ```python3.
    const info = (tok.info || '').trim(), raw = info.split(/\s+/)[0];
    const lang = raw.replace(/^[{.(\[]+|[}:;,.)\]]+$/g, '').toLowerCase();
    let code = tok.content;
    // Models sometimes put a component's JSON on the fence line itself (```steps [{"title":…}]): that is its content.
    const rest = info.slice(raw.length).trim();
    if (rest && /^[\[{]/.test(rest) && R.fences[lang]) code = rest + '\n' + code;
    else if (rest && !code.trim() && !R.fences[lang]) code = rest;   // ```python print(1)```: the code is on the fence line
    const isLastOpen = env.streaming && env.openFence && idx === env.lastFenceIdx;
    // A stray or mid-line fence leaves an empty block: show nothing rather than an empty code box.
    if (!code.trim() && !isLastOpen) return '';
    const custom = R.fences[lang];
    if (custom) { const out = custom(code, ctx, { open: isLastOpen }); if (out != null) return out; }
    if (lang === 'mermaid' || lang === 'mmd') {
      const key = 'm' + hash(code.trim() + (darkMQ.matches ? 'd' : 'l'));
      mermaidSrc.set(key, code); cap(mermaidSrc, 600);
      const tools = '<div class="diagram-tools"><button data-act="copy-src" data-src-key="' + key + '">Copy source</button></div>';
      if (isLastOpen) return '<div class="mermaid-block" data-key="' + key + '-p"><div class="diagram-pending">Drawing diagram…</div></div>';
      const done = mermaidSvg.get(key);
      if (done && done.error) return '<div class="mermaid-block" data-key="' + key + '">' + tools + '<div class="diagram-error">Diagram error: ' + esc(done.error) + '<pre>' + esc(code) + '</pre></div></div>';
      // The SVG never passes through the HTML sanitizer (it strips Mermaid's <style> and <foreignObject> labels, leaving
      // blank boxes): this is a placeholder that processMermaid fills, from the cache at once or after drawing.
      return '<div class="mermaid-block" data-key="' + key + '" data-pending="1">' + (done ? '' : '<div class="diagram-pending">Drawing diagram…</div>') + '</div>';
    }
    if (lang === 'plot' || lang === 'graph' || lang === 'function-plot') {
      if (isLastOpen) return '<div class="plot-block" data-key="p-pending"><div class="diagram-pending">Plotting…</div></div>';
      try { return '<div class="plot-block" data-key="p' + hash(code) + '">' + Plot.render(code) + '</div>'; }
      catch (e) { return '<div class="plot-block"><div class="diagram-error">Plot error: ' + esc(e.message) + '<pre>' + esc(code) + '</pre></div></div>'; }
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
    return renderCode(code, lang, isLastOpen ? { streamingFence: true } : env);
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
    return src.split('\n').map(line => {
      if (/^\s*subgraph\b/.test(line)) return line.replace(/^(\s*subgraph\s+\S+\s*\[)([^\]]*)(\])\s*$/, (m, a, inner, c) => a + q(inner) + c)
        .replace(/^(\s*subgraph\s+)([^\[\n]*[()][^\[\n]*)$/, (m, a, t) => a + '"' + t.trim().replace(/"/g, '#quot;') + '"');
      return line
        // Edge labels: -->|f(x) = 2x| B
        .replace(/\|([^|\n]+)\|/g, (m, inner) => '|' + q(inner) + '|')
        // [text], {text}, and (text) whose text itself has parentheses — greedy to the last bracket before an arrow.
        .replace(/(\b[\w-]+)\[(?![\[(\/\\"])([^\n]*?)\](?=\s*(?:$|;|-|=|\.|&|:::))/g, (m, id, inner) => id + '[' + q(inner) + ']')
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
  // Wide diagrams scroll at a readable size instead of shrinking their text below 90%.
  function fitDiagram(el) {
    const svg = el.querySelector('svg'); if (!svg || !svg.viewBox || !svg.viewBox.baseVal) return;
    const natural = svg.viewBox.baseVal.width, room = el.clientWidth - 24;
    if (natural && room > 0 && natural * 0.9 > room) { svg.style.maxWidth = 'none'; svg.style.width = Math.round(natural * 0.9) + 'px'; }
  }
  let fillSeq = 0;
  function fillMermaid(el, key) {
    const r = mermaidSvg.get(key), code = mermaidSrc.get(key) || '';
    el.removeAttribute('data-pending');
    const tools = '<div class="diagram-tools"><button data-act="copy-src" data-src-key="' + key + '">Copy source</button></div>';
    // The same diagram twice needs distinct SVG ids (its styles are scoped by id).
    const svg = r.error ? '' : r.replace(/\bmmd(\d+)\b/g, 'mmd$1x' + (++fillSeq));
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
        try { const { svg } = await renderMermaid(code.trim()); mermaidSvg.set(key, svg); cap(mermaidSvg, 300); }
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
  function markdown(text, streaming) {
    const env = { streaming };
    if (streaming) { const f = text.match(/^\s{0,3}(```|~~~)/gm); env.openFence = !!(f && f.length % 2 === 1); }
    try {
      const tokens = md.parse(text, env);
      if (env.openFence) { for (let i = tokens.length - 1; i >= 0; i--) if (tokens[i].type === 'fence') { env.lastFenceIdx = i; break; } }
      return DOMPurify.sanitize(md.renderer.render(tokens, md.options, env), PURIFY);
    } catch (e) { return '<p>' + esc(text) + '</p>'; }
  }
  const inline = s => markdown(String(s == null ? '' : s), false).replace(/^\s*<p>|<\/p>\s*$/g, '');

  // ── Streaming: render only what changed ──
  // A streaming reply is split at blank lines that can't change meaning (outside fences and $$ blocks, not before a
  // list item or an indented continuation). Finished sections come from a cache, so a frame costs O(the tail), not
  // O(the whole reply). Short replies and replies with footnotes/reference links render whole.
  const segCache = new Map();
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
  function markdownLive(text) {
    if (text.length < 3000 || /\[\^|^\s{0,3}\[[^\]]+\]:/m.test(text)) return markdown(text, true);
    const segs = segments(text);
    let html = '';
    for (let i = 0; i < segs.length - 1; i++) {
      let h = segCache.get(segs[i]);
      if (h === undefined) { h = markdown(segs[i], false); segCache.set(segs[i], h); cap(segCache, 400); }
      html += h;
    }
    return html + markdown(segs[segs.length - 1], true);
  }
  /** Keeps a Map to its newest `n` entries (Maps iterate in insertion order). */
  function cap(map, n) { if (map.size > n) { const drop = map.size - n; let k = 0; for (const key of map.keys()) { if (k++ >= drop) break; map.delete(key); } } }

  /** Run component processors (language, tables, canvases…) on freshly inserted DOM. */
  function processNode(node) {
    if (node.nodeType !== 1) return;
    for (const p of R.processors) { try { p(node, ctx); } catch (e) { console.log('processor', e); } }
    processMermaid(node);
  }
  /** Replace children of `el` with new HTML, keeping unchanged top-level nodes so diagrams, selection and processed DOM survive streaming. */
  function morph(el, html) {
    const tpl = document.createElement('template');
    tpl.innerHTML = html;
    const next = Array.from(tpl.content.childNodes);
    const cur = Array.from(el.childNodes);
    let i = 0;
    for (; i < next.length; i++) {
      const n = next[i], c = cur[i];
      const src = n.nodeType === 1 ? n.outerHTML : n.nodeValue;
      if (c && c._src === src) continue;
      n._src = src;
      if (c) el.replaceChild(n, c); else el.appendChild(n);
      processNode(n);
    }
    for (let j = cur.length - 1; j >= i; j--) if (cur[j].parentNode === el) el.removeChild(cur[j]);
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
        const card = document.querySelector('[data-tool-id="' + CSS.escape(b.id) + '"]');
        if (card) renderToolCard(card, card._block);
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
    const rep = (m.blocks || []).find(b => b.meta && b.meta.agentReport);
    if (rep) {
      const r = rep.meta, body = (rep.text || '').replace(/^<background-agent[^>]*>\n?|\n?<\/background-agent>\s*$/g, '');
      el.className = 'msg agent-note';
      return setHTML(el, '<div class="agent-report"><div class="ar-head"><span class="ar-icon">◈</span><span>Background agent <b>' + esc(r.handle || '') + '</b> · ' +
        esc(r.title || '') + ' — ' + (r.state === 'done' ? 'finished' : esc(r.state || 'finished')) + '</span>' +
        '<button class="btn mini" data-act="agent-open" data-agent="' + esc(r.agentReport) + '">Open</button></div>' +
        '<details><summary>Report</summary><div class="md">' + markdown(body, false) + '</div></details></div>');
    }
    const imgs = m.blocks.filter(b => b.kind === 'image'), files = m.blocks.filter(b => b.kind === 'file');
    const text = visibleText(m);
    let html = '';
    if (imgs.length || files.length) {
      html += '<div class="attachments">' + imgs.filter(b => /^[A-Za-z0-9+/=\s]*$/.test(b.data || '')).map(b => '<img src="data:' + esc(/^image\/[\w.+-]+$/.test(b.mime || '') ? b.mime : 'image/png') + ';base64,' + esc(b.data) + '" alt="">').join('') +
        files.map(b => '<span class="file-chip">📄 ' + esc(b.name || 'file') + '</span>').join('') + '</div>';
    }
    if (text) html += '<div class="bubble"><div class="md">' + markdown(text, false) + '</div></div>';
    html += '<div class="msg-actions"><button data-act="edit">Edit</button><button data-act="copy-msg">Copy</button></div>';
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
    const streaming = S.streamingId === m.id;
    const kids = blocksEl.children;
    const blocks = m.blocks || [];
    let vi = 0;
    blocks.forEach((b, i) => {
      if (b.kind === 'thinking' && (!(b.text || '').trim() || !S.showThinking)) return;
      if (b.kind === 'text' && !(b.text || '').length) return;
      let node = kids[vi];
      const want = b.kind + ':' + (b.kind === 'toolUse' ? b.id : i);
      if (!node || node._key !== want) {
        const fresh = document.createElement('div');
        fresh._key = want;
        if (node) blocksEl.insertBefore(fresh, node); else blocksEl.appendChild(fresh);
        node = fresh;
      }
      const isLast = i === blocks.length - 1;
      if (b.kind === 'text') {
        node.className = 'md';
        // Keyed on the streaming flag as well: when the stream ends, an unclosed fence must render as finished.
        const live = streaming && isLast, src = (live ? '\u0001' : '') + b.text;
        if (node._src !== src) { morph(node, live ? markdownLive(b.text) : markdown(b.text, false)); node._src = src; }
      } else if (b.kind === 'thinking') {
        renderThinking(node, b, streaming && isLast);
      } else if (b.kind === 'toolUse') {
        node.className = 'tool-wrap';
        node._block = b;
        node.setAttribute('data-tool-id', b.id);
        renderToolCard(node, b);
      }
      vi++;
    });
    while (kids.length > vi) blocksEl.removeChild(kids[kids.length - 1]);
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
    if (!streaming && endsTurn(m) && blocks.some(b => b.kind === 'text' && (b.text || '').trim())) {
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

  function renderThinking(node, b, live) {
    node.className = '';
    let d = node.querySelector('details');
    if (!d) {
      node.innerHTML = '<details class="thinking"><summary></summary><div class="thinking-body md"></div></details>';
      d = node.querySelector('details');
      d.addEventListener('toggle', () => {
        if (d._prog) { d._prog = false; return; }
        d._user = true;
        const body = d.querySelector('.thinking-body');
        if (d.open && d._b && body._src !== d._b.text) { morph(body, markdown(d._b.text || '', false)); body._src = d._b.text; }
      });
    }
    const setOpen = v => { if (d.open !== v) { d._prog = true; d.open = v; } };
    d._b = b;
    d.classList.toggle('live', live);
    if (!d._user) setOpen(live);
    const words = (b.text || '').trim().split(/\s+/).length;
    d.querySelector('summary').textContent = live ? 'Thinking…' : 'Thought process · ' + words + ' words';
    const body = d.querySelector('.thinking-body');
    if (body._src !== b.text && d.open) {
      morph(body, markdown(b.text || '', live)); body._src = b.text;
      if (live) body.scrollTop = body.scrollHeight;
    }
  }

  // ───────────────────────── Tool cards ─────────────────────────
  const TOOL_META = {
    bash: ['⌘', 'Terminal'], read: ['📄', 'Read'], write: ['✏️', 'Write'], edit: ['✏️', 'Edit'], ls: ['📁', 'List'],
    glob: ['🔎', 'Find files'], grep: ['🔎', 'Search files'], web_search: ['🌐', 'Web search'], web_fetch: ['🌐', 'Read page'],
    run_code: ['▶︎', 'Run code'], math: ['∑', 'Math'], todo_write: ['☑︎', 'Checklist'], task: ['🧭', 'Sub-agent'],
    flashcards: ['🗂', 'Flashcards'], mastery: ['📈', 'Mastery'], lesson_plan: ['🗺', 'Learning plan'], memory_search: ['🧠', 'Recall'],
    memory_save: ['🧠', 'Remember'], memory_update: ['🧠', 'Update memory'], memory_forget: ['🧠', 'Forget'], memory: ['🧠', 'Memory'],
    load_tools: ['🧰', 'Load tools'], agents: ['🧭', 'Sub-agents'], project_memory: ['📒', 'Project memory'],
  };
  const MEMORY_TITLES = { search: 'Recall', save: 'Remember', update: 'Update memory', forget: 'Forget' };
  function summaryOf(b) {
    const i = b.input || {};
    switch (b.name) {
      case 'bash': return i.command || '';
      case 'read': case 'write': case 'edit': case 'ls': return i.path || '';
      case 'glob': case 'grep': return i.pattern || '';
      case 'web_search': return i.query || '';
      case 'web_fetch': return i.url || '';
      case 'run_code': return (i.language || '') + ' snippet';
      case 'math': return (i.operation || '') + ' ' + (i.expression || '');
      case 'task': return (i.resume ? '↻ ' + i.resume + ' · ' : '') + (i.description || '') + (i.model ? ' · ' + i.model : '');
      case 'agents': return (i.action || '') + (i.id ? ' ' + i.id : '');
      case 'project_memory': return (i.action === 'add' ? (i.section ? i.section + ': ' : '') : (i.action || 'view') + ' ') + (i.text || '');
      case 'memory_save': return (i.scope === 'folder' ? '[folder] ' : '') + (i.content || '');
      case 'memory_search': return i.query || '';
      case 'memory_update': case 'memory_forget': return '#' + (i.id || '');
      case 'memory': return i.action === 'search' ? (i.query || '') : i.action === 'save' ? (i.scope === 'folder' ? '[folder] ' : '') + (i.content || '')
        : '#' + (i.id || '') + (i.content ? ' ' + i.content : '');
      case 'load_tools': return (i.names || []).join(', ');
      case 'flashcards': return (i.action || '') + ' ' + (i.deck || '') + (i.cards ? ' · ' + i.cards.length + ' cards' : '');
      case 'mastery': return (i.action || '') + ' ' + (i.concept || i.subject || '');
      case 'lesson_plan': return (i.action || '') + ' ' + (i.title || i.id || '');
      default: return '';
    }
  }

  function renderToolCard(node, b) {
    if (!b) return;
    const r = S.results.get(b.id);
    const pend = S.pending.get(b.id);
    const pendingCall = b.meta && b.meta.pending;
    const custom = R.toolCards[b.name];
    if (custom && !pendingCall && !(pend && pend.kind === 'permission')) {
      const out = custom(b, r, pend, ctx);
      if (out != null) return setHTML(node, out);
    }
    let [icon, title] = TOOL_META[b.name] || ['🔧', b.name];
    if (b.name === 'memory' && b.input && MEMORY_TITLES[b.input.action]) title = MEMORY_TITLES[b.input.action];
    const running = pendingCall || !r || (r.meta && r.meta.running);
    const isErr = r && r.isError;
    const compact = ['memory', 'memory_save', 'memory_search', 'memory_update', 'memory_forget', 'mastery', 'load_tools', 'project_memory'].includes(b.name) && !pend;
    const open = S.openTools.has(b.id) || b.name === 'todo_write' || (b.name === 'lesson_plan' && r && !running);
    let state = running ? '<span class="spinner"></span>' : (isErr ? 'failed' : (r && r.meta && r.meta.ms ? fmtMs(r.meta.ms) : '✓'));
    if (pend && pend.kind === 'permission') state = 'needs approval';
    let html = '';
    if (pend && pend.kind === 'permission') html += renderApproval(b, pend);
    // Sub-agents: open the live transcript in the right-hand panel, or stop just this one.
    const agentID = (r && r.meta && r.meta.agentID) || (b.input && b.input.resume) || b.id;
    const bg = r && r.meta && r.meta.background;
    const agentActs = b.name !== 'task' || pendingCall || (!running && !bg && !(r && r.meta && (r.meta.subagent || r.meta.agentID))) ? ''
      : '<span class="tool-acts">' + (r && r.meta && r.meta.handle ? '<span class="agent-handle">' + esc(r.meta.handle) + (bg ? ' · background' : '') + '</span>' : '') +
        '<button class="btn mini" data-act="agent-open" data-agent="' + esc(agentID) + '">Open</button>' +
        (running ? '<button class="btn mini danger" data-act="agent-stop" data-agent="' + esc(agentID) + '">Stop</button>' : '') + '</span>';
    html += '<div class="tool' + (open ? ' open' : '') + (isErr ? ' error' : '') + (compact && !open ? ' compact' : '') + '">' +
      '<div class="head" data-act="toggle-tool"><span class="icon">' + icon + '</span><span class="name">' + esc(title) + '</span>' +
      '<span class="sum">' + esc(summaryOf(b)) + '</span>' + agentActs + '<span class="state">' + state + '</span></div>' +
      '<div class="body">' + toolBody(b, r) + '</div></div>';
    setHTML(node, html);
  }
  const fmtMs = ms => ms < 1000 ? Math.round(ms) + ' ms' : (ms / 1000).toFixed(1) + ' s';

  function toolBody(b, r) {
    const i = b.input || {};
    const out = r ? (r.text || '') : (S.progress.get(b.id) || '');
    const pre = (s, max = 20000) => '<pre>' + esc(s.length > max ? s.slice(0, max) + '\n…' : s) + '</pre>';
    switch (b.name) {
      case 'bash': return '<div class="label">Command</div>' + pre(i.command || '') + (out ? '<div class="label">Output</div>' + pre(out) : '');
      case 'run_code': return renderCode(i.code || '', i.language || '', { streamingFence: true }) + (out ? '<div class="label">Output</div>' + pre(out) : '');
      case 'web_search': {
        const res = r && r.meta && r.meta.results;
        if (!res) return out ? pre(out) : '';
        return '<ul class="results">' + res.map(x => '<li><a class="t" href="' + esc(x.url) + '">' + esc(x.title) + '</a><div class="u">' + esc(x.url) + '</div><div class="s">' + esc(x.snippet) + '</div></li>').join('') + '</ul>';
      }
      case 'web_fetch': {
        const t = r && r.meta && r.meta.title;
        return '<div><a href="' + esc(i.url) + '">' + esc(t || i.url) + '</a></div>' + (out ? '<div class="label">Extracted</div>' + pre(out, 4000) : '');
      }
      case 'edit': return '<div class="label">' + esc(i.path) + '</div><pre class="diff"><span class="del">' + esc(i.old_string || '') + '</span><span class="add">' + esc(i.new_string || '') + '</span></pre>' + (out ? '<div class="label">Result</div>' + pre(out) : '');
      case 'write': return renderCode(i.content || '', (i.path || '').split('.').pop(), { streamingFence: true }) + (out ? pre(out) : '');
      case 'math': { const latex = r && r.meta && r.meta.latex; return (latex ? tex(latex, true) : '') + (out ? pre(out) : ''); }
      case 'todo_write':
        return '<ul class="todo">' + (i.todos || []).map(t => '<li class="' + esc(t.status) + '">' + (t.status === 'completed' ? '✓' : t.status === 'in_progress' ? '▸' : '○') + ' <span>' + esc(t.content) + '</span></li>').join('') + '</ul>';
      case 'flashcards':
        if (i.action === 'add' && i.cards) return '<div class="md">' + i.cards.slice(0, 30).map(c => '<p><b>Q:</b> ' + inline(c.front) + '<br><b>A:</b> ' + inline(c.back) + '</p>').join('') + '</div>' + (out ? pre(out) : '');
        return out ? pre(out) : '';
      case 'lesson_plan': return out ? '<div class="md plan">' + markdown(out.replace(/^# /, '#### '), false) + '</div>' : '';
      case 'task': return '<div class="label">Brief</div><div class="md">' + markdown(i.prompt || '', false) + '</div>' + (out ? '<div class="label">Report</div><div class="md">' + markdown(out, false) + '</div>' : (S.progress.get(b.id) ? pre(S.progress.get(b.id)) : ''));
      default: return (Object.keys(i).length ? '<div class="label">Input</div>' + pre(JSON.stringify(i, null, 2)) : '') + (out ? '<div class="label">Result</div>' + pre(out) : '');
    }
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
    el._html = null; renderToolCard(el, el._block);   // setHTML keeps focus and caret
  }
  const ctx = {
    esc, hash, tex, post, inline,
    pending: id => S.pending.get(id),
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
    if (R.actions[act]) { R.actions[act](el, e, ctx); return; }
    const msgEl = el.closest('.msg');
    const msgId = msgEl ? msgEl.id.slice(2) : null;
    const toolEl = el.closest('[data-tool-id]');
    const toolId = toolEl ? toolEl.getAttribute('data-tool-id') : null;
    switch (act) {
      case 'toggle-tool':
        if (S.openTools.has(toolId)) S.openTools.delete(toolId); else S.openTools.add(toolId);
        toolEl._html = null; renderToolCard(toolEl, toolEl._block); break;
      case 'copy-code': { const k = el.closest('.code-block').getAttribute('data-key'); post({ type: 'copy', text: codeSources.get(k) || '' }); ctx.flash(el, 'Copied'); break; }
      case 'copy-src': post({ type: 'copy', text: mermaidSrc.get(el.getAttribute('data-src-key')) || '' }); ctx.flash(el, 'Copied'); break;
      case 'run': {
        const blk = el.closest('.code-block'); const k = blk.getAttribute('data-key');
        el.textContent = 'Running…'; el.disabled = true;
        post({ type: 'run', key: k, lang: blk.getAttribute('data-lang'), code: codeSources.get(k) || '' }); break;
      }
      case 'copy-msg': { const rec = S.byId.get(msgId); post({ type: 'copy', text: rec ? visibleText(rec.msg) : '' }); ctx.flash(el, 'Copied'); break; }
      case 'speak': { const rec = S.byId.get(msgId); post({ type: 'speak', text: rec ? visibleText(rec.msg) : '' }); break; }
      case 'regenerate': post({ type: 'regenerate' }); break;
      case 'retry': post({ type: 'retry' }); break;
      case 'quick': post({ type: 'quick', q: el.getAttribute('data-q'), id: msgId }); break;
      case 'suggest': post({ type: 'suggest', text: el.getAttribute('data-text') }); break;
      case 'edit': startEdit(msgId); break;
      case 'edit-save': { const ta = msgEl.querySelector('textarea'); msgEl._editing = false; post({ type: 'edit', id: msgId, text: ta.value }); break; }
      case 'edit-cancel': { msgEl._editing = false; msgEl._html = null; renderMessage(S.byId.get(msgId).msg); break; }
      case 'approve': post({ type: 'answer', id: toolId, value: { decision: el.getAttribute('data-v') } }); break;
      case 'older': el.disabled = true; el.textContent = 'Loading…'; post({ type: 'older' }); break;
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
    const sug = (w.suggestions || []).map(s => '<div class="suggestion" data-act="suggest" data-text="' + esc(s.prompt) + '"><div class="t">' + esc(s.title) + '</div><div class="d">' + esc(s.subtitle || '') + '</div></div>').join('');
    const stats = (w.stats || []).map(s => '<span class="pill">' + esc(s) + '</span>').join('');
    thread.innerHTML = '<div class="welcome"><div class="logo">🎓</div><h1>' + esc(w.title || 'What would you like to learn?') + '</h1><p>' + esc(w.subtitle || '') + '</p><div class="suggestions">' + sug + '</div>' + (stats ? '<div class="stats">' + stats + '</div>' : '') + '</div>';
  }

  // ───────────────────────── API for Swift ─────────────────────────
  window.T = {
    reset(messages, opts) {
      if (R.pauseVisuals) R.pauseVisuals(opts && opts.pauseVisuals);
      document.body.classList.toggle('agent-mode', !!(opts && opts.agent));   // a coding session: no teaching chips
      S.messages = []; S.byId.clear(); S.results.clear(); S.dirty.clear(); S.progress.clear();
      S.streamingId = null; S.welcome = (opts && opts.welcome) || null;
      S.showThinking = !opts || opts.showThinking !== false;
      thread.innerHTML = '';
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
      markLast();
      const anchor = opts && opts.anchor && document.getElementById('m-' + opts.anchor);
      if (anchor) { stick = false; anchor.scrollIntoView({ block: 'start' }); return; }
      stick = true; scrollBottom(false);
      requestAnimationFrame(() => scrollBottom(false));
    },
    upsert(m) {
      if (thread.querySelector('.welcome')) { thread.innerHTML = ''; stick = true; }
      const rec = S.byId.get(m.id);
      if (rec) { const i = S.messages.findIndex(x => x.id === m.id); if (i >= 0) S.messages[i] = m; rec.msg = m; }
      else {
        S.messages.push(m); S.byId.set(m.id, { msg: m, el: null });
        if (m.role === 'assistant') S.streamingId = m.id;
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
      S.streamingId = id;
      schedule(id);
    },
    toolProgress(toolId, text) {
      S.progress.set(toolId, ((S.progress.get(toolId) || '') + text).slice(-20000));
      const el = document.querySelector('[data-tool-id="' + CSS.escape(toolId) + '"]');
      if (el && S.openTools.has(toolId)) renderToolCard(el, el._block);
    },
    interaction(p, active) {
      if (active) S.pending.set(p.id, p); else S.pending.delete(p.id);
      const el = document.querySelector('[data-tool-id="' + CSS.escape(p.id) + '"]');
      if (el) { el._html = null; renderToolCard(el, el._block); if (active) el.scrollIntoView({ block: 'nearest', behavior: 'smooth' }); }
    },
    status(text, running) {
      S.running = !!running;
      if (!running) { const sid = S.streamingId; S.streamingId = null; if (sid) schedule(sid); }
      statusEl.hidden = !text;
      statusEl.querySelector('.label').textContent = text || '';
    },
    codeOutput(key, text, failed) {
      S.codeOutputs.set(key, { text, failed });
      document.querySelectorAll('.code-block[data-key="' + key + '"]').forEach(el => {
        let o = el.querySelector('.code-output');
        if (!o) { o = document.createElement('div'); el.appendChild(o); }
        o.className = 'code-output' + (failed ? ' failed' : '');
        o.innerHTML = '<span class="label">Output</span>' + esc(text);
        const btn = el.querySelector('[data-act="run"]'); if (btn) { btn.textContent = '▶ Run'; btn.disabled = false; }
      });
    },
    notice(text) { if (window.TeacherToast) window.TeacherToast(text); },
    setFontSize(px) { document.documentElement.style.setProperty('--font-size', px + 'px'); },
    card(front, back, show) {
      document.body.classList.add('card-mode');
      thread.innerHTML = '<div class="flashcard"><div class="face md">' + markdown(front || '', false) + '</div>' +
        (show ? '<div class="divider"></div><div class="face back md">' + markdown(back || '', false) + '</div>' : '') + '</div>';
      processNode(thread);
    },
    scrollToBottom() { stick = true; scrollBottom(true); },
  };
  darkMQ.addEventListener('change', () => {
    mermaidSvg.clear();
    if (window.mermaid) mermaid.initialize(mermaidConfig());
    for (const m of S.messages) { const r = S.byId.get(m.id); if (r && r.el) { r.el.querySelectorAll('.md').forEach(n => { n._src = null; }); schedule(m.id); } }
  });
  post({ type: 'ready' });
})();
