// Renderer stress for scripts/perf: run by `MyAITeacher --webtest scripts/perf/render-stress.js` in the app's own WebKit
// (offscreen, rAF running). Each case logs one "PERFJSON {…}" line with its timings; nothing here asserts, it measures.
(async function () {
  'use strict';
  const send = m => window.webkit.messageHandlers.bridge.postMessage(Object.assign({ type: 'webtest' }, m));
  const log = text => send({ event: 'log', text: String(text) });
  const report = (name, data) => log('PERFJSON ' + JSON.stringify(Object.assign({ case: name }, data)));
  const frame = () => new Promise(r => requestAnimationFrame(() => r()));
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const pct = (xs, p) => { const s = xs.slice().sort((a, b) => a - b); return s.length ? s[Math.min(s.length - 1, Math.floor(p * s.length))] : 0; };
  const stats = xs => ({ frames: xs.length, p50_ms: +pct(xs, 0.5).toFixed(1), p95_ms: +pct(xs, 0.95).toFixed(1), max_ms: +Math.max(0, ...xs).toFixed(1) });

  // The same shape as PerfSeed.message in DebugHooks.swift: question, tool step, tool result, rich reply.
  function lesson(n) {
    const out = [];
    for (let i = 0; i < n; i++) {
      const t = Math.floor(i / 4), k = t % 7 + 2, call = 'perf_' + t;
      if (i % 4 === 0) out.push({ id: 'm' + i, role: 'user', blocks: [{ kind: 'text', text: 'Question ' + t + ': how does the chain rule apply to sin(x^' + k + ')?' }] });
      else if (i % 4 === 1) out.push({ id: 'm' + i, role: 'assistant', blocks: [{ kind: 'text', text: 'Let me check a reference first.' }, { kind: 'toolUse', id: call, name: 'web_fetch', input: { url: 'https://example.org/' + t } }] });
      else if (i % 4 === 2) out.push({ id: 'm' + i, role: 'user', blocks: [{ kind: 'toolResult', id: call, name: 'web_fetch', text: 'The chain rule says… '.repeat(t % 10 === 0 ? 400 : 60) }] });
      else out.push({ id: 'm' + i, role: 'assistant', model: 'perf', turn: { duration: 6.5, steps: 2, tools: [], usage: { input: 4200, output: 520, cacheRead: 0, cacheWrite: 0 } },
        blocks: [{ kind: 'text', text: section(t) + (t % 25 === 0 ? '\n\n```mermaid\nflowchart LR\n  A[outer f] --> B[inner g]\n```' : '') }] });
    }
    return out;
  }
  function section(t) {
    const k = t % 7 + 2;
    return '## Step ' + t + ': the chain rule\n\nFor $f(x) = \\sin(x^{' + k + '})$ the outer function is $\\sin u$, so\n\n$$f\'(x) = \\cos(x^{' + k + '}) \\cdot ' + k + 'x^{' + (k - 1) + '}$$\n\n' +
      '1. **Differentiate the outer function**.\n2. **Multiply** by the inner derivative.\n3. Check at $x = 1$.\n\n```python\nimport math\nprint(math.cos(1) * ' + k + ')\n```\n\n' +
      '| x | f(x) |\n|---|---|\n| 0 | 0 |\n| 1 | 0.841 |\n\nTry it yourself: what is the derivative of $\\cos(3x^2)$?\n\n';
  }
  const nodes = () => document.getElementsByTagName('*').length;

  async function resetCase(n) {
    T.status('', false);
    const msgs = lesson(n);
    const t0 = performance.now(); T.reset(msgs, {}); const sync = performance.now() - t0;
    await frame(); const painted = performance.now() - t0;
    report('reset-' + n, { reset_ms: +sync.toFixed(0), painted_ms: +painted.toFixed(0), rendered: document.querySelectorAll('.msg').length, nodes: nodes() });
  }

  async function streamCase(chars, perFrame) {
    T.reset([{ id: 'q', role: 'user', blocks: [{ kind: 'text', text: 'question' }] }], {});
    const a = { id: 'stream', role: 'assistant', blocks: [] };
    T.status('Thinking…', true); T.upsert(a);
    let text = '', t = 0;
    while (text.length < chars) text += section(t++);
    text = text.slice(0, chars);
    const times = []; const t0 = performance.now();
    let last = performance.now();
    for (let i = 0; i < text.length; i += perFrame) {
      T.delta(a.id, 0, 'text', text.slice(i, i + perFrame));
      await frame();
      const now = performance.now(); times.push(now - last); last = now;
    }
    T.status('', false); await sleep(200);
    report('stream-' + Math.round(chars / 1000) + 'k', Object.assign(stats(times), { total_ms: +(performance.now() - t0).toFixed(0), nodes: nodes() }));
  }

  async function prependCase() {
    // Paging in earlier messages re-renders the window from the top (ChatSession.loadEarlier → sink.reset).
    const all = lesson(1400), ms = [];
    for (let shown = 400; shown <= 1400; shown += 200) {
      const t0 = performance.now(); T.reset(all.slice(all.length - shown), { earlier: all.length - shown }); ms.push(+(performance.now() - t0).toFixed(0));
      await frame();
    }
    report('prepend', { steps: ms, max_ms: Math.max(...ms), nodes: nodes() });
  }

  async function toolChurnCase(n) {
    T.reset([{ id: 'q', role: 'user', blocks: [{ kind: 'text', text: 'question' }] }], {});
    T.status('Working…', true);
    const times = []; let last = performance.now();
    for (let i = 0; i < n; i++) {
      const id = 'tc' + i;
      T.upsert({ id: 'a' + i, role: 'assistant', blocks: [{ kind: 'toolUse', id, name: 'read', input: { path: '/tmp/f' + i } }] });
      T.upsert({ id: 'r' + i, role: 'user', blocks: [{ kind: 'toolResult', id, name: 'read', text: 'line\n'.repeat(200) }] });
      await frame();
      const now = performance.now(); times.push(now - last); last = now;
    }
    T.status('', false);
    report('tool-churn-' + n, Object.assign(stats(times), { nodes: nodes() }));
  }

  const cases = [() => resetCase(400), () => resetCase(2000), () => streamCase(60000, 240), prependCase, () => toolChurnCase(300)];
  let passed = 0;
  for (const c of cases) { send({ event: 'start', name: 'stress' }); await c(); passed++; await sleep(300); }
  T.reset([], {});
  send({ event: 'done', passed, failed: 0, expectedErrors: [] });
})();
