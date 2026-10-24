// The code agent's cards: diagnostics (parsed problems), symbols (outlines and definitions), and the undo footer that
// puts a turn's file changes back (the app keeps a checkpoint per turn).
(function () {
  'use strict';
  const R = window.TeacherUI;
  const input = n => n.props.input || {};
  const meta = n => (n.props.result && n.props.result.meta) || {};

  R.defineTool({ name: 'diagnostics', icon: '🩺', title: 'Diagnostics',
    summary: n => {
      const m = meta(n), i = input(n);
      const what = i.command || i.what || 'check';
      if (n.props.status !== 'done' && n.props.status !== 'error') return what;
      return what + (m.errors != null ? ' · ' + (m.errors === 0 && !m.warnings ? 'clean' : (m.errors + ' error' + (m.errors === 1 ? '' : 's') + (m.warnings ? ', ' + m.warnings + ' warning' + (m.warnings === 1 ? '' : 's') : ''))) : '');
    },
    open: n => n.props.status === 'error' || (meta(n).errors || 0) > 0,
    body: (n, ctx) => n.props.output ? ctx.pre(n.props.output) : '' });

  R.defineTool({ name: 'source', icon: '📚', title: 'Library source',
    summary: n => { const i = input(n), m = meta(n); return (i.action || 'locate') + ' ' + (i.library || '') + (i.path ? ' ' + i.path + (i.from ? ':' + i.from : '') : i.query ? ' “' + i.query + '”' : '') + (m.root && i.action === 'locate' ? ' → ' + m.root : ''); },
    body: (n, ctx) => n.props.output ? ctx.pre(n.props.output) : '' });

  R.defineTool({ name: 'symbols', icon: '§', title: 'Symbols',
    summary: n => (input(n).path ? 'outline of ' + input(n).path : 'definitions of ' + (input(n).query || '')) + (meta(n).count != null ? ' · ' + meta(n).count : ''),
    body: (n, ctx) => n.props.output ? ctx.pre(n.props.output) : '' });

  // A write or edit whose syntax check failed is marked on its card.
  R.registerProcessor(root => {
    const cards = (root.matches && root.matches('[data-tool-id]') ? [root] : []).concat(Array.from(root.querySelectorAll('[data-tool-id]')));
    cards.forEach(el => {
      const b = el._block; if (!b || (b.name !== 'edit' && b.name !== 'write')) return;
      const r = R._ctx && R._ctx.result(b.id);
      el.classList.toggle('syntax-errors', !!(r && r.meta && r.meta.syntaxErrors));
    });
  });

  // Undo under a code agent's reply: the files the turn changed, and one click to put them back.
  const undone = new Set();
  R.onLessonChange(() => undone.clear());
  R.registerFooter((m, turnMsgs, userMsg, ctx) => {
    const t = m.turn; if (!t || !t.checkpoint || !t.changedFiles || !t.changedFiles.length) return '';
    const files = t.changedFiles;
    const done = undone.has(t.checkpoint);
    return '<div class="turn-undo"><span>✎ ' + files.length + ' file' + (files.length === 1 ? '' : 's') + ' changed</span><span class="files" title="' + ctx.esc(files.join('\n')) + '">' + ctx.esc(files.slice(0, 6).join(', ')) + (files.length > 6 ? ', …' : '') + '</span>' +
      '<button class="btn mini" data-act="undo-turn" data-turn="' + ctx.esc(t.checkpoint) + '"' + (done ? ' disabled' : '') + '>' + (done ? 'Undone' : 'Undo this turn\'s changes') + '</button></div>';
  });
  R.registerAction('undo-turn', (el, e, ctx) => {
    const turn = el.getAttribute('data-turn');
    if (!turn || undone.has(turn)) return;
    undone.add(turn); el.disabled = true; el.textContent = 'Undone';
    ctx.post({ type: 'revert', turn });
  });
})();
