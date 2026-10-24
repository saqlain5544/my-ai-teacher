// Multilingual text: per-block direction, per-run language tagging, script fonts, click-to-hear.
// Runs after every render on freshly inserted DOM. (The page's own <html lang> is not a tagged run.)
(function () {
  'use strict';
  const R = window.TeacherUI;

  const SCRIPTS = [
    { re: /[؀-ۿݐ-ݿࢠ-ࣿﭐ-﷿ﹰ-﻿]/, lang: 'ar', rtl: true, min: 1 },
    { re: /[֐-׿יִ-ﭏ]/, lang: 'he', rtl: true, min: 1 },
    { re: /[぀-ヿㇰ-ㇿ]/, lang: 'ja', min: 1 },
    { re: /[㐀-鿿豈-﫿]/, lang: 'zh', min: 1 },
    { re: /[가-힯ᄀ-ᇿ]/, lang: 'ko', min: 1 },
    { re: /[ऀ-ॿ]/, lang: 'hi', min: 1 },
    { re: /[ঀ-৿]/, lang: 'bn', min: 1 },
    { re: /[฀-๿]/, lang: 'th', min: 1 },
    { re: /[Ѐ-ӿ]/, lang: 'ru', min: 2 },
    { re: /[Ͱ-Ͽἀ-῿]/, lang: 'el', min: 3 },  // avoid tagging single Greek math letters
  ];
  const RTL_LANGS = /^(ar|he|fa|ur|ps|yi|dv|ku|sd|ug)\b/;
  const STRONG_RTL = /[֐-ࣿיִ-﷿ﹰ-﻿]/g;
  const STRONG_LTR = /[A-Za-zÀ-ɏͰ-ϿЀ-ӿऀ-෿฀-๿぀-鿿가-힯]/g;
  const SKIP = 'code, pre, .katex, .math-display, .math-inline, .fl, [lang]:not(html), svg, .code-block, .mermaid-block, .plot-block, .comp, textarea, input, select, button, rt';

  function scriptOf(ch) { for (const s of SCRIPTS) if (s.re.test(ch)) return s; return null; }
  function refineLang(lang, text) {
    if (lang === 'ar') { if (/[پچژگ]/.test(text)) return 'fa'; if (/[ٹڈڑںے]/.test(text)) return 'ur'; }
    if (lang === 'zh' && /[぀-ヿ]/.test(text)) return 'ja';
    return lang;
  }

  /** Wrap foreign-script runs (with the spaces/punctuation between their words) in <span class="fl" lang dir>. */
  function wrapRuns(node) {
    const text = node.nodeValue;
    if (!text || !/[^\x00-ɏ]/.test(text)) return;
    const frag = document.createDocumentFragment();
    let i = 0, last = 0, changed = false;
    while (i < text.length) {
      const sc = scriptOf(text[i]);
      if (!sc) { i++; continue; }
      let j = i + 1, end = i + 1;
      while (j < text.length) {
        const s2 = scriptOf(text[j]);
        if (s2 && (s2 === sc || (sc.lang === 'ja' && s2.lang === 'zh') || (sc.lang === 'zh' && s2.lang === 'ja'))) { end = j + 1; j++; continue; }
        // Allow spaces and in-script punctuation inside a run.
        if (/[\s،؛؟۔、。，！？।\-'’]/.test(text[j])) { j++; continue; }
        break;
      }
      // Trailing script punctuation (Arabic ؟ ، ۔ ; CJK 。！？) belongs to the run.
      while (end < text.length && /[،؛؟۔。！？]/.test(text[end])) end++;
      const run = text.slice(i, end);
      const letters = run.replace(/[\s\p{P}]/gu, '').length;
      if (letters >= sc.min) {
        frag.appendChild(document.createTextNode(text.slice(last, i)));
        const span = document.createElement('span');
        const lang = refineLang(sc.lang, run);
        span.className = 'fl';
        span.setAttribute('lang', lang);
        span.setAttribute('dir', sc.rtl ? 'rtl' : 'ltr');
        span.textContent = run;
        frag.appendChild(span);
        last = end; changed = true;
      }
      i = end;
    }
    if (!changed) return;
    frag.appendChild(document.createTextNode(text.slice(last)));
    node.parentNode.replaceChild(frag, node);
  }

  /** Explicit direction per block, from strong-character counts (dir="auto" would follow only the first letter). */
  function setDirection(block) {
    if (block.hasAttribute('dir') && !block._autoDir) return;
    const clone = block.cloneNode(true);
    clone.querySelectorAll('code, pre, .katex, .math-inline, .math-display, rt').forEach(n => n.remove());
    const t = clone.textContent;
    const rtl = (t.match(STRONG_RTL) || []).length, ltr = (t.match(STRONG_LTR) || []).length;
    if (rtl === 0) { if (block._autoDir) { block.removeAttribute('dir'); block._autoDir = false; } return; }
    block.setAttribute('dir', rtl > ltr ? 'rtl' : 'ltr');
    block._autoDir = true;
  }

  function process(root) {
    // 1) Explicit language spans from the model: style, direction, click-to-hear.
    root.querySelectorAll('[lang]').forEach(el => {
      if (el === document.documentElement || el.closest('.code-block, .katex, svg')) return;
      const lang = el.getAttribute('lang');
      if (!lang) return;
      el.classList.add('fl');
      if (RTL_LANGS.test(lang) && !el.hasAttribute('dir')) el.setAttribute('dir', 'rtl');
    });
    // 2) Auto-detected foreign-script runs.
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: n => (n.parentElement && n.parentElement.closest(SKIP)) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT,
    });
    const nodes = []; let n;
    while ((n = walker.nextNode())) nodes.push(n);
    nodes.forEach(wrapRuns);
    // 3) Block direction.
    root.querySelectorAll('p, li, h1, h2, h3, h4, h5, h6, blockquote, td, th, dt, dd, .q, .prompt, .bubble > .md, .vocab-meaning').forEach(setDirection);
    if (root.matches && root.matches('p, li, h1, h2, h3, h4, td, th')) setDirection(root);
  }
  R.registerProcessor(process);

  // Models sometimes wrap language markup in backticks; render `<span lang="xx">…</span>` as the real span.
  R.registerMarkdown(md => {
    const orig = md.renderer.rules.code_inline;
    md.renderer.rules.code_inline = (tokens, idx, opts, env, self) => {
      const c = tokens[idx].content.trim();
      // Only plain text and <span lang> tags inside → it was meant as markup, not code.
      if (/<span lang=/.test(c) && !/<(?!\/?span\b)/.test(c)) {
        const SPAN = /<span lang="([A-Za-z-]{2,12})"(?: dir="(rtl|ltr|auto)")?>([^<]*)<\/span>/g;
        let out = '', last = 0, m;
        while ((m = SPAN.exec(c))) {
          out += md.utils.escapeHtml(c.slice(last, m.index)) + '<span lang="' + m[1] + '"' + (m[2] ? ' dir="' + m[2] + '"' : '') + '>' + md.utils.escapeHtml(m[3]) + '</span>';
          last = SPAN.lastIndex;
        }
        if (!/</.test(c.slice(last))) return out + md.utils.escapeHtml(c.slice(last));
      }
      return orig(tokens, idx, opts, env, self);
    };
  });

  // Click a foreign-language span to hear it (with the right voice).
  R.registerAction('__fl', () => {});
  document.addEventListener('click', (e) => {
    const fl = e.target.closest && e.target.closest('.fl');
    // A reading passage's words open their own popover (with its own 🔊): a click there isn't "read the passage".
    if (!fl || e.target.closest('a, button, input, textarea, select, .rd-body')) return;
    if (window.getSelection && String(window.getSelection()).length > 0) return;
    const text = Array.from(fl.childNodes).filter(c => !(c.nodeType === 1 && c.tagName === 'RT')).map(c => c.nodeType === 1 && c.tagName === 'RUBY'
      ? Array.from(c.childNodes).filter(x => !(x.nodeType === 1 && (x.tagName === 'RT' || x.tagName === 'RP'))).map(x => x.textContent).join('') : c.textContent).join('');
    window.TeacherUI._ctx && window.TeacherUI._ctx.post({ type: 'speak', text: text.trim(), lang: fl.getAttribute('lang') });
    fl.classList.add('speaking'); setTimeout(() => fl.classList.remove('speaking'), 900);
  });
})();
