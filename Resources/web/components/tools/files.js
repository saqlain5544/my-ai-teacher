// Tool cards for the file and shell tools: bash, read, write, edit, ls, glob, grep, run_tests, run_code.
// A descriptor gives the card its icon, title, one-line summary and opened body; the core draws the frame.
(function () {
  'use strict';
  const R = window.TeacherUI;
  const input = n => n.props.input || {};
  const path = n => input(n).path || input(n).file_path || '';   // models used to Claude Code's tools send file_path (the app maps it)
  const output = (n, ctx, label) => n.props.output ? (label ? '<div class="label">' + label + '</div>' : '') + ctx.pre(n.props.output) : '';
  /** A file's language from its name (`App.tsx` → tsx, `Dockerfile` → dockerfile), for highlighting. */
  const lang = p => {
    const base = String(p || '').split('/').pop().toLowerCase();
    if (base === 'dockerfile' || base === 'makefile') return base;
    const m = /\.([a-z0-9+#]+)$/.exec(base);
    return m ? m[1] : '';
  };
  /** A command's output, apart from the notes the app adds for the agent: the "[It now runs in the background…]" kind of
   *  bracketed note at the end and the "Background jobs: …" summary. Those are for the model; the person sees them small. */
  function splitNotes(text) {
    let body = String(text || '').replace(/\s+$/, '');
    const notes = [];
    for (let guard = 0; guard < 4; guard++) {
      const jobs = body.search(/(^|\n)Background jobs: /);
      if (jobs >= 0) { notes.unshift(body.slice(jobs).trim()); body = body.slice(0, jobs).replace(/\s+$/, ''); continue; }
      if (body.endsWith(']')) {
        const open = body.lastIndexOf('\n[');
        const start = open >= 0 ? open + 1 : (body.startsWith('[') ? 0 : -1);
        if (start >= 0 && body.length - start > 40) { notes.unshift(body.slice(start).trim()); body = body.slice(0, start).replace(/\s+$/, ''); continue; }
      }
      break;
    }
    return { body, notes };
  }
  /** A command's output as a console block under its own label (with the exit code), the agent's notes as footnotes. */
  function shellOutput(n, ctx) {
    const text = n.props.output;
    if (!text) return '';
    const m = (n.props.result && n.props.result.meta) || {};
    const exit = typeof m.exit === 'number' ? '<span class="exit ' + (m.exit === 0 ? 'ok' : 'bad') + '">exit ' + m.exit + '</span>' : '';
    const { body, notes } = splitNotes(text);
    return '<div class="label">Output' + exit + '</div>' +
      (body ? '<pre class="console">' + ctx.esc(body.length > 20000 ? body.slice(0, 20000) + '\n…' : body) + '</pre>' : '<div class="console-empty">No output</div>') +
      notes.map(t => '<div class="tool-note">' + ctx.esc(t) + '</div>').join('');
  }
  /** Code in the file's colours (plain when the language is unknown). */
  const hl = (ctx, code, l) => '<pre class="hl"><code class="hljs">' + ctx.highlight(code, l) + '</code></pre>';
  /** `read`'s numbered lines (cat -n): the numbers in a gutter, the code highlighted beside them; any note after, plain. */
  function numbered(ctx, text, l) {
    const rows = String(text).split('\n'), nums = [], code = [];
    let i = 0;
    for (; i < rows.length; i++) {
      const m = /^\s*(\d+)\t(.*)$/.exec(rows[i]);
      if (!m) break;
      nums.push(m[1]); code.push(m[2]);
    }
    if (!nums.length) return ctx.pre(text);
    const rest = rows.slice(i).join('\n').trim();
    return '<div class="code-file"><pre class="gutter" aria-hidden="true">' + nums.join('\n') + '</pre>' +
      '<pre class="hl"><code class="hljs">' + ctx.highlight(code.join('\n'), l) + '</code></pre></div>' + (rest ? ctx.pre(rest) : '');
  }

  R.defineTool({ name: 'bash', icon: 'terminal', tone: 'slate', title: 'Terminal', summary: n => input(n).command || '',
    // Running: the learner can send it to the background (the agent carries on). Backgrounded: its handle, and Stop.
    headActions(n, ctx) {
      const m = (n.props.result && n.props.result.meta) || {};
      // Running, not waiting for approval: "Background" for a command that hasn't started made no sense.
      if (n.props.status === 'running' && !(n.props.interaction && n.props.interaction.kind === 'permission')) return '<span class="tool-acts"><button class="btn mini" data-act="tool-background" title="Let it run in the background; the agent carries on">Background</button></span>';
      if (!m.background || n.props.status === 'pending') return '';
      return '<span class="tool-acts"><span class="agent-handle">' + ctx.esc(m.background) + ' · background' + (m.url ? ' · ' + ctx.esc(m.url) : '') + '</span>' +
        '<button class="btn mini danger" data-act="job-stop" data-job="' + ctx.esc(m.background) + '">Stop</button></span>';
    },
    body: (n, ctx) => '<div class="label">Command</div><pre class="hl command"><code class="hljs">' + ctx.highlight(input(n).command || '', 'bash') + '</code></pre>' +
      shellOutput(n, ctx) });
  R.defineTool({ name: 'read', icon: 'file-text', tone: 'blue', title: 'Read', summary: path,
    body: (n, ctx) => n.props.output ? (n.props.result && n.props.result.isError ? ctx.pre(n.props.output) : numbered(ctx, n.props.output, lang(path(n)))) : '' });
  R.defineTool({ name: 'write', icon: 'file-plus', tone: 'blue', title: 'Write', summary: path,
    body: (n, ctx) => ctx.code(input(n).content || '', path(n).split('.').pop()) + output(n, ctx) });
  R.defineTool({ name: 'edit', icon: 'pencil', tone: 'blue', title: 'Edit', summary: path,
    body: (n, ctx) => {
      const i = input(n);
      const changes = (i.old_string != null ? [i] : []).concat(Array.isArray(i.edits) ? i.edits : []);
      return '<div class="label path">' + ctx.esc(path(n)) + (changes.length > 1 ? ' · ' + changes.length + ' changes' : '') + '</div>' +
        changes.map(c => '<pre class="diff hljs"><span class="del">' + ctx.highlight(c.old_string || '', lang(path(n))) + '</span><span class="add">' +
          ctx.highlight(c.new_string || '', lang(path(n))) + '</span></pre>').join('') +
        output(n, ctx, 'Result');
    } });
  R.defineTool({ name: 'ls', icon: 'folder', tone: 'blue', title: 'List', summary: path });
  R.defineTool({ name: 'glob', icon: 'search', tone: 'blue', title: 'Find files', summary: n => input(n).pattern || '' });
  R.defineTool({ name: 'grep', icon: 'text-search', tone: 'blue', title: 'Search files', summary: n => input(n).pattern || '' });
  // ── run_tests: a pass/fail card the learner can re-run without asking (the app runs the same tests and tells the
  // teacher with their next message) ──
  const reruns = new Map();   // tool id → the latest re-run's result meta
  R.onLessonChange(() => reruns.clear());
  const testsMeta = n => reruns.get(n.props.callId) || (n.props.result && n.props.result.meta) || null;
  let lastCtx = null;
  window.TeacherTests = {
    update(id, meta) { reruns.set(id, Object.assign({ rerun: true }, meta)); if (lastCtx) lastCtx.refreshCard(id); },
    failed(id, msg) { reruns.set(id, { error: msg }); if (lastCtx) lastCtx.refreshCard(id); },
  };
  R.defineTool({ name: 'run_tests', icon: 'flask', tone: 'green', title: 'Tests',
    summary: n => { const m = testsMeta(n); return m && m.total != null ? m.passed + '/' + m.total + ' passing' + (m.rerun ? ' · re-run' : '') : (input(n).command || input(n).filter || ''); },
    open: n => { const m = testsMeta(n); return !!(m && (m.rerun || m.error || (m.total != null && m.passed < m.total))); },
    body(n, ctx) {
      lastCtx = ctx;
      const m = testsMeta(n);
      if (m && m.error) return '<div class="tests-error">' + ctx.esc(m.error) + '</div>';
      if (!m || !Array.isArray(m.tests)) return output(n, ctx);
      const rows = m.tests.map(t => {
        const cases = t.cases ? ' <span class="tests-cases">' + t.cases.passed + ' passed' + (t.cases.failed ? ', ' + t.cases.failed + ' failed' : '') + '</span>' : '';
        const head = '<span class="tests-mark ' + (t.passed ? 'ok' : 'bad') + '">' + R.icon(t.passed ? 'check-circle' : 'x-circle') + '</span><code>' + ctx.esc(t.name) + '</code>' + cases +
          '<span class="tests-time">' + (+t.seconds || 0).toFixed(1) + ' s</span>';
        return t.passed ? '<div class="tests-row">' + head + '</div>'
          : '<details class="tests-row" open><summary>' + head + '</summary>' + ctx.pre(String(t.output || '').slice(-3000)) + '</details>';
      }).join('');
      const done = n.props.status === 'done' || n.props.status === 'error' || m.rerun;
      return '<div class="tests' + (m.passed === m.total ? ' all-pass' : '') + '"><div class="tests-head"><b>' + m.passed + ' of ' + m.total + ' passing</b>' +
        (m.rerun ? '<span class="tests-note">re-run by you</span>' : '') +
        (done ? '<button class="btn mini" data-act="tests-rerun">' + R.icon('refresh') + 'Run again</button>' : '') + '</div>' + rows + '</div>';
    } });
  R.registerAction('tests-rerun', (el, e, ctx) => {
    const card = el.closest('[data-tool-id]'); if (!card || !card._block) return;
    lastCtx = ctx; el.disabled = true; el.innerHTML = '<span class="spinner"></span>Running…';
    const i = card._block.input || {};
    ctx.post({ type: 'runTests', id: card.getAttribute('data-tool-id'), input: { command: i.command || null, path: i.path || null, filter: i.filter || null } });
  });
  R.defineTool({ name: 'run_code', icon: 'play', tone: 'slate', title: 'Run code', summary: n => (input(n).language || '') + ' snippet',
    body: (n, ctx) => ctx.code(input(n).code || '', input(n).language || '') + output(n, ctx, 'Output') });
})();
