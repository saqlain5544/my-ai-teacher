// Tool cards for the learner-model and housekeeping tools: memory, project_memory, load_tools. All compact: one line
// when closed, so a reply that remembers something does not grow a box.
(function () {
  'use strict';
  const R = window.TeacherUI;
  const input = n => n.props.input || {};
  const MEMORY_TITLES = { search: 'Recall', save: 'Remember', update: 'Update memory', forget: 'Forget' };

  R.defineTool({ name: 'memory', icon: 'brain', tone: 'purple', compact: true,
    title: n => MEMORY_TITLES[input(n).action] || 'Memory',
    summary: n => {
      const i = input(n);
      return i.action === 'search' ? (i.query || '') : i.action === 'save' ? (i.scope === 'folder' ? '[folder] ' : '') + (i.content || '')
        : '#' + (i.id || '') + (i.content ? ' ' + i.content : '');
    } });
  R.defineTool({ name: 'memory_search', icon: 'brain', tone: 'purple', title: 'Recall', compact: true, summary: n => input(n).query || '' });
  R.defineTool({ name: 'memory_save', icon: 'brain', tone: 'purple', title: 'Remember', compact: true, summary: n => (input(n).scope === 'folder' ? '[folder] ' : '') + (input(n).content || '') });
  R.defineTool({ name: 'memory_update', icon: 'brain', tone: 'purple', title: 'Update memory', compact: true, summary: n => '#' + (input(n).id || '') });
  R.defineTool({ name: 'memory_forget', icon: 'brain', tone: 'purple', title: 'Forget', compact: true, summary: n => '#' + (input(n).id || '') });
  R.defineTool({ name: 'project_memory', icon: 'bookmark', tone: 'purple', title: 'Project memory', compact: true,
    summary: n => { const i = input(n); return (i.action === 'add' ? (i.section ? i.section + ': ' : '') : (i.action || 'view') + ' ') + (i.text || ''); } });
  R.defineTool({ name: 'load_tools', icon: 'toolbox', tone: 'grey', title: 'Load tools', compact: true, summary: n => (input(n).names || []).join(', ') });
})();
