// Tool card: `exercise`. Every action has its own card, so a call's hidden tests and reference solution are never
// rendered (not even in an expanded default card), and neither is a failed setup's output (it can quote the tests).
(function () {
  'use strict';
  const R = window.TeacherUI;
  const line = (ctx, icon, text, spin) => '<div class="exercise-line">' + (spin ? '<span class="spinner"></span> ' : icon + ' ') + ctx.esc(text) + '</div>';
  R.registerToolCard('exercise', (b, r, pend, ctx) => {
    const i = b.input || {}, action = i.action || 'list';
    const running = !r || (r.meta && r.meta.running);
    const meta = (r && r.meta) || {};
    if (action === 'draft') return line(ctx, '📐', 'Designing a project' + (i.title ? ': ' + i.title : ''), running);
    if (action === 'add') return line(ctx, '🗂', running ? 'Writing the project…' : 'Project files prepared', running);
    if (action === 'read') return line(ctx, '👀', running ? 'Reading your code…' : 'Read your code', running);
    if (action === 'check') return line(ctx, '🧪', running ? 'Running the hidden tests on your code…' : 'Ran the hidden tests on your code', running);
    if (action === 'list') return line(ctx, '🗂', 'Looked at your exercises', running);
    // create / publish: the project card.
    const title = i.title || meta.title || 'Exercise', brief = i.brief || meta.brief || '', lang = i.language || meta.language || '';
    let h = '<div class="exercise-card"><div class="ex-head"><span class="ex-title">💻 ' + ctx.esc(title) + '</span>' +
      (lang ? '<span class="ex-lang">' + ctx.esc(lang) + '</span>' : '') + '</div>';
    if (running) h += '<div class="ex-body muted"><span class="spinner"></span> Setting up the project and proving its tests…</div>';
    else if (r.isError) h += '<div class="ex-body muted">The exercise didn\'t pass its own checks yet; your teacher is fixing it.</div>';
    else {
      h += (brief ? '<div class="ex-body md">' + ctx.md(brief) + '</div>' : '') +
        '<div class="ex-foot"><span class="ex-folder">' + ctx.esc(meta.folder || '') + '</span>' +
        '<button class="btn primary" data-act="ex-open" data-id="' + ctx.esc(meta.exercise || '') + '">Open in editor</button></div>';
    }
    return h + '</div>';
  });
  R.registerAction('ex-open', (el, e, ctx) => ctx.post({ type: 'openExercise', id: el.getAttribute('data-id') }));
})();
