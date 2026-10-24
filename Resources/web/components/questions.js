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
    if (!F) { F = { answers: [], other: [], hints: [], certainty: [], started: Date.now(), perms: {}, matchPerm: {}, selected: [] }; forms.set(id, F); }
    return F;
  }
  /** A question's hints, gentlest first (`hints`, or the older single `hint`). */
  const ladder = q => (Array.isArray(q.hints) ? q.hints : []).concat(q.hint && !(q.hints || []).includes(q.hint) ? [q.hint] : []).filter(Boolean);
  // 0 = "don't know yet": not an answer to grade but a gap to teach (the question needs no answer then).
  const CERTAINTY = [[0, 'Don\'t know yet'], [1, 'Guessing'], [2, 'Unsure'], [3, 'Sure']];
  // Why a quiz was skipped: the teacher reacts differently to each (Testing.SkipReason in the app).
  const SKIP_REASONS = [['need_more', 'I need more explanation first'], ['too_easy', 'Too easy for me'], ['not_now', 'Not now, keep going'], ['unclear', 'A question is unclear or wrong']];
  const blank = a => a == null || a === '' || (Array.isArray(a) && a.every(x => x == null || x === '' || x === -1));
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
        return '<label class="opt' + cls + '"' + (active ? ' data-act="q-pick" tabindex="0" role="radio" aria-checked="' + (given === oi) + '" data-focus="o' + qi + '-' + oi + '"' : '') + ' data-q="' + qi + '" data-o="' + oi + '"><input type="radio" tabindex="-1"' + (given === oi ? ' checked' : '') + dis(active) + '><span class="md">' + ctx.inline(o) + '</span></label>';
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
        return '<label class="opt' + cls + '"' + (active ? ' data-act="q-toggle" tabindex="0" role="checkbox" aria-checked="' + sel + '" data-focus="o' + qi + '-' + oi + '"' : '') + ' data-q="' + qi + '" data-o="' + oi + '"><input type="checkbox" tabindex="-1"' + (sel ? ' checked' : '') + dis(active) + '><span class="md">' + ctx.inline(o) + '</span></label>';
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
        const max = limit(q, multiline);
        const attrs = ' maxlength="' + max + '"' + (q.min_length ? ' data-minlen="' + (+q.min_length) + '"' : '') + (q.pattern ? ' data-pattern="' + ctx.esc(q.pattern) + '"' : '');
        const val = v == null ? (multiline ? (q.starter || '') : '') : String(v);
        return (multiline
          ? '<textarea class="q-text' + (mono ? ' mono' : '') + '" data-q-input="' + qi + '" placeholder="' + ph + '" spellcheck="' + !mono + '"' + (mono ? ' rows="8"' : '') + attrs + '>' + ctx.esc(val) + '</textarea>'
          : '<input type="text" class="q-text" data-q-input="' + qi + '" placeholder="' + ph + '" value="' + ctx.esc(val) + '"' + attrs + '>') +
          '<div class="q-meta"><span class="q-err" data-err="' + qi + '"></span>' + (mono ? '' : '<span class="q-count" data-count="' + qi + '">' + val.length + ' / ' + max + '</span>') + '</div>';
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
      const range = q.min != null && q.max != null ? q.min + ' to ' + q.max : q.min != null ? '≥ ' + q.min : q.max != null ? '≤ ' + q.max : '';
      return '<div class="q-numeric"><input type="text" inputmode="' + (q.integer ? 'numeric' : 'decimal') + '" class="q-text" data-q-input="' + qi + '" data-numeric="' + (q.integer ? 'int' : 'num') + '"' +
        (q.min != null ? ' data-min="' + (+q.min) + '"' : '') + (q.max != null ? ' data-max="' + (+q.max) + '"' : '') +
        ' placeholder="' + ctx.esc(q.placeholder || (q.integer ? 'Whole number' : 'Number') + (range ? ' (' + range + ')' : '')) + '" value="' + ctx.esc(v == null ? '' : v) + '"' + dis(active) + '>' +
        (q.unit ? '<span class="q-unit">' + ctx.inline(q.unit) + '</span>' : '') + '</div><div class="q-meta"><span class="q-err" data-err="' + qi + '"></span></div>';
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
    F.ctx = ctx; F.active = active && !locked(F, pend);
    const gradedList = r && r.meta && r.meta.graded;
    const answeredList = r && r.meta && r.meta.answers;
    let h = '<div class="quiz' + (graded ? '' : ' askform') + '" data-form="' + ctx.esc(id) + '"><div class="quiz-head"><span class="title">' + (graded ? '📝 ' : '💬 ') + ctx.esc(input.title || (graded ? 'Quiz' : 'A few questions')) + '</span>' +
      '<span class="meta">' + qs.length + ' question' + (qs.length === 1 ? '' : 's') + (input.subject ? ' · ' + ctx.esc(input.subject) : '') + '</span></div>';
    const kase = input.case || (pend && pend.payload && pend.payload.case);
    if (kase) h += '<div class="quiz-case"><div class="qc-label">Case</div><div class="md">' + ctx.md(String(kase)) + '</div></div>';
    qs.forEach((q, qi) => {
      const impl = R.questionTypes[q.type] || R.questionTypes.short_text;
      let g = gradedList ? gradedList[qi] : null;
      if (!g && answeredList) g = { given: answeredList[qi], correct: null };
      if (g && graded && qs[qi] && g.answer === undefined) g.answer = qs[qi].answer;
      // Choices form a named group, so VoiceOver reads the question with them and says "2 of 4" (loose radios had neither).
      const pid = 'qp-' + String(id).replace(/[^\w-]/g, '_') + '-' + qi;
      const group = { single_choice: 'radiogroup', multiple_choice: 'group' }[q.type];
      const body = impl.render(q, qi, F, ctx, active, g, id);
      h += '<div class="quiz-q" data-qi="' + qi + '"><div class="qn">' + (qs.length > 1 ? 'Question ' + (qi + 1) : '') + (q.concept ? (qs.length > 1 ? ' · ' : '') + ctx.esc(q.concept) : '') + '</div>' +
        (q.type !== 'fill_blanks' || q.text ? '<div class="prompt md" id="' + pid + '">' + ctx.md(q.prompt || '') + '</div>' : '') +
        (group ? '<div role="' + group + '" aria-labelledby="' + pid + '">' + body + '</div>' : body);
      // Hints open one at a time, gentlest first; an answer after a hint is logged as helped (no mastery gain).
      const hs = ladder(q), opened = Math.min(+F.hints[qi] || 0, hs.length);
      if (hs.length && active) {
        for (let k = 0; k < opened; k++) h += '<div class="hint">' + (F.nudged === qi && k === 0 ? '<span class="nudge">Stuck? Here\'s a nudge.</span> ' : '') + '💡 ' + (hs.length > 1 ? '<b>Hint ' + (k + 1) + ':</b> ' : '') + ctx.inline(hs[k]) + '</div>';
        if (opened < hs.length) h += '<button class="hint-btn" data-act="q-hint" data-q="' + qi + '">' + (opened ? 'Another hint (' + (opened + 1) + ' of ' + hs.length + ')' : 'Show hint') + '</button>';
      }
      // How sure, before the result: a confident mistake is the one most worth correcting.
      if (graded && active) {
        h += '<div class="certainty" role="radiogroup" aria-label="How sure are you?"><span class="c-label">How sure?</span>' + CERTAINTY.map(([v, t]) =>
          '<button data-act="q-sure" data-q="' + qi + '" data-v="' + v + '" role="radio" aria-checked="' + (F.certainty[qi] === v) + '" class="' + (F.certainty[qi] === v ? 'sel' : '') + '">' + t + '</button>').join('') + '</div>';
      }
      if (g && graded) {
        const ok = g.correct;
        const cls = ok === true ? 'good' : ok === false ? 'bad' : 'neutral';
        const label = g.unknown ? '🤷 Not known yet — your teacher will explain it' : ok === true ? '✅ Correct' : ok === false ? (g.score > 0 ? '🟡 Partly right (' + Math.round(g.score * 100) + '%)' : '❌ Not quite') : '📝 Your teacher will review this';
        let expl = g.explanation ? '<div class="md">' + ctx.md(g.explanation) + '</div>' : '';
        if (ok === false && g.expected && !['single_choice', 'multiple_choice', 'true_false', 'ordering', 'matching', 'fill_blanks'].includes(q.type)) expl = '<div>Expected: <b>' + (q.type === 'math' ? ctx.tex(g.expected, false) : ctx.esc(g.expected)) + '</b></div>' + expl;
        if (ok === false && g.misconception) expl = '<div class="mis">Common mix-up: ' + ctx.inline(g.misconception) + '</div>' + expl;
        const notes = [];
        if (ok === false && g.certainty === 3) notes.push('You were sure: worth a closer look.');
        if (ok === true && g.certainty === 1) notes.push('Right, but a guess: it will come back.');
        if (ok === true && g.hints > 0) notes.push('With a hint: try one without next time.');
        h += '<div class="feedback ' + cls + '"><b>' + label + '</b>' + expl + (notes.length ? '<div class="fb-note">' + notes.map(ctx.esc).join(' ') + '</div>' : '') + '</div>';
      }
      h += '</div>';
    });
    if (active) {
      h += '<div class="quiz-foot"><span></span>' +
        (locked(F, pend) ? '<div class="btn-row"><span class="answered"><span class="spinner"></span> Sent</span></div></div>'
          : F.skipAsk ? '<div class="skip-why" role="group" aria-label="Why skip?"><span class="c-label">Why skip?</span>' +
              SKIP_REASONS.map(([v, t]) => '<button class="btn" data-act="q-skip-why" data-v="' + v + '">' + t + '</button>').join('') +
              '<button class="btn link" data-act="q-skip-back">Back</button></div></div>'
          : '<div class="btn-row"><button class="btn" data-act="q-skip">' + (graded ? 'Skip' : 'Dismiss') + '</button><button class="btn primary" data-act="q-submit">' + ctx.esc(input.submit_label || (graded ? 'Submit answers' : 'Send')) + '</button></div></div>');
    } else if (gradedList) {
      const score = r.meta.score, total = r.meta.total;
      if (!total) h += '<div class="quiz-foot"><span class="answered">Sent — your teacher will review your answers.</span></div>';
      else h += '<div class="quiz-foot"><span class="score' + (total && score / total >= 0.8 ? ' great' : '') + '">Score: ' + score + ' / ' + total + '</span><span class="meta">' + (total && score === total ? '🎉 Perfect!' : 'Mistakes are how we learn.') + '</span></div>';
    } else if (r && r.isError) {
      const why = /skipped the (?:quiz|question) — ([^.]+)\./.exec(r.text || '');
      h += '<div class="quiz-foot"><span class="answered">' + (/Interrupted/.test(r.text || '') ? 'Interrupted — the app closed before this was answered.' : why ? 'Skipped — ' + ctx.esc(why[1]) + '.' : 'Skipped.') + '</span></div>';
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
    const p = (pend && pend.payload) || {};
    const question = i.question || p.question || '', options = i.options || p.options || [];
    const multi = i.multi_select != null ? i.multi_select : p.multi_select, free = (i.allow_free_text != null ? i.allow_free_text : p.allow_free_text) !== false;
    const off = locked(F, pend) ? ' disabled' : '';
    let h = '<div class="ask"><div class="q md">' + ctx.inline(question) + '</div><div class="opts">';
    options.forEach((o, oi) => { h += '<button class="btn' + (F.selected.includes(oi) ? ' sel' : '') + '" data-act="ask-opt" data-o="' + oi + '"' + off + '>' + ctx.inline(o) + '</button>'; });
    h += '</div>';
    if (multi) h += '<div class="btn-row" style="margin-bottom:8px"><button class="btn primary" data-act="ask-submit"' + (off || (F.selected.length ? '' : ' disabled')) + '>Submit</button></div>';
    if (free) h += '<div class="free"><textarea placeholder="Or type your own answer…" data-ask-text' + off + '>' + ctx.esc(F.text || '') + '</textarea><button class="btn primary" data-act="ask-submit"' + off + '>' + (F.sent ? 'Sent' : 'Send') + '</button></div>';
    h += '<div class="ask-foot"><button class="btn link" data-act="q-skip"' + off + '>Skip</button></div>';
    return h + '</div>';
  }

  R.registerToolCard('quiz', (b, r, pend, ctx) => renderForm(b, r, pend, ctx, true));
  R.registerToolCard('ask_learner', (b, r, pend, ctx) => {
    const qs = (b.input && b.input.questions) || (pend && pend.payload && pend.payload.questions);
    const graded = !!((b.input && b.input.graded) || (r && r.meta && r.meta.graded));
    return qs ? renderForm(b, r, pend, ctx, graded) : renderQuick(b, r, pend, ctx);
  });

  // ── Actions & inputs ─────────────────────────────────────────────────
  const toolOf = el => { const t = el.closest('[data-tool-id]'); return t ? t.getAttribute('data-tool-id') : null; };
  const qi = el => +el.getAttribute('data-q');
  const questionsOf = (id, ctx) => {
    const el = document.querySelector('[data-tool-id="' + CSS.escape(id) + '"]');
    if (!el || !el._block) return [];
    const p = ctx.pending(id), pl = p && p.payload;
    return normalize((el._block.input && el._block.input.questions) || (pl && pl.questions) || []);
  };
  const inputOf = (id, card, ctx) => { const p = ctx.pending(id); return Object.assign({}, p && p.payload, card._block.input); };
  // A send locks the card until the interaction ends; if the app asks again (new pending object), it unlocks.
  const lock = (F, ctx, id) => { F.sent = true; F.sentFor = ctx.pending(id); };
  const locked = (F, pend) => { if (F.sent && F.sentFor !== pend) F.sent = false; return !!F.sent; };
  R.registerAction('q-pick', (el, e, ctx) => { e.preventDefault(); const id = toolOf(el); const F = state(id); F.answers[qi(el)] = +el.getAttribute('data-o'); ctx.refreshCard(id); });
  R.registerAction('q-toggle', (el, e, ctx) => {
    e.preventDefault(); const id = toolOf(el), F = state(id), q = qi(el), o = +el.getAttribute('data-o');
    const cur = Array.isArray(F.answers[q]) ? F.answers[q] : [];
    const max = (questionsOf(id, ctx)[q] || {}).max_select;
    if (cur.includes(o)) F.answers[q] = cur.filter(x => x !== o);
    else F.answers[q] = (max && cur.length >= max ? cur.slice(1) : cur).concat([o]).sort((a, b) => a - b);
    ctx.refreshCard(id);
  });
  R.registerAction('q-tf', (el, e, ctx) => { const id = toolOf(el); state(id).answers[qi(el)] = el.getAttribute('data-v') === 'true'; ctx.refreshCard(id); });
  R.registerAction('q-scale', (el, e, ctx) => { const id = toolOf(el); state(id).answers[qi(el)] = +el.getAttribute('data-v'); ctx.refreshCard(id); });
  R.registerAction('q-hint', (el, e, ctx) => { const id = toolOf(el), F = state(id), q = qi(el); F.hints[q] = (+F.hints[q] || 0) + 1; ctx.refreshCard(id); });
  R.registerAction('q-sure', (el, e, ctx) => {
    const id = toolOf(el), F = state(id), q = qi(el), v = +el.getAttribute('data-v');
    F.certainty[q] = F.certainty[q] === v ? undefined : v; ctx.refreshCard(id);
  });
  R.registerAction('q-move', (el, e, ctx) => {
    const id = toolOf(el), F = state(id), q = qi(el), pos = +el.getAttribute('data-pos'), d = +el.getAttribute('data-d');
    const order = F.perms[q]; const j = pos + d;
    if (!order || j < 0 || j >= order.length) return;
    [order[pos], order[j]] = [order[j], order[pos]];
    F.answers[q] = order.slice();
    ctx.refreshCard(id);
  });
  // A form's Skip asks why first (the teacher teaches more, raises the bar or moves on accordingly); a quick question skips at once.
  R.registerAction('q-skip', (el, e, ctx) => {
    const id = toolOf(el), F = state(id); if (locked(F, ctx.pending(id))) return;
    if (el.closest('.quiz')) { F.skipAsk = true; ctx.refreshCard(id); return; }
    lock(F, ctx, id); el.disabled = true;
    ctx.post({ type: 'answer', id, value: { cancelled: true } });
  });
  R.registerAction('q-skip-back', (el, e, ctx) => { const id = toolOf(el); state(id).skipAsk = false; ctx.refreshCard(id); });
  R.registerAction('q-skip-why', (el, e, ctx) => {
    const id = toolOf(el), F = state(id); if (locked(F, ctx.pending(id))) return;
    lock(F, ctx, id); F.skipAsk = false; ctx.refreshCard(id);
    ctx.post({ type: 'answer', id, value: { cancelled: true, reason: el.getAttribute('data-v') } });
  });
  R.registerAction('q-submit', (el, e, ctx) => {
    const id = toolOf(el), F = state(id);
    const card = el.closest('[data-tool-id]');
    collect(card, F);
    if (!validate(card, F, questionsOf(id, ctx))) return;
    const n = card.querySelectorAll('.quiz-q').length;
    const answers = Array.from({ length: n }, (_, i) => {
      let a = F.answers[i];
      if (a === undefined || a === '') a = (F.other[i] || '').trim() || null;
      return a === undefined ? null : a;
    });
    if (locked(F, ctx.pending(id))) return;
    lock(F, ctx, id); el.disabled = true; el.textContent = 'Sent';
    ctx.post({ type: 'answer', id, value: { answers, hints: Array.from({ length: n }, (_, i) => +F.hints[i] || 0),
      certainty: Array.from({ length: n }, (_, i) => F.certainty[i] ?? null), seconds: (Date.now() - F.started) / 1000 } });
  });

  // ── Stuck: after a quiet spell the first hint opens by itself (once per form), on the first unanswered question that has one ──
  const STALL_MS = 75000;
  ['input', 'pointerdown', 'keydown'].forEach(t => document.addEventListener(t, e => {
    const card = e.target && e.target.closest && e.target.closest('[data-tool-id]');
    const F = card && forms.get(card.getAttribute('data-tool-id'));
    if (F) F.touched = Date.now();
  }, true));
  function nudgeStuck(now) {
    if (document.hidden) return;
    forms.forEach((F, id) => {
      if (!F.active || !F.ctx || F.nudged != null || now - (F.touched || F.started) < STALL_MS) return;
      if (!document.querySelector('[data-tool-id="' + CSS.escape(id) + '"]')) return;
      const k = questionsOf(id, F.ctx).findIndex((q, i) => ladder(q).length && !(+F.hints[i]) && blank(F.answers[i]));
      if (k < 0) return;
      F.nudged = k; F.hints[k] = 1; F.ctx.refreshCard(id);
    });
  }
  setInterval(() => nudgeStuck(Date.now()), 5000);
  R.registerAction('ask-opt', (el, e, ctx) => {
    const id = toolOf(el), F = state(id), o = +el.getAttribute('data-o'), card = el.closest('[data-tool-id]');
    const input = inputOf(id, card, ctx);
    if (locked(F, ctx.pending(id))) return;
    const ta = card.querySelector('[data-ask-text]'); if (ta) F.text = ta.value;
    if (input.multi_select) { F.selected = F.selected.includes(o) ? F.selected.filter(x => x !== o) : F.selected.concat([o]); ctx.refreshCard(id); return; }
    lock(F, ctx, id); F.selected = [o]; ctx.refreshCard(id);
    ctx.post({ type: 'answer', id, value: { selected: [input.options[o]], text: (F.text || '').trim() } });
  });
  R.registerAction('ask-submit', (el, e, ctx) => {
    const id = toolOf(el), F = state(id), card = el.closest('[data-tool-id]');
    if (locked(F, ctx.pending(id))) return;
    const ta = card.querySelector('[data-ask-text]'); if (ta) F.text = ta.value;
    const opts = inputOf(id, card, ctx).options || [];
    if (!F.selected.length && !(F.text || '').trim()) { if (ta) ta.focus(); return; }
    lock(F, ctx, id); ctx.refreshCard(id);
    ctx.post({ type: 'answer', id, value: { selected: F.selected.map(i => opts[i]), text: (F.text || '').trim() } });
  });
  R.registerAction('q-pen', (el) => {
    const c = el.closest('.draw').querySelector('canvas'), F = state(toolOf(el));
    c._pen = el.getAttribute('data-c'); (F.pen = F.pen || {})[+c.getAttribute('data-q')] = c._pen;
  });
  R.registerAction('q-clear', (el) => {
    const c = el.closest('.draw').querySelector('canvas'); const id = toolOf(el);
    c.getContext('2d').clearRect(0, 0, c.width, c.height); const F = state(id); F.answers[qi(el)] = undefined; if (F.raw) F.raw[qi(el)] = null;
  });

  // ── Typed input: numbers accept only numeric characters; text has length bounds and an optional pattern ──
  const limit = (q, multiline) => Math.max(1, Math.min(+q.max_length || (multiline ? 5000 : 300), 100000));
  // Integer fields still accept "." and "," so the learner sees why 12.5 isn't allowed instead of getting 125.
  const NUM_CHARS = { num: /[^0-9.,+\-eE\/ \u0660-\u0669\u06F0-\u06F9\uFF10-\uFF19\u0966-\u096F]/g, int: /[^0-9.,\-\u0660-\u0669\u06F0-\u06F9\uFF10-\uFF19\u0966-\u096F]/g };
  /** Arabic-Indic, Persian, full-width and Devanagari digits → 0-9. */
  const normDigits = s => String(s).replace(/[\u0660-\u0669\u06F0-\u06F9\uFF10-\uFF19\u0966-\u096F]/g, c => {
    const k = c.charCodeAt(0);
    return String(k - (k >= 0xFF10 ? 0xFF10 : k >= 0x0966 ? 0x0966 : k >= 0x06F0 ? 0x06F0 : 0x0660));
  });
  /** A number from what the learner typed: 3.5, -2, 1/2, 2,5 (decimal comma), 1e3; NaN when it isn't one. */
  function toNumber(s) {
    s = normDigits(s).trim().replace(/\s+/g, '');
    if (!s) return NaN;
    if (/^[+-]?\d{1,3}(,\d{3})+(\.\d+)?$/.test(s)) s = s.replace(/,/g, '');   // 1,234.5
    const frac = /^([+-]?\d+(?:\.\d+)?)\/(\d+(?:\.\d+)?)$/.exec(s);
    if (frac) return +frac[2] ? +frac[1] / +frac[2] : NaN;
    if (/^[+-]?\d+,\d+$/.test(s)) s = s.replace(',', '.');
    else s = s.replace(/,(?=\d{3}(\D|$))/g, '');
    return /^[+-]?(\d+\.?\d*|\.\d+)(e[+-]?\d+)?$/i.test(s) ? Number(s) : NaN;
  }
  /** The problem with one field's value, or '' — what the learner sees under the field. */
  function problem(inp) {
    const v = inp.value, kind = inp.getAttribute('data-numeric');
    if (kind) {
      if (!v.trim()) return '';
      const n = toNumber(v);
      if (Number.isNaN(n)) return 'Enter a number' + (kind === 'int' ? ' (whole number)' : ' (e.g. 3.5, -2, 1/2)');
      if (kind === 'int' && !Number.isInteger(n)) return 'Enter a whole number';
      const lo = inp.getAttribute('data-min'), hi = inp.getAttribute('data-max');
      if (lo != null && n < +lo) return 'Must be at least ' + lo;
      if (hi != null && n > +hi) return 'Must be at most ' + hi;
      return '';
    }
    const minlen = +inp.getAttribute('data-minlen') || 0, pat = inp.getAttribute('data-pattern');
    if (v.trim() && v.trim().length < minlen) return 'At least ' + minlen + ' characters';
    if (v.trim() && pat) { try { if (!new RegExp('^(?:' + pat + ')$').test(v.trim())) return FORMAT_HINT; } catch (_) {} }
    return '';
  }
  function showProblem(card, inp, force) {
    const qi = inp.getAttribute('data-q-input'), msg = problem(inp);
    const show = msg && (force || inp._touched);
    inp.classList.toggle('invalid', !!show);
    inp.setAttribute('aria-invalid', show ? 'true' : 'false');
    const e = card.querySelector('[data-err="' + qi + '"]'); if (e) e.textContent = show ? msg : '';
    return msg;
  }
  /** Checks every field; marks the bad ones and focuses the first. True when the form can be sent. */
  // A pattern only hints at the shape: models also write the accepted answers as one ("1/4|one quarter"), and a learner
  // who is wrong must still be able to hand in an answer. Numbers and length limits do block.
  const FORMAT_HINT = 'Doesn\'t look like the expected format (you can still submit)';
  function validate(card, F, qs) {
    let first = null;
    card.querySelectorAll('[data-q-input]').forEach(inp => { const msg = showProblem(card, inp, true); if (msg && msg !== FORMAT_HINT && !first) first = inp; });
    if (first) { first.focus(); return false; }
    // Nothing answered at all: say so instead of sending an empty form (Skip is the way to pass).
    const answered = (qs || []).some((q, i) => F.certainty[i] === 0 || (q.type !== 'ordering' && q.type !== 'scale' && !blank(F.answers[i])))
      || (qs || []).every(q => q.type === 'ordering' || q.type === 'scale');
    const foot = card.querySelector('.quiz-foot');
    let note = card.querySelector('.q-empty');
    if (!answered && foot) {
      if (!note) { note = document.createElement('div'); note.className = 'q-empty'; foot.prepend(note); }
      note.textContent = 'Answer at least one question, or use Skip.';
      return false;
    }
    if (note) note.remove();
    return true;
  }
  document.addEventListener('beforeinput', e => {
    const t = e.target; if (!t || !t.getAttribute || !t.getAttribute('data-numeric') || !e.data) return;
    if (NUM_CHARS[t.getAttribute('data-numeric')].test(e.data)) e.preventDefault();   // letters never get in
    NUM_CHARS[t.getAttribute('data-numeric')].lastIndex = 0;
  }, true);
  document.addEventListener('focusout', e => {
    const t = e.target; if (!t || !t.hasAttribute || !t.hasAttribute('data-q-input')) return;
    const card = t.closest('[data-tool-id]'); if (!card) return;
    t._touched = true; showProblem(card, t);
  }, true);

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
    const kind = t.getAttribute && t.getAttribute('data-numeric');
    if (kind && (NUM_CHARS[kind].test(t.value) || /[\u0660-\u0669\u06F0-\u06F9\uFF10-\uFF19\u0966-\u096F]/.test(t.value))) {
      NUM_CHARS[kind].lastIndex = 0; t.value = normDigits(t.value.replace(NUM_CHARS[kind], ''));   // pasted text, other digit scripts
    }
    if (kind) NUM_CHARS[kind].lastIndex = 0;
    if (t.hasAttribute('data-q-input')) {
      const c = card.querySelector('[data-count="' + t.getAttribute('data-q-input') + '"]');
      if (c) c.textContent = t.value.length + ' / ' + t.getAttribute('maxlength');
      if (t._touched) showProblem(card, t);
    }
    const F = state(card.getAttribute('data-tool-id'));
    collect(card, F);
    if (t.hasAttribute('data-ask-text')) F.text = t.value;
    if (t.hasAttribute('data-q-other')) {
      const q = +t.getAttribute('data-q-other');
      if (t.value.trim()) {
        F.answers[q] = t.value;
        card.querySelectorAll('.opt[data-q="' + q + '"]').forEach(o => { o.classList.remove('sel'); o.setAttribute('aria-checked', 'false'); const r = o.querySelector('input'); if (r) r.checked = false; });
      } else if (typeof F.answers[q] === 'string') F.answers[q] = undefined;
    }
    if (t.getAttribute('data-math')) {
      const pv = card.querySelector('[data-preview="' + t.getAttribute('data-q-input') + '"]');
      if (pv) pv.innerHTML = t.value.trim() ? ctx.tex(t.value, true) : '<span class="muted">Preview appears here</span>';
    }
    if (t.matches('textarea.mono') && e.type === 'keydown') return;
  });
  document.addEventListener('keydown', (e) => {
    const t = e.target;
    if (t.matches && t.matches('label.opt[tabindex]') && (e.key === ' ' || e.key === 'Enter')) { e.preventDefault(); t.click(); return; }
    if (t.matches && t.matches('label.opt[tabindex]') && /^Arrow(Down|Up|Left|Right)$/.test(e.key)) {
      const opts = Array.from(t.closest('.quiz-q').querySelectorAll('label.opt[tabindex]'));
      const j = opts.indexOf(t) + (e.key === 'ArrowDown' || e.key === 'ArrowRight' ? 1 : -1);
      if (opts[j]) { e.preventDefault(); opts[j].focus(); }
      return;
    }
    if (t.matches && t.matches('textarea.mono') && e.key === 'Escape') { t.blur(); return; }
    if (t.matches && t.matches('textarea.mono') && e.key === 'Tab' && !e.shiftKey) {
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
      // Re-renders restore the transparent strokes (not the white-backed export) and keep the chosen pen.
      F.raw = F.raw || {}; F.pen = F.pen || {};
      if (F.raw[q]) { const im = new Image(); im.onload = () => g.drawImage(im, 0, 0); im.src = F.raw[q]; }
      if (F.pen[q]) c._pen = F.pen[q];
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
        F.raw[q] = c.toDataURL('image/png');
      };
      c.addEventListener('pointerup', end); c.addEventListener('pointerleave', end); c.addEventListener('pointercancel', end);
    });
  });

  window.TeacherForms = { state, normalize, nudgeStuck, STALL_MS };
})();
