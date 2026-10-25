// Tool cards for the web, browser and desktop tools: web_search, web_fetch, browser, computer, mac.
(function () {
  'use strict';
  const R = window.TeacherUI;
  const input = n => n.props.input || {};
  const meta = n => (n.props.result && n.props.result.meta) || {};

  R.defineTool({ name: 'web_search', icon: 'globe', tone: 'teal', title: 'Web search', summary: n => input(n).query || '',
    body(n, ctx) {
      const res = meta(n).results;
      if (!res) return n.props.output ? ctx.pre(n.props.output) : '';
      return '<ul class="results">' + res.map(x => '<li><a class="t" href="' + ctx.esc(x.url) + '">' + ctx.esc(x.title) + '</a><div class="u">' + ctx.esc(x.url) + '</div><div class="s">' + ctx.esc(x.snippet) + '</div></li>').join('') + '</ul>';
    } });
  R.defineTool({ name: 'web_fetch', icon: 'link', tone: 'teal', title: 'Read page', summary: n => input(n).url || '',
    body(n, ctx) {
      const url = input(n).url, t = meta(n).title;
      return '<div><a href="' + ctx.esc(url) + '">' + ctx.esc(t || url) + '</a></div>' + (n.props.output ? '<div class="label">Extracted</div>' + ctx.pre(n.props.output, 4000) : '');
    } });

  // What the agent did and saw: the screenshot, and the result without the untrusted-content envelope.
  function seen(n, ctx) {
    const shot = n.props.result ? ctx.imageSrc(n.props.result) : '';
    const shown = (n.props.output || '').replace(/^Everything until <\/untrusted_\w+> comes from[^\n]*\n/gm, '').replace(/<\/?untrusted_\w+_content[^>]*>\n?/g, '');
    return (shot ? '<img class="tool-shot" src="' + ctx.esc(shot) + '" alt="">' : '') + (shown ? ctx.pre(shown, 8000) : '');
  }
  R.defineTool({ name: 'browser', icon: 'window', tone: 'teal', title: 'Browser', body: seen,
    summary: n => { const i = input(n); return (i.action || '') + ' ' + (i.url || i.ref || i.text || i.key || i.selector || (i.fields ? i.fields.length + ' fields' : '')); } });
  R.defineTool({ name: 'computer', icon: 'monitor', tone: 'teal', title: 'Computer', body: seen,
    summary: n => { const i = input(n); return (i.action || '') + (i.coordinate ? ' (' + i.coordinate.join(', ') + ')' : '') + (i.text ? ' ' + i.text : ''); } });
  R.defineTool({ name: 'mac', icon: 'apps', tone: 'teal', title: 'Mac apps', body: seen,
    summary: n => { const i = input(n); return (i.action || '') + ' ' + ((i.apps || []).join(', ') || i.app || i.ref || i.query || ''); } });
})();
