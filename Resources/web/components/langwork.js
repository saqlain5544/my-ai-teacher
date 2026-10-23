// Serious language work for the language mentor — reading, checked dictation, written work and its correction:
//   ```reading      a graded passage: click any word for its reading, meaning and dictionary entry and save it (with the
//                   sentence it came from) to the learner's words; readings (furigana, pinyin) shown for all words, only
//                   for words not yet known, or none; each sentence plays on its own, the whole passage sentence by sentence
//                   (with pauses to shadow), a sentence can be translated on device; "Done" logs the words read.
//                   {"lang","title","level","text","translation","readings":"all|new|none","note"}
//   ```correction   the learner's text against its correction, word by word: what changed, numbered errors with their
//                   type and why, rubric scores, a more natural version, and a cue to produce it again (checked here).
//                   {"lang","original","corrected","errors":[{"wrong","right","type","why"}],"rubric":[{"criterion","score","max","note"}],"better","recast"}
//   question types  dictation (listen and write; graded word by word), translate, rewrite (a register or style),
//                   build_sentence (one sentence from given words, typed), table (a paradigm to fill)
// The alignment here is the app's (Study/TextDiff.swift): words, characters for unspaced scripts, in order.
(function () {
  'use strict';
  const R = window.TeacherUI;
  const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const RTL = /^(ar|he|fa|ur|ps|yi|dv|ku|sd|ug)\b/;
  const langAttr = l => l ? ' lang="' + esc(l) + '"' + (RTL.test(l) ? ' dir="rtl"' : '') : '';
  const UNSPACED = /[぀-ヿ㐀-鿿豈-﫿฀-๿]/;
  const post = m => { if (R._ctx) R._ctx.post(m); };
  let seq = 0;
  const nextKey = p => p + (++seq) + '-' + Date.now().toString(36);

  // ── Alignment (as TextDiff.swift) ─────────────────────────────────────
  const norm = (s, strict) => {
    let t = String(s).toLowerCase().normalize('NFD');
    if (!strict) t = t.replace(/[\u0300-\u036f\u064B-\u065F\u0670\u0640\u0591-\u05C7]/g, '');   // accents; harakat and niqqud are optional too
    return t.normalize('NFC').replace(/[^\p{L}\p{M}\p{N}#+]+/gu, ' ').trim();
  };
  function tokens(s, strict) {
    s = String(s || '');
    // Characters as the reader sees them (a Thai consonant with its vowel and tone marks is one), as Swift's Character.
    if (UNSPACED.test(s)) return Array.from(new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(s), x => x.segment)
      .filter(c => /^[\p{L}\p{N}]/u.test(c)).map(c => ({ text: c, norm: norm(c, strict) }));
    return s.split(/\s+/).map(w => ({ text: w.replace(/^[\p{P}\p{S}]+|[\p{P}\p{S}]+$/gu, ''), norm: norm(w, strict) })).filter(t => t.norm);
  }
  /** [{k: same|wrong|missing|extra, t, g}] and the share of target tokens matched in order. */
  function align(target, given, strict) {
    const t = tokens(target, strict), g = tokens(given, strict), n = t.length, m = g.length;
    const L = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
    for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) L[i][j] = t[i].norm === g[j].norm ? L[i + 1][j + 1] + 1 : Math.max(L[i + 1][j], L[i][j + 1]);
    const raw = []; let i = 0, j = 0;
    while (i < n || j < m) {
      if (i < n && j < m && t[i].norm === g[j].norm) { raw.push({ k: 'same', t: t[i].text, g: g[j].text }); i++; j++; }
      else if (j < m && (i === n || L[i][j + 1] >= L[i + 1][j])) { raw.push({ k: 'extra', g: g[j].text }); j++; }
      else { raw.push({ k: 'missing', t: t[i].text }); i++; }
    }
    const ops = [];
    for (let k = 0; k < raw.length;) {
      if (raw[k].k === 'same') { ops.push(raw[k++]); continue; }
      const run = []; while (k < raw.length && raw[k].k !== 'same') run.push(raw[k++]);
      const miss = run.filter(o => o.k === 'missing'), extra = run.filter(o => o.k === 'extra'), p = Math.min(miss.length, extra.length);
      for (let q = 0; q < p; q++) ops.push({ k: 'wrong', t: miss[q].t, g: extra[q].g });
      ops.push(...miss.slice(p), ...extra.slice(p));
    }
    // Extra words count against the score: "el gato negro come mucho" is not "el gato negro".
    const extra = ops.filter(o => o.k === 'extra').length;
    return { ops, score: n ? ops.filter(o => o.k === 'same').length / (n + extra) : 0 };
  }
  /** The alignment drawn inline: right words plain, a wrong one struck through with the right one after it, a missing
   *  one inserted, an extra one struck. `joiner` '' for unspaced scripts. */
  function diffHTML(ops, lang) {
    const joinWith = ops.some(o => UNSPACED.test((o.t || '') + (o.g || ''))) ? '' : ' ';
    return '<span class="lw-diff"' + langAttr(lang) + '>' + ops.map(o =>
      o.k === 'same' ? '<span class="d-same">' + esc(o.t || o.g) + '</span>'
        : o.k === 'wrong' ? '<span class="d-wrong"><del>' + esc(o.g) + '</del><ins>' + esc(o.t) + '</ins></span>'
          : o.k === 'missing' ? '<ins class="d-missing">' + esc(o.t) + '</ins>' : '<del class="d-extra">' + esc(o.g) + '</del>').join(joinWith) + '</span>';
  }
  const scoreLine = (d, what) => '<span class="lw-score' + (d.score >= 0.999 ? ' good' : d.score >= 0.8 ? ' ok' : '') + '">' + Math.round(d.score * 100) + '% of the ' + (what || 'words') + ' right</span>';

  // ── Question types ────────────────────────────────────────────────────
  const field = (q, qi, F, ctx, active, g, opts) => {
    const v = g ? g.given : F.answers[qi];
    if (!active) return '<div class="q-given"' + langAttr(q.lang) + '>' + (v == null || v === '' ? '<span class="muted">(no answer)</span>' : esc(v)) + '</div>';
    const rows = opts && opts.rows || 4;
    return '<textarea class="q-text lw-answer" data-q-input="' + qi + '" rows="' + rows + '" spellcheck="false" maxlength="' + (+q.max_length || 8000) + '"' + langAttr(q.lang) +
      ' placeholder="' + esc(q.placeholder || (opts && opts.placeholder) || 'Write it here…') + '"' + (q.min_length ? ' data-minlen="' + (+q.min_length) + '"' : '') + '>' + esc(v == null ? '' : v) + '</textarea>' +
      '<div class="q-meta"><span class="q-err" data-err="' + qi + '"></span><span class="q-count lw-words" data-words="' + qi + '">' + wordInfo(v, q) + '</span></div>';
  };
  const countWords = s => { s = String(s || '').trim(); if (!s) return 0; return UNSPACED.test(s) ? Array.from(s.replace(/[\s\p{P}]/gu, '')).length : s.split(/\s+/).length; };
  const wordInfo = (v, q) => { const n = countWords(v), unit = UNSPACED.test(String(v || '') + (q.text || '')) ? 'characters' : 'words'; return n + ' ' + unit + (q.min_words ? ' (at least ' + q.min_words + ')' : ''); };
  const rubricHTML = q => Array.isArray(q.rubric) && q.rubric.length ? '<div class="lw-rubric-ask"><span class="muted">Marked on:</span> ' + q.rubric.map(r => esc(r.criterion || r.name || r) + (r.points ? ' <b>' + esc(r.points) + '</b>' : '')).join(' · ') + '</div>' : '';
  const sourceBox = (q, label) => '<div class="lw-source"><div class="lw-label">' + esc(label) + (q.from ? ' · ' + esc(q.from) : '') + '</div><div class="lw-src-text"' + langAttr(q.from && q.from.length <= 3 ? q.from : '') + '>' + esc(q.text || '') + '</div>' +
    '<button class="btn mini ll-play" data-act="ll-play" data-text="' + esc(q.text || '') + '" data-lang="' + esc(q.from || '') + '">🔊</button></div>';

  R.registerQuestionType('dictation', {
    render(q, qi, F, ctx, active, g) {
      // The audio comes from `listen` (questions.js plays it first, text hidden); after grading, the check word by word.
      if (g && g.given != null && g.given !== '') {
        const d = g.diff || align(q.listen || q.text || '', String(g.given), q.accents === 'strict');
        return '<div class="lw-check"><div class="lw-label">What you wrote, checked</div>' + diffHTML(d.ops, q.lang || q.listen_lang) + '<div class="lw-check-foot">' + scoreLine(d) +
          '<span class="lw-legend"><del>extra</del> <ins>missing</ins> <span class="d-wrong"><del>yours</del><ins>right</ins></span></span></div></div>';
      }
      return field(q, qi, F, ctx, active, g, { rows: 2, placeholder: 'Write exactly what you hear…' });
    },
  });
  R.registerQuestionType('translate', {
    render(q, qi, F, ctx, active, g) {
      return sourceBox(q, 'Translate' + (q.to ? ' into ' + q.to : '')) + rubricHTML(q) + field(q, qi, F, ctx, active, g, { placeholder: 'Your translation…' });
    },
  });
  R.registerQuestionType('rewrite', {
    render(q, qi, F, ctx, active, g) {
      return sourceBox(q, 'Rewrite') + '<div class="lw-instruction">✎ ' + ctx.inline(q.instruction || '') + '</div>' + rubricHTML(q) + field(q, qi, F, ctx, active, g, { placeholder: 'Your version…' });
    },
  });
  R.registerQuestionType('build_sentence', {
    render(q, qi, F, ctx, active, g) {
      const v = String((g ? g.given : F.answers[qi]) || '');
      const words = (q.words || []).map(String);
      return '<div class="lw-words-given" data-words-for="' + qi + '">' + words.map(w => '<span class="lw-chip' + (v && norm(v).includes(norm(w)) ? ' used' : '') + '"' + langAttr(q.lang) + '>' + esc(w) + '</span>').join('') +
        '</div><div class="q-help">Write one sentence that uses all of them (change their form as the grammar needs).</div>' + rubricHTML(q) + field(q, qi, F, ctx, active, g, { rows: 2, placeholder: 'Your sentence…' });
    },
  });
  R.registerQuestionType('table', {
    render(q, qi, F, ctx, active, g) {
      const rows = q.rows || [], cols = q.columns || [], cells = q.cells || [];
      const given = (g ? g.given : F.answers[qi]) || [];
      const key = g && Array.isArray(g.answer) ? g.answer : null;
      let h = '<table class="lw-table"' + langAttr(q.lang) + '><thead><tr><th></th>' + cols.map(c => '<th>' + esc(c) + '</th>').join('') + '</tr></thead><tbody>';
      rows.forEach((r, ri) => {
        h += '<tr><th>' + esc(r) + '</th>';
        cols.forEach((c, ci) => {
          const shown = cells[ri] && cells[ri][ci];
          if (shown != null && shown !== '') { h += '<td class="lw-shown">' + esc(shown) + '</td>'; return; }
          const v = (given[ri] && given[ri][ci]) || '';
          let cls = '';
          if (key && key[ri] && key[ri][ci] != null) cls = [].concat(key[ri][ci]).map(x => norm(x, q.accents === 'strict')).includes(norm(v, q.accents === 'strict')) ? ' ok' : ' bad';
          h += '<td><input type="text" class="blank lw-cell' + cls + '" data-q-cell="' + qi + ':' + ri + ':' + ci + '" value="' + esc(v) + '"' + (active ? '' : ' disabled') + ' spellcheck="false">' +
            (cls === ' bad' ? '<span class="blank-fix">' + esc([].concat(key[ri][ci])[0]) + '</span>' : '') + '</td>';
        });
        h += '</tr>';
      });
      return h + '</tbody></table>';
    },
  });
  // Typing in a written answer: the word count, and which given words a built sentence uses so far.
  document.addEventListener('input', e => {
    const t = e.target; if (!t || !t.matches) return;
    if (t.matches('textarea.lw-answer')) {
      const qi = t.getAttribute('data-q-input'), card = t.closest('[data-tool-id]'); if (!card) return;
      const q = questionOf(card, +qi) || {};
      const w = card.querySelector('[data-words="' + qi + '"]'); if (w) w.textContent = wordInfo(t.value, q);
      const chips = card.querySelector('[data-words-for="' + qi + '"]');
      if (chips) chips.querySelectorAll('.lw-chip').forEach(c => c.classList.toggle('used', !!t.value && norm(t.value).includes(norm(c.textContent))));
    }
    if (t.matches('input[data-q-cell]')) {
      const [qi, r, c] = t.getAttribute('data-q-cell').split(':').map(Number);
      const card = t.closest('[data-tool-id]'); if (!card || !window.TeacherForms) return;
      const F = window.TeacherForms.state(card.getAttribute('data-tool-id'));
      const a = Array.isArray(F.answers[qi]) ? F.answers[qi] : (F.answers[qi] = []);
      (a[r] = Array.isArray(a[r]) ? a[r] : [])[c] = t.value;
    }
  }, true);
  function questionOf(card, qi) {
    const b = card._block; const qs = (b && b.input && b.input.questions) || [];
    return qs[qi];
  }

  // ── ```correction ─────────────────────────────────────────────────────
  const ERR_COLORS = { grammar: '#e5484d', particle: '#8e4ec6', conjugation: '#30a46c', vocabulary: '#2f6fec', spelling: '#f76b15', 'word order': '#0d9488', register: '#d6409f', meaning: '#946800' };
  const errColor = t => { const k = String(t || '').toLowerCase(); for (const n in ERR_COLORS) if (k.startsWith(n.slice(0, 5))) return ERR_COLORS[n]; return 'var(--muted)'; };
  const play = (text, lang) => '<button class="btn mini ll-play" data-act="ll-play" data-text="' + esc(text) + '" data-lang="' + esc(lang || '') + '">🔊</button>';
  R.defineComponent({ names: ['correction', 'corrections', 'feedback-writing'], version: 1, selector: '.lw-correction',
    pending: () => '<div class="comp"><div class="diagram-pending">Marking your writing…</div></div>',
    validate: p => { R.check(p, 'object'); if (!p.original && !p.text) throw new Error('needs original'); if (p.corrected == null && p.correct == null) throw new Error('needs corrected'); return p; },
    render(p, ctx, env) {
      const lang = p.lang || '', original = String(p.original || p.text || ''), corrected = String(p.corrected != null ? p.corrected : p.correct);
      const d = align(corrected, original, true);
      const errors = (p.errors || p.mistakes || []).map(e => typeof e === 'string' ? { why: e } : e);
      const rub = (p.rubric || []).filter(r => r && (r.criterion || r.name));
      const total = rub.reduce((a, r) => a + (+r.score || 0), 0), max = rub.reduce((a, r) => a + (+r.max || +r.points || 0), 0);
      const key = 'cr' + ctx.hash(env.code);
      let h = '<div class="comp lw-correction" data-key="' + key + '" data-corrected="' + esc(corrected) + '" data-lang="' + esc(lang) + '">' +
        '<div class="lw-head"><span>✍️ ' + esc(p.title || 'Your writing, corrected') + '</span>' + (max ? '<span class="lw-total">' + total + ' / ' + max + '</span>' : '') +
        (d.score >= 0.999 ? '<span class="lw-perfect">No changes needed</span>' : '') +
        '<span class="lw-views" role="tablist"><button class="on" data-act="lw-view" data-v="diff">Changes</button><button data-act="lw-view" data-v="corrected">Corrected</button><button data-act="lw-view" data-v="original">Yours</button></span></div>';
      h += '<div class="lw-text lw-v-diff">' + diffHTML(d.ops, lang) + '</div>' +
        '<div class="lw-text lw-v-corrected" hidden><span' + langAttr(lang) + '>' + esc(corrected) + '</span> ' + play(corrected, lang) + '</div>' +
        '<div class="lw-text lw-v-original" hidden><span' + langAttr(lang) + '>' + esc(original) + '</span></div>';
      if (errors.length) {
        h += '<ol class="lw-errors">' + errors.map((e, i) => '<li data-wrong="' + esc(e.wrong || '') + '" data-right="' + esc(e.right || '') + '" style="--err:' + errColor(e.type) + '">' +
          (e.type ? '<span class="lw-type">' + esc(e.type) + '</span>' : '') +
          (e.wrong || e.right ? '<span class="lw-pair"><del' + langAttr(lang) + '>' + esc(e.wrong || '∅') + '</del> → <ins' + langAttr(lang) + '>' + esc(e.right || '∅') + '</ins></span>' : '') +
          (e.why ? '<span class="lw-why md">' + ctx.inline(e.why) + '</span>' : '') + '</li>').join('') + '</ol>';
      }
      if (rub.length) {
        h += '<div class="lw-rubric">' + rub.map(r => { const mx = +r.max || +r.points || 0, sc = +r.score || 0;
          return '<div class="lw-r"><span class="lw-r-name">' + esc(r.criterion || r.name) + '</span><span class="lw-bar"><span style="width:' + (mx ? Math.round(100 * sc / mx) : 0) + '%"></span></span><span class="lw-r-score">' + sc + (mx ? '/' + mx : '') + '</span>' +
            (r.note ? '<span class="lw-r-note">' + ctx.inline(r.note) + '</span>' : '') + '</div>'; }).join('') + '</div>';
      }
      if (p.better) h += '<div class="lw-better"><span class="lw-label">More natural</span><span' + langAttr(lang) + '>' + esc(p.better) + '</span> ' + play(p.better, lang) + '</div>';
      if (p.note || p.summary) h += '<div class="lw-note md">' + ctx.inline(p.note || p.summary) + '</div>';
      if (d.score < 0.999 || p.recast) {
        h += '<div class="lw-again"><div class="lw-label">Now produce it again' + (p.recast ? ': <span class="md">' + ctx.inline(p.recast) + '</span>' : ' — from memory, without looking') + '</div>' +
          '<textarea class="q-text lw-again-input" data-kbd rows="2" spellcheck="false"' + langAttr(lang) + ' placeholder="Write the corrected version…"></textarea>' +
          '<div class="btn-row"><button class="btn" data-act="lw-check">Check</button><button class="btn primary" data-act="lw-send">Send to teacher</button></div><div class="lw-again-result"></div></div>';
      }
      return h + '</div>';
    },
    mount(el) {
      // Hiding the corrected text while they produce it again: the "Changes" view shows it, so typing switches to "Yours".
      const ta = el.querySelector('.lw-again-input'); if (!ta || ta._lw) return; ta._lw = true;
      ta.addEventListener('focus', () => view(el, 'original'));
    } });
  function view(el, v) {
    el.querySelectorAll('.lw-text').forEach(t => { t.hidden = !t.classList.contains('lw-v-' + v); });
    el.querySelectorAll('.lw-views button').forEach(b => b.classList.toggle('on', b.getAttribute('data-v') === v));
  }
  R.registerAction('lw-view', el => { const c = el.closest('.lw-correction'); if (c) view(c, el.getAttribute('data-v')); });
  R.registerAction('lw-check', el => {
    const c = el.closest('.lw-correction'); if (!c) return;
    const ta = c.querySelector('.lw-again-input'), out = c.querySelector('.lw-again-result');
    const d = align(c.getAttribute('data-corrected') || '', ta.value, true);
    out.innerHTML = d.score >= 0.999 && d.ops.every(o => o.k === 'same') ? '<span class="lw-score good">✓ Exactly right</span>' : diffHTML(d.ops, c.getAttribute('data-lang')) + ' ' + scoreLine(d);
  });
  R.registerAction('lw-send', (el, e, ctx) => {
    const c = el.closest('.lw-correction'); if (!c) return;
    const t = c.querySelector('.lw-again-input').value.trim(); if (!t) { c.querySelector('.lw-again-input').focus(); return; }
    ctx.post({ type: 'suggest', text: 'My corrected version: ' + t });
    el.disabled = true; el.textContent = 'Sent';
  });

  // ── ```reading ────────────────────────────────────────────────────────
  const readers = new Map();   // key -> { lang, text, sentences: [[s, e]], tokens, readings, playing }
  function segments(text, lang) {
    // Sentences and words as the page can find them (Intl.Segmenter); the app's analysis replaces the words with readings.
    const sentences = [], words = [];
    try {
      const ss = new Intl.Segmenter(lang || undefined, { granularity: 'sentence' });
      for (const s of ss.segment(text)) if (s.segment.trim()) sentences.push([s.index, s.index + s.segment.length]);
      const ws = new Intl.Segmenter(lang || undefined, { granularity: 'word' });
      for (const w of ws.segment(text)) if (w.isWordLike) words.push({ s: w.index, e: w.index + w.segment.length });
    } catch (_) { sentences.push([0, text.length]); }
    return { sentences: sentences.length ? sentences : [[0, text.length]], words };
  }
  function readingBody(st) {
    const { text, sentences, lang } = st;
    const toks = st.tokens || st.words;
    const mode = st.mode;
    let h = '', ti = 0;
    sentences.forEach(([s0, s1], si) => {
      let p = s0, inner = '';
      while (ti < toks.length && toks[ti].e <= s1) {
        const t = toks[ti++]; if (t.s < p) continue;
        inner += esc(text.slice(p, t.s));
        const w = text.slice(t.s, t.e);
        const ruby = t.r && (mode === 'all' || (mode === 'new' && !t.known)) && /[一-鿿㐀-䶿]/.test(w) ? t.r : '';
        inner += '<span class="rd-w' + (t.known ? ' known' : '') + (t.saved ? ' saved' : '') + '" data-s="' + t.s + '" data-e="' + t.e + '">' + (ruby ? '<ruby>' + esc(w) + '<rt>' + esc(ruby) + '</rt></ruby>' : esc(w)) + '</span>';
        p = t.e;
      }
      inner += esc(text.slice(p, s1));
      h += '<span class="rd-s" data-si="' + si + '">' + inner.replace(/\n{2,}/g, '<br><br>').replace(/\n/g, '<br>') + '<button class="rd-play" data-act="rd-say" data-si="' + si + '" title="Hear this sentence" aria-label="Hear this sentence">▸</button></span>';
      const gap = text.slice(s1, (sentences[si + 1] || [text.length])[0]);
      if (gap) h += esc(gap).replace(/\n{2,}/g, '<br><br>').replace(/\n/g, '<br>');
    });
    return h;
  }
  const hasReadings = l => /^(ja|zh)/.test(l || '');
  R.defineComponent({ names: ['reading', 'passage', 'text-reader'], version: 1, selector: '.lw-reading',
    pending: () => '<div class="comp"><div class="diagram-pending">Preparing the passage…</div></div>',
    validate: p => { if (typeof p === 'string') p = { text: p }; R.check(p, 'object'); if (!String(p.text || p.passage || '').trim()) throw new Error('needs text'); return p; },
    render(p, ctx, env) {
      const text = String(p.text || p.passage), lang = p.lang || p.language || '';
      const key = 'rd' + ctx.hash(env.code);
      let st = readers.get(key);
      if (!st) {
        const seg = segments(text, lang);
        st = { key, lang, text, title: p.title || '', sentences: seg.sentences, words: seg.words, tokens: null, mode: p.readings || (hasReadings(lang) ? 'new' : 'none'), analysed: false };
        readers.set(key, st);
      }
      const n = countWords(text), unit = UNSPACED.test(text) ? 'characters' : 'words';
      const minutes = Math.max(1, Math.round(n / (UNSPACED.test(text) ? 250 : 130)));
      let h = '<div class="comp lw-reading" data-key="' + key + '"><div class="rd-head"><span class="rd-title">📖 ' + esc(p.title || 'Reading') + '</span>' +
        (p.level ? '<span class="rd-level">' + esc(p.level) + '</span>' : '') + '<span class="rd-meta">' + n + ' ' + unit + ' · ~' + minutes + ' min</span><span class="kbd-sp" style="flex:1"></span>' +
        (hasReadings(lang) ? '<span class="lw-views rd-modes" title="Readings above the words">' + [['all', 'Readings'], ['new', 'New words'], ['none', 'None']].map(([v, t]) => '<button data-act="rd-mode" data-v="' + v + '" class="' + (st.mode === v ? 'on' : '') + '">' + t + '</button>').join('') + '</span>' : '') +
        '<button class="btn mini" data-act="rd-all">▶ Read aloud</button><button class="btn mini" data-act="rd-all" data-shadow="1" title="Pauses after each sentence for you to repeat it">🗣 Shadow</button></div>' +
        '<div class="rd-body"' + langAttr(lang) + '>' + readingBody(st) + '</div>' +
        '<div class="rd-pop" hidden></div>';
      if (p.translation) h += '<details class="rd-tr"><summary>Translation</summary><div class="md">' + ctx.md(Array.isArray(p.translation) ? p.translation.join('\n\n') : String(p.translation)) + '</div></details>';
      if (p.note) h += '<div class="ll-note md">' + ctx.inline(p.note) + '</div>';
      h += '<div class="rd-foot"><span class="muted">Click any word for its reading and meaning, and to save it with this sentence.</span><button class="btn mini" data-act="rd-done">✓ Done reading</button></div>';
      return h + '</div>';
    },
    mount(el) {
      const st = readers.get(el.getAttribute('data-key')); if (!st || st.analysed) return;
      st.analysed = true;
      post({ type: 'langwork', op: 'analyze', key: st.key, text: st.text, lang: st.lang });
    } });
  function refreshReading(key) {
    const st = readers.get(key); if (!st) return;
    document.querySelectorAll('.lw-reading[data-key="' + key + '"] .rd-body').forEach(b => { b.innerHTML = readingBody(st); });
    document.querySelectorAll('.lw-reading[data-key="' + key + '"] .rd-modes button').forEach(b => b.classList.toggle('on', b.getAttribute('data-v') === st.mode));
  }
  R.registerAction('rd-mode', el => { const c = el.closest('.lw-reading'), st = c && readers.get(c.getAttribute('data-key')); if (!st) return; st.mode = el.getAttribute('data-v'); refreshReading(st.key); });
  const sentenceText = (st, si) => { const s = st.sentences[si]; return s ? st.text.slice(s[0], s[1]).trim() : ''; };
  R.registerAction('rd-say', (el, e) => {
    e.stopPropagation();
    const c = el.closest('.lw-reading'), st = c && readers.get(c.getAttribute('data-key')); if (!st) return;
    stopPlaying(st); say(st, +el.getAttribute('data-si'));
  });
  function highlight(st, si) {
    document.querySelectorAll('.lw-reading[data-key="' + st.key + '"] .rd-s').forEach(s => s.classList.toggle('speaking', +s.getAttribute('data-si') === si));
  }
  function say(st, si, then) {
    const key = st.key + ':' + si;
    st.waiting = key; st.then = then || null;
    highlight(st, si);
    post({ type: 'speak', text: sentenceText(st, si), lang: st.lang, key });
  }
  function stopPlaying(st) { st.playing = false; st.then = null; clearTimeout(st.timer); highlight(st, -1); }
  R.registerAction('rd-all', el => {
    const c = el.closest('.lw-reading'), st = c && readers.get(c.getAttribute('data-key')); if (!st) return;
    if (st.playing) { stopPlaying(st); post({ type: 'speak', text: '', stop: true }); return; }
    st.playing = true;
    const shadow = el.hasAttribute('data-shadow');
    const step = si => {
      if (!st.playing || si >= st.sentences.length) { stopPlaying(st); return; }
      say(st, si, () => {
        // Shadowing: a pause as long as the sentence took, for the learner to say it after the voice.
        const wait = shadow ? Math.min(12000, 600 + sentenceText(st, si).length * (UNSPACED.test(st.text) ? 260 : 75)) : 150;
        st.timer = setTimeout(() => step(si + 1), wait);
      });
    };
    step(0);
  });
  R.registerAction('rd-done', (el, e, ctx) => {
    const c = el.closest('.lw-reading'), st = c && readers.get(c.getAttribute('data-key')); if (!st) return;
    ctx.post({ type: 'langwork', op: 'read', key: st.key, lang: st.lang, title: st.title, words: countWords(st.text), chars: st.text.length, unit: UNSPACED.test(st.text) ? 'characters' : 'words' });
    el.disabled = true; el.textContent = '✓ Logged';
  });

  // Click a word: its reading, meaning and dictionary entry, with Save (the sentence goes with it).
  document.addEventListener('click', e => {
    const w = e.target.closest && e.target.closest('.rd-w');
    const card = e.target.closest && e.target.closest('.lw-reading');
    if (!card) return;
    const pop = card.querySelector('.rd-pop');
    if (!w) { if (pop && !e.target.closest('.rd-pop')) pop.hidden = true; return; }
    const st = readers.get(card.getAttribute('data-key')); if (!st) return;
    const s = +w.getAttribute('data-s'), en = +w.getAttribute('data-e');
    const tok = (st.tokens || st.words).find(t => t.s === s) || { s, e: en };
    const word = st.text.slice(s, en);
    const si = st.sentences.findIndex(([a, b]) => s >= a && s < b);
    const key = nextKey('lk');
    st.lookup = { key, word, tok, si, el: w };
    card.querySelectorAll('.rd-w.sel').forEach(x => x.classList.remove('sel')); w.classList.add('sel');
    pop.innerHTML = popHTML(st, null);
    pop.hidden = false;
    const cr = card.getBoundingClientRect(), wr = w.getBoundingClientRect();
    pop.style.left = Math.max(8, Math.min(cr.width - 330, wr.left - cr.left)) + 'px';
    pop.style.top = (wr.bottom - cr.top + 6) + 'px';
    post({ type: 'langwork', op: 'lookup', key, word, lemma: tok.l || null, lang: st.lang, sentence: sentenceText(st, si) });
  });
  function popHTML(st, r) {
    const lk = st.lookup; if (!lk) return '';
    const t = lk.tok || {};
    const reading = (r && r.reading) || t.r || '';
    let h = '<div class="rd-pop-head"><span class="rd-pop-word"' + langAttr(st.lang) + '>' + esc(lk.word) + '</span>' + (reading ? '<span class="rd-pop-reading">' + esc(reading) + '</span>' : '') +
      play(lk.word, st.lang) + '<button class="rd-pop-x" data-act="rd-close" aria-label="Close">✕</button></div>';
    const lemma = (r && r.lemma) || t.l;
    if (lemma && lemma !== lk.word) h += '<div class="rd-pop-lemma">dictionary form: <b' + langAttr(st.lang) + '>' + esc(lemma) + '</b></div>';
    if (!r) h += '<div class="rd-pop-senses muted">Looking it up…</div>';
    else {
      if (r.senses && r.senses.length) h += '<ol class="rd-pop-senses">' + r.senses.slice(0, 5).map(x => '<li>' + (x.pos ? '<span class="rd-pos">' + esc(x.pos) + '</span> ' : '') + esc(x.text) + '</li>').join('') + '</ol>';
      else h += '<div class="rd-pop-senses muted">' + esc(r.note || 'No dictionary entry found. Ask your teacher about it.') + '</div>';
      if (r.source) h += '<div class="rd-pop-src">' + esc(r.source) + '</div>';
    }
    const saved = r && r.saved;
    h += '<div class="rd-pop-actions"><button class="btn mini primary" data-act="rd-save"' + (saved ? ' disabled' : '') + '>' + (saved ? '✓ In your words (' + esc(saved) + ')' : '＋ Save with this sentence') + '</button>' +
      '<button class="btn mini" data-act="rd-translate">Translate sentence</button><button class="btn mini" data-act="rd-ask">Ask teacher</button></div><div class="rd-pop-tr"></div>';
    return h;
  }
  // Any other audio (a 🔊 elsewhere) ends a passage being read aloud: the app stops the voice, so its "spoken" never comes.
  document.addEventListener('click', e => {
    const b = e.target.closest && e.target.closest('[data-act="ll-play"]');
    if (!b) return;
    for (const st of readers.values()) if (st.playing || st.waiting) { stopPlaying(st); st.waiting = null; }
  }, true);
  R.registerAction('rd-close', el => { const p = el.closest('.rd-pop'); if (p) p.hidden = true; });
  R.registerAction('rd-save', (el, e, ctx) => {
    const c = el.closest('.lw-reading'), st = c && readers.get(c.getAttribute('data-key')); if (!st || !st.lookup) return;
    const lk = st.lookup, r = lk.result || {};
    const meaning = (r.senses && r.senses[0] && r.senses[0].text) || '';
    ctx.post({ type: 'vocab', op: 'add', word: { term: r.lemma || lk.tok.l || lk.word, lang: st.lang, reading: r.reading || lk.tok.r || '', meaning: meaning.slice(0, 160) || '(look up)',
      example: sentenceText(st, lk.si), example_meaning: lk.translation || '', pos: r.senses && r.senses[0] && r.senses[0].pos || '', tags: ['reading'], notes: st.title ? 'From “' + st.title + '”' : '' } });
    el.disabled = true; el.textContent = '✓ Saved';
    if (lk.el) lk.el.classList.add('saved');
  });
  R.registerAction('rd-translate', (el, e, ctx) => {
    const c = el.closest('.lw-reading'), st = c && readers.get(c.getAttribute('data-key')); if (!st || !st.lookup) return;
    el.disabled = true; el.textContent = 'Translating…';
    ctx.post({ type: 'langwork', op: 'translate', key: st.lookup.key, text: sentenceText(st, st.lookup.si), lang: st.lang });
  });
  R.registerAction('rd-ask', (el, e, ctx) => {
    const c = el.closest('.lw-reading'), st = c && readers.get(c.getAttribute('data-key')); if (!st || !st.lookup) return;
    ctx.post({ type: 'suggest', text: 'In “' + sentenceText(st, st.lookup.si) + '”, what does “' + st.lookup.word + '” mean here, and how does the sentence work?' });
  });

  /** From the app (T.lang): a lookup, a passage's analysis, a translation, the end of a spoken sentence. */
  R.langEvent = function (kind, key, data) {
    if (kind === 'analysis') {
      const st = readers.get(key); if (!st || !data) return;
      if (Array.isArray(data.tokens) && data.tokens.length) st.tokens = data.tokens;
      if (Array.isArray(data.sentences) && data.sentences.length) st.sentences = data.sentences;
      refreshReading(key); return;
    }
    if (kind === 'spoken') {
      for (const st of readers.values()) if (st.waiting === key) { st.waiting = null; const then = st.then; st.then = null; if (then) then(); else highlight(st, -1); }
      return;
    }
    for (const st of readers.values()) {
      if (!st.lookup || st.lookup.key !== key) continue;
      const pop = document.querySelector('.lw-reading[data-key="' + st.key + '"] .rd-pop'); if (!pop) continue;
      if (kind === 'lookup') { st.lookup.result = data || {}; pop.innerHTML = popHTML(st, data || {}); }
      if (kind === 'translation') {
        st.lookup.translation = data && data.text || '';
        const box = pop.querySelector('.rd-pop-tr'), b = pop.querySelector('[data-act="rd-translate"]');
        if (box) box.innerHTML = data && data.text ? '<div class="rd-tr-text">' + esc(data.text) + '</div><div class="rd-pop-src">' + esc(data.source || '') + '</div>' : '<div class="muted">' + esc((data && data.note) || 'No on-device translation for this language.') + '</div>';
        if (b) { b.disabled = false; b.textContent = 'Translate sentence'; }
      }
    }
  };

  R.injectStyles('langwork', `
    .lw-diff { line-height: 1.9; font-size: 1.08em; }
    .lw-diff del, .lw-errors del, .lw-legend del { color: var(--bad); text-decoration: line-through; text-decoration-thickness: 1.5px; background: var(--bad-soft); border-radius: 3px; padding: 0 2px; }
    .lw-diff ins, .lw-errors ins, .lw-legend ins { color: var(--good); text-decoration: none; background: var(--good-soft); border-radius: 3px; padding: 0 2px; font-weight: 600; }
    .lw-diff .d-wrong del { margin-right: 1px; }
    .lw-check { border: 1px solid var(--border); border-radius: 10px; padding: 8px 12px; background: var(--card); }
    .lw-check-foot { display: flex; gap: 12px; align-items: center; margin-top: 4px; font-size: .85em; flex-wrap: wrap; }
    .lw-legend { color: var(--muted); }
    .lw-score { color: var(--muted); font-weight: 600; } .lw-score.ok { color: var(--warn); } .lw-score.good { color: var(--good); }
    .lw-label { font-size: .78em; color: var(--muted); text-transform: uppercase; letter-spacing: .04em; margin-bottom: 3px; }
    .lw-source { border-left: 3px solid var(--accent); padding: 4px 10px; margin: 4px 0 8px; background: var(--card); border-radius: 0 8px 8px 0; display: flex; flex-wrap: wrap; align-items: center; gap: 6px; }
    .lw-source .lw-label { width: 100%; }
    .lw-src-text { font-size: 1.1em; }
    .lw-instruction { margin: 0 0 6px; font-weight: 500; }
    .lw-rubric-ask { font-size: .85em; margin-bottom: 6px; }
    .lw-words-given { display: flex; gap: 6px; flex-wrap: wrap; margin: 4px 0; }
    .lw-chip { border: 1px solid var(--border); border-radius: 999px; padding: 2px 10px; font-size: 1.05em; background: var(--card); }
    .lw-chip.used { border-color: var(--good); background: var(--good-soft); }
    textarea.lw-answer { width: 100%; }
    .lw-table { border-collapse: collapse; margin: 4px 0; }
    .lw-table th, .lw-table td { border: 1px solid var(--border); padding: 4px 8px; text-align: left; }
    .lw-table thead th { background: var(--card); font-size: .85em; color: var(--muted); }
    .lw-table td.lw-shown { color: var(--muted); }
    .lw-table input.lw-cell { width: 9em; border: 0; background: transparent; font: inherit; }
    .lw-table input.lw-cell.ok { color: var(--good); } .lw-table input.lw-cell.bad { color: var(--bad); text-decoration: line-through; }
    .lw-correction { border: 1px solid var(--border); border-radius: 12px; padding: 10px 14px; }
    .lw-head { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; font-weight: 600; margin-bottom: 8px; }
    .lw-total { background: var(--accent-soft); color: var(--accent); border-radius: 999px; padding: 1px 10px; font-size: .9em; }
    .lw-perfect { color: var(--good); font-weight: 500; font-size: .9em; }
    .lw-views { margin-left: auto; display: inline-flex; border: 1px solid var(--border); border-radius: 7px; overflow: hidden; font-weight: 400; }
    .lw-views button { border: 0; background: var(--bg); color: var(--muted); padding: 2px 9px; font: inherit; font-size: .85em; cursor: pointer; }
    .lw-views button + button { border-left: 1px solid var(--border); }
    .lw-views button.on { background: var(--accent); color: #fff; }
    .lw-text { padding: 6px 0 8px; font-size: 1.05em; }
    .lw-errors { margin: 4px 0 8px; padding-left: 1.4em; }
    .lw-errors li { margin: 4px 0; border-left: 3px solid var(--err); padding-left: 8px; list-style-position: outside; }
    .lw-type { font-size: .72em; text-transform: uppercase; letter-spacing: .04em; color: var(--err); border: 1px solid var(--err); border-radius: 999px; padding: 0 6px; margin-right: 6px; }
    .lw-pair { margin-right: 8px; }
    .lw-why { color: var(--muted); }
    .lw-rubric { display: grid; gap: 4px; margin: 6px 0 8px; }
    .lw-r { display: grid; grid-template-columns: minmax(110px, auto) 1fr auto; gap: 8px; align-items: center; font-size: .9em; }
    .lw-r-note { grid-column: 1 / -1; color: var(--muted); font-size: .92em; }
    .lw-bar { height: 6px; background: var(--card-2); border-radius: 3px; overflow: hidden; } .lw-bar span { display: block; height: 100%; background: var(--accent); }
    .lw-better { background: var(--good-soft); border-radius: 8px; padding: 6px 10px; margin: 6px 0; display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
    .lw-better .lw-label { width: 100%; margin: 0; }
    .lw-again { border-top: 1px dashed var(--border); margin-top: 8px; padding-top: 8px; }
    .lw-again textarea { width: 100%; }
    .lw-again-result { margin-top: 6px; }
    .lw-note { color: var(--muted); font-size: .92em; }
    .lw-reading { border: 1px solid var(--border); border-radius: 12px; padding: 10px 16px; position: relative; }
    .rd-head { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; margin-bottom: 8px; }
    .rd-title { font-weight: 600; }
    .rd-level { font-size: .78em; border: 1px solid var(--border); border-radius: 999px; padding: 0 8px; color: var(--muted); }
    .rd-meta { font-size: .82em; color: var(--muted); }
    .rd-modes { margin-left: 0; }
    .rd-body { font-size: 1.25em; line-height: 2.1; }
    .rd-body ruby rt { font-size: .5em; color: var(--accent); }
    .rd-w { cursor: pointer; border-radius: 4px; }
    .rd-w:hover { background: var(--accent-soft); }
    .rd-w.sel { background: var(--accent-soft); outline: 1px solid var(--accent); }
    .rd-w.saved { border-bottom: 2px dotted var(--good); }
    .rd-s.speaking { background: color-mix(in srgb, var(--warn-soft) 70%, transparent); border-radius: 4px; }
    .rd-play { border: 0; background: transparent; color: var(--faint); cursor: pointer; font-size: .7em; padding: 0 3px; opacity: 0; vertical-align: middle; }
    .rd-s:hover .rd-play, .rd-s.speaking .rd-play { opacity: 1; }
    .rd-pop { position: absolute; z-index: 20; width: 320px; background: var(--bg); border: 1px solid var(--border); border-radius: 12px; box-shadow: 0 8px 28px rgba(0,0,0,.18); padding: 10px 12px; font-size: .92em; }
    .rd-pop-head { display: flex; align-items: baseline; gap: 8px; }
    .rd-pop-word { font-size: 1.5em; }
    .rd-pop-reading { color: var(--accent); }
    .rd-pop-x { margin-left: auto; border: 0; background: transparent; color: var(--muted); cursor: pointer; }
    .rd-pop-lemma { color: var(--muted); font-size: .9em; }
    .rd-pop-senses { margin: 6px 0; padding-left: 1.3em; }
    .rd-pos { font-size: .75em; color: var(--muted); font-style: italic; }
    .rd-pop-src { font-size: .75em; color: var(--faint); }
    .rd-pop-actions { display: flex; gap: 6px; flex-wrap: wrap; margin-top: 6px; }
    .rd-pop-tr { margin-top: 6px; }
    .rd-tr-text { background: var(--card); border-radius: 6px; padding: 4px 8px; }
    .rd-tr summary { cursor: pointer; color: var(--muted); font-size: .9em; }
    .rd-foot { display: flex; align-items: center; gap: 10px; justify-content: space-between; margin-top: 8px; font-size: .85em; flex-wrap: wrap; }
  `);
  window.TeacherLangWork = { align, tokens, diffHTML, segments, readers, countWords };
})();
