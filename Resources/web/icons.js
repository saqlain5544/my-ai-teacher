// The transcript's icons: one line-drawn set on a 24-unit grid, stroked in the text colour, so every tool card, button
// and callout reads as one family in both themes (emoji drew differently per glyph and could not take a tint).
// `R.icon(name)` → inline SVG; a name the set doesn't know (an older descriptor's emoji) is shown as text.
(function () {
  'use strict';
  const R = window.TeacherUI;
  const P = {
    terminal: '<path d="M4 17l6-5-6-5"/><path d="M12 19h8"/>',
    file: '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/>',
    'file-text': '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/><path d="M9 13h6M9 17h4"/>',
    'file-plus': '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/><path d="M12 11v6M9 14h6"/>',
    pencil: '<path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L8 18l-4 1 1-4z"/><path d="M14.5 5.5l3 3"/>',
    folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
    search: '<circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/>',
    'text-search': '<path d="M4 6h16M4 12h5M4 18h4"/><circle cx="15.5" cy="15" r="3.5"/><path d="M21 20.5l-3-3"/>',
    globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18"/><path d="M12 3c2.5 2.5 3.8 5.5 3.8 9s-1.3 6.5-3.8 9c-2.5-2.5-3.8-5.5-3.8-9S9.5 5.5 12 3z"/>',
    link: '<path d="M10 14a4.5 4.5 0 0 0 6.4 0l3-3a4.5 4.5 0 0 0-6.4-6.4l-1.2 1.2"/><path d="M14 10a4.5 4.5 0 0 0-6.4 0l-3 3a4.5 4.5 0 0 0 6.4 6.4l1.2-1.2"/>',
    window: '<rect x="3" y="4" width="18" height="16" rx="2.5"/><path d="M3 9h18"/><path d="M6.5 6.5h.01M9.5 6.5h.01"/>',
    monitor: '<rect x="2.5" y="3.5" width="19" height="13" rx="2"/><path d="M8 20.5h8M12 16.5v4"/>',
    apps: '<rect x="3.5" y="3.5" width="7" height="7" rx="1.8"/><rect x="13.5" y="3.5" width="7" height="7" rx="1.8"/><rect x="3.5" y="13.5" width="7" height="7" rx="1.8"/><rect x="13.5" y="13.5" width="7" height="7" rx="1.8"/>',
    bot: '<rect x="4" y="8" width="16" height="12" rx="3"/><path d="M12 8V4.5M9.5 4.5h5"/><path d="M9 13.5v1.5M15 13.5v1.5"/>',
    users: '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20a6.5 6.5 0 0 1 13 0"/><path d="M16 4.6a3.5 3.5 0 0 1 0 6.8M18 14a6.5 6.5 0 0 1 3.5 6"/>',
    brain: '<path d="M12 5a3 3 0 0 0-5.5-1.2A3 3 0 0 0 4 7.2a3.3 3.3 0 0 0-.8 5.6 3.4 3.4 0 0 0 3 5.2A3 3 0 0 0 12 19z"/><path d="M12 5a3 3 0 0 1 5.5-1.2A3 3 0 0 1 20 7.2a3.3 3.3 0 0 1 .8 5.6 3.4 3.4 0 0 1-3 5.2A3 3 0 0 1 12 19"/><path d="M12 5v14M7 9.5a2.5 2.5 0 0 1 2.5 1.5M17 9.5a2.5 2.5 0 0 0-2.5 1.5M7.5 14.5h2M16.5 14.5h-2"/>',
    bookmark: '<path d="M18 21l-6-4-6 4V5a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2z"/>',
    book: '<path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20V3H6.5A2.5 2.5 0 0 0 4 5.5z"/><path d="M4 19.5A2.5 2.5 0 0 0 6.5 22H20v-5"/>',
    flask: '<path d="M9 3h6M10 3v6.5L4.6 18.4A1.8 1.8 0 0 0 6.2 21h11.6a1.8 1.8 0 0 0 1.6-2.6L14 9.5V3"/><path d="M7.5 15h9"/>',
    play: '<path d="M7 4.8v14.4a1 1 0 0 0 1.5.9l11.3-7.2a1 1 0 0 0 0-1.8L8.5 3.9A1 1 0 0 0 7 4.8z"/>',
    check: '<path d="M20 6.5L9.5 17 4 11.5"/>',
    x: '<path d="M18 6L6 18M6 6l12 12"/>',
    'check-circle': '<circle cx="12" cy="12" r="9"/><path d="M8.5 12.3l2.4 2.4 4.6-4.9"/>',
    'x-circle': '<circle cx="12" cy="12" r="9"/><path d="M15 9l-6 6M9 9l6 6"/>',
    circle: '<circle cx="12" cy="12" r="9"/>',
    'circle-dot': '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3.5" fill="currentColor" stroke="none"/>',
    alert: '<path d="M10.3 4L2.2 18a2 2 0 0 0 1.7 3h16.2a2 2 0 0 0 1.7-3L13.7 4a2 2 0 0 0-3.4 0z"/><path d="M12 9.5v4M12 17h.01"/>',
    octagon: '<path d="M8 2.5h8L21.5 8v8L16 21.5H8L2.5 16V8z"/><path d="M12 8v4.5M12 16h.01"/>',
    info: '<circle cx="12" cy="12" r="9"/><path d="M12 16v-4.5M12 8h.01"/>',
    help: '<circle cx="12" cy="12" r="9"/><path d="M9.3 9.2a2.8 2.8 0 0 1 5.4 1c0 1.9-2.7 2.5-2.7 4"/><path d="M12 17.2h.01"/>',
    clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    flame: '<path d="M12 21.5c3.6 0 6.5-2.6 6.5-6.3 0-3.2-1.9-5.2-3.4-7.3-.5 1.6-1.4 2.7-2.6 3.2.4-3.2-1-6.2-3.6-8.6.2 3.2-1.6 5.2-3.1 7.1-1.1 1.4-2.3 3.1-2.3 5.6 0 3.7 2.9 6.3 6.5 6.3z"/><path d="M12 21.5c-1.7 0-3-1.3-3-3 0-2 1.6-3 3-4.8 1.4 1.8 3 2.8 3 4.8 0 1.7-1.3 3-3 3z"/>',
    zap: '<path d="M13 2.5L4.5 13.5H11l-1 8 8.5-11H12z"/>',
    wrench: '<path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.4-3.4a6 6 0 0 1-7.9 7.9l-6.5 6.5a2.1 2.1 0 0 1-3-3l6.5-6.5a6 6 0 0 1 7.9-7.9z"/>',
    toolbox: '<rect x="3" y="7" width="18" height="13" rx="2.5"/><path d="M8.5 7V5.5a2 2 0 0 1 2-2h3a2 2 0 0 1 2 2V7"/><path d="M3 13h18M10 13v2h4v-2"/>',
    activity: '<path d="M21 12h-4l-3 8-4-16-3 8H3"/>',
    code: '<path d="M16 17l5-5-5-5M8 7l-5 5 5 5"/>',
    braces: '<path d="M8 3.5H7a2 2 0 0 0-2 2V10a2 2 0 0 1-2 2 2 2 0 0 1 2 2v4.5a2 2 0 0 0 2 2h1"/><path d="M16 3.5h1a2 2 0 0 1 2 2V10a2 2 0 0 0 2 2 2 2 0 0 0-2 2v4.5a2 2 0 0 1-2 2h-1"/>',
    eye: '<path d="M2.5 12S6 5 12 5s9.5 7 9.5 7-3.5 7-9.5 7-9.5-7-9.5-7z"/><circle cx="12" cy="12" r="3"/>',
    shield: '<path d="M12 21.5s7.5-3.5 7.5-9.5V5.5L12 2.5l-7.5 3V12c0 6 7.5 9.5 7.5 9.5z"/><path d="M12 8v4.5M12 15.8h.01"/>',
    cap: '<path d="M22 9.5L12 4.5 2 9.5l10 5z"/><path d="M6 11.5V17c3.3 2.3 8.7 2.3 12 0v-5.5"/><path d="M22 9.5V15"/>',
    bulb: '<path d="M9 18h6M10 21.5h4"/><path d="M15 14.5c.2-1 .8-1.8 1.5-2.6A5.5 5.5 0 1 0 6.5 8.5c0 1.3.5 2.5 1.5 3.4.8.8 1.3 1.6 1.5 2.6z"/>',
    sparkles: '<path d="M11 3.5l1.8 4.7 4.7 1.8-4.7 1.8L11 16.5l-1.8-4.7L4.5 10l4.7-1.8z"/><path d="M18.5 14.5l.9 2.1 2.1.9-2.1.9-.9 2.1-.9-2.1-2.1-.9 2.1-.9z"/>',
    paperclip: '<path d="M20.5 11.5l-8.6 8.6a5.5 5.5 0 0 1-7.8-7.8l8.6-8.6a3.7 3.7 0 0 1 5.2 5.2l-8.6 8.6a1.8 1.8 0 0 1-2.6-2.6l7.9-7.9"/>',
    image: '<rect x="3" y="3.5" width="18" height="17" rx="2.5"/><circle cx="9" cy="9.5" r="1.8"/><path d="M21 15.5l-5-5-11 10"/>',
    copy: '<rect x="8.5" y="8.5" width="12" height="12" rx="2.2"/><path d="M15.5 8.5V6a2.5 2.5 0 0 0-2.5-2.5H6A2.5 2.5 0 0 0 3.5 6v7A2.5 2.5 0 0 0 6 15.5h2.5"/>',
    refresh: '<path d="M20.5 11.5A8.5 8.5 0 0 0 5.6 6.4L3.5 8.5"/><path d="M3.5 3.5v5h5"/><path d="M3.5 12.5a8.5 8.5 0 0 0 14.9 5.1l2.1-2.1"/><path d="M20.5 20.5v-5h-5"/>',
    volume: '<path d="M11 5L6 9H3v6h3l5 4z"/><path d="M15.5 9a4.5 4.5 0 0 1 0 6"/><path d="M18.5 6a8.5 8.5 0 0 1 0 12"/>',
    stop: '<circle cx="12" cy="12" r="9"/><rect x="9" y="9" width="6" height="6" rx="1"/>',
    'list-checks': '<path d="M3.5 6.5l1.5 1.5 2.5-2.5M3.5 12.5l1.5 1.5 2.5-2.5M3.5 18.5l1.5 1.5 2.5-2.5"/><path d="M11 7h9.5M11 13h9.5M11 19h9.5"/>',
    list: '<path d="M8.5 6h12M8.5 12h12M8.5 18h12"/><path d="M3.5 6h.01M3.5 12h.01M3.5 18h.01"/>',
    map: '<path d="M9 4.5L3.5 6.5v13L9 17.5l6 2 5.5-2v-13L15 6.5z"/><path d="M9 4.5v13M15 6.5v13"/>',
    trend: '<path d="M3 17l6-6 4 4 8-8"/><path d="M14.5 7H21v6.5"/>',
    sigma: '<path d="M18 7V4.5H6l6.5 7.5L6 19.5h12V17"/>',
    cards: '<rect x="3" y="7.5" width="13.5" height="13" rx="2.2"/><path d="M7.5 3.5h11a2 2 0 0 1 2 2v11"/>',
    languages: '<path d="M5 8l6 6M4 14l6-6 2-3M2 5h12M7 2h1"/><path d="M22 22l-5-10-5 10M14 18h6"/>',
    cpu: '<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9.5 2.5V6M14.5 2.5V6M9.5 18v3.5M14.5 18v3.5M2.5 9.5H6M2.5 14.5H6M18 9.5h3.5M18 14.5h3.5"/>',
    layers: '<path d="M12 3l9 5-9 5-9-5z"/><path d="M3 13l9 5 9-5"/>',
    undo: '<path d="M9 14L4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11"/>',
    'arrow-down': '<path d="M12 5v14M18.5 12.5L12 19l-6.5-6.5"/>',
    'arrow-right': '<path d="M5 12h14M12.5 5.5L19 12l-6.5 6.5"/>',
    'arrow-down-circle': '<circle cx="12" cy="12" r="9"/><path d="M12 8v8M8.5 12.5L12 16l3.5-3.5"/>',
    'chevron-right': '<path d="M9.5 6l6 6-6 6"/>',
    'chevron-down': '<path d="M6 9.5l6 6 6-6"/>',
    external: '<path d="M14.5 3.5h6v6M10 14L20.5 3.5"/><path d="M18 13.5v5a2 2 0 0 1-2 2H5.5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h5"/>',
    flag: '<path d="M5 21V4.5"/><path d="M5 4.5s1.2-1 4-1 4.5 2 7.5 2 3-1 3-1v10s-.8 1-3 1-4.5-2-7.5-2-4 1-4 1"/>',
    ruler: '<path d="M21 15.5a2.2 2.2 0 0 1 0 3.1L18.6 21a2.2 2.2 0 0 1-3.1 0L3 8.5a2.2 2.2 0 0 1 0-3.1L5.4 3a2.2 2.2 0 0 1 3.1 0z"/><path d="M14.5 12.5l2-2M11.5 9.5l2-2M8.5 6.5l2-2M17.5 15.5l2-2"/>',
    target: '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5"/><circle cx="12" cy="12" r="1" fill="currentColor"/>',
    dot: '<circle cx="12" cy="12" r="2.5" fill="currentColor" stroke="none"/>',
  };
  R.icons = P;
  const esc = s => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  /** `name` from the set as an inline SVG (`cls` adds classes); anything else as escaped text in the same box. */
  R.icon = function (name, cls) {
    const c = 'i' + (cls ? ' ' + cls : '');
    if (P[name]) return '<svg class="' + c + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + P[name] + '</svg>';
    return name ? '<span class="' + c + ' i-text" aria-hidden="true">' + esc(name) + '</span>' : '';
  };
})();
