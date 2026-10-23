// The on-screen keyboard for the language the learner is learning: shows under the transcript whenever a text field of a
// quiz, form or problem card takes focus and the lesson's target language has a layout (keyboard-layouts.js), and types
// into that field. Composition runs here, not in the OS: Hangul jamo combine into syllables, kana take ゛゜ and small
// forms, romaji turn into kana as they are typed, a tone key cycles pinyin tone marks, and combining marks (Vietnamese
// tones, niqqud, harakat) fold into the letter before the caret. The app tells the page the target language
// (T.setLanguage); the learner can pick any layout from the panel's menu.
(function () {
  'use strict';
  const R = window.TeacherUI;
  const LAYOUTS = window.TeacherKeyboardLayouts || {};
  const K = { lang: null, native: null, layout: null, code: null, shift: false, kata: false, mode: null, auto: true, open: false, target: null, pinned: false };

  // ── Hangul: jamo → syllables ───────────────────────────────────────────
  const CHO = 'ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ';
  const JUNG = 'ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ';
  const JONG = '\0ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ';
  const VOWEL_PAIRS = { 'ㅗㅏ': 'ㅘ', 'ㅗㅐ': 'ㅙ', 'ㅗㅣ': 'ㅚ', 'ㅜㅓ': 'ㅝ', 'ㅜㅔ': 'ㅞ', 'ㅜㅣ': 'ㅟ', 'ㅡㅣ': 'ㅢ' };
  const FINAL_PAIRS = { 'ㄱㅅ': 'ㄳ', 'ㄴㅈ': 'ㄵ', 'ㄴㅎ': 'ㄶ', 'ㄹㄱ': 'ㄺ', 'ㄹㅁ': 'ㄻ', 'ㄹㅂ': 'ㄼ', 'ㄹㅅ': 'ㄽ', 'ㄹㅌ': 'ㄾ', 'ㄹㅍ': 'ㄿ', 'ㄹㅎ': 'ㅀ', 'ㅂㅅ': 'ㅄ' };
  const SPLIT = {};
  Object.keys(FINAL_PAIRS).forEach(k => { SPLIT[FINAL_PAIRS[k]] = [k[0], k[1]]; });
  Object.keys(VOWEL_PAIRS).forEach(k => { SPLIT[VOWEL_PAIRS[k]] = [k[0], k[1]]; });
  const isVowel = c => JUNG.includes(c);
  const isJamo = c => c.length === 1 && (CHO.includes(c) || JUNG.includes(c) || JONG.includes(c));
  const syl = (cho, jung, jong) => String.fromCharCode(0xAC00 + (cho * 21 + jung) * 28 + jong);
  function decompose(ch) {
    const c = ch.charCodeAt(0) - 0xAC00;
    if (c < 0 || c >= 11172) return null;
    return { cho: Math.floor(c / 588), jung: Math.floor((c % 588) / 28), jong: c % 28 };
  }
  /** Returns what the text before the caret becomes when `j` is typed: [charactersToRemove, replacementText]. */
  function hangul(prev, j) {
    const s = prev ? decompose(prev) : null;
    if (isVowel(j)) {
      if (s && s.jong === 0) {
        const pair = VOWEL_PAIRS[JUNG[s.jung] + j];
        if (pair) return [1, syl(s.cho, JUNG.indexOf(pair), 0)];
        return [0, j];
      }
      if (s && s.jong > 0) {   // the final consonant moves on to start the new syllable
        const f = JONG[s.jong], parts = SPLIT[f];
        if (parts) return [1, syl(s.cho, s.jung, JONG.indexOf(parts[0])) + syl(CHO.indexOf(parts[1]), JUNG.indexOf(j), 0)];
        if (CHO.includes(f)) return [1, syl(s.cho, s.jung, 0) + syl(CHO.indexOf(f), JUNG.indexOf(j), 0)];
        return [0, j];
      }
      if (prev && CHO.includes(prev)) return [1, syl(CHO.indexOf(prev), JUNG.indexOf(j), 0)];
      if (prev && isVowel(prev) && VOWEL_PAIRS[prev + j]) return [1, VOWEL_PAIRS[prev + j]];
      return [0, j];
    }
    if (s && s.jong === 0 && JONG.includes(j)) return [1, syl(s.cho, s.jung, JONG.indexOf(j))];
    if (s && s.jong > 0) {
      const pair = FINAL_PAIRS[JONG[s.jong] + j];
      if (pair) return [1, syl(s.cho, s.jung, JONG.indexOf(pair))];
    }
    return [0, j];
  }
  /** Backspace that removes one jamo, as Korean keyboards do. */
  function hangulBackspace(prev) {
    const s = decompose(prev || '');
    if (!s) return prev && SPLIT[prev] ? [1, SPLIT[prev][0]] : [1, ''];
    if (s.jong > 0) { const parts = SPLIT[JONG[s.jong]]; return [1, syl(s.cho, s.jung, parts ? JONG.indexOf(parts[0]) : 0)]; }
    const vp = SPLIT[JUNG[s.jung]];
    if (vp) return [1, syl(s.cho, JUNG.indexOf(vp[0]), 0)];
    return [1, CHO[s.cho]];
  }

  // ── Kana: voicing marks, small forms, romaji ───────────────────────────
  const SMALL = { 'あ': 'ぁ', 'い': 'ぃ', 'う': 'ぅ', 'え': 'ぇ', 'お': 'ぉ', 'つ': 'っ', 'や': 'ゃ', 'ゆ': 'ゅ', 'よ': 'ょ', 'わ': 'ゎ', 'か': 'ゕ', 'け': 'ゖ',
    'ア': 'ァ', 'イ': 'ィ', 'ウ': 'ゥ', 'エ': 'ェ', 'オ': 'ォ', 'ツ': 'ッ', 'ヤ': 'ャ', 'ユ': 'ュ', 'ヨ': 'ョ', 'ワ': 'ヮ', 'カ': 'ヵ', 'ケ': 'ヶ' };
  const BIG = {}; Object.keys(SMALL).forEach(k => { BIG[SMALL[k]] = k; });
  const toKatakana = s => s.replace(/[ぁ-ゖ]/g, c => String.fromCharCode(c.charCodeAt(0) + 0x60));
  const toHiragana = s => s.replace(/[ァ-ヶ]/g, c => String.fromCharCode(c.charCodeAt(0) - 0x60));
  /** Toggles ゛ (mark U+3099) or ゜ (U+309A) on a kana: か → が → か. */
  function voicing(prev, mark) {
    if (!prev) return [0, ''];
    const d = prev.normalize('NFD');
    const base = d.replace(/[゙゚]/g, '');
    if (d.includes(mark)) return [1, base];
    const v = (base + mark).normalize('NFC');
    return v.length === 1 ? [1, v] : [0, ''];
  }
  const ROMAJI = {
    a: 'あ', i: 'い', u: 'う', e: 'え', o: 'お', ka: 'か', ki: 'き', ku: 'く', ke: 'け', ko: 'こ', sa: 'さ', shi: 'し', si: 'し', su: 'す', se: 'せ', so: 'そ',
    ta: 'た', chi: 'ち', ti: 'ち', tsu: 'つ', tu: 'つ', te: 'て', to: 'と', na: 'な', ni: 'に', nu: 'ぬ', ne: 'ね', no: 'の', ha: 'は', hi: 'ひ', fu: 'ふ', hu: 'ふ', he: 'へ', ho: 'ほ',
    ma: 'ま', mi: 'み', mu: 'む', me: 'め', mo: 'も', ya: 'や', yu: 'ゆ', yo: 'よ', ra: 'ら', ri: 'り', ru: 'る', re: 'れ', ro: 'ろ', wa: 'わ', wo: 'を', nn: 'ん',
    ga: 'が', gi: 'ぎ', gu: 'ぐ', ge: 'げ', go: 'ご', za: 'ざ', ji: 'じ', zi: 'じ', zu: 'ず', ze: 'ぜ', zo: 'ぞ', da: 'だ', di: 'ぢ', du: 'づ', de: 'で', do: 'ど',
    ba: 'ば', bi: 'び', bu: 'ぶ', be: 'べ', bo: 'ぼ', pa: 'ぱ', pi: 'ぴ', pu: 'ぷ', pe: 'ぺ', po: 'ぽ',
    kya: 'きゃ', kyu: 'きゅ', kyo: 'きょ', sha: 'しゃ', shu: 'しゅ', sho: 'しょ', sya: 'しゃ', syu: 'しゅ', syo: 'しょ', cha: 'ちゃ', chu: 'ちゅ', cho: 'ちょ', tya: 'ちゃ', tyu: 'ちゅ', tyo: 'ちょ',
    nya: 'にゃ', nyu: 'にゅ', nyo: 'にょ', hya: 'ひゃ', hyu: 'ひゅ', hyo: 'ひょ', mya: 'みゃ', myu: 'みゅ', myo: 'みょ', rya: 'りゃ', ryu: 'りゅ', ryo: 'りょ',
    gya: 'ぎゃ', gyu: 'ぎゅ', gyo: 'ぎょ', ja: 'じゃ', ju: 'じゅ', jo: 'じょ', jya: 'じゃ', jyu: 'じゅ', jyo: 'じょ', zya: 'じゃ', zyu: 'じゅ', zyo: 'じょ', bya: 'びゃ', byu: 'びゅ', byo: 'びょ', pya: 'ぴゃ', pyu: 'ぴゅ', pyo: 'ぴょ',
    dya: 'ぢゃ', dyu: 'ぢゅ', dyo: 'ぢょ', fa: 'ふぁ', fi: 'ふぃ', fe: 'ふぇ', fo: 'ふぉ', va: 'ゔぁ', vi: 'ゔぃ', vu: 'ゔ', ve: 'ゔぇ', vo: 'ゔぉ',
    she: 'しぇ', che: 'ちぇ', je: 'じぇ', tsa: 'つぁ', tsi: 'つぃ', tse: 'つぇ', tso: 'つぉ', thi: 'てぃ', dhi: 'でぃ', twu: 'とぅ', dwu: 'どぅ', wi: 'うぃ', we: 'うぇ',
    xa: 'ぁ', xi: 'ぃ', xu: 'ぅ', xe: 'ぇ', xo: 'ぉ', la: 'ぁ', li: 'ぃ', lu: 'ぅ', le: 'ぇ', lo: 'ぉ', xtu: 'っ', ltu: 'っ', xtsu: 'っ', ltsu: 'っ',
    xya: 'ゃ', xyu: 'ゅ', xyo: 'ょ', lya: 'ゃ', lyu: 'ゅ', lyo: 'ょ', xwa: 'ゎ', '-': 'ー', ',': '、', '.': '。', '?': '？', '!': '！',
  };
  const ROMAJI_PREFIXES = new Set();
  Object.keys(ROMAJI).forEach(k => { for (let i = 1; i < k.length; i++) ROMAJI_PREFIXES.add(k.slice(0, i)); });
  /** Converts a run of Latin letters to kana; what cannot be decided yet (a lone "k", "n" before nothing) stays Latin at the end. */
  function romajiToKana(run, katakana) {
    let out = '', i = 0;
    const s = run.toLowerCase();
    while (i < s.length) {
      const c = s[i];
      if (c === 'n' && s[i + 1] === 'n') { out += 'ん'; i += (s[i + 2] && /[aiueoy]/.test(s[i + 2])) ? 1 : 2; continue; }   // konnichiha → こんにちは
      if (c === 'n' && s[i + 1] === '\'') { out += 'ん'; i += 2; continue; }
      if (c === 'n' && i + 1 < s.length && !/[aiueoyn']/.test(s[i + 1])) { out += 'ん'; i += 1; continue; }
      if (/[bcdfghjklmpqrstvwxz]/.test(c) && s[i + 1] === c && s[i + 2] && /[aiueoy]/.test(s[i + 2]) || (/[bcdfghjkmpqrstvwz]/.test(c) && s[i + 1] === c && (s[i + 2] === 'h' || s[i + 2] === 'y'))) {
        out += 'っ'; i += 1; continue;
      }
      let hit = null;
      for (const n of [4, 3, 2, 1]) { const k = s.slice(i, i + n); if (k.length === n && ROMAJI[k]) { hit = k; break; } }
      if (hit) { out += ROMAJI[hit]; i += hit.length; continue; }
      if (ROMAJI_PREFIXES.has(s.slice(i))) break;   // an unfinished syllable at the end
      out += run[i]; i += 1;
    }
    const kana = katakana ? toKatakana(out) : out;
    return { kana, rest: run.slice(i) };
  }

  // ── Pinyin tone marks ────────────────────────────────────────────────
  const TONES = { a: 'āáǎà', e: 'ēéěè', i: 'īíǐì', o: 'ōóǒò', u: 'ūúǔù', ü: 'ǖǘǚǜ', A: 'ĀÁǍÀ', E: 'ĒÉĚÈ', I: 'ĪÍǏÌ', O: 'ŌÓǑÒ', U: 'ŪÚǓÙ', Ü: 'ǕǗǙǛ' };
  const TONED = {}; Object.keys(TONES).forEach(v => { for (let t = 0; t < 4; t++) TONED[TONES[v][t]] = [v, t + 1]; });
  /** The syllable before the caret with its tone advanced (1 → 2 → 3 → 4 → none): "ma" → "mā", "mǎ" → "mà". */
  function cycleTone(text) {
    const m = /[A-Za-züÜāáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜĀÁǍÀĒÉĚÈĪÍǏÌŌÓǑÒŪÚǓÙǕǗǙǛ]+$/.exec(text);
    if (!m) return null;
    let tone = 0, plain = '';
    for (const ch of m[0]) { const t = TONED[ch]; if (t) { plain += t[0]; tone = t[1]; } else plain += ch; }
    const next = (tone + 1) % 5;
    let pos = -1;
    const low = plain.toLowerCase();
    if (low.includes('a')) pos = low.indexOf('a'); else if (low.includes('e')) pos = low.indexOf('e');
    else if (low.includes('ou')) pos = low.indexOf('o');
    else { for (let i = low.length - 1; i >= 0; i--) if ('iouü'.includes(low[i])) { pos = i; break; } }
    if (pos < 0) return null;
    const v = plain[pos];
    const marked = next === 0 ? v : TONES[v][next - 1];
    return { remove: m[0].length, text: plain.slice(0, pos) + marked + plain.slice(pos + 1) };
  }

  // ── Editing the focused field ─────────────────────────────────────────
  const FIELDS = 'input.q-text, input.blank, textarea.q-text, textarea[data-ask-text], input[data-q-other], textarea.pb-attempt, .edit-box textarea';
  const eligible = el => !!(el && el.matches && el.matches(FIELDS) && !el.hasAttribute('data-numeric') && !el.hasAttribute('data-math') && !el.classList.contains('mono'));
  function replaceBefore(el, remove, text) {
    const start = el.selectionStart, end = el.selectionEnd;
    const from = Math.max(0, start - remove);
    el.setRangeText(text, from, end, 'end');
    el.dispatchEvent(new Event('input', { bubbles: true }));
  }
  const before = (el, n) => el.value.slice(Math.max(0, el.selectionStart - n), el.selectionStart);
  function insert(el, text) {
    if (!el) return;
    const layout = K.layout || {};
    if (layout.compose === 'hangul' && isJamo(text)) { const [n, t] = hangul(before(el, 1), text); replaceBefore(el, n, t); return; }
    if (layout.compose === 'marks' && /^[̀-ͯ]$/.test(text)) {
      const p = before(el, 1); const v = (p + text).normalize('NFC');
      if (p && v.length === 1) { replaceBefore(el, 1, v); return; }
    }
    if (/^[֑-ׇً-ْٰ]$/.test(text)) { replaceBefore(el, 0, text); return; }   // niqqud, harakat: combining as they are
    if (K.shift && layout.upper && !layout.shift) text = text.toUpperCase();
    if (K.kata && layout.compose === 'kana') text = toKatakana(text);
    replaceBefore(el, 0, text);
    if (K.shift && !K.pinned) { K.shift = false; render(); }
  }
  function special(el, k) {
    if (!el && k !== 'shift' && k !== 'mode' && k !== 'kana') return;
    switch (k) {
      case 'bksp': {
        if (el.selectionStart !== el.selectionEnd) { replaceBefore(el, 0, ''); return; }
        const p = before(el, 1);
        if ((K.layout || {}).compose === 'hangul' && p) { const [n, t] = hangulBackspace(p); replaceBefore(el, n, t); return; }
        replaceBefore(el, 1, ''); return;
      }
      case 'space': replaceBefore(el, 0, ' '); return;
      case 'enter': replaceBefore(el, 0, '\n'); return;
      case 'shift': K.shift = !K.shift; render(); return;
      case 'dakuten': case 'handakuten': { const [n, t] = voicing(before(el, 1), k === 'dakuten' ? '゙' : '゚'); if (n) replaceBefore(el, n, t); return; }
      case 'small': { const p = before(el, 1); const t = SMALL[p] || BIG[p]; if (t) replaceBefore(el, 1, t); return; }
      case 'kana': K.kata = !K.kata; render(); return;
      case 'tone': { const r = cycleTone(before(el, 12)); if (r) replaceBefore(el, r.remove, r.text); return; }
      case 'mode': { const modes = (K.layout || {}).modes || []; if (modes.length) { K.mode = modes[(modes.indexOf(K.mode) + 1) % modes.length]; render(); } return; }
    }
  }
  // Romaji mode: Latin letters typed on the physical keyboard become kana as soon as a syllable is complete.
  document.addEventListener('input', e => {
    const el = e.target;
    if (!K.open || K.mode !== 'romaji' || el !== K.target || !eligible(el) || e.inputType !== 'insertText') return;
    const m = /[A-Za-z'\-,.?!]+$/.exec(el.value.slice(0, el.selectionStart));
    if (!m) return;
    const { kana, rest } = romajiToKana(m[0], K.kata);
    if (kana === '' && rest === m[0]) return;
    replaceBefore(el, m[0].length, kana + rest);
  }, true);

  // ── The panel ─────────────────────────────────────────────────────────
  let panel = null;
  function ensurePanel() {
    if (panel) return panel;
    panel = document.createElement('div');
    panel.id = 'kbd';
    panel.hidden = true;
    panel.setAttribute('role', 'group');
    panel.setAttribute('aria-label', 'On-screen keyboard');
    // Keys must not steal focus from the field they type into.
    panel.addEventListener('mousedown', e => { if (!e.target.closest('select')) e.preventDefault(); });
    panel.addEventListener('click', e => {
      const b = e.target.closest('button'); if (!b) return;
      const el = K.target && document.contains(K.target) ? K.target : null;
      if (b.hasAttribute('data-key')) insert(el, b.getAttribute('data-key'));
      else if (b.hasAttribute('data-fn')) {
        const fn = b.getAttribute('data-fn');
        if (fn === 'close') { K.open = false; K.auto = false; render(); return; }
        if (fn === 'pin') { K.pinned = !K.pinned; render(); return; }
        special(el, fn);
      }
    });
    panel.addEventListener('change', e => {
      const s = e.target.closest('select[data-layout]'); if (!s) return;
      setLayout(s.value); K.open = true; K.auto = true; render();
      if (K.target && document.contains(K.target)) K.target.focus();
    });
    document.body.appendChild(panel);
    return panel;
  }
  // A language whose entry has no rows (plain Latin alphabet) needs no panel.
  const usable = code => { const l = LAYOUTS[code]; return l && l.rows && l.rows.length ? l : null; };
  function setLayout(code) {
    const l = usable(code);
    K.code = l ? code : null; K.layout = l; K.shift = false; K.kata = false;
    K.mode = l && l.modes ? l.modes[0] : null;
  }
  const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const FN_LABEL = { shift: '⇧', bksp: '⌫', space: '␣', enter: '⏎', dakuten: '゛', handakuten: '゜', small: '小', kana: 'カナ', tone: 'ā→á', mode: 'ローマ字' };
  function render() {
    const p = ensurePanel();
    const l = K.layout;
    const show = K.open && !!l;
    p.hidden = !show;
    document.body.classList.toggle('kbd-open', show);
    if (!show) return;
    let rows = (K.shift && l.shift) ? l.shift : l.rows;
    if (K.mode === 'romaji') rows = [[{ k: 'kana' }, '、', '。', 'ー', '？', '！', '「', '」', { k: 'bksp' }, { k: 'mode' }]];
    const options = Object.keys(LAYOUTS).filter(usable).sort((a, b) => LAYOUTS[a].english.localeCompare(LAYOUTS[b].english))
      .map(c => '<option value="' + c + '"' + (c === K.code ? ' selected' : '') + '>' + esc(LAYOUTS[c].name) + ' · ' + esc(LAYOUTS[c].english) + '</option>').join('');
    let h = '<div class="kbd-head"><select data-layout aria-label="Keyboard language">' + options + '</select>' +
      (K.mode === 'romaji' ? '<span class="kbd-hint">Type romaji: <b>konnichiha</b> → こんにちは</span>' : l.compose === 'hangul' ? '<span class="kbd-hint">Jamo join into syllables as you type</span>' : l.compose === 'pinyin' ? '<span class="kbd-hint">Type the syllable, then ā→á for its tone</span>' : '') +
      '<span class="kbd-sp"></span><button data-fn="pin" class="kbd-fn' + (K.pinned ? ' on' : '') + '" title="Keep shift on">⇧ lock</button><button data-fn="close" class="kbd-fn" title="Hide (click a field\'s ⌨ to show it again)">✕</button></div>';
    h += '<div class="kbd-rows"' + (l.rtl ? ' dir="rtl"' : '') + '>';
    for (const row of rows) {
      h += '<div class="kbd-row">';
      for (const key of row) {
        if (typeof key === 'string') {
          let label = key;
          if (K.shift && l.upper && !l.shift) label = key.toUpperCase();
          if (K.kata && l.compose === 'kana') label = toKatakana(key);
          const combining = /^[̀-֑ͯ-ׇً-゙゚ْٰ]$/.test(key);
          h += '<button data-key="' + esc(key) + '" class="kbd-key' + (combining ? ' kbd-mark' : '') + '"' + (K.code ? ' lang="' + esc(K.code) + '"' : '') + '>' + (combining ? '◌' : '') + esc(label) + '</button>';
        } else {
          const on = (key.k === 'shift' && K.shift) || (key.k === 'kana' && K.kata);
          const label = key.k === 'mode' ? (K.mode === 'romaji' ? 'かな' : FN_LABEL.mode) : FN_LABEL[key.k] || key.k;
          h += '<button data-fn="' + esc(key.k) + '" class="kbd-key kbd-fn' + (key.k === 'space' ? ' kbd-space' : '') + (on ? ' on' : '') + '">' + esc(label) + '</button>';
        }
      }
      h += '</div>';
    }
    p.innerHTML = h + '</div>';
  }

  // A field that can take the target language shows the keyboard (unless the learner closed it) and gets a ⌨ toggle.
  document.addEventListener('focusin', e => {
    const el = e.target;
    if (!eligible(el)) return;
    K.target = el;
    if (K.layout && K.auto && !K.open) { K.open = true; render(); }
  });
  function addToggles(root) {
    if (!K.layout) return;
    const list = (root.matches && root.matches(FIELDS) ? [root] : []).concat(Array.from(root.querySelectorAll(FIELDS)));
    for (const el of list) {
      if (!eligible(el) || el._kbdToggle || !el.parentNode) continue;
      el._kbdToggle = true;
      el.setAttribute('lang', K.code);
      if (K.layout.rtl) el.setAttribute('dir', 'auto');
      const b = document.createElement('button');
      b.type = 'button'; b.className = 'kbd-toggle'; b.textContent = '⌨'; b.title = 'On-screen keyboard: ' + K.layout.english;
      b.setAttribute('aria-label', 'On-screen keyboard');
      b.addEventListener('mousedown', ev => ev.preventDefault());
      b.addEventListener('click', () => { K.target = el; K.open = !K.open; K.auto = K.open; render(); el.focus(); });
      el.insertAdjacentElement('afterend', b);
    }
  }
  R.registerProcessor(root => addToggles(root));

  /** From the app: the lesson's language state ({target, native, …}); the panel follows the target language's layout. */
  R.setLanguage = function (state) {
    const target = state && state.target ? String(state.target).slice(0, 2).toLowerCase() : null;
    K.lang = target; K.native = state && state.native || null;
    if (target !== K.code) { setLayout(target); K.auto = true; K.open = K.open && !!K.layout; }
    render();
    document.querySelectorAll(FIELDS).forEach(el => { if (el._kbdToggle) { el._kbdToggle = false; const t = el.nextElementSibling; if (t && t.classList.contains('kbd-toggle')) t.remove(); } });
    if (K.layout) addToggles(document.body);
  };

  R.injectStyles('keyboard', `
    #kbd { position: fixed; left: 0; right: 0; bottom: 0; z-index: 40; background: var(--card); border-top: 1px solid var(--border); box-shadow: 0 -4px 18px rgba(0,0,0,.08); padding: 6px 10px 10px; user-select: none; font-size: var(--font-size); }
    body.kbd-open #thread { padding-bottom: 300px; }
    .kbd-head { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; color: var(--muted); font-size: .85em; }
    .kbd-head select { font: inherit; max-width: 260px; }
    .kbd-sp { flex: 1; }
    .kbd-hint b { color: var(--fg); }
    .kbd-rows { display: flex; flex-direction: column; gap: 4px; max-width: 820px; margin: 0 auto; }
    .kbd-row { display: flex; justify-content: center; gap: 4px; flex-wrap: wrap; }
    .kbd-key { min-width: 38px; height: 38px; padding: 0 8px; border: 1px solid var(--border); border-radius: 8px; background: var(--bg); color: var(--fg); font-size: 1.1em; cursor: pointer; line-height: 1; }
    .kbd-key:hover { border-color: var(--accent); }
    .kbd-key:active { background: var(--accent-soft); }
    .kbd-key.kbd-fn { background: var(--card-2); font-size: .9em; color: var(--muted); }
    .kbd-key.kbd-fn.on, .kbd-head .kbd-fn.on { background: var(--accent); color: #fff; border-color: var(--accent); }
    .kbd-key.kbd-space { min-width: 180px; }
    .kbd-key.kbd-mark { color: var(--accent); }
    .kbd-head .kbd-fn { border: 1px solid var(--border); background: var(--bg); color: var(--muted); border-radius: 6px; padding: 2px 8px; cursor: pointer; }
    .kbd-toggle { border: 0; background: transparent; color: var(--faint); cursor: pointer; font-size: 1em; padding: 2px 4px; margin-left: 2px; vertical-align: middle; }
    .kbd-toggle:hover { color: var(--accent); }
    .quiz-q .kbd-toggle, .ask .kbd-toggle { float: right; margin-top: -30px; margin-right: 6px; position: relative; z-index: 1; }
  `);
  window.TeacherKeyboard = { state: K, layouts: LAYOUTS, hangul, hangulBackspace, romajiToKana, cycleTone, voicing, insert, special, setLayout, render, eligible };
})();
