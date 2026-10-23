// The transcript's internal AST: a typed projection of what Swift sends (messages of blocks, tool results as separate
// messages) that the renderer consumes. The event stream and the stored blocks stay the source of truth; this is a
// materialised view with stable node ids and explicit tool-call → result links, built per message, cheaply.
//
//   message { id, role, draft, reviewIssues, error, turn, children: [node] }
//   node    { id, type, version, index, props, meta: { hidden } }
//   types   text (a markdown leaf) · thinking · tool (call + status + result ref) · attachment · agentReport · error
//
// Everything richer (a chart, a quiz, a visual) is a component rendered inside a text leaf or a tool card, not a node
// type: the vocabulary here stays small so the renderer, search and export never need a switch per feature.
(function () {
  'use strict';
  const VERSION = 1;
  const TYPES = ['message', 'text', 'thinking', 'tool', 'attachment', 'agentReport', 'error'];

  /** Stable id for a block: tool calls by their call id, the rest by position (positions only ever grow while a reply
   *  streams, and inserted hidden context goes at the front of a learner message, never a reply). */
  const nodeId = (m, b, i) => m.id + ':' + (b.kind === 'toolUse' && b.id ? b.id : 'b' + i);

  /** The status of a tool call from its block and (when it arrived) its result. */
  function toolStatus(b, result) {
    if (b.meta && b.meta.pending) return 'pending';
    if (!result) return 'running';
    if (result.meta && result.meta.running) return 'running';
    return result.isError ? 'error' : 'done';
  }

  /** `lookup` resolves what lives outside the message: `result(callId)`, `pending(callId)` (an interaction waiting for
   *  the learner), `progress(callId)` (streamed output of a tool still running). All optional. */
  function toNodes(m, lookup) {
    const L = Object.assign({ result: () => null, pending: () => null, progress: () => '' }, lookup || {});
    const children = [];
    (m.blocks || []).forEach((b, i) => {
      const meta = { hidden: !!(b.meta && b.meta.hidden) };
      const base = { id: nodeId(m, b, i), version: VERSION, index: i, meta };
      switch (b.kind) {
        case 'text':
          if (b.meta && b.meta.backgroundTask) {
            const r = b.meta;
            children.push(Object.assign(base, { type: 'agentReport', props: { agent: '', task: true, handle: r.backgroundTask, title: r.title || '', state: r.exit === 0 ? 'done' : 'failed (exit ' + r.exit + ')',
              seconds: r.seconds, text: (b.text || '').replace(/^<background-task[^>]*>\n?|\n?<\/background-task>\s*$/g, '') } }));
          } else if (b.meta && b.meta.agentReport) {
            const r = b.meta;
            children.push(Object.assign(base, { type: 'agentReport', props: { agent: r.agentReport, handle: r.handle || '', title: r.title || '', state: r.state || 'done',
              text: (b.text || '').replace(/^<background-agent[^>]*>\n?|\n?<\/background-agent>\s*$/g, '') } }));
          } else children.push(Object.assign(base, { type: 'text', props: { markdown: b.text || '' } }));
          break;
        case 'thinking':
          children.push(Object.assign(base, { type: 'thinking', props: { text: b.text || '' } }));
          break;
        case 'toolUse': {
          const result = L.result(b.id);
          children.push(Object.assign(base, { type: 'tool', props: {
            callId: b.id, name: b.name || '', input: b.input || {}, status: toolStatus(b, result),
            resultRef: result ? result.id : null, result: result || null,
            output: result ? (result.text || '') : (L.progress(b.id) || ''),
            interaction: L.pending(b.id) || null,
          }, block: b }));
          break;
        }
        case 'image': case 'file':
          children.push(Object.assign(base, { type: 'attachment', props: { kind: b.kind, name: b.name || '', mime: b.mime || '', blob: b.blob || '', data: b.data || '', text: b.text || '' } }));
          break;
        case 'toolResult':
          break;   // results hang off their tool node (resultRef); a result-only message has no nodes of its own
        default:
          children.push(Object.assign(base, { type: 'error', props: { message: 'This part of the reply (' + String(b.kind) + ') cannot be shown by this version of the app.', block: b.kind } }));
      }
    });
    return { id: m.id, type: 'message', version: VERSION, role: m.role, draft: !!(m.meta && m.meta.superseded),
      reviewIssues: (m.meta && m.meta.reviewIssues) || [], error: m.error || null, turn: m.turn || null, children };
  }

  /** The text a reader (or the model, or search) should see: visible text leaves, in order. */
  function textOf(node) {
    const kids = node.children || [];
    return kids.filter(n => n.type === 'text' && !n.meta.hidden).map(n => n.props.markdown).join('\n');
  }

  /** The tool calls of a message with their results, for anything that needs the graph rather than the tree. */
  function toolsOf(node) { return (node.children || []).filter(n => n.type === 'tool'); }

  const AST = { VERSION, TYPES, nodeId, toNodes, textOf, toolsOf, toolStatus };
  window.TeacherAST = AST;
  if (window.TeacherUI) window.TeacherUI.ast = AST;
})();
