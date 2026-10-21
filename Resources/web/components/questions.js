// Interactive question components for the `ask_learner` and `quiz` tools.
// Types: single_choice, multiple_choice, true_false, short_text, long_text, numeric, fill_blanks,
//        ordering, matching, scale, code, math, drawing.
(function () {
  'use strict';
  const R = window.TeacherUI;
  const forms = new Map();   // toolId -> form state

  const ALIASES = { mcq: 'single_choice', choice: 'single_choice', multi: 'multiple_choice', short: 'short_text', text: 'short_text',
    essay: 'long_text', tf: 'true_false', boolean: 'true_false', number: 'numeric', cloze: 'fill_blanks', order: 'ordering',
    match: 'matching', likert: 'scale', rating: 'scale' };
  function normalize(qs) {
    return (qs || []).map(q => {
      const o = Object.assign({}, q);
      if (o.prompt == null && o.question != null) o.prompt = o.question;
      if (ALIASES[o.type]) o.type = ALIASES[o.type];
      if (!o.type) o.type = o.options ? 'single_choice' : 'short_text';
      return o;
    });
  }
  function seeded(seed) { let s = 0; for (const c of seed) s = (s * 31 + c.charCodeAt(0)) >>> 0; return () => (s = (s * 1664525 + 1013904223) >>> 0) / 4294967296; }
  function shuffle(n, seed) {
    const a = Array.from({ length: n }, (_, i) => i), rnd = seeded(seed);
    for (let i = n - 1; i > 0; i--) { const j = Math.floor(rnd() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; }
    if (n > 1 && a.every((v, i) => v === i)) a.push(a.shift());
    return a;
  }
  function state(id) {
    let F = forms.get(id);
    if (!F) { F = { answers: [], other: [], hints: [], confidence: 0, started: Date.now(), perms: {}, matchPerm: {}, selected: [] }; forms.set(id, F); }
    return F;
  }
  const dis = a => a ? '' : ' disabled';

  // ── Type renderers ────────────────────────────────────────────────────
  // render(q, qi, F, ctx, active, g) → html ; g = graded entry {correct, given, answer, expected, explanation} when reviewing
  const T = {};
  T.single_choice = {
    render(q, qi, F, ctx, active, g) {
      const given = g ? g.given : F.answers[qi];
      let h = (q.options || []).map((o, oi) => {
        let cls = given === oi ? ' sel' : '';
        if (g && g.correct != null) cls = g.answer === oi ? ' correct' : (given === oi ? ' wrong' : '');
        return '<label class="opt' + cls + '"' + (active ? ' data-act="q-pick"' : '') + ' data-q="' + qi + '" data-o="' + oi + '"><input type="radio" tabindex="-1"' + (given === oi ? ' checked' : '') + dis(active) + '><span class="md">' + ctx.inline(o) + '</span></label>';
      }).join('');
      if (q.allow_other) {
        const v = typeof given === 'string' ? given : (F.other[qi] || '');
        h += active ? '<input type="text" class="q-text" data-q-other="' + qi + '" placeholder="Other…" value="' + ctx.esc(v) + '">' : (typeof given === 'string' ? '<div class="q-given">“' + ctx.esc(given) + '”</div>' : '');
      }
      return h;
    },
  };
  T.multiple_choice = {
    render(q, qi, F, ctx, active, g) {
      const given = (g ? g.given : F.answers[qi]) || [];
      const ans = g && Array.isArray(g.answer) ? g.answer : null;
      return (q.options || []).map((o, oi) => {
        const sel = Array.isArray(given) && given.includes(oi);
        let cls = sel ? ' sel' : '';
        if (ans) cls = ans.includes(oi) ? (sel ? ' correct' : ' missed') : (sel ? ' wrong' : '');
        return '<label class="opt' + cls + '"' + (active ? ' data-act="q-toggle"' : '') + ' data-q="' + qi + '" data-o="' + oi + '"><input type="checkbox" tabindex="-1"' + (sel ? ' checked' : '') + dis(active) + '><span class="md">' + ctx.inline(o) + '</span></label>';
      }).join('') + (active ? '<div class="q-help">' + (q.max_select ? 'Choose up to ' + q.max_select : 'Select all that apply') + '</div>' : '');
    },
  };
  T.true_false = {
    render(q, qi, F, ctx, active, g) {
      const given = g ? g.given : F.answers[qi];
      return '<div class="tf">' + [true, false].map(v => {
        let cls = given === v ? ' sel' : '';
        if (g && typeof g.answer === 'boolean') cls = g.answer === v ? ' correct' : (given === v ? ' wrong' : '');
        return '<button class="btn tf-btn' + cls + '"' + (active ? ' data-act="q-tf"' : ' disabled') + ' data-q="' + qi + '" data-v="' + v + '">' + (v ? 'True' : 'False') + '</button>';
      }).join('') + '</div>';
    },
  };
  function textInput(multiline, mono) {
    return {
      render(q, qi, F, ctx, active, g) {
        const v = g ? g.given : F.answers[qi];
        if (!active) return '<div class="q-given' + (mono ? ' mono' : '') + '">' + (v == null || v === '' ? '<span class="muted">(no answer)</span>' : ctx.esc(v)) + '</div>';
        const ph = ctx.esc(q.placeholder || (mono ? '' : 'Type your answer…'));
        return multiline
          ? '<textarea class="q-text' + (mono ? ' mono' : '') + '" data-q-input="' + qi + '" placeholder="' + ph + '" spellcheck="' + !mono + '"' + (mono ? ' rows="8"' : '') + '>' + ctx.esc(v == null ? (q.starter || '') : v) + '</textarea>'
          : '<input type="text" class="q-text" data-q-input="' + qi + '" placeholder="' + ph + '" value="' + ctx.esc(v == null ? '' : v) + '">';
      },
    };
  }
  T.short_text = textInput(false);
  T.long_text = textInput(true);
  T.code = {
    render(q, qi, F, ctx, active, g) {
      return '<div class="q-code-label">' + ctx.esc(q.language || 'code') + '</div>' + textInput(true, true).render(q, qi, F, ctx, active, g);
    },
  };
  T.numeric = {
    render(q, qi, F, ctx, active, g) {
      const v = g ? g.given : F.answers[qi];
      return '<div class="q-numeric"><input type="text" inputmode="decimal" class="q-text" data-q-input="' + qi + '" placeholder="' + ctx.esc(q.placeholder || 'Number') + '" value="' + ctx.esc(v == null ? '' : v) + '"' + dis(active) + '>' +
        (q.unit ? '<span class="q-unit">' + ctx.inline(q.unit) + '</span>' : '') + '</div>';
    },
  };
  T.math = {
    render(q, qi, F, ctx, active, g) {
      const v = (g ? g.given : F.answers[qi]) || '';
      return '<input type="text" class="q-text mono" data-q-input="' + qi + '" data-math="1" placeholder="' + ctx.esc(q.placeholder || 'e.g. 2x^2 + \\frac{1}{3}') + '" value="' + ctx.esc(v) + '"' + dis(active) + '>' +
        '<div class="math-preview" data-preview="' + qi + '">' + (v ? ctx.tex(v, true) : '<span class="muted">Preview appears here</span>') + '</div>';
    },
  };
  T.fill_blanks = {
    render(q, qi, F, ctx, active, g) {
      const given = (g ? g.given : F.answers[qi]) || [];
      const parts = String(q.text || q.prompt || '').split('{{}}');
      const exp = g && Array.isArray(g.answer) ? g.answer : null;
      let h = '<div class="blanks md">';
      parts.forEach((p, k) => {
        h += ctx.inline(p);
        if (k === parts.length - 1) return;
        const v = given[k] == null ? '' : given[k];
        const opts = q.blank_options && q.blank_options[k];
        let cls = '';
        if (exp && exp[k] != null) {
          const alts = [].concat(exp[k]).map(x => String(x).trim().toLowerCase());
          cls = alts.includes(String(v).trim().toLowerCase()) ? ' ok' : ' bad';
        }
        if (opts && active) {
          h += '<select class="blank" data-q-blank="' + qi + ':' + k + '"><option value=""></option>' + opts.map(o => '<option' + (o === v ? ' selected' : '') + '>' + ctx.esc(o) + '</option>').join('') + '</select>';
        } else {
          h += '<input type="text" class="blank' + cls + '" data-q-blank="' + qi + ':' + k + '" value="' + ctx.esc(v) + '" size="' + Math.max(4, String(v).length + 1) + '"' + dis(active) + '>';
          if (cls === ' bad' && exp) h += '<span class="blank-fix">' + ctx.esc([].concat(exp[k])[0]) + '</span>';
        }
      });
      return h + '</div>';
    },
  };
  T.ordering = {
    render(q, qi, F, ctx, active, g, id) {
      const items = q.items || [];
      let order = g ? (g.given || []) : (F.perms[qi] || (F.perms[qi] = shuffle(items.length, id + ':' + qi)));
      if (!F.answers[qi] && !g) F.answers[qi] = order.slice();
      return '<ol class="ordering">' + order.map((it, pos) => {
        const cls = g && g.correct != null ? (it === pos ? ' correct' : ' wrong') : '';
        return '<li class="ord-item' + cls + '"><span class="md">' + ctx.inline(items[it] || '') + '</span>' + (active ? '<span class="ord-btns"><button data-act="q-move" data-q="' + qi + '" data-pos="' + pos + '" data-d="-1"' + (pos === 0 ? ' disabled' : '') + '>↑</button><button data-act="q-move" data-q="' + qi + '" data-pos="' + pos + '" data-d="1"' + (pos === order.length - 1 ? ' disabled' : '') + '>↓</button></span>' : '') + '</li>';
      }).join('') + '</ol>' + (g && g.correct === false ? '<div class="q-help">Correct order: ' + items.map(ctx.inline).join(' → ') + '</div>' : '');
    },
  };
  T.matching = {
    render(q, qi, F, ctx, active, g, id) {
      const pairs = q.pairs || [];
      const perm = F.matchPerm[qi] || (F.matchPerm[qi] = shuffle(pairs.length, id + ':m' + qi));
      const given = (g ? g.given : F.answers[qi]) || [];
      return '<table class="matching"><tbody>' + pairs.map((p, li) => {
        const sel = given[li] == null ? -1 : given[li];
        const cls = g && g.correct != null ? (sel === li ? ' ok' : ' bad') : '';
        return '<tr><td class="md">' + ctx.inline(p[0]) + '</td><td>→</td><td><select class="match' + cls + '" data-q-match="' + qi + ':' + li + '"' + dis(active) + '><option value="-1">Choose…</option>' +
          perm.map(ri => '<option value="' + ri + '"' + (sel === ri ? ' selected' : '') + '>' + ctx.esc(pairs[ri][1]) + '</option>').join('') + '</select>' +
          (cls === ' bad' ? ' <span class="blank-fix">' + ctx.esc(p[1]) + '</span>' : '') + '</td></tr>';
      }).join('') + '</tbody></table>';
    },
  };
  T.scale = {
    render(q, qi, F, ctx, active, g) {
      const min = q.min == null ? 1 : q.min, step = q.step || 1;
      const labels = q.labels || [];
      const max = q.max == null ? (labels.length > 2 ? min + (labels.length - 1) * step : 5) : q.max;
      const points = []; for (let v = min; v <= max + 1e-9; v += step) points.push(+v.toFixed(6));
      const given = g ? g.given : F.answers[qi];
      const btn = (v, inner, cls) => '<button class="' + cls + (given === v ? ' sel' : '') + '"' + (active ? ' data-act="q-scale"' : ' disabled') + ' data-q="' + qi + '" data-v="' + v + '">' + inner + '</button>';
      // One label per point → labelled options (e.g. self-assessment levels).
      if (labels.length === points.length && labels.length > 2) {
        return '<div class="scale-labelled">' + points.map((v, i) => btn(v, '<span class="sl-n">' + v + '</span><span class="sl-t">' + ctx.inline(labels[i]) + '</span>', 'scale-opt')).join('') + '</div>';
      }
      let h = '<div class="scale">' + (labels[0] ? '<span class="scale-l">' + ctx.esc(labels[0]) + '</span>' : '');
      points.forEach(v => { h += btn(v, String(v), 'scale-btn'); });
      return h + (labels[1] ? '<span class="scale-l">' + ctx.esc(labels[labels.length - 1]) + '</span>' : '') + '</div>';
    },
  };
  T.drawing = {
    render(q, qi, F, ctx, active, g) {
      const img = g ? (g.given && (g.given.image || g.given)) : (F.answers[qi] && F.answers[qi].image);
      if (!active) return img ? '<img class="q-drawing" src="' + ctx.esc(img) + '" alt="drawing">' : '<div class="q-given muted">(no drawing)</div>';
      return '<div class="draw"><div class="draw-tools"><button data-act="q-pen" data-q="' + qi + '" data-c="ink">Pen</button><button data-act="q-pen" data-q="' + qi + '" data-c="#e5484d">Red</button><button data-act="q-pen" data-q="' + qi + '" data-c="#2f6fec">Blue</button><button data-act="q-pen" data-q="' + qi + '" data-c="erase">Eraser</button><button data-act="q-clear" data-q="' + qi + '">Clear</button></div>' +
        '<canvas class="q-canvas" data-q="' + qi + '" width="1200" height="640"></canvas></div>';
    },
  };
  Object.keys(T).forEach(k => R.registerQuestionType(k, T[k]));

  // ── Form card ─────────────────────────────────────────────────────────
  // A result with meta.running is the loop's placeholder while tools execute — not an answer.
  const finished = r => (r && !(r.meta && r.meta.running)) ? r : null;

  function renderForm(b, r, pend, ctx, graded) {
    r = finished(r);
    const id = b.id;
    const input = b.input || {};
    const active = !!pend && !r;
    const qs = normalize(active && pend.payload && pend.payload.questions ? pend.payload.questions : input.questions);
    const F = state(id);
    const gradedList = r && r.meta && r.meta.graded;
    const answeredList = r && r.meta && r.meta.answers;
    let h = '<div class="quiz' + (graded ? '' : ' askform') + '" data-form="' + ctx.esc(id) + '"><div class="quiz-head"><span class="title">' + (graded ? '📝 ' : '💬 ') + ctx.esc(input.title || (graded ? 'Quiz' : 'A few questions')) + '</span>' +
      '<span class="meta">' + qs.length + ' question' + (qs.length === 1 ? '' : 's') + (input.subject ? ' · ' + ctx.esc(input.subject) : '') + '</span></div>';
    qs.forEach((q, qi) => {
      const impl = R.questionTypes[q.type] || R.questionTypes.short_text;
      let g = gradedList ? gradedList[qi] : null;
      if (!g && answeredList) g = { given: answeredList[qi], correct: null };
      if (g && graded && qs[qi] && g.answer === undefined) g.answer = qs[qi].answer;
      h += '<div class="quiz-q" data-qi="' + qi + '"><div class="qn">' + (qs.length > 1 ? 'Question ' + (qi + 1) : '') + (q.concept ? (qs.length > 1 ? ' · ' : '') + ctx.esc(q.concept) : '') + '</div>' +
        (q.type !== 'fill_blanks' || q.text ? '<div class="prompt md">' + ctx.md(q.prompt || '') + '</div>' : '') +
        impl.render(q, qi, F, ctx, active, g, id);
      if (q.hint && active) h += F.hints[qi] ? '<div class="hint">💡 ' + ctx.inline(q.hint) + '</div>' : '<button class="hint-btn" data-act="q-hint" data-q="' + qi + '">Show hint</button>';
      if (g && graded) {
        const ok = g.correct;
        const cls = ok === true ? 'good' : ok === false ? 'bad' : 'neutral';
        const label = ok === true ? '✅ Correct' : ok === false ? (g.score > 0 ? '🟡 Partly right (' + Math.round(g.score * 100) + '%)' : '❌ Not quite') : '📝 Your teacher will review this';
        let expl = g.explanation ? '<div class="md">' + ctx.md(g.explanation) + '</div>' : '';
        if (ok === false && g.expected && !['single_choice', 'multiple_choice', 'true_false', 'ordering', 'matching', 'fill_blanks'].includes(q.type)) expl = '<div>Expected: <b>' + (q.type === 'math' ? ctx.tex(g.expected, false) : ctx.esc(g.expected)) + '</b></div>' + expl;
        h += '<div class="feedback ' + cls + '"><b>' + label + '</b>' + expl + '</div>';
      }
      h += '</div>';
    });
    if (active) {
      h += '<div class="quiz-foot">' + (graded ? '<div class="confidence">Confidence: ' + [1, 2, 3, 4, 5].map(n => '<button data-act="q-conf" data-v="' + n + '" class="' + (F.confidence === n ? 'sel' : '') + '">' + n + '</button>').join('') + '</div>' : '<span></span>') +
        '<div class="btn-row"><button class="btn" data-act="q-skip">' + (graded ? 'Skip' : 'Dismiss') + '</button><button class="btn primary" data-act="q-submit">' + ctx.esc(input.submit_label || (graded ? 'Submit answers' : 'Send')) + '</button></div></div>';
    } else if (gradedList) {
      const score = r.meta.score, total = r.meta.total;
      h += '<div class="quiz-foot"><span class="score' + (total && score / total >= 0.8 ? ' great' : '') + '">Score: ' + score + ' / ' + total + '</span><span class="meta">' + (total && score === total ? '🎉 Perfect!' : 'Mistakes are how we learn.') + '</span></div>';
    } else if (r && r.isError) {
      h += '<div class="quiz-foot"><span class="answered">' + (/Interrupted/.test(r.text || '') ? 'Interrupted — the app closed before this was answered.' : 'Skipped.') + '</span></div>';
    } else if (r) {
      h += '<div class="quiz-foot"><span class="answered">✓ Sent</span></div>';
    } else {
      h += '<div class="quiz-foot"><span class="answered"><span class="spinner"></span> Preparing…</span></div>';
    }
    return h + '</div>';
  }

  function renderQuick(b, r, pend, ctx) {
    r = finished(r);
    const i = b.input || {};
    if (r && !pend) {
      const ans = (r.text || '').replace(/^Learner's answer:\s*/, '');
      return '<div class="ask answered-ask"><div class="q md">' + ctx.inline(i.question) + '</div><div class="answered">→ ' + ctx.esc(ans) + '</div></div>';
    }
    if (!pend) return '<div class="ask"><div class="q md">' + ctx.inline(i.question || '') + '</div><span class="spinner"></span></div>';
    const F = state(b.id);
    let h = '<div class="ask"><div class="q md">' + ctx.inline(i.question || '') + '</div><div class="opts">';
    (i.options || []).forEach((o, oi) => { h += '<button class="btn' + (F.selected.includes(oi) ? ' sel' : '') + '" data-act="ask-opt" data-o="' + oi + '">' + ctx.inline(o) + '</button>'; });
    h += '</div>';
    if (i.multi_select) h += '<div class="btn-row" style="margin-bottom:8px"><button class="btn primary" data-act="ask-submit">Submit</button></div>';
    if (i.allow_free_text !== false) h += '<div class="free"><textarea placeholder="Or type your own answer…" data-ask-text></textarea><button class="btn primary" data-act="ask-submit">Send</button></div>';
    return h + '</div>';
  }

  R.registerToolCard('quiz', (b, r, pend, ctx) => renderForm(b, r, pend, ctx, true));
  R.registerToolCard('ask_learner', (b, r, pend, ctx) => (b.input && b.input.questions) ? renderForm(b, r, pend, ctx, !!b.input.graded) : renderQuick(b, r, pend, ctx));

  // ── Actions & inputs ─────────────────────────────────────────────────
  const toolOf = el => { const t = el.closest('[data-tool-id]'); return t ? t.getAttribute('data-tool-id') : null; };
  const qi = el => +el.getAttribute('data-q');
  const questionsOf = id => {
    const el = document.querySelector('[data-tool-id="' + CSS.escape(id) + '"]');
    return el && el._block ? normalize(el._block.input.questions) : [];
  };
  R.registerAction('q-pick', (el, e, ctx) => { e.preventDefault(); const id = toolOf(el); const F = state(id); F.answers[qi(el)] = +el.getAttribute('data-o'); ctx.refreshCard(id); });
  R.registerAction('q-toggle', (el, e, ctx) => {
    e.preventDefault(); const id = toolOf(el), F = state(id), q = qi(el), o = +el.getAttribute('data-o');
    const cur = Array.isArray(F.answers[q]) ? F.answers[q] : [];
    const max = (questionsOf(id)[q] || {}).max_select;
    if (cur.includes(o)) F.answers[q] = cur.filter(x => x !== o);
    else F.answers[q] = (max && cur.length >= max ? cur.slice(1) : cur).concat([o]).sort((a, b) => a - b);
    ctx.refreshCard(id);
  });
  R.registerAction('q-tf', (el, e, ctx) => { const id = toolOf(el); state(id).answers[qi(el)] = el.getAttribute('data-v') === 'true'; ctx.refreshCard(id); });
  R.registerAction('q-scale', (el, e, ctx) => { const id = toolOf(el); state(id).answers[qi(el)] = +el.getAttribute('data-v'); ctx.refreshCard(id); });
  R.registerAction('q-hint', (el, e, ctx) => { const id = toolOf(el); state(id).hints[qi(el)] = true; ctx.refreshCard(id); });
  R.registerAction('q-conf', (el, e, ctx) => { const id = toolOf(el); state(id).confidence = +el.getAttribute('data-v'); ctx.refreshCard(id); });
  R.registerAction('q-move', (el, e, ctx) => {
    const id = toolOf(el), F = state(id), q = qi(el), pos = +el.getAttribute('data-pos'), d = +el.getAttribute('data-d');
    const order = F.perms[q]; const j = pos + d;
    if (!order || j < 0 || j >= order.length) return;
    [order[pos], order[j]] = [order[j], order[pos]];
    F.answers[q] = order.slice();
    ctx.refreshCard(id);
  });
  R.registerAction('q-skip', (el, e, ctx) => ctx.post({ type: 'answer', id: toolOf(el), value: { cancelled: true } }));
  R.registerAction('q-submit', (el, e, ctx) => {
    const id = toolOf(el), F = state(id);
    const card = el.closest('[data-tool-id]');
    collect(card, F);
    const n = card.querySelectorAll('.quiz-q').length;
    const answers = Array.from({ length: n }, (_, i) => {
      let a = F.answers[i];
      if (a === undefined || a === '') a = (F.other[i] || '').trim() || null;
      return a === undefined ? null : a;
    });
    el.disabled = true; el.textContent = 'Sent';
    ctx.post({ type: 'answer', id, value: { answers, confidence: F.confidence || null, seconds: (Date.now() - F.started) / 1000 } });
  });
  R.registerAction('ask-opt', (el, e, ctx) => {
    const id = toolOf(el), F = state(id), o = +el.getAttribute('data-o'), card = el.closest('[data-tool-id]');
    const input = card._block.input;
    if (input.multi_select) { F.selected = F.selected.includes(o) ? F.selected.filter(x => x !== o) : F.selected.concat([o]); ctx.refreshCard(id); }
    else ctx.post({ type: 'answer', id, value: { selected: [input.options[o]] } });
  });
  R.registerAction('ask-submit', (el, e, ctx) => {
    const id = toolOf(el), F = state(id), card = el.closest('[data-tool-id]');
    const ta = card.querySelector('[data-ask-text]'); const opts = card._block.input.options || [];
    ctx.post({ type: 'answer', id, value: { selected: F.selected.map(i => opts[i]), text: ta ? ta.value.trim() : '' } });
  });
  R.registerAction('q-pen', (el) => { const c = el.closest('.draw').querySelector('canvas'); c._pen = el.getAttribute('data-c'); });
  R.registerAction('q-clear', (el) => {
    const c = el.closest('.draw').querySelector('canvas'); const id = toolOf(el);
    c.getContext('2d').clearRect(0, 0, c.width, c.height); state(id).answers[qi(el)] = undefined;
  });

  function collect(card, F) {
    card.querySelectorAll('[data-q-input]').forEach(inp => { F.answers[+inp.getAttribute('data-q-input')] = inp.value; });
    card.querySelectorAll('[data-q-other]').forEach(inp => { F.other[+inp.getAttribute('data-q-other')] = inp.value; });
    card.querySelectorAll('[data-q-blank]').forEach(inp => {
      const [q, k] = inp.getAttribute('data-q-blank').split(':').map(Number);
      (F.answers[q] = Array.isArray(F.answers[q]) ? F.answers[q] : [])[k] = inp.value;
    });
    card.querySelectorAll('[data-q-match]').forEach(sel => {
      const [q, l] = sel.getAttribute('data-q-match').split(':').map(Number);
      (F.answers[q] = Array.isArray(F.answers[q]) ? F.answers[q] : [])[l] = +sel.value;
    });
  }
  R.registerInput((e, ctx) => {
    const t = e.target; if (!t || !t.closest) return;
    const card = t.closest('[data-tool-id]'); if (!card) return;
    const F = state(card.getAttribute('data-tool-id'));
    collect(card, F);
    if (t.hasAttribute('data-q-other')) { const q = +t.getAttribute('data-q-other'); if (t.value.trim()) F.answers[q] = t.value; }
    if (t.getAttribute('data-math')) {
      const pv = card.querySelector('[data-preview="' + t.getAttribute('data-q-input') + '"]');
      if (pv) pv.innerHTML = t.value.trim() ? ctx.tex(t.value, true) : '<span class="muted">Preview appears here</span>';
    }
    if (t.matches('textarea.mono') && e.type === 'keydown') return;
  });
  document.addEventListener('keydown', (e) => {
    const t = e.target;
    if (t.matches && t.matches('textarea.mono') && e.key === 'Tab') {
      e.preventDefault();
      const s = t.selectionStart; t.value = t.value.slice(0, s) + '    ' + t.value.slice(t.selectionEnd); t.selectionStart = t.selectionEnd = s + 4;
      t.dispatchEvent(new Event('input', { bubbles: true }));
    }
  });

  // ── Drawing canvas hydration ─────────────────────────────────────────
  R.registerProcessor((root) => {
    root.querySelectorAll('canvas.q-canvas').forEach(c => {
      if (c._ready) return; c._ready = true;
      const card = c.closest('[data-tool-id]'); if (!card) return;
      const id = card.getAttribute('data-tool-id'), q = +c.getAttribute('data-q'), F = state(id);
      const g = c.getContext('2d');
      g.lineCap = 'round'; g.lineJoin = 'round';
      if (F.answers[q] && F.answers[q].image) { const im = new Image(); im.onload = () => g.drawImage(im, 0, 0); im.src = F.answers[q].image; }
      let drawing = false, last = null;
      const pt = e => { const r = c.getBoundingClientRect(); return [(e.clientX - r.left) * c.width / r.width, (e.clientY - r.top) * c.height / r.height]; };
      c.addEventListener('pointerdown', e => { drawing = true; last = pt(e); c.setPointerCapture(e.pointerId); });
      c.addEventListener('pointermove', e => {
        if (!drawing) return;
        const p = pt(e), pen = c._pen || 'ink';
        g.globalCompositeOperation = pen === 'erase' ? 'destination-out' : 'source-over';
        g.strokeStyle = pen === 'ink' ? '#111' : pen;
        g.lineWidth = pen === 'erase' ? 28 : 4 * (e.pressure ? 0.5 + e.pressure : 1);
        g.beginPath(); g.moveTo(last[0], last[1]); g.lineTo(p[0], p[1]); g.stroke();
        last = p;
      });
      const end = () => {
        if (!drawing) return; drawing = false;
        // Export on a white background so the model sees dark ink on white.
        const out = document.createElement('canvas'); out.width = c.width; out.height = c.height;
        const og = out.getContext('2d'); og.fillStyle = '#fff'; og.fillRect(0, 0, out.width, out.height);
        og.drawImage(c, 0, 0);
        F.answers[q] = { image: out.toDataURL('image/png') };
      };
      c.addEventListener('pointerup', end); c.addEventListener('pointerleave', end);
    });
  });

  window.TeacherForms = { state, normalize };
})();
