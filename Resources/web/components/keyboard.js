// The on-screen keyboard for the language the learner is learning: shows under the transcript whenever a text field of a
// quiz, form or problem card takes focus and the lesson's target language has a layout (keyboard-layouts.js), and types
// into that field. Composition runs here, not in the OS: Hangul jamo combine into syllables, kana take ゛゜ and small
// forms, romaji turn into kana as they are typed, a tone key cycles pinyin tone marks, and combining marks (Vietnamese
// tones, niqqud, harakat) fold into the letter before the caret, tone keys or digits mark pinyin (ni3 → nǐ), and a vowel
// letter after a Devanagari or Bengali consonant becomes its vowel sign. Modes: tapping, romaji (Japanese), and "Mac keys"
// (the physical keys type the script in its standard layout, lighting the key up). Kana before the caret that spell a word
// the learner saved offer its kanji. The Mac's own input source for the language is offered when it is installed. The
// app tells the page the target language (T.setLanguage); the learner can pick any layout from the panel's menu.
(function () {
  'use strict';
  const R = window.TeacherUI;
  const LAYOUTS = window.TeacherKeyboardLayouts || {};
  const K = { lang: null, native: null, layout: null, code: null, shift: false, kata: false, mode: null, auto: true, open: false, target: null, pinned: false,
    compact: false, words: [], source: null, cands: [] };

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
  // Pinyin syllables: an initial and a final. The syllable before the caret is the longest such ending of the letters
  // there ("nǐhao" ends in "hao", not "nǐhao"), so a tone lands on its own syllable.
  const INITIALS = ['zh', 'ch', 'sh', 'b', 'p', 'm', 'f', 'd', 't', 'n', 'l', 'g', 'k', 'h', 'j', 'q', 'x', 'r', 'z', 'c', 's', 'y', 'w', ''];
  const FINALS = new Set(('a o e i u ü v ai ei ao ou an en ang eng ong er ia ie iao iu ian in iang ing iong ua uo uai ui uan un uang ueng ' +
    'üe ve ue üan van ün vn').split(' '));
  const isSyllable = s => INITIALS.some(i => s.startsWith(i) && FINALS.has(s.slice(i.length)));
  function lastSyllable(text) {
    const m = /[A-Za-züÜāáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜĀÁǍÀĒÉĚÈĪÍǏÌŌÓǑÒŪÚǓÙǕǗǙǛ]+$/.exec(text);
    if (!m) return null;
    const chars = Array.from(m[0]);
    const plain = chars.map(ch => (TONED[ch] ? TONED[ch][0] : ch).toLowerCase()).join('');
    for (let n = Math.min(6, chars.length); n >= 1; n--) if (isSyllable(plain.slice(-n))) return chars.slice(-n).join('');
    return m[0];
  }
  /** The syllable before the caret with its tone advanced (1 → 2 → 3 → 4 → none): "ma" → "mā", "mǎ" → "mà". */
  function cycleTone(text) {
    const s = lastSyllable(text);
    if (!s) return null;
    const m = [s];
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

  /** The syllable before the caret with tone `n` (1–4; 0 or 5 = neutral, no mark): "ni" + 3 → "nǐ", "hǎo" + 4 → "hào". */
  function setTone(text, n) {
    const s = lastSyllable(text);
    if (!s) return null;
    const m = [s];
    let plain = '';
    for (const ch of m[0]) { const t = TONED[ch]; plain += t ? t[0] : ch; }
    const low = plain.toLowerCase();
    let pos = -1;
    if (low.includes('a')) pos = low.indexOf('a'); else if (low.includes('e')) pos = low.indexOf('e');
    else if (low.includes('ou')) pos = low.indexOf('o');
    else { for (let i = low.length - 1; i >= 0; i--) if ('iouü'.includes(low[i])) { pos = i; break; } }
    if (pos < 0) return null;
    const v = plain[pos], k = n % 5;
    return { remove: m[0].length, text: plain.slice(0, pos) + (k ? TONES[v][k - 1] : v) + plain.slice(pos + 1) };
  }

  // ── Abugidas: a vowel letter typed after a consonant becomes its vowel sign (क + आ → का) ─────────
  const MATRA = {
    'आ': 'ा', 'इ': 'ि', 'ई': 'ी', 'उ': 'ु', 'ऊ': 'ू', 'ऋ': 'ृ', 'ए': 'े', 'ऐ': 'ै', 'ओ': 'ो', 'औ': 'ौ', 'ऍ': 'ॅ', 'ऑ': 'ॉ',
    'আ': 'া', 'ই': 'ি', 'ঈ': 'ী', 'উ': 'ু', 'ঊ': 'ূ', 'ঋ': 'ৃ', 'এ': 'ে', 'ঐ': 'ৈ', 'ও': 'ো', 'ঔ': 'ৌ',
  };
  const CONSONANT = /[क-हक़-य़ক-হড়-য়़়]$/;
  /** What typing `ch` after `prev` inserts in an abugida: a vowel sign after a consonant, अ there adds nothing (the inherent vowel). */
  function abugida(prev, ch) {
    if (!prev || !CONSONANT.test(prev)) return null;
    if (ch === 'अ' || ch === 'অ') return '';
    return MATRA[ch] || null;
  }

  // ── Editing the focused field ─────────────────────────────────────────
  const FIELDS = 'input.q-text, input.blank, textarea.q-text, textarea[data-ask-text], input[data-q-other], textarea.pb-attempt, .edit-box textarea, [data-kbd]';
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
    if (layout.compose === 'abugida' && el.selectionStart === el.selectionEnd) {
      const m = abugida(before(el, 1), text);
      if (m != null) { if (m) replaceBefore(el, 0, m); return; }
    }
    if (/^[֑-ׇً-ْٰ]$/.test(text)) { replaceBefore(el, 0, text); return; }   // niqqud, harakat: combining as they are
    if (K.shift && layout.upper && !layout.shift) text = text.toUpperCase();
    if (K.kata && layout.compose === 'kana') text = toKatakana(text);
    replaceBefore(el, 0, text);
    if (K.shift && !K.pinned) { K.shift = false; render(); }
  }
  function special(el, k) {
    if (!el && !['shift', 'mode', 'kana'].includes(k)) return;
    const tone = /^tone([1-4])$/.exec(k);
    if (tone) { const r = setTone(before(el, 12), +tone[1]); if (r) replaceBefore(el, r.remove, r.text); return; }
    switch (k) {
      case 'bksp': {
        if (el.selectionStart !== el.selectionEnd) { replaceBefore(el, 0, ''); return; }
        const p = before(el, 1);
        if ((K.layout || {}).compose === 'hangul' && p) { const [n, t] = hangulBackspace(p); replaceBefore(el, n, t); return; }
        const last = Array.from(before(el, 2)).pop() || '';
        replaceBefore(el, last.length || 1, ''); return;
      }
      case 'space': replaceBefore(el, 0, ' '); return;
      case 'enter': replaceBefore(el, 0, '\n'); return;
      case 'shift': K.shift = !K.shift; render(); return;
      case 'dakuten': case 'handakuten': { const [n, t] = voicing(before(el, 1), k === 'dakuten' ? '゙' : '゚'); if (n) replaceBefore(el, n, t); return; }
      case 'small': { const p = before(el, 1); const t = SMALL[p] || BIG[p]; if (t) replaceBefore(el, 1, t); return; }
      case 'kana': K.kata = !K.kata; render(); return;
      case 'tone': { const r = cycleTone(before(el, 12)); if (r) replaceBefore(el, r.remove, r.text); return; }
      case 'mode': { const modes = modesOf(K.layout); if (modes.length > 1) { K.mode = modes[(modes.indexOf(K.mode) + 1) % modes.length]; render(); } return; }
    }
  }
  /** The input modes a layout offers: its own (kana/romaji), else tapping; "keys" when the Mac's keys can type it. */
  function modesOf(l) {
    if (!l) return [];
    const m = (l.modes && l.modes.length ? l.modes.slice() : ['tap']);
    if (l.physical && !m.includes('keys')) m.push('keys');
    return m;
  }
  const MODE_LABEL = { kana: 'かな', romaji: 'ローマ字', tap: 'Tap', keys: 'Mac keys' };
  const MODE_HELP = {
    romaji: 'Type romaji on your Mac keyboard: <b>konnichiha</b> → こんにちは',
    keys: 'Your Mac keys type this script in its standard layout; the key lights up here',
  };

  // Typed on the Mac's own keyboard: romaji → kana, pinyin digits → tone marks, and the kanji candidates below.
  document.addEventListener('input', e => {
    const el = e.target;
    if (!K.layout || el !== K.target || !eligible(el) || e.inputType !== 'insertText') return;
    if (K.open && K.mode === 'romaji') {
      const m = /[A-Za-z'\-,.?!]+$/.exec(el.value.slice(0, el.selectionStart));
      if (m) {
        const { kana, rest } = romajiToKana(m[0], K.kata);
        if (!(kana === '' && rest === m[0])) replaceBefore(el, m[0].length, kana + rest);
      }
    }
    if (K.auto && K.layout.compose === 'pinyin' && /^[0-5]$/.test(e.data || '')) {
      const head = el.value.slice(0, el.selectionStart);
      const r = /[A-Za-züÜĀ-ǜ]$/.test(head.slice(0, -1)) ? setTone(head.slice(0, -1), +e.data) : null;
      if (r) { el.setRangeText(r.text, el.selectionStart - 1 - r.remove, el.selectionStart, 'end'); el.dispatchEvent(new Event('input', { bubbles: true })); }
    }
    if (K.open) candidates(el);
  }, true);

  // "Mac keys": the physical key's position types the script's character (Arabic PC, ЙЦУКЕН, 2-set Korean…).
  const CODES = [
    ['KeyQ', 'KeyW', 'KeyE', 'KeyR', 'KeyT', 'KeyY', 'KeyU', 'KeyI', 'KeyO', 'KeyP', 'BracketLeft', 'BracketRight'],
    ['KeyA', 'KeyS', 'KeyD', 'KeyF', 'KeyG', 'KeyH', 'KeyJ', 'KeyK', 'KeyL', 'Semicolon', 'Quote'],
    ['KeyZ', 'KeyX', 'KeyC', 'KeyV', 'KeyB', 'KeyN', 'KeyM', 'Comma', 'Period', 'Slash'],
  ];
  /** The character the Mac key `code` types in "keys" mode (shifted or not), or null. */
  function physicalChar(l, code, shift) {
    if (!l || !l.physical) return null;
    for (let r = 0; r < CODES.length; r++) {
      const c = CODES[r].indexOf(code);
      if (c < 0) continue;
      const rows = shift && l.physical_shift ? l.physical_shift : l.physical;
      const row = rows[r] || [];
      const ch = row[c];
      return ch == null || ch === '' ? null : ch;
    }
    return null;
  }
  document.addEventListener('keydown', e => {
    const el = e.target;
    if (!K.layout || el !== K.target || !eligible(el) || e.metaKey || e.ctrlKey || e.altKey || e.isComposing) return;
    if (e.key === 'Backspace' && K.open && K.layout.compose === 'hangul' && el.selectionStart === el.selectionEnd && /[가-힣]$/.test(before(el, 1))) {
      e.preventDefault(); special(el, 'bksp'); return;
    }
    if (!K.open || K.mode !== 'keys') return;
    const ch = physicalChar(K.layout, e.code, e.shiftKey);
    if (!ch) return;
    e.preventDefault();
    insert(el, ch);
    flash(ch);
  }, true);
  function flash(ch) {
    if (!panel) return;
    const b = panel.querySelector('[data-key="' + CSS.escape(ch) + '"]');
    if (!b) return;
    b.classList.remove('hit'); void b.offsetWidth; b.classList.add('hit');
    setTimeout(() => b.classList.remove('hit'), 220);
  }

  // ── Kanji from the learner's own words: the kana before the caret that spell a word they've saved ──
  function candidates(el) {
    const bar = panel && panel.querySelector('.kbd-cands');
    if (!bar) return;
    const list = K.layout && K.layout.compose === 'kana' && el ? matchWords(before(el, 16)) : [];
    K.cands = list;
    bar.innerHTML = list.map((w, i) => '<button data-cand="' + i + '" lang="ja" title="' + esc(w.kana) + '">' + esc(w.term) + '</button>').join('');
    bar.hidden = !list.length;
  }
  /** Words whose reading ends the kana run before the caret, longest reading first (たべる → 食べる). */
  function matchWords(head) {
    const run = (/[ぁ-ゖァ-ヺー]+$/.exec(head) || [''])[0];
    if (!run) return [];
    const hira = toHiragana(run), seen = new Set(), out = [];
    for (const w of (K.words || []).slice().sort((a, b) => b.kana.length - a.kana.length)) {
      if (!w.kana || w.kana === w.term || seen.has(w.term)) continue;
      if (hira.endsWith(toHiragana(w.kana))) { seen.add(w.term); out.push(w); }
      if (out.length >= 6) break;
    }
    return out;
  }

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
      if (b.hasAttribute('data-key')) { insert(el, b.getAttribute('data-key')); if (el) candidates(el); }
      else if (b.hasAttribute('data-cand')) {
        const w = (K.cands || [])[+b.getAttribute('data-cand')];
        if (w && el) {
          const run = (/[ぁ-ゖァ-ヺー]+$/.exec(before(el, 16)) || [''])[0];
          replaceBefore(el, Math.min(run.length, w.kana.length), w.term); candidates(el);
        }
      } else if (b.hasAttribute('data-setmode')) { K.mode = b.getAttribute('data-setmode'); render(); }
      else if (b.hasAttribute('data-source')) {
        if (R._ctx) R._ctx.post({ type: 'inputSource', op: b.getAttribute('data-source'), lang: K.code });
      } else if (b.hasAttribute('data-fn')) {
        const fn = b.getAttribute('data-fn');
        if (fn === 'close') { K.open = false; K.auto = false; render(); return; }
        if (fn === 'pin') { K.pinned = !K.pinned; render(); return; }
        if (fn === 'compact') { K.compact = !K.compact; store('kbd.compact.' + K.code, K.compact ? '1' : ''); render(); return; }
        special(el, fn);
        if (el) candidates(el);
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
  // Per-viewer conveniences (compact or full, the intro seen): local storage, which may be unavailable.
  const load = k => { try { return localStorage.getItem(k); } catch (_) { return null; } };
  const store = (k, v) => { try { if (v) localStorage.setItem(k, v); else localStorage.removeItem(k); } catch (_) {} };
  // A language whose entry has no rows (plain Latin alphabet) needs no panel.
  const usable = code => { const l = LAYOUTS[code]; return l && l.rows && l.rows.length ? l : null; };
  function setLayout(code) {
    const l = usable(code);
    K.code = l ? code : null; K.layout = l; K.shift = false; K.kata = false;
    K.mode = l ? modesOf(l)[0] : null;
    K.compact = !!(l && load('kbd.compact.' + code));
  }
  const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const FN_LABEL = { shift: '⇧', bksp: '⌫', space: 'space', enter: '⏎', dakuten: '゛', handakuten: '゜', small: '小', kana: 'カナ', tone: 'ā→á', mode: 'ローマ字',
    tone1: 'ˉ 1', tone2: 'ˊ 2', tone3: 'ˇ 3', tone4: 'ˋ 4' };
  const FN_TITLE = { shift: 'Shift', bksp: 'Delete', space: 'Space', dakuten: 'Voiced mark (か → が)', handakuten: 'Semi-voiced mark (は → ぱ)', small: 'Small kana (つ → っ)',
    kana: 'Katakana', tone: 'Cycle the tone of the syllable before the caret', mode: 'Input mode', tone1: 'First tone (high level)', tone2: 'Second tone (rising)',
    tone3: 'Third tone (dipping)', tone4: 'Fourth tone (falling)' };
  const COMBINING = /^[̀-֑ͯ-ׇً-़゙゚ْٰु-्ँ-ःा-ीা-্ঁ-ঃัิ-ฺ็-๎]$/;
  function render() {
    const p = ensurePanel();
    const l = K.layout;
    const show = K.open && !!l;
    p.hidden = !show;
    document.body.classList.toggle('kbd-open', show);
    document.body.classList.toggle('kbd-compact', show && K.compact);
    if (!show) return;
    let rows = (K.shift && l.shift) ? l.shift : l.rows;
    if (K.mode === 'romaji') rows = [[{ k: 'kana' }, '、', '。', 'ー', '？', '！', '「', '」', { k: 'bksp' }, { k: 'mode' }]];
    else if (K.compact) {
      // Compact: only the helpers (marks, tone and function keys) — the letters come from the Mac's keys.
      const keep = rows.filter(r => r.some(k => typeof k !== 'string' || COMBINING.test(k)));
      rows = keep.length ? keep : rows.slice(-1);
    }
    const options = Object.keys(LAYOUTS).filter(usable).sort((a, b) => LAYOUTS[a].english.localeCompare(LAYOUTS[b].english))
      .map(c => '<option value="' + c + '"' + (c === K.code ? ' selected' : '') + '>' + esc(LAYOUTS[c].name) + ' · ' + esc(LAYOUTS[c].english) + '</option>').join('');
    const modes = modesOf(l);
    const hint = MODE_HELP[K.mode] || (l.compose === 'hangul' ? 'Jamo join into syllables as you type' : l.compose === 'pinyin' ? 'Type the syllable, then its tone (a key below, or the digit: ni3 → nǐ)'
      : l.compose === 'abugida' ? 'A vowel after a consonant becomes its sign: क + आ → का' : l.compose === 'marks' && l.rtl ? 'Harakat attach to the letter before them' : '');
    const src = K.source;
    let h = '<div class="kbd-head"><select data-layout aria-label="Keyboard language">' + options + '</select>' +
      (modes.length > 1 ? '<span class="kbd-modes" role="radiogroup" aria-label="Input mode">' + modes.map(m => '<button data-setmode="' + m + '" role="radio" aria-checked="' + (m === K.mode) + '" class="' + (m === K.mode ? 'on' : '') + '">' + esc(MODE_LABEL[m] || m) + '</button>').join('') + '</span>' : '') +
      (hint ? '<span class="kbd-hint">' + hint + '</span>' : '') + '<span class="kbd-sp"></span>' +
      (src ? (src.enabled ? (src.selected ? '<span class="kbd-src on" title="The Mac is typing with ' + esc(src.name) + '">✓ ' + esc(src.name) + '</span>'
        : '<button data-source="select" class="kbd-src" title="Switch the Mac to its own ' + esc(src.name) + ' input (kanji conversion, full layout)">Use Mac input: ' + esc(src.name) + '</button>')
        : '<button data-source="settings" class="kbd-src" title="Add the Mac\'s own input source for this language in System Settings">Add Mac input…</button>') : '') +
      (l.upper && !l.shift ? '<button data-fn="pin" class="kbd-fn' + (K.pinned ? ' on' : '') + '" title="Keep shift on">⇧ lock</button>' : '') +
      '<button data-fn="compact" class="kbd-fn" title="' + (K.compact ? 'Show every key' : 'Only the helper keys') + '">' + (K.compact ? '▴ Full' : '▾ Compact') + '</button>' +
      '<button data-fn="close" class="kbd-fn" title="Hide (the ⌨ beside a field brings it back)">✕</button></div>';
    h += '<div class="kbd-cands" hidden aria-label="Kanji from your words"></div>';
    h += '<div class="kbd-rows' + (l.compose === 'kana' && K.mode !== 'romaji' && !K.compact ? ' kbd-grid' : '') + '"' + (l.rtl ? ' dir="rtl"' : '') + '>';
    for (const row of rows) {
      h += '<div class="kbd-row">';
      for (const key of row) {
        if (typeof key === 'string') {
          if (key === '') { h += '<span class="kbd-gap"></span>'; continue; }
          let label = key;
          if (K.shift && l.upper && !l.shift) label = key.toUpperCase();
          if (K.kata && l.compose === 'kana') label = toKatakana(key);
          const combining = COMBINING.test(key);
          h += '<button data-key="' + esc(key) + '" class="kbd-key' + (combining ? ' kbd-mark' : '') + '"' + (K.code ? ' lang="' + esc(K.code) + '"' : '') + '>' + (combining ? '◌' : '') + esc(label) + '</button>';
        } else {
          const on = (key.k === 'shift' && K.shift) || (key.k === 'kana' && K.kata);
          const label = key.k === 'mode' ? (K.mode === 'romaji' ? 'かな' : FN_LABEL.mode) : FN_LABEL[key.k] || key.k;
          h += '<button data-fn="' + esc(key.k) + '" class="kbd-key kbd-fn' + (key.k === 'space' ? ' kbd-space' : '') + (/^tone\d$/.test(key.k) ? ' kbd-tone' : '') + (on ? ' on' : '') + '" title="' + esc(FN_TITLE[key.k] || key.k) + '">' + esc(label) + '</button>';
        }
      }
      h += '</div>';
    }
    p.innerHTML = h + '</div>';
    if (K.target && document.contains(K.target)) candidates(K.target);
  }

  // Whether a field is for the target language: its question's `lang` says so; without one, the question's own text
  // has the script or names the language. A profile question answered in the learner's language ("What do you do?")
  // keeps the ⌨ toggle but doesn't pop the panel open.
  const SCRIPT = { ja: /[぀-ヿ一-鿿]/, zh: /[一-鿿]/, ko: /[가-힯ㄱ-ㆎ]/, ar: /[؀-ۿ]/, fa: /[؀-ۿ]/, ur: /[؀-ۿ]/, he: /[֐-׿]/, ru: /[Ѐ-ӿ]/, uk: /[Ѐ-ӿ]/,
    el: /[Ͱ-Ͽ]/, hi: /[ऀ-ॿ]/, bn: /[ঀ-৿]/, th: /[฀-๿]/ };
  function wants(el) {
    const tagged = el.closest('[data-lang]');
    if (tagged) return String(tagged.getAttribute('data-lang')).slice(0, 2).toLowerCase() === K.code;
    const l = K.layout; if (!l) return false;
    if (!SCRIPT[K.code]) return true;   // Latin languages: the accent row is small and always fits
    const box = el.closest('.quiz-q, .ask, .problem, .comp, .msg');
    const prompt = box ? (box.querySelector('.prompt, .q, .pb-q') || box).textContent : '';
    return SCRIPT[K.code].test(prompt) || new RegExp(l.english.split(' ')[0] + '|' + String(l.name).split(' ')[0], 'i').test(prompt);
  }
  // A field that can take the target language shows the keyboard (unless the learner closed it) and gets a ⌨ toggle.
  document.addEventListener('focusin', e => {
    const el = e.target;
    if (!eligible(el)) return;
    K.target = el;
    if (K.layout && K.auto && !K.open && wants(el)) { K.open = true; render(); }
    if (K.open) candidates(el);
  });
  function addToggles(root) {
    if (!K.layout) return;
    const list = (root.matches && root.matches(FIELDS) ? [root] : []).concat(Array.from(root.querySelectorAll(FIELDS)));
    for (const el of list) {
      if (!eligible(el) || el._kbdToggle || !el.parentNode) continue;
      el._kbdToggle = true;
      if (wants(el)) el.setAttribute('lang', K.code);
      el.setAttribute('spellcheck', 'false');
      if (K.layout.rtl) el.setAttribute('dir', 'auto');
      const b = document.createElement('button');
      b.type = 'button'; b.className = 'kbd-toggle';
      b.innerHTML = '⌨ <span lang="' + esc(K.code) + '">' + esc(shortName(K.layout)) + '</span>';
      b.title = 'On-screen ' + K.layout.english + ' keyboard';
      b.setAttribute('aria-label', 'On-screen ' + K.layout.english + ' keyboard');
      b.addEventListener('mousedown', ev => ev.preventDefault());
      b.addEventListener('click', () => { K.target = el; K.open = !K.open; K.auto = K.open; render(); el.focus(); });
      el.insertAdjacentElement('afterend', b);
    }
  }
  const shortName = l => String(l.name || '').split(' · ')[0];
  R.registerProcessor(root => addToggles(root));

  // The first time a language's keyboard is ready, say so once: where it appears and how to type.
  function intro() {
    if (!K.layout || load('kbd.intro.' + K.code)) return;
    store('kbd.intro.' + K.code, '1');
    if (!window.TeacherToast) return;
    const how = K.layout.modes && K.layout.modes.includes('romaji') ? 'tap kana, or type romaji on your Mac keyboard'
      : K.layout.physical ? 'tap the keys, or type with your Mac keys in “Mac keys” mode' : 'tap the keys';
    window.TeacherToast('⌨ ' + K.layout.english + ' keyboard ready: it opens under any answer field (' + how + '). The ⌨ ' + shortName(K.layout) + ' button beside a field shows or hides it.');
  }

  /** From the app: the lesson's language state ({target, native, words, inputSource, …}); the panel follows the target. */
  R.setLanguage = function (state) {
    const target = state && state.target ? String(state.target).slice(0, 2).toLowerCase() : null;
    K.lang = target; K.native = state && state.native || null;
    K.words = state && Array.isArray(state.words) ? state.words.filter(w => w && w.term && w.kana) : [];
    K.source = state && state.inputSource || null;
    if (target !== K.code) { setLayout(target); K.auto = true; K.open = K.open && !!K.layout; if (K.layout) intro(); }
    render();
    document.querySelectorAll(FIELDS).forEach(el => { if (el._kbdToggle) { el._kbdToggle = false; const t = el.nextElementSibling; if (t && t.classList.contains('kbd-toggle')) t.remove(); } });
    if (K.layout) addToggles(document.body);
  };

  R.injectStyles('keyboard', `
    #kbd { position: fixed; left: 0; right: 0; bottom: 0; z-index: 40; background: color-mix(in srgb, var(--card) 92%, transparent); backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px);
      border-top: 1px solid var(--border); box-shadow: 0 -6px 24px rgba(0,0,0,.08); padding: 6px 12px 10px; user-select: none; font-size: var(--font-size); }
    body.kbd-open #thread { padding-bottom: 320px; }
    body.kbd-open.kbd-compact #thread { padding-bottom: 150px; }
    .kbd-head { display: flex; align-items: center; gap: 8px; margin: 0 auto 6px; max-width: 900px; color: var(--muted); font-size: .84em; flex-wrap: wrap; }
    .kbd-head select { font: inherit; max-width: 220px; }
    .kbd-sp { flex: 1; }
    .kbd-hint { min-width: 0; }
    .kbd-hint b { color: var(--fg); }
    .kbd-modes { display: inline-flex; border: 1px solid var(--border); border-radius: 7px; overflow: hidden; }
    .kbd-modes button { border: 0; background: var(--bg); color: var(--muted); padding: 2px 9px; font: inherit; cursor: pointer; }
    .kbd-modes button + button { border-left: 1px solid var(--border); }
    .kbd-modes button.on { background: var(--accent); color: #fff; }
    .kbd-src { border: 1px solid var(--border); background: var(--bg); color: var(--fg); border-radius: 6px; padding: 2px 8px; font: inherit; cursor: pointer; }
    .kbd-src.on { color: var(--good); border-color: transparent; background: transparent; cursor: default; }
    .kbd-cands { display: flex; gap: 6px; justify-content: center; margin: 0 auto 6px; flex-wrap: wrap; }
    .kbd-cands button { border: 1px solid var(--accent); background: var(--accent-soft); color: var(--fg); border-radius: 8px; padding: 2px 10px; font-size: 1.15em; cursor: pointer; }
    .kbd-rows { display: flex; flex-direction: column; gap: 5px; max-width: 900px; margin: 0 auto; }
    .kbd-row { display: flex; justify-content: center; gap: 5px; flex-wrap: wrap; }
    .kbd-grid .kbd-row { flex-wrap: nowrap; }
    .kbd-gap { min-width: 40px; height: 40px; }
    .kbd-key { min-width: 40px; height: 40px; padding: 0 8px; border: 1px solid var(--border); border-radius: 9px; background: var(--bg); color: var(--fg); font-size: 1.15em; cursor: pointer; line-height: 1;
      box-shadow: 0 1px 0 var(--border); transition: transform .06s ease, background .12s ease, border-color .12s ease; }
    .kbd-key:hover { border-color: var(--accent); }
    .kbd-key:active, .kbd-key.hit { transform: translateY(1px) scale(.96); background: var(--accent-soft); border-color: var(--accent); }
    .kbd-key.kbd-fn { background: var(--card-2); font-size: .86em; color: var(--muted); }
    .kbd-key.kbd-fn.on, .kbd-head .kbd-fn.on { background: var(--accent); color: #fff; border-color: var(--accent); }
    .kbd-key.kbd-space { min-width: 200px; }
    .kbd-key.kbd-mark { color: var(--accent); }
    .kbd-key.kbd-tone { color: var(--fg); font-size: .95em; }
    .kbd-head .kbd-fn { border: 1px solid var(--border); background: var(--bg); color: var(--muted); border-radius: 6px; padding: 2px 8px; cursor: pointer; font: inherit; }
    .kbd-toggle { border: 1px solid var(--border); background: var(--bg); color: var(--muted); cursor: pointer; font-size: .78em; padding: 1px 7px; border-radius: 999px; margin-left: 4px; vertical-align: middle; white-space: nowrap; }
    .kbd-toggle:hover { color: var(--accent); border-color: var(--accent); }
    .quiz-q .kbd-toggle, .ask .kbd-toggle { float: right; margin-top: -32px; margin-right: 6px; position: relative; z-index: 1; }
  `);
  window.TeacherKeyboard = { wants, state: K, layouts: LAYOUTS, hangul, hangulBackspace, romajiToKana, cycleTone, setTone, abugida, voicing, insert, special, setLayout, render, eligible, physicalChar, matchWords, modesOf };
})();
