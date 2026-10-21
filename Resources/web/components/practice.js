// Retrieval practice that runs entirely in the transcript (no tool call, nothing added to the context):
//   ```practice  [{"q":"…","a":"…","hint":"…"}]   self-check cards: try → reveal → got it / missed
//   ```steps     {"reveal":true,"steps":[…]}       worked example revealed one step at a time (in data.js markup)
// State lives here, keyed by block + item, so re-renders while streaming never reset what the learner did.
(function () {
  'use strict';
  const R = window.TeacherUI;
  const state = new Map(); // key -> { open:Set, hint:Set, mark:{i:'got'|'miss'}, shown:n, sent:bool }
  const S = k => { let s = state.get(k); if (!s) { s = { open: new Set(), hint: new Set(), mark: {}, shown: 1, sent: false }; state.set(k, s); } return s; };

  function parse(code) {
    const j = JSON.parse(code);
    return Array.isArray(j) ? { items: j } : { title: j.title, items: j.items || j.questions || j.cards || [] };
  }

  R.registerFence(['practice', 'selfcheck', 'self-check'], (code, ctx, env) => {
    if (env && env.open) return '<div class="comp"><div class="diagram-pending">Building practice…</div></div>';
    let spec;
    try { spec = parse(code); } catch (e) { return '<div class="comp comp-error"><div class="diagram-error">practice: ' + ctx.esc(e.message) + '</div></div>'; }
    const key = 'pr' + ctx.hash(code);
    const items = spec.items.map(it => typeof it === 'string' ? { q: it } : it);
    let h = '<div class="comp practice" data-key="' + key + '" data-n="' + items.length + '">' +
      '<div class="pr-head"><span class="pr-title">✎ ' + ctx.esc(spec.title || 'Practice') + '</span><span class="pr-score"></span></div>';
    items.forEach((it, i) => {
      h += '<div class="pr-item" data-i="' + i + '" data-q="' + ctx.esc(String(it.q || it.question || '').slice(0, 160)) + '"><div class="pr-q md">' + ctx.inline(it.q || it.question || '') + '</div>' +
        (it.hint ? '<div class="pr-hint md" hidden>💡 ' + ctx.inline(it.hint) + '</div>' : '') +
        '<div class="pr-a md" hidden>' + ctx.md(String(it.a || it.answer || '')) + '</div>' +
        '<div class="pr-actions">' + (it.hint ? '<button class="btn link" data-act="pr-hint">Hint</button>' : '') +
        '<button class="btn" data-act="pr-show">Show answer</button>' +
        '<span class="pr-mark" hidden><button class="btn" data-act="pr-mark" data-v="got">✓ Got it</button><button class="btn" data-act="pr-mark" data-v="miss">✗ Missed</button></span></div></div>';
    });
    return h + '<div class="pr-foot" hidden><button class="btn primary" data-act="pr-send">Tell the teacher how it went</button></div></div>';
  });

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

  R.registerProcessor(root => {
    const q = sel => (root.matches && root.matches(sel) ? [root] : []).concat(Array.from(root.querySelectorAll(sel)));
    q('.practice').forEach(apply);
    q('.steps.reveal').forEach(applySteps);
  });

  const host = el => el.closest('.practice');
  const idx = el => +el.closest('.pr-item').getAttribute('data-i');
  R.registerAction('pr-show', el => { const p = host(el); S(p.getAttribute('data-key')).open.add(idx(el)); apply(p); });
  R.registerAction('pr-hint', el => { const p = host(el); S(p.getAttribute('data-key')).hint.add(idx(el)); apply(p); });
  R.registerAction('pr-mark', el => { const p = host(el); S(p.getAttribute('data-key')).mark[idx(el)] = el.getAttribute('data-v'); apply(p); });
  R.registerAction('pr-send', (el, e, ctx) => {
    const p = host(el), s = S(p.getAttribute('data-key'));
    if (s.sent) return;
    const items = Array.from(p.querySelectorAll('.pr-item'));
    const missed = items.filter(it => s.mark[+it.getAttribute('data-i')] === 'miss').map(it => '“' + it.getAttribute('data-q') + '”');
    const got = items.length - missed.length;
    ctx.post({ type: 'suggest', text: 'Practice: I got ' + got + ' of ' + items.length + '.' + (missed.length ? ' I missed ' + missed.join(', ') + '.' : '') });
    s.sent = true; apply(p);
  });
  R.registerAction('steps-next', el => { const b = el.closest('.steps'); S(b.getAttribute('data-key')).shown++; applySteps(b); });
  R.registerAction('steps-all', el => { const b = el.closest('.steps'); S(b.getAttribute('data-key')).shown = 1e9; applySteps(b); });
})();
