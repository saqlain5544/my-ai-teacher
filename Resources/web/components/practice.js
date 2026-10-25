// Retrieval practice that runs entirely in the transcript (no tool call, nothing added to the context):
//   ```practice  [{"q":"…","a":"…","hint":"…"}]   self-check cards: try → reveal → got it / missed
//   ```steps     {"reveal":true,"steps":[…]}       worked example revealed one step at a time (in data.js markup)
//   ```problem   {"q","hints":[…],"solution","answer","concept","subject"}   attempt first: hints and the solution stay
//                hidden until the learner tries (the attempt goes to the tutor) or asks for them (logged as help)
// State lives here, keyed by block + item, so re-renders while streaming never reset what the learner did.
(function () {
  'use strict';
  const R = window.TeacherUI;
  const state = new Map(); // key -> { open:Set, hint:Set, mark:{i:'got'|'miss'}, shown:n, sent:bool }
  R.onLessonChange(() => state.clear());
  const S = k => { let s = state.get(k); if (!s) { s = { open: new Set(), hint: new Set(), mark: {}, shown: 1, sent: false, hints: 0, text: '', at: Date.now() }; state.set(k, s); } return s; };

  function parse(code) {
    const j = R.parseLoose(code);
    if (Array.isArray(j)) return { items: j };
    const list = j && (j.items || j.questions || j.cards);
    if (list) return { title: j.title, items: list };
    // One card per value ({"q":…} on each line, as models often write a list): every value is a card.
    const all = R.parseLoose(code, { all: true });
    return { items: (Array.isArray(all) ? all : [all]).filter(x => x && typeof x === 'object') };
  }

  R.defineComponent({ names: ['practice', 'selfcheck', 'self-check'], version: 2,
    pending: () => '<div class="comp"><div class="diagram-pending">Building practice…</div></div>',
    parse, validate: spec => { R.check(spec.items, { type: 'array', min: 1 }); return spec; },
    render(spec, ctx, env) {
    const key = 'pr' + ctx.hash(env.code);
    const items = spec.items.map(it => typeof it === 'string' ? { q: it } : it);
    let h = '<div class="comp practice" data-key="' + key + '" data-n="' + items.length + '">' +
      '<div class="pr-head"><span class="pr-title">✎ ' + ctx.esc(spec.title || 'Practice') + '</span><span class="pr-score"></span></div>';
    items.forEach((it, i) => {
      h += '<div class="pr-item" data-i="' + i + '" data-q="' + ctx.esc(String(it.q || it.question || '').slice(0, 160)) + '"><div class="pr-q md">' + ctx.inline(it.q || it.question || '') + '</div>' +
        (it.hint ? '<div class="pr-hint md" hidden>' + R.icon('bulb') + ctx.inline(it.hint) + '</div>' : '') +
        '<div class="pr-a md" hidden>' + ctx.md(String(it.a || it.answer || '')) + '</div>' +
        '<div class="pr-actions">' + (it.hint ? '<button class="btn link" data-act="pr-hint">Hint</button>' : '') +
        '<button class="btn" data-act="pr-show">Show answer</button>' +
        '<span class="pr-mark" hidden><button class="btn" data-act="pr-mark" data-v="got">✓ Got it</button><button class="btn" data-act="pr-mark" data-v="miss">✗ Missed</button></span></div></div>';
    });
    return h + '<div class="pr-foot" hidden><button class="btn primary" data-act="pr-send">Tell the teacher how it went</button></div></div>';
  } });

  function apply(el) {
    const s = S(el.getAttribute('data-key')), n = +el.getAttribute('data-n');
    el.querySelectorAll('.pr-item').forEach(it => {
      const i = +it.getAttribute('data-i'), open = s.open.has(i), mark = s.mark[i];
      const a = it.querySelector('.pr-a'), hint = it.querySelector('.pr-hint');
      a.hidden = !open; if (hint) hint.hidden = !s.hint.has(i) && !open;
      it.querySelector('[data-act="pr-show"]').hidden = open;
      const hb = it.querySelector('[data-act="pr-hint"]'); if (hb) hb.hidden = open || s.hint.has(i);
      it.querySelector('.pr-mark').hidden = !open;
      it.querySelectorAll('[data-act="pr-mark"]').forEach(b => b.classList.toggle('sel', b.getAttribute('data-v') === mark));
      it.classList.toggle('got', mark === 'got'); it.classList.toggle('miss', mark === 'miss');
    });
    const marked = Object.keys(s.mark).length, got = Object.values(s.mark).filter(v => v === 'got').length;
    el.querySelector('.pr-score').textContent = marked ? got + ' / ' + n + ' got it' : '';
    const foot = el.querySelector('.pr-foot'); foot.hidden = marked < n;
    const send = foot.querySelector('button'); send.disabled = s.sent; send.textContent = s.sent ? 'Sent ✓' : 'Tell the teacher how it went';
  }

  function applySteps(el) {
    const s = S(el.getAttribute('data-key')), steps = el.querySelectorAll('.step');
    steps.forEach((st, i) => { st.hidden = i >= s.shown; });
    const more = el.querySelector('.steps-more');
    if (more) more.hidden = s.shown >= steps.length;
  }

  let lastCtx = null;   // for the stall timer, which runs outside any render or action
  R.registerProcessor((root, ctx) => {
    if (ctx) lastCtx = ctx;
    const q = sel => (root.matches && root.matches(sel) ? [root] : []).concat(Array.from(root.querySelectorAll(sel)));
    q('.practice').forEach(apply);
    q('.steps.reveal').forEach(applySteps);
    q('.problem').forEach(applyProblem);
  });

  const host = el => el.closest('.practice');
  const idx = el => +el.closest('.pr-item').getAttribute('data-i');
  R.registerAction('pr-show', el => { const p = host(el); S(p.getAttribute('data-key')).open.add(idx(el)); apply(p); });
  R.registerAction('pr-hint', el => { const p = host(el); S(p.getAttribute('data-key')).hint.add(idx(el)); apply(p); });
  function sendPractice(p, ctx) {
    const s = S(p.getAttribute('data-key'));
    if (s.sent) return;
    const items = Array.from(p.querySelectorAll('.pr-item'));
    const missed = items.filter(it => s.mark[+it.getAttribute('data-i')] === 'miss').map(it => '“' + it.getAttribute('data-q') + '”');
    const got = items.length - missed.length;
    ctx.post({ type: 'suggest', text: 'Practice: I got ' + got + ' of ' + items.length + '.' + (missed.length ? ' I missed ' + missed.join(', ') + '.' : '') });
    s.sent = true; apply(p);
  }
  // The tutor steps in on misses: once every card is marked and one was missed, the result goes to the tutor unasked.
  R.registerAction('pr-mark', (el, e, ctx) => {
    const p = host(el), s = S(p.getAttribute('data-key'));
    s.mark[idx(el)] = el.getAttribute('data-v'); apply(p);
    const marks = Object.values(s.mark);
    if (!s.sent && marks.length >= +p.getAttribute('data-n') && marks.includes('miss')) sendPractice(p, ctx);
  });
  R.registerAction('pr-send', (el, e, ctx) => sendPractice(host(el), ctx));

  // ── Problem: attempt first ────────────────────────────────────────────
  R.defineComponent({ names: ['problem', 'exercise', 'try'], version: 2,
    pending: () => '<div class="comp"><div class="diagram-pending">Setting a problem…</div></div>',
    validate: p => {
      if (Array.isArray(p)) p = p[0] || {};
      R.check(p, 'object');
      if (!String(p.q || p.problem || p.question || p.prompt || '').trim()) throw new Error('needs the question (q)');
      return p;
    },
    render(p, ctx, env) {
    const code = env.code;
    const q = String(p.q || p.problem || p.question || p.prompt || '');
    const hints = (Array.isArray(p.hints) ? p.hints : p.hint ? [p.hint] : []).map(String);
    const sol = p.solution || p.worked || p.steps || '';
    const solution = Array.isArray(sol) ? sol.map((x, i) => (i + 1) + '. ' + (typeof x === 'string' ? x : x.text || x.title || '')).join('\n') : String(sol);
    const answer = p.answer != null ? String(p.answer) : '';
    const key = 'pb' + ctx.hash(code);
    return '<div class="comp problem" data-key="' + key + '" data-concept="' + ctx.esc(p.concept || '') + '" data-subject="' + ctx.esc(p.subject || '') + '" data-q="' + ctx.esc(q.slice(0, 160)) + '">' +
      '<div class="pb-head"><span class="pb-title">' + R.icon('target') + ctx.esc(p.title || 'Your turn') + '</span><span class="pb-sub">Try it first: hints and the solution are here when you need them</span></div>' +
      '<div class="pb-q md">' + ctx.md(q) + '</div>' +
      hints.map((h, i) => '<div class="hint pb-hint" data-h="' + i + '" hidden><span class="nudge" hidden>Stuck? Here\'s a nudge.</span> ' + R.icon('bulb') + (hints.length > 1 ? '<b>Hint ' + (i + 1) + ':</b> ' : '') + ctx.inline(h) + '</div>').join('') +
      '<textarea class="q-text pb-attempt" rows="3" placeholder="Your attempt: steps, a first idea, or where you got stuck…"></textarea>' +
      '<div class="pb-actions">' + (hints.length ? '<button class="btn link" data-act="pb-hint" data-n="' + hints.length + '">Hint</button>' : '') +
      (solution || answer ? '<button class="btn link" data-act="pb-solution">Show solution</button>' : '') +
      '<span class="pb-sent" hidden>Sent to your teacher ✓</span><button class="btn primary" data-act="pb-send">Check my attempt</button></div>' +
      (solution || answer ? '<div class="pb-solution" hidden>' + (answer ? '<div class="pb-answer"><b>Answer:</b> <span class="md">' + ctx.inline(answer) + '</span></div>' : '') + (solution ? '<div class="md">' + ctx.md(solution) + '</div>' : '') + '</div>' : '') +
      '</div>';
  } });

  function applyProblem(el) {
    const s = S(el.getAttribute('data-key'));
    el.querySelectorAll('.pb-hint').forEach(h => {
      const i = +h.getAttribute('data-h');
      h.hidden = i >= s.hints;
      h.querySelector('.nudge').hidden = !(s.nudged && i === 0);
    });
    const hb = el.querySelector('[data-act="pb-hint"]');
    if (hb) {
      const n = +hb.getAttribute('data-n');
      hb.hidden = s.hints >= n || s.seen;
      hb.textContent = s.hints ? 'Another hint (' + (s.hints + 1) + ' of ' + n + ')' : 'Hint';
    }
    const sol = el.querySelector('.pb-solution'); if (sol) sol.hidden = !s.seen;
    const sb = el.querySelector('[data-act="pb-solution"]');
    if (sb) { sb.hidden = s.seen; sb.textContent = s.attempted ? 'Compare with the solution' : 'Show solution'; sb.title = s.attempted ? '' : 'Seeing it before trying counts as help'; }
    const ta = el.querySelector('.pb-attempt'); if (ta && ta.value !== s.text) ta.value = s.text;
    el.querySelector('.pb-sent').hidden = !s.attempted;
    el.classList.toggle('attempted', !!s.attempted);
  }
  const problemOf = el => el.closest('.problem');
  // Opening help is logged (answers after it don't raise mastery); a solution seen before any attempt is also told to the tutor.
  const logHelp = (el, ctx, event, note) => ctx.post({ type: 'study', event, concept: el.getAttribute('data-concept') || null,
    subject: el.getAttribute('data-subject') || null, note: note || null });
  R.registerAction('pb-hint', (el, e, ctx) => {
    const p = problemOf(el), s = S(p.getAttribute('data-key'));
    s.hints++; applyProblem(p); logHelp(p, ctx, 'hint');
  });
  R.registerAction('pb-solution', (el, e, ctx) => {
    const p = problemOf(el), s = S(p.getAttribute('data-key'));
    if (s.seen) return;
    s.seen = true; applyProblem(p);
    if (!s.attempted) logHelp(p, ctx, 'solution', 'The learner opened the solution of the problem “' + p.getAttribute('data-q') + '” without attempting it' + (s.hints ? ' (after ' + s.hints + ' hint' + (s.hints > 1 ? 's' : '') + ')' : '') + '. Set a similar problem for them to try unaided.');
  });
  R.registerAction('pb-send', (el, e, ctx) => {
    const p = problemOf(el), s = S(p.getAttribute('data-key')), ta = p.querySelector('.pb-attempt');
    s.text = ta ? ta.value : s.text;
    if (!s.text.trim()) { if (ta) { ta.focus(); ta.classList.add('invalid'); } return; }
    if (ta) ta.classList.remove('invalid');
    ctx.post({ type: 'suggest', text: 'My attempt at “' + p.getAttribute('data-q') + '”' + (s.hints ? ' (after ' + s.hints + ' hint' + (s.hints > 1 ? 's' : '') + ')' : '') + (s.seen ? ' (after seeing the solution)' : '') + ':\n\n' + s.text.trim() });
    s.attempted = true; applyProblem(p);
  });
  document.addEventListener('input', e => {
    const t = e.target; if (!t || !t.classList || !t.classList.contains('pb-attempt')) return;
    const p = problemOf(t); if (p) { const s = S(p.getAttribute('data-key')); s.text = t.value; s.touched = Date.now(); }
  });

  // Stuck on the latest reply's problem, in view (nothing typed, no hint): the first hint opens by itself, once. Older
  // problems scrolled past while reading back are left alone.
  const STALL_MS = 90000;
  function nudgeProblems(now) {
    if (document.hidden) return;
    document.querySelectorAll('.msg.last .problem').forEach(p => {
      const s = S(p.getAttribute('data-key')), r = p.getBoundingClientRect();
      if (s.nudged || s.attempted || s.seen || s.hints || s.text.trim() || !p.querySelector('.pb-hint')) return;
      if (now - (s.touched || s.at) < STALL_MS || r.bottom < 0 || r.top > innerHeight) return;
      s.nudged = true; s.hints = 1; applyProblem(p);
      if (lastCtx) logHelp(p, lastCtx, 'hint');
    });
  }
  setInterval(() => nudgeProblems(Date.now()), 5000);
  window.TeacherPractice = { nudgeProblems, STALL_MS };
  R.registerAction('steps-next', el => { const b = el.closest('.steps'); S(b.getAttribute('data-key')).shown++; applySteps(b); });
  R.registerAction('steps-all', el => { const b = el.closest('.steps'); S(b.getAttribute('data-key')).shown = 1e9; applySteps(b); });
})();
