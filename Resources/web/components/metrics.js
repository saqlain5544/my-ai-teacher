// Response & memory metadata: compact footer under each finished turn, expandable details, memory chips, toasts.
(function () {
  'use strict';
  const R = window.TeacherUI;
  const open = new Set();
  // 950 · 12.4k · 3.61M: large counts in millions, never "3609.8k".
  const k = n => n == null ? '—' : n >= 1e7 ? (n / 1e6).toFixed(1) + 'M' : n >= 1e6 ? (n / 1e6).toFixed(2) + 'M'
    : n >= 10000 ? (n / 1000).toFixed(1).replace(/\.0$/, '') + 'k' : n >= 1000 ? (n / 1000).toFixed(1) + 'k' : String(Math.round(n));
  const sec = s => s == null ? '—' : s < 1 ? Math.round(s * 1000) + ' ms' : s < 60 ? s.toFixed(1) + ' s' : Math.floor(s / 60) + 'm ' + Math.round(s % 60) + 's';
  const tps = st => {
    const gen = (st.duration || 0) - (st.timeToFirstToken || 0);
    return st.usage && st.usage.output > 1 && gen > 0.05 ? (st.usage.output - 1) / gen : null;
  };
  const LANG_NAMES = { en: 'English', ar: 'Arabic', es: 'Spanish', fr: 'French', de: 'German', it: 'Italian', pt: 'Portuguese', ja: 'Japanese', zh: 'Chinese', ko: 'Korean',
    hi: 'Hindi', ur: 'Urdu', fa: 'Persian', he: 'Hebrew', ru: 'Russian', tr: 'Turkish', nl: 'Dutch', el: 'Greek', th: 'Thai', bn: 'Bengali', id: 'Indonesian', vi: 'Vietnamese', pl: 'Polish', sv: 'Swedish' };
  const langName = l => LANG_NAMES[l] || l;

  R.registerFooter((m, turnMsgs, userMsg, ctx) => {
    const t = m.turn; if (!t) return '';
    const steps = turnMsgs.map(x => x.metrics).filter(Boolean);
    const last = steps[steps.length - 1] || {};
    const u = t.usage || {};
    const totalTok = (u.input || 0) + (u.cacheRead || 0) + (u.cacheWrite || 0) + (u.output || 0);
    const speeds = steps.map(tps).filter(Boolean);
    const speed = speeds.length ? speeds.reduce((a, b) => a + b, 0) / speeds.length : null;
    const recalled = userMsg && userMsg.meta && userMsg.meta.recalled || [];
    const parts = [];
    parts.push('<span title="Model">' + ctx.esc(last.model || m.model || '') + '</span>');
    parts.push('<span title="Total time for this reply">⏱ ' + sec(t.duration) + '</span>');
    if (speed) parts.push('<span title="Average decode speed (excludes time to first token)">⚡ ' + Math.round(speed) + ' tok/s</span>');
    const inTok = totalTok - (u.output || 0), est = steps.some(s => s.usageEstimated) ? '*' : '';
    parts.push('<span title="Input tokens across every model call (including cached), and output tokens">' + k(inTok) + ' in · ' + k(u.output || 0) + ' out' + est + '</span>');
    if (t.tools && t.tools.length) parts.push('<span title="Tool calls">🔧 ' + t.tools.length + '</span>');
    if (t.steps > 1) parts.push('<span title="Model calls in this turn">' + t.steps + ' steps</span>');
    const chips = [];
    if (recalled.length) chips.push('<button class="chip-mem" data-act="metrics-toggle">🧠 Used ' + recalled.length + ' memor' + (recalled.length === 1 ? 'y' : 'ies') + '</button>');
    if (t.memoryWrites) chips.push('<button class="chip-mem" data-act="open-memory">🧠 Memory updated (' + t.memoryWrites + ')</button>');
    if (t.languages && t.languages.length > 1) chips.push('<span class="chip-lang" title="Languages in this reply">🌐 ' + t.languages.map(langName).join(' · ') + '</span>');
    const isOpen = open.has(m.id);
    let h = '<div class="turn-meta"><button class="meta-line" data-act="metrics-toggle" title="Show details">' + parts.join('<i>·</i>') + '<span class="meta-caret">' + (isOpen ? '▾' : '▸') + '</span></button>' + chips.join('') + '</div>';
    if (isOpen) h += details(t, steps, recalled, ctx);
    return h;
  });

  function details(t, steps, recalled, ctx) {
    const u = t.usage || {};
    const promptTotal = (u.input || 0) + (u.cacheRead || 0) + (u.cacheWrite || 0);
    const hit = promptTotal ? Math.round((u.cacheRead || 0) / promptTotal * 100) : null;
    let h = '<div class="metrics-panel">';
    h += '<div class="mp-grid">' +
      cell('Total time', sec(t.duration)) + cell('First token', sec(t.timeToFirstToken)) + cell('Model time', sec(steps.reduce((a, s) => a + (s.duration || 0), 0))) +
      cell('Tool time', sec((t.tools || []).reduce((a, x) => a + (x.duration || 0) - (x.waitedForLearner || 0), 0))) +
      cell('Input', k(u.input)) + cell('Cached', k(u.cacheRead) + (hit != null ? ' (' + hit + '%)' : '')) + cell('Cache write', k(u.cacheWrite)) +
      cell('Output', k(u.output)) + cell('Reasoning', u.reasoningTokens != null ? k(u.reasoningTokens) : '—') + cell('Finish', (steps[steps.length - 1] || {}).finishReason || '—') +
      '</div>';
    // Step waterfall
    const t0 = new Date((steps[0] || {}).startedAt ? (steps[0].startedAt * 1000) : 0).getTime();
    const total = Math.max(0.001, t.duration || 0);
    h += '<div class="mp-title">Steps</div><table class="mp-steps"><thead><tr><th>#</th><th>Timeline</th><th>TTFT</th><th>Time</th><th>Out</th><th>tok/s</th><th>Tools</th><th>Finish</th></tr></thead><tbody>';
    steps.forEach((s, i) => {
      const start = s.startedAt ? ((s.startedAt * 1000) - t0) / 1000 : 0;
      const left = Math.max(0, Math.min(100, (start / total * 100) || 0)), width = Math.max(1.5, (s.duration || 0) / total * 100);
      const ttftW = s.timeToFirstToken ? Math.min(width, s.timeToFirstToken / total * 100) : 0;
      const sp = tps(s);
      h += '<tr><td>' + (i + 1) + '</td><td class="wf"><div class="wf-bar" style="left:' + left + '%;width:' + width + '%"><div class="wf-ttft" style="width:' + (width ? ttftW / width * 100 : 0) + '%"></div></div></td>' +
        '<td>' + sec(s.timeToFirstToken) + '</td><td>' + sec(s.duration) + '</td><td>' + k(s.usage && s.usage.output) + (s.usageEstimated ? '*' : '') + '</td><td>' + (sp ? Math.round(sp) : '—') + '</td><td>' + (s.toolCalls || 0) + '</td><td>' + ctx.esc(s.finishReason || '') + (s.retries ? ' ↻' + s.retries : '') + '</td></tr>';
    });
    h += '</tbody></table>';
    if (t.tools && t.tools.length) {
      const byName = {};
      t.tools.forEach(x => { const b = byName[x.name] = byName[x.name] || { n: 0, d: 0, fail: 0, wait: 0 }; b.n++; b.d += x.duration || 0; if (!x.ok) b.fail++; b.wait += x.waitedForLearner || 0; });
      h += '<div class="mp-title">Tools</div><div class="mp-tools">' + Object.keys(byName).map(n => {
        const b = byName[n];
        return '<span class="pill">' + ctx.esc(n) + ' ×' + b.n + ' · ' + sec(b.d - b.wait) + (b.wait > 0.5 ? ' (+' + sec(b.wait) + ' you)' : '') + (b.fail ? ' · ' + b.fail + ' failed' : '') + '</span>';
      }).join('') + '</div>';
    }
    if (recalled.length) {
      h += '<div class="mp-title">Memories used</div><ul class="mp-mem">' + recalled.map(r => '<li><span class="mem-id">#' + ctx.esc(r.id) + '</span> <span class="mem-kind">' + ctx.esc(r.kind) + '</span> ' + ctx.esc(r.content) + (r.score != null ? ' <span class="mem-score">' + Math.round(r.score * 100) + '%</span>' : '') + '</li>').join('') + '</ul>';
    }
    if (t.languages && t.languages.length) h += '<div class="mp-title">Languages</div><div>' + t.languages.map(langName).join(', ') + '</div>';
    if (steps.some(s => s.usageEstimated)) h += '<div class="mp-note">* The provider didn’t report usage; output estimated from length.</div>';
    h += '<div class="mp-actions"><button class="btn" data-act="copy-metrics">Copy raw metrics</button><button class="btn" data-act="open-memory">Open Memory</button></div>';
    return h + '</div>';
  }
  const cell = (label, value) => '<div class="mp-cell"><div class="mp-l">' + label + '</div><div class="mp-v">' + value + '</div></div>';

  R.registerAction('metrics-toggle', (el, e, ctx) => {
    const msg = el.closest('.msg'); if (!msg) return;
    const id = msg.id.slice(2);
    if (open.has(id)) open.delete(id); else open.add(id);
    ctx.rerender(id);
  });
  R.registerAction('open-memory', (el, e, ctx) => ctx.post({ type: 'memory' }));
  R.registerAction('copy-metrics', (el, e, ctx) => {
    const msg = el.closest('.msg'); const rec = msg && ctx.message(msg.id.slice(2));
    if (rec) ctx.post({ type: 'copy', text: JSON.stringify({ turn: rec.turn, steps: ctx.turnMessages(rec.id).map(m => m.metrics) }, null, 2) });
    ctx.flash(el, 'Copied');
  });

  // Toasts (memory updates, compaction notices…)
  let toastTimer = 0;
  window.TeacherToast = (text) => {
    let el = document.getElementById('toast');
    if (!el) { el = document.createElement('div'); el.id = 'toast'; document.body.appendChild(el); }
    el.textContent = text;
    el.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove('show'), 4200);
  };
})();
