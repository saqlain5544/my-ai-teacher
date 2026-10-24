// The code mentor's project cards: test runs (a pass/fail bar) and review rounds (findings by file, with severity).
(function () {
  'use strict';
  const R = window.TeacherUI;
  const input = n => n.props.input || {};
  const meta = n => (n.props.result && n.props.result.meta) || {};
  const bar = (run, ctx) => {
    if (!run) return '';
    if (run.errored) return '<div class="tests-bar errored">Tests could not run (exit ' + ctx.esc(run.exit) + ')</div>';
    const total = (run.passed || 0) + (run.failed || 0), pct = total ? Math.round(run.passed / total * 100) : 0;
    return '<div class="tests-bar' + (run.failed ? ' red' : ' green') + '"><div class="tb-fill" style="width:' + pct + '%"></div><span>' + run.passed + ' passed · ' + run.failed + ' failed' + (run.seconds != null ? ' · ' + (+run.seconds).toFixed(1) + ' s' : '') + '</span></div>' +
      (run.failing && run.failing.length ? '<div class="tests-failing">' + run.failing.slice(0, 12).map(f => '<code>' + ctx.esc(f) + '</code>').join(' ') + '</div>' : '');
  };

  R.defineTool({ name: 'project_tests', icon: '🧪', title: 'Project tests',
    summary: n => {
      const i = input(n), m = meta(n), r = m.run;
      const what = i.action === 'set' ? 'register ' + (i.command || '') : i.action === 'run' ? 'run' : 'status';
      return what + (r ? ' · ' + (r.errored ? 'did not run' : r.passed + ' passed, ' + r.failed + ' failed') : '');
    },
    open: n => n.props.status === 'error' || !!(meta(n).run && (meta(n).run.failed || meta(n).run.errored)) && input(n).action !== 'set',
    body: (n, ctx) => bar(meta(n).run, ctx) + (n.props.output ? ctx.pre(n.props.output) : '') });

  R.defineTool({ name: 'project_review', icon: '🔍', title: 'Code review',
    summary: n => {
      const i = input(n), m = meta(n);
      if (i.action === 'start') return 'round ' + (m.round || '') + (m.changes ? ' · ' + m.changes.length + ' file' + (m.changes.length === 1 ? '' : 's') + ' changed' : '');
      if (i.action === 'findings') { const r = m.round || {}; const open = (r.findings || []).filter(f => !f.resolved).length; return 'round ' + (r.number || '') + ' · ' + (r.verdict === 'pass' ? '✅ pass' : 'changes requested') + (open ? ' · ' + open + ' open' : ''); }
      return 'rounds';
    },
    open: n => input(n).action === 'findings',
    body(n, ctx) {
      const i = input(n), m = meta(n);
      if (i.action === 'findings' && m.round) {
        const r = m.round;
        let h = '<div class="review-head ' + (r.verdict === 'pass' ? 'pass' : 'changes') + '"><b>' + (r.verdict === 'pass' ? '✅ Ready' : '✎ Changes requested') + '</b>' + (r.summary ? '<span class="md">' + ctx.inline(r.summary) + '</span>' : '') + '</div>';
        h += bar(r.tests, ctx);
        const byFile = {};
        (r.findings || []).forEach(f => { (byFile[f.file] = byFile[f.file] || []).push(f); });
        Object.keys(byFile).sort().forEach(file => {
          h += '<div class="review-file"><div class="rf-name">' + ctx.esc(file) + '</div>' + byFile[file].sort((a, b) => (a.line || 0) - (b.line || 0)).map(f =>
            '<div class="finding ' + ctx.esc(f.severity) + (f.resolved ? ' resolved' : '') + '"><span class="f-sev">' + ctx.esc(f.severity) + '</span>' + (f.line ? '<span class="f-line">:' + f.line + '</span>' : '') + '<span class="f-text md">' + ctx.inline(f.text) + '</span>' + (f.resolved ? '<span class="f-done">fixed</span>' : '') + '</div>').join('') + '</div>';
        });
        if (!(r.findings || []).length) h += '<div class="q-help">No findings.</div>';
        return h;
      }
      if (i.action === 'start' && m.changes) {
        return '<div class="review-changes">' + m.changes.map(c => '<div><span class="rc-kind ' + ctx.esc(c.kind) + '">' + ctx.esc(c.kind) + '</span> ' + ctx.esc(c.path) + ' <span class="rc-add">+' + c.added + '</span> <span class="rc-del">−' + c.removed + '</span></div>').join('') + '</div>' + (n.props.output ? '<details><summary>Diff and tests</summary>' + ctx.pre(n.props.output) + '</details>' : '');
      }
      return n.props.output ? ctx.pre(n.props.output) : '';
    } });

  R.injectStyles('mentor', `
    .tests-bar { position: relative; height: 22px; border-radius: 6px; background: var(--bad-soft); overflow: hidden; font-size: .82em; margin: 4px 0 6px; }
    .tests-bar .tb-fill { position: absolute; inset: 0 auto 0 0; background: var(--good-soft); }
    .tests-bar.green { background: var(--good-soft); }
    .tests-bar span { position: relative; line-height: 22px; padding: 0 8px; color: var(--fg); }
    .tests-bar.errored { background: var(--warn-soft); padding: 0 8px; line-height: 22px; }
    .tests-failing { font-size: .8em; color: var(--bad); margin-bottom: 6px; display: flex; flex-wrap: wrap; gap: 4px; }
    .review-head { display: flex; gap: 10px; align-items: baseline; margin-bottom: 6px; flex-wrap: wrap; }
    .review-head.pass b { color: var(--good); } .review-head.changes b { color: var(--warn); }
    .review-file { margin-top: 8px; }
    .rf-name { font-family: var(--mono); font-size: .85em; color: var(--muted); margin-bottom: 2px; }
    .finding { display: flex; gap: 8px; align-items: baseline; padding: 4px 8px; border-left: 3px solid var(--border); margin: 2px 0; font-size: .92em; }
    .finding.must { border-color: var(--bad); } .finding.should { border-color: var(--warn); } .finding.nit { border-color: var(--faint); }
    .finding.resolved { opacity: .55; text-decoration: line-through; }
    .f-sev { font-size: .75em; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); min-width: 44px; }
    .f-line { font-family: var(--mono); font-size: .85em; color: var(--muted); }
    .f-text { flex: 1; min-width: 0; }
    .f-done { font-size: .78em; color: var(--good); text-decoration: none; }
    .review-changes { font-family: var(--mono); font-size: .85em; }
    .rc-kind { color: var(--muted); } .rc-kind.added { color: var(--good); } .rc-kind.deleted { color: var(--bad); }
    .rc-add { color: var(--good); } .rc-del { color: var(--bad); }
  `);
})();
