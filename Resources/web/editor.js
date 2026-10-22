// The exercise editor: the learner's project files in CodeMirror, saved as they type; Run, Test and Submit go to the app,
// which runs them sandboxed and sends back only the output. The hidden tests and the teacher's solution never come here.
(function () {
  'use strict';
  const C = window.CM;
  const $ = s => document.querySelector(s);
  const post = m => { if (window.__onPost) window.__onPost(m); try { window.webkit.messageHandlers.exercise.postMessage(m); } catch (e) {} };
  const S = { ex: null, files: {}, states: new Map(), current: null, view: null, timers: {}, busy: null };

  // Token colours from CSS variables, so light and dark follow the system.
  const style = C.HighlightStyle.define([
    { tag: [C.tags.keyword, C.tags.controlKeyword, C.tags.moduleKeyword, C.tags.operatorKeyword, C.tags.definitionKeyword], color: 'var(--tk-kw)' },
    { tag: [C.tags.string, C.tags.special(C.tags.string), C.tags.regexp], color: 'var(--tk-str)' },
    { tag: [C.tags.number, C.tags.bool, C.tags.null, C.tags.atom], color: 'var(--tk-num)' },
    { tag: [C.tags.comment, C.tags.lineComment, C.tags.blockComment, C.tags.docComment], color: 'var(--tk-com)', fontStyle: 'italic' },
    { tag: [C.tags.function(C.tags.variableName), C.tags.function(C.tags.propertyName)], color: 'var(--tk-fn)' },
    { tag: [C.tags.typeName, C.tags.className, C.tags.namespace], color: 'var(--tk-type)' },
    { tag: [C.tags.propertyName, C.tags.attributeName], color: 'var(--tk-prop)' },
    { tag: [C.tags.meta, C.tags.annotation, C.tags.processingInstruction], color: 'var(--tk-meta)' },
    { tag: [C.tags.operator, C.tags.punctuation], color: 'var(--tk-op)' },
    { tag: C.tags.heading, fontWeight: '700', color: 'var(--tk-fn)' },
    { tag: C.tags.emphasis, fontStyle: 'italic' }, { tag: C.tags.strong, fontWeight: '700' },
  ]);
  const theme = C.EditorView.theme({
    '&': { height: '100%', fontSize: '13px', color: 'var(--fg)', backgroundColor: 'var(--bg)' },
    '.cm-content': { fontFamily: 'var(--mono)', caretColor: 'var(--accent)' },
    '.cm-scroller': { fontFamily: 'var(--mono)', lineHeight: '1.5' },
    '.cm-gutters': { backgroundColor: 'var(--panel)', color: 'var(--muted)', borderRight: '1px solid var(--border)' },
    '.cm-activeLine': { backgroundColor: 'var(--accent-soft)' }, '.cm-activeLineGutter': { backgroundColor: 'var(--accent-soft)' },
    '&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection': { backgroundColor: 'var(--sel) !important' },
    '.cm-cursor': { borderLeftColor: 'var(--accent)' },
    '.cm-tooltip': { backgroundColor: 'var(--panel)', border: '1px solid var(--border)', color: 'var(--fg)' },
  });

  const LANG = {
    py: () => C.python(), js: () => C.javascript(), mjs: () => C.javascript(), cjs: () => C.javascript(), jsx: () => C.javascript({ jsx: true }),
    ts: () => C.javascript({ typescript: true }), tsx: () => C.javascript({ typescript: true, jsx: true }),
    c: () => C.cpp(), h: () => C.cpp(), cc: () => C.cpp(), cpp: () => C.cpp(), hpp: () => C.cpp(), cxx: () => C.cpp(),
    rs: () => C.rust(), go: () => C.go(), java: () => C.java(), html: () => C.html(), css: () => C.css(), json: () => C.json(),
    md: () => C.markdown(), sql: () => C.sql(), swift: () => C.StreamLanguage.define(C.swift), rb: () => C.StreamLanguage.define(C.ruby),
    sh: () => C.StreamLanguage.define(C.shell), zsh: () => C.StreamLanguage.define(C.shell), bash: () => C.StreamLanguage.define(C.shell),
    toml: () => C.StreamLanguage.define(C.toml), yaml: () => C.StreamLanguage.define(C.yaml), yml: () => C.StreamLanguage.define(C.yaml),
  };
  const langFor = path => { const ext = (path.split('.').pop() || '').toLowerCase(); return LANG[ext] ? [LANG[ext]()] : []; };

  function makeState(path, text) {
    return C.EditorState.create({
      doc: text,
      extensions: [
        C.lineNumbers(), C.highlightActiveLineGutter(), C.highlightSpecialChars(), C.history(), C.foldGutter(), C.drawSelection(),
        C.dropCursor(), C.indentOnInput(), C.bracketMatching(), C.closeBrackets(), C.autocompletion(), C.rectangularSelection(),
        C.crosshairCursor(), C.highlightActiveLine(), C.highlightSelectionMatches(), C.indentUnit.of('    '),
        C.syntaxHighlighting(style), theme,
        C.keymap.of([...C.closeBracketsKeymap, ...C.defaultKeymap, ...C.searchKeymap, ...C.historyKeymap, ...C.foldKeymap,
          ...C.completionKeymap, C.indentWithTab]),
        C.EditorView.updateListener.of(u => { if (u.docChanged) scheduleSave(path, u.state.doc.toString()); }),
        ...langFor(path),
      ],
    });
  }

  function scheduleSave(path, text) {
    S.files[path] = text;
    clearTimeout(S.timers[path]);
    S.timers[path] = setTimeout(() => post({ type: 'save', path, content: text }), 400);
  }
  function flushSaves() {
    for (const p of Object.keys(S.timers)) { clearTimeout(S.timers[p]); post({ type: 'save', path: p, content: S.files[p] }); }
    S.timers = {};
  }

  function open(path) {
    if (!(path in S.files)) return;
    if (S.view && S.current) S.states.set(S.current, S.view.state);
    S.current = path;
    let st = S.states.get(path);
    if (!st) { st = makeState(path, S.files[path]); S.states.set(path, st); }
    if (!S.view) S.view = new C.EditorView({ state: st, parent: $('#editor') });
    else S.view.setState(st);
    $('#file-name').textContent = path;
    renderList();
    S.view.focus();
  }

  function renderList() {
    const ul = $('#file-list');
    ul.innerHTML = '';
    Object.keys(S.files).sort((a, b) => (a === 'BRIEF.md') - (b === 'BRIEF.md') || a.localeCompare(b)).forEach(p => {
      const li = document.createElement('li');
      li.className = p === S.current ? 'active' : '';
      li.dataset.path = p;
      li.innerHTML = '<span class="name"></span><button class="icon del" title="Delete">×</button>';
      li.querySelector('.name').textContent = p;
      ul.appendChild(li);
    });
  }

  function setStatus(text, cls) { const s = $('#status'); s.textContent = text || ''; s.className = 'status ' + (cls || ''); }
  function notice(text) {
    const n = document.createElement('div'); n.className = 'notice'; n.textContent = text; document.body.appendChild(n);
    setTimeout(() => n.remove(), 2600);
  }

  // ── From the app ──
  window.EX = {
    load(d) {
      const keep = S.current;
      S.ex = d; S.files = Object.assign({}, d.files || {});
      for (const p of Array.from(S.states.keys())) if (!(p in S.files)) S.states.delete(p);
      $('#run-btn').hidden = !d.canRun;
      $('#brief').innerHTML = window.markdownit ? window.markdownit({ html: false, linkify: true }).render(d.brief || '') : '';
      setStatus(d.passed ? 'Tests pass' : d.attempts ? d.attempts + ' test run' + (d.attempts === 1 ? '' : 's') : '', d.passed ? 'pass' : '');
      if (d.lastOutput && !S.shownOutput) { $('#output').textContent = d.lastOutput; S.shownOutput = true; }
      const first = keep in S.files ? keep : Object.keys(S.files).filter(p => p !== 'BRIEF.md').sort()[0] || Object.keys(S.files)[0];
      if (first) { S.current = null; open(first); } else renderList();
    },
    busy(kind) {
      S.busy = kind;
      document.querySelectorAll('.bar .btn[data-cmd]').forEach(b => { if (b.dataset.cmd !== 'brief') b.disabled = true; });
      setStatus(kind === 'run' ? 'Running…' : kind === 'test' ? 'Testing…' : 'Submitting…', 'busy');
      $('#output-title').textContent = kind === 'run' ? 'Program output' : 'Test output';
    },
    output(r) {
      S.busy = null;
      document.querySelectorAll('.bar .btn[data-cmd]').forEach(b => { b.disabled = false; });
      $('#output').textContent = r.text || '(no output)';
      $('#output').scrollTop = $('#output').scrollHeight;
      if (r.kind === 'run') setStatus(r.ok ? 'Ran' : 'Exited with an error', r.ok ? '' : 'fail');
      else setStatus(r.ok ? (r.kind === 'submit' ? 'Submitted · tests pass' : 'Tests pass') : (r.kind === 'submit' ? 'Submitted · tests fail' : 'Tests fail'), r.ok ? 'pass' : 'fail');
    },
    notice,
    state: () => ({ files: Object.keys(S.files), current: S.current, text: S.view && S.view.state.doc.toString() }),
  };

  // ── Learner actions ──
  function command(cmd) {
    if (cmd === 'brief') { const b = $('#brief'); b.hidden = !b.hidden; return; }
    if (cmd === 'clear') { $('#output').textContent = ''; return; }
    if (cmd === 'new') {
      const name = prompt('New file (path inside the project):', '');
      if (name && name.trim()) post({ type: 'create', path: name.trim() });
      return;
    }
    if (['run', 'test', 'submit'].includes(cmd)) {
      if (S.busy) return;
      flushSaves();
      post({ type: cmd });
    }
  }
  document.addEventListener('click', e => {
    const b = e.target.closest('[data-cmd]'); if (b) { command(b.dataset.cmd); return; }
    const del = e.target.closest('#file-list .del');
    if (del) { const p = del.closest('li').dataset.path; if (confirm('Delete ' + p + '?')) { flushSaves(); post({ type: 'delete', path: p }); } return; }
    const li = e.target.closest('#file-list li'); if (li) open(li.dataset.path);
  });
  document.addEventListener('dblclick', e => {
    const li = e.target.closest('#file-list li'); if (!li) return;
    const from = li.dataset.path, to = prompt('Rename to:', from);
    if (to && to.trim() && to.trim() !== from) { flushSaves(); post({ type: 'rename', from, to: to.trim() }); }
  });
  document.addEventListener('keydown', e => {
    if (!e.metaKey) return;
    if (e.key === 'Enter') { e.preventDefault(); command(e.shiftKey ? 'submit' : 'test'); }
    else if (e.key === 'r' || e.key === 'R') { e.preventDefault(); command('run'); }
    else if (e.key === 's' || e.key === 'S') { e.preventDefault(); flushSaves(); notice('Saved'); }
  }, true);

  // The output panel's height follows the splitter.
  const splitter = $('#splitter');
  splitter.addEventListener('pointerdown', e => {
    splitter.setPointerCapture(e.pointerId);
    const out = document.querySelector('.output'), work = document.querySelector('.work').getBoundingClientRect();
    const move = ev => { out.style.height = Math.max(60, Math.min(work.height - 120, work.bottom - ev.clientY)) + 'px'; };
    splitter.addEventListener('pointermove', move);
    splitter.addEventListener('pointerup', () => splitter.removeEventListener('pointermove', move), { once: true });
  });

  post({ type: 'ready' });
})();
