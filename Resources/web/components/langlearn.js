// Language-learning components and question types for the language mentor:
//   ```gloss        an interlinear sentence: each word with its reading, meaning and role, a translation under it, and
//                   word-order lines between the two ({"lang","words":[{"w","r","m","pos","role"}],"translation","align":[[i,j]]})
//   ```listen       a listening card: play, play slowly, text hidden for dictation ({"lang","text","translation","hide"})
//   ```dialogue     a two-voice dialogue with click-to-hear lines; the learner's role is hidden for role-play ({"lines","you"})
//   ```conjugation  a paradigm table with the stem and endings told apart ({"verb","stem","tense","forms":[{"person","form"}]})
//   ```tones        Mandarin tone contours on the five-level scale ({"syllables":[{"pinyin","tone"}]} or {"text":"nǐ hǎo"})
//   question type `speak`: the learner says the target sentence; on-device recognition in that language returns what was
//   heard, shown word by word against the target; `listen` on any question plays audio for dictation.
(function () {
  'use strict';
  const R = window.TeacherUI;
  const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const RTL = /^(ar|he|fa|ur|ps|yi|dv|ku|sd|ug)\b/;
  const langAttr = l => l ? ' lang="' + esc(l) + '"' + (RTL.test(l) ? ' dir="rtl"' : '') : '';
  const CJK = /[぀-ヿ㐀-鿿豈-﫿가-힯฀-๿]/;

  // ── Listening: one player used by ```listen, dialogues and questions ──
  function player(o) {
    const text = String(o.text || ''), lang = o.lang || '';
    const btn = (label, rate, cls) => '<button class="btn mini ll-play' + (cls || '') + '" data-act="ll-play" data-text="' + esc(text) + '" data-lang="' + esc(lang) + '"' + (rate ? ' data-rate="' + rate + '"' : '') + '>' + label + '</button>';
    let h = '<div class="ll-player' + (o.hide ? ' hidden-text' : '') + '">' + btn('▶ Play') + btn('🐢 Slowly', 0.55) +
      (o.hide ? '<button class="btn mini link" data-act="ll-reveal">Show text</button>' : '');
    h += '<span class="ll-text"' + langAttr(lang) + (o.hide ? ' hidden' : '') + '>' + esc(text) + '</span>';
    if (o.translation) h += '<span class="ll-tr"' + (o.hide ? ' hidden' : '') + '>' + esc(o.translation) + '</span>';
    return h + '</div>';
  }
  R.registerAction('ll-play', (el, e, ctx) => {
    e.stopPropagation();
    ctx.post({ type: 'speak', text: el.getAttribute('data-text'), lang: el.getAttribute('data-lang') || null, rate: el.hasAttribute('data-rate') ? +el.getAttribute('data-rate') : null });
    el.classList.add('speaking'); setTimeout(() => el.classList.remove('speaking'), 900);
  });
  R.registerAction('ll-reveal', el => {
    const p = el.closest('.ll-player, .dl-line, .dl-you');
    if (!p) return;
    p.querySelectorAll('[hidden]').forEach(x => { x.hidden = false; });
    p.classList.remove('hidden-text'); el.remove();
  });

  R.defineComponent({ names: ['listen', 'audio', 'dictation'], version: 1,
    pending: () => '<div class="comp"><div class="diagram-pending">Preparing audio…</div></div>',
    validate: p => { if (typeof p === 'string') p = { text: p }; R.check(p, 'object'); if (!String(p.text || '').trim()) throw new Error('needs text'); return p; },
    render(p, ctx, env) {
      const hide = p.hide === true || p.dictation === true || /dictation/.test(env.lang || '');
      return '<div class="comp listen" data-key="ls' + ctx.hash(env.code) + '"><div class="ll-head">🎧 ' + esc(p.title || (hide ? 'Listen and write what you hear' : 'Listen')) + '</div>' +
        player({ text: p.text, lang: p.lang, hide, translation: p.translation }) + (p.note ? '<div class="ll-note md">' + ctx.inline(p.note) + '</div>' : '') + '</div>';
    } });

  // ── Interlinear gloss with word-order lines ───────────────────────────
  const ROLE_COLORS = { subject: '#2f6fec', topic: '#2f6fec', object: '#e5484d', verb: '#30a46c', particle: '#8e4ec6', adjective: '#f76b15', adverb: '#0d9488',
    preposition: '#d6409f', postposition: '#d6409f', noun: '#946800', pronoun: '#2f6fec', article: '#8e4ec6', conjunction: '#5b5bd6', auxiliary: '#30a46c', copula: '#30a46c',
    adposition: '#d6409f', determiner: '#8e4ec6', numeral: '#946800', interjection: '#12a594', question: '#12a594', negation: '#e5484d', suffix: '#8e4ec6', prefix: '#8e4ec6' };
  const roleColor = r => { const k = String(r || '').toLowerCase().replace(/[^a-z]/g, ''); for (const n in ROLE_COLORS) if (k.startsWith(n.slice(0, 4))) return ROLE_COLORS[n]; return null; };
  function glossWords(p) {
    let words = p.words || p.tokens || p.items;
    if (!words && p.text) words = String(p.text).split(/\s+/).filter(Boolean);
    return (words || []).map(w => typeof w === 'string' ? { w } : Object.assign({}, w, { w: w.w || w.word || w.text || w.form || '', r: w.r || w.reading || w.romaji || w.pinyin || '', m: w.m || w.meaning || w.gloss || '' }));
  }
  R.defineComponent({ names: ['gloss', 'interlinear', 'sentence'], version: 1, selector: '.gloss',
    pending: () => '<div class="comp"><div class="diagram-pending">Glossing…</div></div>',
    validate: p => { if (Array.isArray(p)) p = { words: p }; R.check(p, 'object'); if (!glossWords(p).length) throw new Error('needs words'); return p; },
    render(p, ctx, env) {
      const words = glossWords(p), lang = p.lang || p.language || '';
      const tr = p.translation || p.meaning || p.t || '';
      const trWords = tr ? String(tr).split(/(\s+)/) : [];
      const align = Array.isArray(p.align) ? p.align.filter(a => Array.isArray(a) && a.length === 2) : [];
      let h = '<div class="comp gloss" data-key="gl' + ctx.hash(env.code) + '"' + (align.length ? ' data-align="' + esc(JSON.stringify(align)) + '"' : '') + '>';
      if (p.title) h += '<div class="gl-title">' + esc(p.title) + '</div>';
      h += '<div class="gl-row"' + (RTL.test(lang) ? ' dir="rtl"' : '') + '>' + words.map((w, i) => {
        const c = roleColor(w.role || w.pos);
        return '<div class="gl-w" data-i="' + i + '"' + (c ? ' style="--role:' + c + '"' : '') + '><div class="gw fl"' + langAttr(lang) + '>' + esc(w.w) + '</div>' +
          (w.r ? '<div class="gr">' + esc(w.r) + '</div>' : '') + (w.m ? '<div class="gm">' + esc(w.m) + '</div>' : '') +
          (w.pos || w.role ? '<div class="gp">' + esc(w.role || w.pos) + '</div>' : '') + '</div>';
      }).join('') + '<button class="btn mini ll-play gl-play" data-act="ll-play" data-text="' + esc(words.map(w => w.w).join(CJK.test(words.map(w => w.w).join('')) ? '' : ' ')) + '" data-lang="' + esc(lang) + '">🔊</button></div>';
      if (align.length) h += '<svg class="gl-arcs" aria-hidden="true"></svg>';
      if (tr) h += '<div class="gl-tr">' + trWords.map((t, k) => /^\s+$/.test(t) ? t : '<span class="gl-t" data-j="' + Math.floor(k / 2) + '">' + esc(t) + '</span>').join('') + '</div>';
      const roles = words.map(w => w.role).filter(Boolean);
      if (roles.length) h += '<div class="gl-legend">' + Array.from(new Set(roles)).map(r => '<span style="--role:' + (roleColor(r) || 'var(--muted)') + '">' + esc(r) + '</span>').join('') + '</div>';
      if (p.note) h += '<div class="gl-note md">' + ctx.inline(p.note) + '</div>';
      return h + '</div>';
    },
    mount(el) { drawArcs(el); if (!el._glResize) { el._glResize = true; new ResizeObserver(() => drawArcs(el)).observe(el); } } });
  function drawArcs(el) {
    const svg = el.querySelector('svg.gl-arcs'); if (!svg) return;
    let align; try { align = JSON.parse(el.getAttribute('data-align') || '[]'); } catch (_) { return; }
    const box = el.getBoundingClientRect();
    const row = el.querySelector('.gl-row'), tr = el.querySelector('.gl-tr');
    if (!row || !tr) return;
    const top = row.getBoundingClientRect().bottom - box.top, bottom = tr.getBoundingClientRect().top - box.top;
    svg.style.top = top + 'px'; svg.style.height = Math.max(8, bottom - top) + 'px'; svg.setAttribute('width', box.width); svg.setAttribute('height', Math.max(8, bottom - top));
    const H = Math.max(8, bottom - top);
    svg.innerHTML = align.map(([i, j]) => {
      const a = el.querySelector('.gl-w[data-i="' + i + '"]'), b = el.querySelector('.gl-t[data-j="' + j + '"]');
      if (!a || !b) return '';
      const ra = a.getBoundingClientRect(), rb = b.getBoundingClientRect();
      const x1 = ra.left + ra.width / 2 - box.left, x2 = rb.left + rb.width / 2 - box.left;
      const color = getComputedStyle(a).getPropertyValue('--role').trim() || 'var(--faint)';
      return '<path d="M' + x1 + ',0 C' + x1 + ',' + (H / 2) + ' ' + x2 + ',' + (H / 2) + ' ' + x2 + ',' + H + '" stroke="' + esc(color) + '" fill="none" stroke-width="1.5" opacity=".7" data-i="' + i + '" data-j="' + j + '"/>';
    }).join('');
  }
  document.addEventListener('click', e => {
    const w = e.target.closest('.gl-w, .gl-t'); if (!w) return;
    const g = w.closest('.gloss'); if (!g) return;
    let align; try { align = JSON.parse(g.getAttribute('data-align') || '[]'); } catch (_) { align = []; }
    const i = w.hasAttribute('data-i') ? +w.getAttribute('data-i') : null, j = w.hasAttribute('data-j') ? +w.getAttribute('data-j') : null;
    const on = !w.classList.contains('hi');
    g.querySelectorAll('.hi').forEach(x => x.classList.remove('hi'));
    if (!on) return;
    w.classList.add('hi');
    align.forEach(([a, b]) => {
      if (i != null && a === i) { const t = g.querySelector('.gl-t[data-j="' + b + '"]'); if (t) t.classList.add('hi'); }
      if (j != null && b === j) { const t = g.querySelector('.gl-w[data-i="' + a + '"]'); if (t) t.classList.add('hi'); }
    });
    g.querySelectorAll('.gl-arcs path').forEach(p => p.classList.toggle('hi', (i != null && +p.getAttribute('data-i') === i) || (j != null && +p.getAttribute('data-j') === j)));
  });

  // ── Dialogue / role-play ──────────────────────────────────────────────
  R.defineComponent({ names: ['dialogue', 'dialog', 'conversation', 'roleplay'], version: 1,
    pending: () => '<div class="comp"><div class="diagram-pending">Writing the dialogue…</div></div>',
    validate: p => { if (Array.isArray(p)) p = { lines: p }; R.check(p, 'object'); R.check(p.lines || p.turns || [], { type: 'array', min: 1 }); return p; },
    render(p, ctx, env) {
      const lang = p.lang || p.language || '';
      const lines = (p.lines || p.turns).map(l => typeof l === 'string' ? { text: l } : Object.assign({}, l, { who: l.who || l.speaker || l.name || '', text: l.text || l.line || l.say || '', translation: l.translation || l.meaning || l.en || '' }));
      const you = p.you || p.learner || p.role || '';
      const speakers = Array.from(new Set(lines.map(l => l.who).filter(Boolean)));
      const all = lines.map(l => l.text).join(CJK.test(lines.map(l => l.text).join('')) ? '。' : '. ');
      let h = '<div class="comp dialogue" data-key="dl' + ctx.hash(env.code) + '"><div class="dl-head"><span>💬 ' + esc(p.title || 'Dialogue') + '</span>' +
        (you ? '<span class="dl-you-note">You are <b>' + esc(you) + '</b>: say your lines, then reveal them</span>' : '') +
        '<button class="btn mini" data-act="ll-play" data-text="' + esc(all) + '" data-lang="' + esc(lang) + '">▶ Play all</button></div>';
      lines.forEach(l => {
        const side = speakers.indexOf(l.who) % 2 === 1 ? ' right' : '';
        const mine = you && l.who && l.who.toLowerCase() === String(you).toLowerCase();
        h += '<div class="dl-line' + side + (mine ? ' dl-you' : '') + '">' + (l.who ? '<div class="dl-who">' + esc(l.who) + '</div>' : '') +
          '<div class="dl-bubble">' + (mine ? '<button class="btn mini link" data-act="ll-reveal">Your line · reveal</button>' : '') +
          '<span class="dl-text fl"' + langAttr(lang) + (mine ? ' hidden' : '') + '>' + esc(l.text) + '</span>' +
          (l.reading ? '<span class="dl-reading"' + (mine ? ' hidden' : '') + '>' + esc(l.reading) + '</span>' : '') +
          (l.translation ? '<span class="dl-tr"' + (mine ? ' hidden' : '') + '>' + esc(l.translation) + '</span>' : '') +
          '<button class="btn mini ll-play" data-act="ll-play" data-text="' + esc(l.text) + '" data-lang="' + esc(lang) + '">🔊</button></div></div>';
      });
      if (p.note) h += '<div class="dl-note md">' + ctx.inline(p.note) + '</div>';
      return h + '</div>';
    } });

  // ── Conjugation / declension table ────────────────────────────────────
  R.defineComponent({ names: ['conjugation', 'conjugate', 'paradigm', 'declension'], version: 1,
    pending: () => '<div class="comp"><div class="diagram-pending">Building the table…</div></div>',
    validate: p => { R.check(p, 'object'); R.check(p.forms || p.rows || [], { type: 'array', min: 1 }); return p; },
    render(p, ctx, env) {
      const lang = p.lang || p.language || '';
      const stem = String(p.stem || '');
      const forms = (p.forms || p.rows).map(f => Array.isArray(f) ? { person: f[0], form: f[1], note: f[2] } : typeof f === 'string' ? { form: f } : Object.assign({}, f, { person: f.person || f.pronoun || f.label || f.case || '', form: f.form || f.word || f.value || '' }));
      const cell = f => {
        const form = String(f.form || '');
        if (stem && form.startsWith(stem) && !f.irregular) return '<span class="cj-stem">' + esc(stem) + '</span><span class="cj-end">' + esc(form.slice(stem.length)) + '</span>';
        return '<span class="' + (f.irregular || (stem && !form.startsWith(stem)) ? 'cj-irregular' : '') + '">' + esc(form) + '</span>';
      };
      let h = '<div class="comp conjugation" data-key="cj' + ctx.hash(env.code) + '"><div class="cj-head"><span class="cj-verb fl"' + langAttr(lang) + '>' + esc(p.verb || p.word || p.lemma || '') + '</span>' +
        (p.meaning ? '<span class="cj-meaning">' + esc(p.meaning) + '</span>' : '') + (p.tense || p.title ? '<span class="cj-tense">' + esc(p.tense || p.title) + '</span>' : '') +
        (stem ? '<span class="cj-key"><span class="cj-stem">stem</span> + <span class="cj-end">ending</span></span>' : '') + '</div><table class="cj-table"><tbody>';
      forms.forEach(f => {
        h += '<tr' + (f.irregular ? ' class="irr"' : '') + '><td class="cj-person">' + esc(f.person || '') + '</td><td class="cj-form fl"' + langAttr(lang) + '>' + cell(f) + '</td>' +
          '<td class="cj-note">' + esc(f.note || f.meaning || '') + '</td><td><button class="btn mini ll-play" data-act="ll-play" data-text="' + esc(f.form) + '" data-lang="' + esc(lang) + '">🔊</button></td></tr>';
      });
      h += '</tbody></table>';
      if (forms.some(f => f.irregular)) h += '<div class="cj-legend"><span class="cj-irregular">irregular</span> forms don\'t follow the stem + ending pattern</div>';
      if (p.note) h += '<div class="cj-note-text md">' + ctx.inline(p.note) + '</div>';
      return h + '</div>';
    } });

  // ── Mandarin tones ────────────────────────────────────────────────────
  const TONE_OF = { 'ā': 1, 'á': 2, 'ǎ': 3, 'à': 4, 'ē': 1, 'é': 2, 'ě': 3, 'è': 4, 'ī': 1, 'í': 2, 'ǐ': 3, 'ì': 4, 'ō': 1, 'ó': 2, 'ǒ': 3, 'ò': 4, 'ū': 1, 'ú': 2, 'ǔ': 3, 'ù': 4, 'ǖ': 1, 'ǘ': 2, 'ǚ': 3, 'ǜ': 4 };
  function toneOf(pinyin) {
    const m = /([1-5])$/.exec(pinyin); if (m) return +m[1] % 5;
    for (const ch of pinyin.toLowerCase()) if (TONE_OF[ch]) return TONE_OF[ch];
    return 0;
  }
  // Pitch paths on the 5-level scale (Chao numbers): 55, 35, 214, 51, neutral.
  const CONTOUR = { 1: [[0, 5], [1, 5]], 2: [[0, 3], [1, 5]], 3: [[0, 2], [0.5, 1], [1, 4]], 4: [[0, 5], [1, 1]], 0: [[0.35, 3], [0.65, 3]] };
  R.defineComponent({ names: ['tones', 'tone', 'pitch'], version: 1,
    pending: () => '<div class="comp"><div class="diagram-pending">Drawing tones…</div></div>',
    validate: p => { if (typeof p === 'string') p = { text: p }; if (Array.isArray(p)) p = { syllables: p }; R.check(p, 'object'); if (!(p.syllables || p.text)) throw new Error('needs syllables or text'); return p; },
    render(p, ctx, env) {
      let syl = p.syllables || String(p.text).split(/\s+/).filter(Boolean);
      syl = syl.map(s => typeof s === 'string' ? { pinyin: s } : s).map(s => Object.assign({}, s, { pinyin: s.pinyin || s.p || '', tone: s.tone != null ? +s.tone % 5 : toneOf(s.pinyin || s.p || '') }));
      const W = 84, H = 110, pad = 14, top = 16, bottom = 24;
      const y = lvl => top + (5 - lvl) * (H - top - bottom) / 4;
      let h = '<div class="comp tones" data-key="tn' + ctx.hash(env.code) + '"><svg class="tones-svg" viewBox="0 0 ' + (syl.length * W + pad * 2) + ' ' + H + '" width="' + Math.min(640, syl.length * W + pad * 2) + '" height="' + H + '">';
      for (let l = 1; l <= 5; l++) h += '<line x1="' + pad + '" x2="' + (syl.length * W + pad) + '" y1="' + y(l) + '" y2="' + y(l) + '" class="tn-grid"/><text x="' + (pad - 4) + '" y="' + (y(l) + 3) + '" class="tn-lvl">' + l + '</text>';
      syl.forEach((s, i) => {
        const x0 = pad + i * W + 12, w = W - 24;
        const pts = CONTOUR[s.tone] || CONTOUR[0];
        const d = pts.map((pt, k) => (k ? 'L' : 'M') + (x0 + pt[0] * w) + ',' + y(pt[1])).join(' ');
        h += '<path d="' + d + '" class="tn-path t' + s.tone + '"' + (s.tone === 0 ? ' stroke-dasharray="3 3"' : '') + '/>' +
          (s.tone === 0 ? '<circle cx="' + (x0 + w / 2) + '" cy="' + y(3) + '" r="3" class="tn-dot"/>' : '') +
          '<text x="' + (x0 + w / 2) + '" y="' + (H - 8) + '" class="tn-label">' + esc(s.pinyin) + (s.hanzi ? ' ' + esc(s.hanzi) : '') + '</text>' +
          '<text x="' + (x0 + w / 2) + '" y="' + (top - 5) + '" class="tn-tone">' + (s.tone ? 'tone ' + s.tone : 'neutral') + '</text>';
      });
      h += '</svg><div class="tn-foot"><button class="btn mini ll-play" data-act="ll-play" data-text="' + esc(syl.map(s => s.hanzi || s.pinyin).join('')) + '" data-lang="zh">🔊 Hear it</button>' +
        (p.note ? '<span class="md">' + ctx.inline(p.note) + '</span>' : '<span class="muted">1 high level · 2 rising · 3 dipping · 4 falling</span>') + '</div></div>';
      return h;
    } });

  // ── The `speak` question type: say it, see what was heard ─────────────
  // Words, or characters for scripts written without spaces; case and accents fold, as the app's lenient grading does.
  const tokens = (s, lang) => CJK.test(s) && !/\s/.test(String(s).trim()) ? Array.from(String(s).replace(/[\s\p{P}]/gu, ''))
    : String(s).toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '').normalize('NFC').replace(/[\p{P}]/gu, ' ').split(/\s+/).filter(Boolean);
  /** Which target words were heard: [{w, ok}] and the share matched. */
  function match(target, heard, lang) {
    const t = tokens(target, lang), h = tokens(heard || '', lang);
    const pool = new Map(); h.forEach(w => pool.set(w, (pool.get(w) || 0) + 1));
    const out = t.map(w => { const n = pool.get(w) || 0; if (n) pool.set(w, n - 1); return { w, ok: n > 0 }; });
    return { words: out, score: t.length ? out.filter(x => x.ok).length / t.length : 0 };
  }
  const speakState = new Map();   // "toolId:qi" -> { heard, final, recording }
  R.registerQuestionType('speak', {
    render(q, qi, F, ctx, active, g, id) {
      const target = String(q.target || q.text || q.say || q.sentence || '');
      const lang = q.lang || q.language || '';
      const key = id + ':' + qi;
      const st = speakState.get(key) || {};
      const given = g ? g.given : F.answers[qi];
      const heard = (given && given.heard) || st.heard || '';
      const m = heard ? match(target, heard, lang) : null;
      let h = '<div class="q-speak"><div class="sp-target fl"' + langAttr(lang) + '>' + (m ? m.words.map(w => '<span class="' + (w.ok ? 'ok' : 'miss') + '">' + esc(w.w) + '</span>').join(CJK.test(target) && !/\s/.test(target.trim()) ? '' : ' ') : esc(target)) + '</div>' +
        (q.reading ? '<div class="sp-reading">' + esc(q.reading) + '</div>' : '') +
        '<div class="sp-row"><button class="btn mini ll-play" data-act="ll-play" data-text="' + esc(target) + '" data-lang="' + esc(lang) + '">🔊 Hear it</button>';
      if (active) h += '<button class="btn' + (st.recording ? ' recording' : '') + '" data-act="q-speak" data-q="' + qi + '" data-lang="' + esc(lang) + '">' + (st.recording ? '■ Stop' : '🎤 ' + (heard ? 'Try again' : 'Say it')) + '</button>' + (st.recording ? '<span class="sp-live">Listening…</span>' : '');
      h += '</div>';
      if (heard) h += '<div class="sp-heard"><span class="sp-label">Heard:</span> <span class="fl"' + langAttr(lang) + '>' + esc(heard) + '</span>' + (m ? '<span class="sp-score' + (m.score >= 0.8 ? ' good' : '') + '">' + Math.round(m.score * 100) + '% of the words</span>' : '') + '</div>';
      else if (active) h += '<div class="q-help">Say the sentence out loud; the Mac listens in ' + (lang ? esc(lang) : 'the target language') + ' and shows what it understood.</div>';
      return h + '</div>';
    },
  });
  R.registerAction('q-speak', (el, e, ctx) => {
    const card = el.closest('[data-tool-id]'); if (!card) return;
    const id = card.getAttribute('data-tool-id'), qi = +el.getAttribute('data-q'), key = id + ':' + qi;
    const st = speakState.get(key) || {};
    if (st.recording) { ctx.post({ type: 'dictate', id: key, op: 'stop' }); st.recording = false; }
    else { st.recording = true; st.heard = ''; ctx.post({ type: 'dictate', id: key, lang: el.getAttribute('data-lang') || null, op: 'start' }); }
    speakState.set(key, st);
    ctx.refreshCard(id);
  });
  /** From the app: recognised speech for a `speak` question (key "toolId:qi"); `final` ends the recording. */
  R.dictation = function (key, text, final) {
    const st = speakState.get(key) || {};
    st.heard = text || st.heard || '';
    if (final) st.recording = false;
    speakState.set(key, st);
    const [id, qi] = [key.slice(0, key.lastIndexOf(':')), +key.slice(key.lastIndexOf(':') + 1)];
    const F = window.TeacherForms && window.TeacherForms.state(id);
    const card = document.querySelector('[data-tool-id="' + CSS.escape(id) + '"]');
    const q = card && card._block && card._block.input && card._block.input.questions ? card._block.input.questions[qi] : null;
    if (F && st.heard) F.answers[qi] = { heard: st.heard, target: q ? String(q.target || q.text || '') : '' };
    if (R._ctx) R._ctx.refreshCard(id);
  };

  // Questions with `listen`: the audio comes first and the text stays hidden (dictation), whatever the question type.
  R.questionAudio = (q, ctx) => {
    const text = q.listen || q.audio;
    if (!text) return '';
    return player({ text: String(text), lang: q.listen_lang || q.lang || q.language || '', hide: q.show_text !== true });
  };

  R.injectStyles('langlearn', `
    .ll-player { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
    .ll-player .ll-text { font-size: 1.15em; }
    .ll-player .ll-tr, .dl-tr, .gl-tr { color: var(--muted); }
    .ll-play.speaking { background: var(--accent-soft); }
    .listen { border: 1px solid var(--border); border-radius: 12px; padding: 10px 14px; background: var(--card); }
    .ll-head, .dl-head, .cj-head, .gl-title { font-weight: 600; margin-bottom: 8px; display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
    .ll-note, .dl-note, .gl-note, .cj-note-text { color: var(--muted); font-size: .9em; margin-top: 6px; }
    .gloss { border: 1px solid var(--border); border-radius: 12px; padding: 12px 14px; position: relative; overflow-x: auto; }
    .gl-row { display: flex; gap: 14px; align-items: flex-end; flex-wrap: wrap; }
    .gl-w { text-align: center; padding: 4px 6px; border-radius: 8px; border-bottom: 3px solid var(--role, transparent); cursor: pointer; }
    .gl-w:hover, .gl-w.hi { background: var(--accent-soft); }
    .gl-w .gw { font-size: 1.45em; line-height: 1.3; }
    .gl-w .gr { font-size: .8em; color: var(--accent); }
    .gl-w .gm { font-size: .88em; }
    .gl-w .gp { font-size: .72em; color: var(--faint); text-transform: uppercase; letter-spacing: .04em; }
    .gl-play { align-self: center; }
    .gl-arcs { position: absolute; left: 0; width: 100%; pointer-events: none; }
    .gl-arcs path.hi { stroke-width: 3; opacity: 1; }
    .gl-tr { margin-top: 18px; font-size: 1.02em; }
    .gl-t { padding: 1px 2px; border-radius: 4px; cursor: pointer; }
    .gl-t.hi { background: var(--accent-soft); }
    .gl-legend { display: flex; gap: 10px; flex-wrap: wrap; margin-top: 8px; font-size: .78em; color: var(--muted); }
    .gl-legend span { border-bottom: 3px solid var(--role); padding: 0 2px; }
    .dialogue { border: 1px solid var(--border); border-radius: 12px; padding: 10px 14px; }
    .dl-head { justify-content: space-between; }
    .dl-you-note { font-weight: 400; color: var(--muted); font-size: .88em; }
    .dl-line { display: flex; flex-direction: column; align-items: flex-start; margin: 6px 0; }
    .dl-line.right { align-items: flex-end; }
    .dl-who { font-size: .75em; color: var(--faint); text-transform: uppercase; letter-spacing: .05em; margin: 0 6px 2px; }
    .dl-bubble { background: var(--card); border-radius: 14px; padding: 7px 12px; max-width: 86%; display: flex; flex-direction: column; gap: 2px; }
    .dl-line.right .dl-bubble { background: var(--user); }
    .dl-you .dl-bubble { border: 1px dashed var(--accent); }
    .dl-text { font-size: 1.1em; }
    .dl-reading { font-size: .82em; color: var(--accent); }
    .dl-bubble .ll-play { align-self: flex-start; margin-top: 2px; }
    .conjugation { border: 1px solid var(--border); border-radius: 12px; padding: 10px 14px; }
    .cj-verb { font-size: 1.3em; }
    .cj-meaning { color: var(--muted); }
    .cj-tense { font-size: .8em; color: var(--muted); border: 1px solid var(--border); border-radius: 999px; padding: 1px 9px; }
    .cj-key { margin-left: auto; font-size: .8em; color: var(--muted); }
    .cj-table { border-collapse: collapse; width: auto; }
    .cj-table td { padding: 3px 10px 3px 0; border: 0; }
    .cj-person { color: var(--muted); }
    .cj-form { font-size: 1.12em; }
    .cj-stem { color: var(--accent); font-weight: 600; }
    .cj-end { color: var(--bad); font-weight: 600; }
    .cj-irregular { color: var(--warn); font-weight: 600; }
    .cj-note { color: var(--muted); font-size: .88em; }
    .cj-legend { font-size: .8em; color: var(--muted); margin-top: 4px; }
    .tones { border: 1px solid var(--border); border-radius: 12px; padding: 10px 14px; }
    .tones-svg { display: block; max-width: 100%; height: auto; }
    .tn-grid { stroke: var(--border); stroke-width: 1; }
    .tn-lvl { font-size: 9px; fill: var(--faint); text-anchor: end; }
    .tn-path { stroke: var(--accent); stroke-width: 3; fill: none; stroke-linecap: round; stroke-linejoin: round; }
    .tn-path.t2 { stroke: #30a46c; } .tn-path.t3 { stroke: #f76b15; } .tn-path.t4 { stroke: #e5484d; } .tn-path.t0 { stroke: var(--faint); }
    .tn-dot { fill: var(--faint); }
    .tn-label { font-size: 13px; fill: var(--fg); text-anchor: middle; }
    .tn-tone { font-size: 9px; fill: var(--muted); text-anchor: middle; }
    .tn-foot { display: flex; align-items: center; gap: 10px; margin-top: 4px; font-size: .85em; color: var(--muted); }
    .q-speak .sp-target { font-size: 1.3em; margin-bottom: 4px; }
    .q-speak .sp-target .ok { color: var(--good); } .q-speak .sp-target .miss { color: var(--bad); text-decoration: underline dotted; }
    .q-speak .sp-reading { color: var(--accent); font-size: .85em; margin-bottom: 4px; }
    .q-speak .sp-row { display: flex; gap: 8px; align-items: center; margin: 6px 0; }
    .q-speak .btn.recording { background: var(--bad); color: #fff; border-color: var(--bad); }
    .q-speak .sp-live { color: var(--bad); font-size: .85em; animation: pulse 1.2s ease-in-out infinite; }
    @keyframes pulse { 0%, 100% { opacity: .5; } 50% { opacity: 1; } }
    .q-speak .sp-heard { background: var(--card); border-radius: 8px; padding: 6px 10px; font-size: .95em; display: flex; gap: 8px; align-items: baseline; flex-wrap: wrap; }
    .q-speak .sp-label { color: var(--muted); font-size: .85em; }
    .q-speak .sp-score { margin-left: auto; font-size: .82em; color: var(--muted); } .q-speak .sp-score.good { color: var(--good); }
    .quiz-q .ll-player { margin-bottom: 8px; }
  `);
  window.TeacherLang = { player, match, tokens, toneOf, roleColor, glossWords };
})();
