// Tool cards for the file and shell tools: bash, read, write, edit, ls, glob, grep, run_code.
// A descriptor gives the card its icon, title, one-line summary and opened body; the core draws the frame.
(function () {
  'use strict';
  const R = window.TeacherUI;
  const input = n => n.props.input || {};
  const path = n => input(n).path || '';
  const output = (n, ctx, label) => n.props.output ? (label ? '<div class="label">' + label + '</div>' : '') + ctx.pre(n.props.output) : '';

  R.defineTool({ name: 'bash', icon: '⌘', title: 'Terminal', summary: n => input(n).command || '',
    body: (n, ctx) => '<div class="label">Command</div>' + ctx.pre(input(n).command || '') + output(n, ctx, 'Output') });
  R.defineTool({ name: 'read', icon: '📄', title: 'Read', summary: path });
  R.defineTool({ name: 'write', icon: '✏️', title: 'Write', summary: path,
    body: (n, ctx) => ctx.code(input(n).content || '', path(n).split('.').pop()) + output(n, ctx) });
  R.defineTool({ name: 'edit', icon: '✏️', title: 'Edit', summary: path,
    body: (n, ctx) => {
      const i = input(n);
      return '<div class="label">' + ctx.esc(i.path) + '</div><pre class="diff"><span class="del">' + ctx.esc(i.old_string || '') + '</span><span class="add">' + ctx.esc(i.new_string || '') + '</span></pre>' + output(n, ctx, 'Result');
    } });
  R.defineTool({ name: 'ls', icon: '📁', title: 'List', summary: path });
  R.defineTool({ name: 'glob', icon: '🔎', title: 'Find files', summary: n => input(n).pattern || '' });
  R.defineTool({ name: 'grep', icon: '🔎', title: 'Search files', summary: n => input(n).pattern || '' });
  R.defineTool({ name: 'run_code', icon: '▶︎', title: 'Run code', summary: n => (input(n).language || '') + ' snippet',
    body: (n, ctx) => ctx.code(input(n).code || '', input(n).language || '') + output(n, ctx, 'Output') });
})();
