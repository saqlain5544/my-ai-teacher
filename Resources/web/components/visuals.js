// Live visuals: sandboxed iframes running model-written HTML/JS with offline libraries (teacher-lib://).
// Two entry points: a ```visual fence (inline, no extra model round trip) and the `visual` tool (can persist).
(function () {
  'use strict';
  const R = window.TeacherUI;
  const LIBS = { three: 'three.js', d3: 'd3.js', chart: 'chart.js', matter: 'matter.js', katex: 'katex.js' };
  // In the app, libraries come from the teacher-lib: scheme; the dev harness (http) serves them from the repo.
  const LIB_BASE = location.protocol === 'http:' ? location.origin + '/Resources/web/vendor/lib/' : 'teacher-lib://';
  const LIB_SRC = location.protocol === 'http:' ? location.origin : 'teacher-lib:';
  let seq = 0;
  const frames = new Map(); // frame id -> iframe element

  function theme() {
    const cs = getComputedStyle(document.documentElement);
    const v = n => cs.getPropertyValue(n).trim();
    return { fg: v('--fg'), bg: v('--bg'), accent: v('--accent'), muted: v('--muted'), card: v('--card'), border: v('--border') };
  }

  /** Parse an optional header comment: <!-- libs: three, d3; height: 400; title: Orbits --> */
  function header(src) {
    const m = /^\s*<!--([\s\S]*?)-->/.exec(src);
    const out = {};
    if (!m) return out;
    m[1].split(';').forEach(kv => {
      const i = kv.indexOf(':'); if (i < 0) return;
      out[kv.slice(0, i).trim().toLowerCase()] = kv.slice(i + 1).trim();
    });
    return out;
  }

  // Runs inside the frame. WebKit hides error details from sandboxed inline scripts ("Script error."), so the model's
  // scripts run through indirect eval in try/catch and async callbacks are wrapped — the real message reaches the
  // learner (and the teacher, via "Fix").
  const RUNTIME = function (fid) {
    var sent = {};
    function rep(e) {
      var m = e && e.name ? e.name + ': ' + e.message : String(e);
      if (sent[m]) return; sent[m] = 1;
      parent.postMessage({ visualError: fid, msg: m }, '*');
    }
    function wrap(f) { return typeof f !== 'function' ? f : function () { try { return f.apply(this, arguments); } catch (e) { rep(e); } }; }
    ['requestAnimationFrame', 'setTimeout', 'setInterval'].forEach(function (n) {
      var o = window[n]; window[n] = function (f) { var a = [].slice.call(arguments); a[0] = wrap(f); return o.apply(window, a); };
    });
    var map = new WeakMap(), add = EventTarget.prototype.addEventListener, rem = EventTarget.prototype.removeEventListener;
    EventTarget.prototype.addEventListener = function (t, f, o) {
      if (typeof f === 'function') { if (!map.has(f)) map.set(f, wrap(f)); f = map.get(f); }
      return add.call(this, t, f, o);
    };
    EventTarget.prototype.removeEventListener = function (t, f, o) { return rem.call(this, t, (f && map.get(f)) || f, o); };
    window.onerror = function (m, s, l) { if (!/^Script error/.test(m)) rep({ name: 'Error', message: m + (l ? ' (line ' + l + ')' : '') }); };
    window.__runVisual = function () {
      var list = document.querySelectorAll('script[type="text/x-visual"]');
      for (var i = 0; i < list.length; i++) { try { (0, eval)(list[i].textContent); } catch (e) { rep(e); } }
      var last = 0;
      function size() {
        var b = document.body, h = Math.ceil(Math.max(b.scrollHeight, b.getBoundingClientRect().height));
        if (Math.abs(h - last) > 2) { last = h; parent.postMessage({ visualHeight: fid, h: h }, '*'); }
      }
      new ResizeObserver(size).observe(document.body);
      window.addEventListener('load', size); setTimeout(size, 60); setTimeout(size, 600);
    };
  };

  function srcdoc(html, libs, fid) {
    const t = theme();
    // Models sometimes send a whole document: keep its content, drop the wrappers (our head carries the CSP + theme).
    html = String(html).replace(/<!doctype[^>]*>|<\/?(html|head|body)\b[^>]*>|<meta\b[^>]*>/gi, '');
    // Inline scripts run later through the runtime (see RUNTIME); external src= is blocked by the CSP anyway.
    html = html.replace(/<script(?![^>]*\bsrc=)([^>]*)>/gi, (m, attrs) => '<script type="text/x-visual"' + attrs.replace(/\btype\s*=\s*["'][^"']*["']/i, '') + '>');
    const libTags = (libs || []).filter(l => LIBS[l]).map(l => '<script src="' + LIB_BASE + LIBS[l] + '"><\/script>').join('');
    return '<!doctype html><html><head><meta charset="utf-8">' +
      '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; script-src \'unsafe-inline\' \'unsafe-eval\' ' + LIB_SRC + '; style-src \'unsafe-inline\'; img-src data: blob:; font-src data:; media-src data: blob:; connect-src \'none\'">' +
      '<style>:root{--fg:' + t.fg + ';--bg:' + t.bg + ';--accent:' + t.accent + ';--muted:' + t.muted + ';--card:' + t.card + ';--border:' + t.border + ';color-scheme:light dark}' +
      'html,body{margin:0;padding:0;background:transparent;color:var(--fg);font:14px/1.5 -apple-system,BlinkMacSystemFont,sans-serif;overflow-x:hidden}body{position:relative;padding:8px;box-sizing:border-box}' +
      'canvas,svg{max-width:100%;display:block}button,input,select{font:inherit}button{background:var(--card);color:var(--fg);border:1px solid var(--border);border-radius:7px;padding:4px 10px;cursor:pointer}' +
      'input[type=range]{accent-color:var(--accent)}</style>' +
      '<script>(' + RUNTIME.toString() + ')(' + JSON.stringify(fid) + ')<\/script>' + libTags +
      '</head><body>' + html + '<script>__runVisual()<\/script></body></html>';
  }

  function frameHTML(title, html, libs, height, key, note) {
    const fid = key;   // stable: re-rendering the message (streaming) must not restart the visual
    return '<div class="visual" data-key="' + key + '" data-fid="' + fid + '">' +
      '<div class="visual-head"><span class="visual-title">◈ ' + (title ? escapeHTML(title) : 'Interactive visual') + '</span>' +
      (note ? '<span class="visual-note">' + note + '</span>' : '') +
      '<span><button data-act="visual-reload" title="Restart">↻</button><button data-act="visual-max" title="Enlarge">⤢</button></span></div>' +
      '<div class="visual-body" data-src="' + encodeURIComponent(JSON.stringify({ html, libs })) + '" data-h="' + (parseInt(height, 10) || 360) + '"></div>' +
      '<div class="visual-error" hidden><span class="visual-error-msg"></span><button data-act="visual-fix" title="Ask the teacher to fix this visual">Fix</button></div></div>';
  }
  const escapeHTML = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  // After a visual froze the page (the app's watchdog restarted it), visuals wait for a click instead of running.
  let paused = false;
  R.pauseVisuals = on => { paused = !!on; };

  function mount(container, force) {
    const body = container.querySelector('.visual-body');
    if (!body || body.querySelector('iframe')) return;
    if (paused && !force) {
      if (!body.querySelector('.visual-paused')) body.innerHTML = '<div class="visual-paused"><button class="btn" data-act="visual-run">▶ Run visual</button><span>Paused: a visual stopped responding earlier in this lesson.</span></div>';
      return;
    }
    body.innerHTML = '';
    const fid = container.getAttribute('data-fid');
    const { html, libs } = JSON.parse(decodeURIComponent(body.getAttribute('data-src')));
    if (!body.style.height) body.style.height = Math.min(900, Math.max(80, +body.getAttribute('data-h') || 360)) + 'px';
    const f = document.createElement('iframe');
    f.setAttribute('sandbox', 'allow-scripts');
    f.setAttribute('loading', 'lazy');
    f.srcdoc = srcdoc(html, libs, fid);
    body.appendChild(f);
    frames.set(fid, f);
  }

  // Inline fence: ```visual  (temporary; renders once the fence closes)
  R.registerFence(['visual', 'html-live', 'live'], (code, ctx, env) => {
    if (env && env.open) return '<div class="visual"><div class="diagram-pending">Building visual…</div></div>';
    const h = header(code);
    const libs = (h.libs || '').split(/[,\s]+/).map(s => s.trim().toLowerCase()).filter(Boolean);
    return frameHTML(h.title, code.replace(/^\s*<!--[\s\S]*?-->/, ''), libs, parseInt(h.height, 10) || 360, 'vf' + ctx.hash(code));
  });

  // Tool card: `visual` (can persist)
  R.registerToolCard('visual', (b, r) => {
    const i = b.input || {};
    if (!i.html) return null;
    const saved = r && r.meta && r.meta.saved;
    return frameHTML(i.title, i.html, i.libs || [], i.height, 'vt' + b.id, saved ? 'saved to library' : '');
  });

  R.registerProcessor(root => {
    const list = root.matches && root.matches('.visual') ? [root] : Array.from(root.querySelectorAll('.visual'));
    list.forEach(mount);
  });

  window.addEventListener('message', e => {
    const d = e.data || {};
    // Only a frame may speak for itself (a visual can't resize or write errors into another one).
    const own = id => { const f = frames.get(id); return f && e.source === f.contentWindow ? f : null; };
    if (d.visualHeight) {
      const f = own(d.visualHeight);
      if (f && f.parentElement && !f.closest('.visual.max')) f.parentElement.style.height = Math.min(900, Math.max(80, d.h)) + 'px';
    } else if (d.visualError) {
      const f = own(d.visualError);
      const box = f && f.closest('.visual') && f.closest('.visual').querySelector('.visual-error');
      if (box) { box.hidden = false; box.querySelector('.visual-error-msg').textContent = '⚠︎ ' + d.msg; }
    }
  });

  R.registerAction('visual-reload', el => {
    const c = el.closest('.visual'); const body = c.querySelector('.visual-body');
    const f = body.querySelector('iframe'); if (f) { frames.delete(c.getAttribute('data-fid')); f.remove(); }
    c.querySelector('.visual-error').hidden = true;
    mount(c, !!f);
  });
  R.registerAction('visual-run', el => { mount(el.closest('.visual'), true); });
  R.registerAction('visual-fix', (el, e, ctx) => {
    const c = el.closest('.visual');
    const title = c.querySelector('.visual-title').textContent.replace(/^◈\s*/, '');
    const msg = c.querySelector('.visual-error-msg').textContent.replace(/^⚠︎\s*/, '');
    ctx.post({ type: 'suggest', text: 'The visual “' + title + '” failed with: ' + msg + '. Please fix it and show it again.' });
    el.disabled = true;
  });
  R.registerAction('visual-max', el => { el.closest('.visual').classList.toggle('max'); });
})();
