// Tool cards for sub-agents: `task` (one sub-agent, with Open/Stop in the card's head) and `agents` (managing them).
(function () {
  'use strict';
  const R = window.TeacherUI;
  const input = n => n.props.input || {};
  const meta = n => (n.props.result && n.props.result.meta) || {};

  R.defineTool({
    name: 'task', icon: '🧭', title: 'Sub-agent',
    summary: n => { const i = input(n); return (i.resume ? '↻ ' + i.resume + ' · ' : '') + (i.description || '') + (i.model ? ' · ' + i.model : ''); },
    // Open the live transcript in the right-hand panel, or stop just this one.
    headActions(n, ctx) {
      const m = meta(n), running = n.props.status === 'pending' || n.props.status === 'running';
      if (n.props.status === 'pending' || (!running && !m.background && !(m.subagent || m.agentID))) return '';
      const agentID = m.agentID || input(n).resume || n.props.callId;
      return '<span class="tool-acts">' + (m.handle ? '<span class="agent-handle">' + ctx.esc(m.handle) + (m.background ? ' · background' : '') + '</span>' : '') +
        '<button class="btn mini" data-act="agent-open" data-agent="' + ctx.esc(agentID) + '">Open</button>' +
        (running ? '<button class="btn mini danger" data-act="agent-stop" data-agent="' + ctx.esc(agentID) + '">Stop</button>' : '') + '</span>';
    },
    body(n, ctx) {
      const out = n.props.result ? (n.props.result.text || '') : '';
      return '<div class="label">Brief</div><div class="md">' + ctx.md(input(n).prompt || '') + '</div>' +
        (out ? '<div class="label">Report</div><div class="md">' + ctx.md(out) + '</div>' : (ctx.progress(n.props.callId) ? ctx.pre(ctx.progress(n.props.callId)) : ''));
    },
  });
  R.defineTool({ name: 'agents', icon: '🧭', title: 'Sub-agents', summary: n => (input(n).action || '') + (input(n).id ? ' ' + input(n).id : '') });
})();
