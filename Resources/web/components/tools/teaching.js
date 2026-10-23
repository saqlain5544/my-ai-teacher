// Tool cards for the teaching tools: flashcards, mastery, math, todo_write, lesson_plan (the course board).
(function () {
  'use strict';
  const R = window.TeacherUI;
  const input = n => n.props.input || {};
  const meta = n => (n.props.result && n.props.result.meta) || {};
  const finished = n => n.props.status === 'done' || n.props.status === 'error';

  R.defineTool({ name: 'flashcards', icon: '🗂', title: 'Flashcards',
    summary: n => { const i = input(n); return (i.action || '') + ' ' + (i.deck || '') + (i.cards ? ' · ' + i.cards.length + ' cards' : ''); },
    body(n, ctx) {
      const i = input(n), out = n.props.output;
      if (i.action === 'add' && i.cards) return '<div class="md">' + i.cards.slice(0, 30).map(c => '<p><b>Q:</b> ' + ctx.inline(c.front) + '<br><b>A:</b> ' + ctx.inline(c.back) + '</p>').join('') + '</div>' + (out ? ctx.pre(out) : '');
      return out ? ctx.pre(out) : '';
    } });
  R.defineTool({ name: 'mastery', icon: '📈', title: 'Mastery', compact: true, summary: n => (input(n).action || '') + ' ' + (input(n).concept || input(n).subject || '') });
  R.defineTool({ name: 'math', icon: '∑', title: 'Math', summary: n => (input(n).operation || '') + ' ' + (input(n).expression || ''),
    body: (n, ctx) => (meta(n).latex ? ctx.tex(meta(n).latex, true) : '') + (n.props.output ? ctx.pre(n.props.output) : '') });
  R.defineTool({ name: 'todo_write', icon: '☑︎', title: 'Checklist', open: () => true,
    body: (n, ctx) => '<ul class="todo">' + (input(n).todos || []).map(t => '<li class="' + ctx.esc(t.status) + '">' + (t.status === 'completed' ? '✓' : t.status === 'in_progress' ? '▸' : '○') + ' <span>' + ctx.esc(t.content) + '</span></li>').join('') + '</ul>' });

  // ── Language mentor: the learner's word deck and language utilities ───
  R.defineTool({ name: 'vocab', icon: '📚', title: 'Vocabulary',
    compact: n => ['remove', 'stats'].includes(input(n).action),
    summary: n => { const i = input(n), w = Array.isArray(i.words) ? i.words : [];
      return (i.action || '') + (w.length ? ' · ' + w.length + ' word' + (w.length === 1 ? '' : 's') + ': ' + w.slice(0, 4).map(x => x.term || x.word || '').join('、') + (w.length > 4 ? '…' : '') : i.term ? ' ' + i.term : i.query ? ' “' + i.query + '”' : ''); },
    body(n, ctx) {
      const i = input(n), w = Array.isArray(i.words) ? i.words : [];
      const list = w.length ? '<table class="vocab-saved"><tbody>' + w.map(x => '<tr><td lang="' + ctx.esc(i.lang || '') + '"><b>' + ctx.esc(x.term || x.word || '') + '</b>' +
        (x.reading ? ' <span class="muted">' + ctx.esc(x.reading) + '</span>' : '') + '</td><td>' + ctx.inline(x.meaning || x.translation || '') + '</td></tr>').join('') + '</tbody></table>' : '';
      return list + (n.props.output ? ctx.pre(n.props.output) : '');
    } });
  R.defineTool({ name: 'language', icon: '🌐', title: 'Language',
    compact: n => input(n).action === 'profile',
    summary: n => { const i = input(n); return (i.action || '') + ' ' + (i.word || i.target || (i.text ? String(i.text).slice(0, 40) : '') || '') + (i.to ? ' → ' + i.to : ''); } });

  // ── The course board / learning plan ──────────────────────────────────
  R.defineTool({ name: 'lesson_plan', icon: '🗺', title: 'Learning plan', open: finished,
    summary: n => { const i = input(n); return (i.action || '') + ' ' + (i.title || i.card || i.id || i.plan || ''); },
    body: (n, ctx) => planBody(n, ctx) });

  /** A lesson plan as a real curriculum: title, goal, then modules with their status and objectives (never one paragraph). */
  function planBody(n, ctx) {
    const i = input(n), r = n.props.result;
    const structured = (r && r.meta && r.meta.plan) || (Array.isArray(i.modules) ? i : null);
    const out = n.props.output || '';
    if (structured && Array.isArray(structured.cards)) return boardBody(structured, ctx);
    if (!structured || !Array.isArray(structured.modules)) {
      return out ? '<div class="md plan">' + ctx.md(ctx.hardLines(out)) + '</div>' : '';
    }
    const mods = structured.modules || [];
    const done = mods.filter(m => m.status === 'done').length;
    const title = String(structured.title || 'Learning plan').replace(/\s*\[plan-[0-9a-z]+\]\s*$/i, '');
    let html = '<div class="plan-card"><div class="plan-top"><div class="plan-title">' + ctx.inline(title) + '</div><div class="plan-meta">' +
      '<span class="pill">' + mods.length + ' module' + (mods.length === 1 ? '' : 's') + '</span>' +
      (done ? '<span class="pill good">' + done + ' done</span>' : '') +
      (structured.subject ? '<span class="pill">' + ctx.esc(structured.subject) + '</span>' : '') + '</div></div>';
    if (structured.goal) html += '<div class="plan-goal"><b>Goal</b> ' + ctx.inline(structured.goal) + '</div>';
    html += '<ol class="plan-mods">' + mods.map((m, k) => {
      const status = ['done', 'in_progress', 'todo'].includes(m.status) ? m.status : 'todo';
      const mark = status === 'done' ? '✓' : status === 'in_progress' ? '▸' : '';
      const objs = (m.objectives || []).filter(o => o != null && String(o).trim());
      return '<li class="plan-mod plan-' + status + '"><span class="plan-mark" aria-hidden="true">' + mark + '</span><div class="plan-body">' +
        '<div class="plan-mtitle"><span class="plan-n">' + (k + 1) + '</span>' + ctx.inline(m.title || '') + '</div>' +
        (objs.length ? '<ul class="plan-objs">' + objs.map(o => '<li>' + ctx.inline(o) + '</li>').join('') + '</ul>' : '') +
        '</div></li>';
    }).join('') + '</ol></div>';
    return html;
  }

  /** A card's outline as a nested table of contents (a chapter of the course book): ticks for finished sections, the
   *  current one marked. Open for the focus card, folded for the others. */
  function outlineHTML(sections, at, ctx) {
    return '<ol class="board-outline">' + (sections || []).map(s => '<li class="' + (s.done ? 'done' : '') + (s.id === at ? ' now' : '') + '">' +
      '<span class="bo-id">' + ctx.esc(s.id) + '</span>' + ctx.inline(String(s.title || '').replace(/^\s*(§\s*)?\d+(\.\d+)*[.):]?\s+(?=\S)/, '')) +
      ((s.points || []).length ? '<div class="bo-points">' + s.points.map(p => ctx.inline(p)).join(' · ') + '</div>' : '') +
      ((s.sections || []).length ? outlineHTML(s.sections, at, ctx) : '') + '</li>').join('') + '</ol>';
  }
  function leaves(sections) { return (sections || []).flatMap(s => (s.sections || []).length ? leaves(s.sections) : [s]); }

  /** The course board: the focus card first (title + the concrete next action), then the lanes; parked detours last. */
  function boardBody(bd, ctx) {
    const esc = ctx.esc, inline = ctx.inline;
    const outline = (c, open) => {
      if (!(c.outline || []).length) return '';
      const ls = leaves(c.outline), done = ls.filter(s => s.done).length;
      return '<details class="board-outline-wrap"' + (open ? ' open' : '') + '><summary>' + done + '/' + ls.length + ' sections</summary>' + outlineHTML(c.outline, c.at, ctx) + '</details>';
    };
    const cards = bd.cards || [];
    const title = String(bd.title || 'Course board').replace(/\s*\[plan-[0-9a-z]+\]\s*$/i, '');
    const course = cards.filter(c => c.lane !== 'parked');
    const done = course.filter(c => c.lane === 'done').length;
    const parked = cards.filter(c => c.lane === 'parked');
    const focus = cards.find(c => c.id === bd.focus && c.lane === 'doing') || cards.find(c => c.lane === 'doing');
    const id = c => '<span class="board-id">' + esc(String(c.id || '').toUpperCase()) + '</span>';
    let html = '<div class="plan-card board"><div class="plan-top"><div class="plan-title">' + inline(title) + '</div><div class="plan-meta">' +
      '<span class="pill">' + course.length + ' card' + (course.length === 1 ? '' : 's') + '</span>' +
      (done ? '<span class="pill good">' + done + ' done</span>' : '') +
      (parked.length ? '<span class="pill">' + parked.length + ' parked</span>' : '') +
      (bd.subject ? '<span class="pill">' + esc(bd.subject) + '</span>' : '') +
      (bd.deadline ? '<span class="pill">due ' + esc(bd.deadline) + '</span>' : '') + '</div></div>';
    if (bd.goal) html += '<div class="plan-goal"><b>Goal</b> ' + inline(bd.goal) + '</div>';
    if (focus) {
      html += '<div class="board-focus"><div class="board-lane-name">Focus</div><div class="board-focus-title">' + id(focus) + inline(focus.title || '') + '</div>' +
        '<div class="board-next">' + (focus.next ? '<b>Next</b> ' + inline(focus.next) : '<span class="board-nonext">next action not set</span>') + '</div>' +
        ((focus.objectives || []).length ? '<ul class="plan-objs">' + focus.objectives.map(o => '<li>' + inline(String(o)) + '</li>').join('') + '</ul>' : '') +
        ((focus.evidence || []).length ? '<div class="board-evidence">' + inline(focus.evidence.slice(-2).join(' · ')) + '</div>' : '') +
        outline(focus, true) + '</div>';
    }
    const lanes = [['review', 'Review'], ['backlog', 'Up next'], ['done', 'Done']];
    for (const [lane, name] of lanes) {
      const cs = cards.filter(c => c.lane === lane);
      if (!cs.length) continue;
      html += '<div class="board-lane board-' + lane + '"><div class="board-lane-name">' + name + ' · ' + cs.length + '</div><ol class="plan-mods">' + cs.map(c =>
        '<li class="plan-mod plan-' + (lane === 'done' ? 'done' : 'todo') + '"><span class="plan-mark" aria-hidden="true">' + (lane === 'done' ? '✓' : lane === 'review' ? '↻' : '') + '</span><div class="plan-body">' +
        '<div class="plan-mtitle">' + id(c) + inline(c.title || '') + '</div>' +
        (c.next && lane !== 'done' ? '<div class="board-cnext">' + inline(c.next) + '</div>' : '') +
        (c.after && c.after.length && lane !== 'done' ? '<div class="board-after">after ' + esc(c.after.map(a => String(a).toUpperCase()).join(', ')) + '</div>' : '') +
        (lane === 'done' && (c.evidence || []).length ? '<div class="board-evidence">' + inline(c.evidence[c.evidence.length - 1]) + '</div>' : '') +
        outline(c, false) + '</div></li>').join('') + '</ol></div>';
    }
    if (parked.length) {
      html += '<details class="board-parked"><summary>Parked · ' + parked.length + '</summary><ul class="board-parked-list">' + parked.map(c =>
        '<li>' + id(c) + inline(c.title || '') + (c.parked_reason ? ' <span class="board-reason">— ' + inline(c.parked_reason) + '</span>' : '') + '</li>').join('') + '</ul></details>';
    }
    return html + '</div>';
  }
})();
