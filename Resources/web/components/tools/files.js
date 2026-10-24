// Tool cards for the file and shell tools: bash, read, write, edit, ls, glob, grep, run_tests, run_code.
// A descriptor gives the card its icon, title, one-line summary and opened body; the core draws the frame.
(function () {
  'use strict';
  const R = window.TeacherUI;
  const input = n => n.props.input || {};
  const path = n => input(n).path || '';
  const output = (n, ctx, label) => n.props.output ? (label ? '<div class="label">' + label + '</div>' : '') + ctx.pre(n.props.output) : '';

  R.defineTool({ name: 'bash', icon: '⌘', title: 'Terminal', summary: n => input(n).command || '',
    // Running: the learner can send it to the background (the agent carries on). Backgrounded: its handle, and Stop.
    headActions(n, ctx) {
      const m = (n.props.result && n.props.result.meta) || {};
      if (n.props.status === 'running') return '<span class="tool-acts"><button class="btn mini" data-act="tool-background" title="Let it run in the background; the agent carries on">Background</button></span>';
      if (!m.background || n.props.status === 'pending') return '';
      return '<span class="tool-acts"><span class="agent-handle">' + ctx.esc(m.background) + ' · background' + (m.url ? ' · ' + ctx.esc(m.url) : '') + '</span>' +
        '<button class="btn mini danger" data-act="job-stop" data-job="' + ctx.esc(m.background) + '">Stop</button></span>';
    },
    body: (n, ctx) => '<div class="label">Command</div>' + ctx.pre(input(n).command || '') + output(n, ctx, 'Output') });
  R.defineTool({ name: 'read', icon: '📄', title: 'Read', summary: path });
  R.defineTool({ name: 'write', icon: '✏️', title: 'Write', summary: path,
    body: (n, ctx) => ctx.code(input(n).content || '', path(n).split('.').pop()) + output(n, ctx) });
  R.defineTool({ name: 'edit', icon: '✏️', title: 'Edit', summary: path,
    body: (n, ctx) => {
      const i = input(n);
      const changes = (i.old_string != null ? [i] : []).concat(Array.isArray(i.edits) ? i.edits : []);
      return '<div class="label">' + ctx.esc(i.path) + (changes.length > 1 ? ' · ' + changes.length + ' changes' : '') + '</div>' +
        changes.map(c => '<pre class="diff"><span class="del">' + ctx.esc(c.old_string || '') + '</span><span class="add">' + ctx.esc(c.new_string || '') + '</span></pre>').join('') +
        output(n, ctx, 'Result');
    } });
  R.defineTool({ name: 'ls', icon: '📁', title: 'List', summary: path });
  R.defineTool({ name: 'glob', icon: '🔎', title: 'Find files', summary: n => input(n).pattern || '' });
  R.defineTool({ name: 'grep', icon: '🔎', title: 'Search files', summary: n => input(n).pattern || '' });
  // ── run_tests: a pass/fail card the learner can re-run without asking (the app runs the same tests and tells the
  // teacher with their next message) ──
  const reruns = new Map();   // tool id → the latest re-run's result meta
  const testsMeta = n => reruns.get(n.props.callId) || (n.props.result && n.props.result.meta) || null;
  let lastCtx = null;
  window.TeacherTests = {
    update(id, meta) { reruns.set(id, Object.assign({ rerun: true }, meta)); if (lastCtx) lastCtx.refreshCard(id); },
    failed(id, msg) { reruns.set(id, { error: msg }); if (lastCtx) lastCtx.refreshCard(id); },
  };
  R.defineTool({ name: 'run_tests', icon: '🧪', title: 'Tests',
    summary: n => { const m = testsMeta(n); return m && m.total != null ? m.passed + '/' + m.total + ' passing' + (m.rerun ? ' · re-run' : '') : (input(n).command || input(n).filter || ''); },
    open: n => { const m = testsMeta(n); return !!(m && (m.rerun || m.error || (m.total != null && m.passed < m.total))); },
    body(n, ctx) {
      lastCtx = ctx;
      const m = testsMeta(n);
      if (m && m.error) return '<div class="tests-error">' + ctx.esc(m.error) + '</div>';
      if (!m || !Array.isArray(m.tests)) return output(n, ctx);
      const rows = m.tests.map(t => {
        const cases = t.cases ? ' <span class="tests-cases">' + t.cases.passed + ' passed' + (t.cases.failed ? ', ' + t.cases.failed + ' failed' : '') + '</span>' : '';
        const head = '<span class="tests-mark ' + (t.passed ? 'ok' : 'bad') + '">' + (t.passed ? '✓' : '✗') + '</span><code>' + ctx.esc(t.name) + '</code>' + cases +
          '<span class="tests-time">' + (+t.seconds || 0).toFixed(1) + ' s</span>';
        return t.passed ? '<div class="tests-row">' + head + '</div>'
          : '<details class="tests-row" open><summary>' + head + '</summary>' + ctx.pre(String(t.output || '').slice(-3000)) + '</details>';
      }).join('');
      const done = n.props.status === 'done' || n.props.status === 'error' || m.rerun;
      return '<div class="tests' + (m.passed === m.total ? ' all-pass' : '') + '"><div class="tests-head"><b>' + m.passed + ' of ' + m.total + ' passing</b>' +
        (m.rerun ? '<span class="tests-note">re-run by you</span>' : '') +
        (done ? '<button class="btn mini" data-act="tests-rerun">Run again</button>' : '') + '</div>' + rows + '</div>';
    } });
  R.registerAction('tests-rerun', (el, e, ctx) => {
    const card = el.closest('[data-tool-id]'); if (!card || !card._block) return;
    lastCtx = ctx; el.disabled = true; el.textContent = 'Running…';
    const i = card._block.input || {};
    ctx.post({ type: 'runTests', id: card.getAttribute('data-tool-id'), input: { command: i.command || null, path: i.path || null, filter: i.filter || null } });
  });
  R.defineTool({ name: 'run_code', icon: '▶︎', title: 'Run code', summary: n => (input(n).language || '') + ' snippet',
    body: (n, ctx) => ctx.code(input(n).code || '', input(n).language || '') + output(n, ctx, 'Output') });
})();
