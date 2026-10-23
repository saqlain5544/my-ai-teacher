// @lazy — code views load the first time a reply uses ```layout or ```tree (see components/manifest.js).
// Views for code lessons (the code mentor's and the code agent's branch of the agent tree):
//   ```layout — a type's memory layout: fields at their offsets, the padding between them, size and alignment.
//   ```tree   — a project's file tree with a note per entry.
(function () {
  'use strict';
  const R = window.TeacherUI;
  const PALETTE = ['#4c8bf5', '#e8a33d', '#43b581', '#c76bd6', '#e5534b', '#3fb7c8', '#9c7b3c', '#7a86f0'];

  /** {"name","size","align","fields":[{"name","type","offset","size"}],"note"} → a byte bar and a table. Padding is what
   *  no field covers, worked out from the offsets (so the picture is exactly what the numbers say). */
  function layout(spec, ctx) {
    const fields = (spec.fields || []).map(f => ({ name: String(f.name || '?'), type: f.type ? String(f.type) : '', offset: +f.offset || 0, size: Math.max(0, +f.size || 0) }))
      .sort((a, b) => a.offset - b.offset);
    if (!fields.length) throw new Error('a layout needs "fields": [{"name","type","offset","size"}]');
    const end = Math.max(...fields.map(f => f.offset + f.size));
    const size = Math.max(+spec.size || 0, end);
    const parts = [];
    let at = 0, padding = 0, overlap = false;
    fields.forEach((f, i) => {
      if (f.offset > at) { parts.push({ pad: true, offset: at, size: f.offset - at }); padding += f.offset - at; }
      if (f.offset < at) overlap = true;
      parts.push(Object.assign({ color: PALETTE[i % PALETTE.length] }, f));
      at = Math.max(at, f.offset + f.size);
    });
    if (size > at) { parts.push({ pad: true, offset: at, size: size - at, tail: true }); padding += size - at; }
    const bar = '<div class="lay-bar">' + parts.map(p => '<div class="lay-seg' + (p.pad ? ' pad' : '') + '" data-w="' + Math.max(p.size, 0.5) + '"' + (p.pad ? '' : ' data-c="' + p.color + '"') + ' title="' +
      ctx.esc((p.pad ? (p.tail ? 'tail padding' : 'padding') : p.name + (p.type ? ': ' + p.type : '')) + ' · offset ' + p.offset + ' · ' + p.size + ' B') + '">' +
      '<span>' + ctx.esc(p.pad ? p.size + ' B pad' : p.name) + '</span></div>').join('') + '</div>';
    const ruler = '<div class="lay-ruler"><span>0</span><span>' + size + ' B</span></div>';
    const rows = parts.map(p => '<tr class="' + (p.pad ? 'pad' : '') + '"><td>' + (p.pad ? '<i>' + (p.tail ? 'tail padding' : 'padding') + '</i>' : '<span class="lay-dot" data-c="' + p.color + '"></span>' + ctx.esc(p.name)) +
      '</td><td><code>' + ctx.esc(p.pad ? '' : p.type) + '</code></td><td>' + p.offset + '</td><td>' + p.size + '</td></tr>').join('');
    const head = '<div class="lay-head"><b>' + ctx.esc(spec.name || 'Layout') + '</b><span>' + size + ' bytes' + (spec.align ? ' · align ' + ctx.esc(String(spec.align)) : '') +
      ' · ' + padding + ' B padding (' + Math.round(100 * padding / Math.max(size, 1)) + '%)</span></div>';
    const warn = overlap ? '<div class="lay-warn">Fields overlap: check the offsets (a union, or a mistake).</div>' : '';
    return '<div class="comp layout" data-key="ly' + ctx.hash(JSON.stringify(spec)) + '">' + head + ruler + bar + warn +
      '<table class="lay-table"><thead><tr><th>Field</th><th>Type</th><th>Offset</th><th>Size</th></tr></thead><tbody>' + rows + '</tbody></table>' +
      (spec.note ? '<div class="lay-note md">' + ctx.inline(String(spec.note)) + '</div>' : '') + '</div>';
  }

  // Sizes and colours go on after insertion: the page's sanitizer strips style attributes from rendered HTML.
  const paint = el => {
    el.querySelectorAll('[data-w]').forEach(s => { s.style.flexGrow = s.getAttribute('data-w'); });
    el.querySelectorAll('[data-c]').forEach(s => { s.style.setProperty('--c', s.getAttribute('data-c')); });
    el.querySelectorAll('[data-d]').forEach(r => { r.style.paddingLeft = (+r.getAttribute('data-d') * 16 + 4) + 'px'; });
  };

  R.defineComponent({ names: ['layout', 'memlayout', 'struct-layout'], raw: true, selector: '.comp.layout', mount: paint,
    render(code, ctx, env) {
      if (env && env.open) return '<div class="comp"><div class="diagram-pending">Building layout…</div></div>';
      try { return layout(R.parseLoose(code), ctx); }
      catch (e) { return '<div class="comp comp-error"><div class="diagram-error">layout: ' + ctx.esc(e.message) + '<pre>' + ctx.esc(code) + '</pre></div></div>'; }
    },
    styles: `
      .comp.layout { padding: 12px 14px; }
      .lay-head { display: flex; justify-content: space-between; gap: 10px; flex-wrap: wrap; margin-bottom: 6px; }
      .lay-head span { color: var(--muted); font-size: .88em; }
      .lay-ruler { display: flex; justify-content: space-between; font-size: .75em; color: var(--muted); }
      .lay-bar { display: flex; height: 38px; border: 1px solid var(--border); border-radius: 6px; overflow: hidden; }
      .lay-seg { flex-basis: 0; min-width: 6px; background: color-mix(in srgb, var(--c) 30%, transparent); border-right: 1px solid var(--border);
                 display: flex; align-items: center; justify-content: center; overflow: hidden; }
      .lay-seg span { font-size: .78em; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; padding: 0 4px; }
      .lay-seg.pad { background: repeating-linear-gradient(45deg, transparent 0 5px, color-mix(in srgb, var(--muted) 25%, transparent) 5px 7px); color: var(--muted); }
      .lay-seg:last-child { border-right: 0; }
      .lay-table { margin-top: 10px; font-size: .88em; }
      .lay-table tr.pad td { color: var(--muted); }
      .lay-dot { display: inline-block; width: 9px; height: 9px; border-radius: 3px; background: var(--c); margin-right: 6px; }
      .lay-warn { color: var(--danger, #e5534b); font-size: .85em; margin-top: 6px; }
      .lay-note { margin-top: 6px; color: var(--muted); font-size: .9em; }
    `,
  });

  /** ["src/", "  main.zig  # entry point", …] or the same as plain text: indentation is depth, a trailing "/" a folder,
   *  "# …" a note. */
  function tree(lines, ctx) {
    const items = lines.map(l => String(l)).filter(l => l.trim()).map(l => {
      const clean = l.replace(/^[\s│├└─|`\-]*?(?=[^\s│├└─|`\-])/, m => ' '.repeat(m.length));   // `tree` command art → spaces
      const depth = Math.floor((clean.length - clean.trimStart().length) / 2);
      const [name, ...note] = clean.trim().split(/\s+#\s*/);
      return { depth, name, note: note.join(' # '), dir: /\/$/.test(name) };
    });
    if (!items.length) throw new Error('a tree needs entries: ["src/", "  main.zig  # entry point"]');
    return '<div class="comp ftree" data-key="ft' + ctx.hash(lines.join('\n')) + '">' + items.map(it =>
      '<div class="ft-row" data-d="' + it.depth + '"><span class="ft-icon">' + (it.dir ? '📁' : '📄') + '</span><code>' + ctx.esc(it.name) + '</code>' +
      (it.note ? '<span class="ft-note">' + ctx.inline(it.note) + '</span>' : '') + '</div>').join('') + '</div>';
  }

  R.defineComponent({ names: ['tree', 'filetree', 'file-tree'], raw: true, selector: '.comp.ftree', mount: paint,
    render(code, ctx, env) {
      if (env && env.open) return '<div class="comp"><div class="diagram-pending">Building tree…</div></div>';
      try {
        let lines;
        if (/^\s*\[/.test(code)) { const v = R.parseLoose(code); lines = Array.isArray(v) ? v : [];}
        else lines = code.split('\n');
        return tree(lines, ctx);
      } catch (e) { return '<div class="comp comp-error"><div class="diagram-error">tree: ' + ctx.esc(e.message) + '<pre>' + ctx.esc(code) + '</pre></div></div>'; }
    },
    styles: `
      .comp.ftree { padding: 8px 10px; font-size: .92em; }
      .ft-row { display: flex; align-items: baseline; gap: 6px; padding-top: 2px; padding-bottom: 2px; }
      .ft-row code { background: none; padding: 0; }
      .ft-icon { font-size: .9em; }
      .ft-note { color: var(--muted); font-size: .9em; margin-left: 6px; }
    `,
  });
})();
