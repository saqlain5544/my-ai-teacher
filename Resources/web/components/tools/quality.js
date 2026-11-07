// How good the learner's tests are: `mutate` (changes no test noticed) and `coverage` (lines no test runs). Both are
// information for the learner, never a grade; a survivor asks a question and leaves the test to them.
(function () {
  'use strict';
  const R = window.TeacherUI;
  const meta = n => (n.props.result && n.props.result.meta) || {};
  const done = n => n.props.status === 'done' || n.props.status === 'error';
  const pct = v => Math.round(v * 100) + '%';

  R.defineTool({ name: 'mutate', icon: 'shield', tone: 'green', title: 'Mutation testing',
    summary: n => {
      const m = meta(n);
      if (!done(n)) return 'changing your code in a scratch copy…';
      return m.score == null ? (m.note || 'no result') : pct(m.score) + ' caught · ' + m.survived + ' survived of ' + (m.killed + m.timedOut + m.survived);
    },
    open: n => done(n) && (meta(n).survived > 0 || n.props.status === 'error'),
    body(n, ctx) {
      const m = meta(n);
      if (m.score == null) return n.props.output ? ctx.pre(n.props.output) : '';
      const judged = m.killed + m.timedOut + m.survived, caught = m.killed + m.timedOut;
      let h = '<div class="tests-bar ' + (m.survived ? 'red' : 'green') + '"><div class="tb-fill" style="width:' + Math.round(m.score * 100) + '%"></div><span>' + caught + ' of ' + judged + ' changes caught by a test' +
        (m.timedOut ? ' (' + m.timedOut + ' by timeout)' : '') + (m.invalid ? ' · ' + m.invalid + ' did not build' : '') + (m.errored ? ' · ' + m.errored + ' errored (not counted)' : '') + '</span></div>';
      if (m.left) h += '<div class="q-help">Left out of the scratch copy: ' + ctx.esc(m.left) + '</div>';
      if (m.note) h += '<div class="q-help">' + ctx.esc(m.note) + '</div>';
      (m.survivors || []).forEach(s => {
        h += '<div class="survivor"><div class="sv-head"><code>' + ctx.esc(s.file) + ':' + s.line + '</code>' + (s.function ? ' <span class="sv-fn">in ' + ctx.esc(s.function) + '</span>' : '') + ' <span class="sv-kind">' + ctx.esc(s.kind) + '</span></div>' +
          '<div class="sv-line del"><b>was</b> <code>' + ctx.esc(s.was) + '</code></div><div class="sv-line add"><b>now</b> <code>' + ctx.esc(s.now) + '</code></div>' +
          '<div class="sv-ask">Every test still passed. What input would make these two lines behave differently, and what test would notice?</div></div>';
      });
      if (!(m.survivors || []).length) h += '<div class="q-help">No change survived: the tests noticed everything tried (' + m.tried + ' of ' + m.available + ' possible).</div>';
      return h;
    } });

  R.defineTool({ name: 'coverage', icon: 'activity', tone: 'green', title: 'Test coverage',
    summary: n => { const m = meta(n); return !done(n) ? 'running the tests with coverage…' : m.files && m.files.length ? (m.exact === false ? 'files average ' + Math.round(m.percent) + '%' : Math.round(m.percent) + '% of lines run') + ' · ' + m.tool : (m.note || 'no result').slice(0, 90); },
    open: n => done(n) && !!(meta(n).files || []).length,
    body(n, ctx) {
      const m = meta(n);
      if (!m.files || !m.files.length) return n.props.output ? ctx.pre(n.props.output) : '';
      return m.files.map(f => {
        const miss = (f.missing || []).map(r => r[0] === r[1] ? r[0] : r[0] + '–' + r[1]).join(', ');
        return '<div class="cov-file"><div class="cov-row"><code>' + ctx.esc(f.path) + '</code><div class="cov-bar"><div style="width:' + Math.round(f.percent) + '%"></div></div><span>' + Math.round(f.percent) + '%</span></div>' +
          (miss ? '<div class="cov-miss">never run: ' + ctx.esc(miss) + '</div>' : '') + '</div>';
      }).join('') + '<div class="q-help">A line that ran is not a line that was checked.</div>';
    } });

  R.injectStyles('quality', `
    .survivor { margin: 6px 0; padding: 6px 10px; border-left: 3px solid var(--warn); font-size: .9em; }
    .sv-head { font-family: var(--mono); font-size: .88em; } .sv-fn, .sv-kind { color: var(--muted); }
    .sv-line { font-family: var(--mono); font-size: .85em; white-space: pre-wrap; } .sv-line b { display: inline-block; width: 2.6em; color: var(--muted); font-weight: 500; }
    .sv-line.del code { color: var(--bad); } .sv-line.add code { color: var(--good); }
    .sv-ask { margin-top: 4px; color: var(--muted); }
    .cov-file { margin: 4px 0; } .cov-row { display: flex; align-items: center; gap: 10px; font-size: .88em; }
    .cov-row code { flex: 0 1 40%; overflow: hidden; text-overflow: ellipsis; }
    .cov-bar { flex: 1; height: 8px; border-radius: 4px; background: var(--bad-soft); overflow: hidden; } .cov-bar div { height: 100%; background: var(--good); }
    .cov-miss { font-family: var(--mono); font-size: .8em; color: var(--muted); margin-left: 4px; }
  `);
})();
