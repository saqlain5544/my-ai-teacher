/// Scripts injected into the agent browser's pages.
enum BrowserScripts {
    /// The agent's helper, in its own content world (`teacher-agent`) of every frame: page scripts can't see it, call it or
    /// fake its answers. It builds the accessibility-style snapshot (open shadow roots, slots and same-origin iframes
    /// included; cross-origin frames register themselves and are read on their own) and performs actions by ref with the
    /// event sequence a real pointer or keyboard would produce. Refs are stable: an element keeps its ref while it lives.
    static let helper = #"""
    (() => {
      if (window.__ta) return;
      const refs = new Map(), ids = new WeakMap();
      let next = 1, prefix = '';
      const token = Math.random().toString(36).slice(2);
      const refOf = el => { let r = ids.get(el); if (!r) { r = 'ref_' + next++; ids.set(el, r); refs.set(r, new WeakRef(el)); } return prefix + r; };
      const byRef = r => { const w = refs.get(String(r).replace(/^f\d+\./, '')); const el = w && w.deref(); return el && el.isConnected ? el : null; };
      // A frame another origin embedded can't be reached from its parent: it introduces itself so the app can read it directly.
      if (window !== window.top) { let cross = false; try { void window.parent.document.title; } catch (e) { cross = true; }
        if (cross) try { webkit.messageHandlers.taFrame.postMessage({ href: location.href }); } catch (e) {} }

      const clip = (s, n) => { s = String(s == null ? '' : s).replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n) + '…' : s; };
      const q = s => '"' + clip(s, 100).replace(/"/g, '\\"') + '"';
      const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'HEAD', 'META', 'LINK', 'BASE', 'TITLE']);
      const TEXTISH = new Set(['', 'text', 'email', 'tel', 'url', 'search', 'password', 'number', 'date', 'datetime-local', 'month', 'week', 'time', 'color']);
      const INTERACTIVE = new Set(['link', 'button', 'textbox', 'searchbox', 'combobox', 'listbox', 'option', 'checkbox', 'radio', 'slider',
        'spinbutton', 'switch', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'treeitem', 'file upload']);
      const STRUCT = new Set(['heading', 'img', 'navigation', 'main', 'form', 'dialog', 'alertdialog', 'alert', 'list', 'listitem', 'table', 'row',
        'cell', 'columnheader', 'rowheader', 'banner', 'contentinfo', 'complementary', 'region', 'article', 'group', 'iframe', 'progressbar',
        'tablist', 'tabpanel', 'menu', 'menubar', 'toolbar', 'status', 'tree', 'grid', 'figure', 'search']);

      function role(el) {
        const r = el.getAttribute('role');
        if (r) return r.split(/\s+/)[0];
        const t = el.tagName;
        switch (t) {
          case 'A': case 'AREA': return el.hasAttribute('href') ? 'link' : null;
          case 'BUTTON': case 'SUMMARY': return 'button';
          case 'SELECT': return el.multiple || el.size > 1 ? 'listbox' : 'combobox';
          case 'TEXTAREA': return 'textbox';
          case 'OPTION': return 'option';
          case 'IMG': return el.getAttribute('alt') === '' ? null : 'img';
          case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6': return 'heading';
          case 'NAV': return 'navigation'; case 'MAIN': return 'main'; case 'FORM': return 'form'; case 'DIALOG': return 'dialog';
          case 'UL': case 'OL': case 'MENU': return 'list'; case 'LI': return 'listitem'; case 'TABLE': return 'table'; case 'TR': return 'row';
          case 'TD': return 'cell'; case 'TH': return 'columnheader'; case 'HEADER': return 'banner'; case 'FOOTER': return 'contentinfo';
          case 'ASIDE': return 'complementary'; case 'ARTICLE': return 'article'; case 'FIELDSET': case 'DETAILS': return 'group';
          case 'IFRAME': case 'FRAME': return 'iframe'; case 'PROGRESS': case 'METER': return 'progressbar'; case 'FIGURE': return 'figure';
          case 'SECTION': return el.hasAttribute('aria-label') || el.hasAttribute('aria-labelledby') ? 'region' : null;
          case 'INPUT': {
            const ty = (el.getAttribute('type') || '').toLowerCase();
            if (ty === 'hidden') return null;
            if (['button', 'submit', 'reset', 'image'].includes(ty)) return 'button';
            if (ty === 'checkbox') return el.getAttribute('switch') != null ? 'switch' : 'checkbox';
            if (ty === 'radio') return 'radio'; if (ty === 'range') return 'slider'; if (ty === 'number') return 'spinbutton';
            if (ty === 'search') return 'searchbox'; if (ty === 'file') return 'file upload';
            return el.list ? 'combobox' : 'textbox';
          }
        }
        if (el.isContentEditable && (!el.parentElement || !el.parentElement.isContentEditable)) return 'textbox';
        return null;
      }
      const textOf = el => clip(el.innerText != null ? el.innerText : el.textContent, 200);
      // A label's own words: the control inside it (a select's options, a textarea's text) isn't part of its name.
      const labelText = (lab, self) => { let s = ''; const walk = n => { for (const c of n.childNodes) {
        if (c.nodeType === 3) s += c.data; else if (c.nodeType === 1 && c !== self && !['SELECT', 'TEXTAREA', 'INPUT', 'SCRIPT', 'STYLE'].includes(c.tagName)) walk(c); } };
        walk(lab); return clip(s, 200); };
      function name(el, r) {
        const by = el.getAttribute('aria-labelledby');
        if (by) { const root = el.getRootNode(); const s = by.split(/\s+/).map(id => { const n = root.getElementById ? root.getElementById(id) : document.getElementById(id); return n ? textOf(n) : ''; }).join(' ').trim(); if (s) return s; }
        const al = el.getAttribute('aria-label'); if (al && al.trim()) return al;
        const t = el.tagName;
        if (t === 'INPUT' || t === 'TEXTAREA' || t === 'SELECT') {
          if (el.labels && el.labels.length) { const s = Array.from(el.labels).map(l => labelText(l, el)).join(' ').trim(); if (s) return s; }
          if (t === 'INPUT' && ['button', 'submit', 'reset'].includes(el.type)) return el.value || (el.type === 'submit' ? 'Submit' : el.type);
          if (t === 'INPUT' && el.type === 'image') return el.alt || el.title || 'Submit';
          return el.getAttribute('placeholder') || el.title || '';
        }
        if (t === 'IMG' || t === 'AREA') return el.alt || el.title || '';
        if (t === 'IFRAME') return el.title || el.name || '';
        if (['link', 'button', 'heading', 'option', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'treeitem', 'cell', 'columnheader',
             'rowheader', 'checkbox', 'radio', 'switch', 'listitem', 'figure', 'status', 'alert'].includes(r)) {
          const s = textOf(el); if (s) return s;
          const img = el.querySelector && el.querySelector('img[alt]'); if (img && img.alt) return img.alt;
        }
        if (t === 'FIELDSET') { const lg = el.querySelector('legend'); if (lg) return textOf(lg); }
        return el.title || '';
      }
      function value(el, r) {
        const t = el.tagName;
        if (t === 'INPUT') {
          if (['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file'].includes(el.type)) return el.type === 'file' && el.files && el.files.length ? el.files.length + ' file(s)' : null;
          if (el.type === 'password') return el.value ? '<hidden>' : '';
          return el.value;
        }
        if (t === 'TEXTAREA') return el.value;
        if (t === 'SELECT') return Array.from(el.selectedOptions).map(o => o.text).join(', ');
        if (r === 'textbox' && el.isContentEditable) return textOf(el);
        if (t === 'PROGRESS' || t === 'METER') return String(el.value);
        const v = el.getAttribute('aria-valuetext') || el.getAttribute('aria-valuenow'); return v;
      }
      function states(el, r) {
        const s = [], a = n => el.getAttribute(n);
        const checkable = ['checkbox', 'radio', 'switch', 'menuitemcheckbox', 'menuitemradio'].includes(r);
        if (checkable) s.push((el.tagName === 'INPUT' ? el.checked : a('aria-checked') === 'true') ? 'checked' : 'unchecked');
        if (a('aria-pressed') != null) s.push(a('aria-pressed') === 'true' ? 'pressed' : 'not pressed');
        if (a('aria-expanded') != null) s.push(a('aria-expanded') === 'true' ? 'expanded' : 'collapsed');
        else if (el.tagName === 'DETAILS') s.push(el.open ? 'expanded' : 'collapsed');
        if (el.tagName === 'OPTION' ? el.selected : a('aria-selected') === 'true') s.push('selected');
        if (el.disabled || a('aria-disabled') === 'true') s.push('disabled');
        if (el.required || a('aria-required') === 'true') s.push('required');
        if (el.readOnly || a('aria-readonly') === 'true') s.push('readonly');
        if (a('aria-invalid') === 'true') s.push('invalid');
        if (r === 'heading') s.push('level=' + (a('aria-level') || el.tagName.slice(1)));
        if (deepActive() === el) s.push('focused');
        if (el.tagName === 'INPUT' && el.type && !['text', 'checkbox', 'radio', 'button', 'submit', 'reset', 'image'].includes(el.type)) s.push('type=' + el.type);
        return s;
      }
      function deepActive(doc = document) {
        let a = doc.activeElement;
        while (a) {
          if (a.shadowRoot && a.shadowRoot.activeElement) { a = a.shadowRoot.activeElement; continue; }
          if (a.tagName === 'IFRAME') { try { const d = a.contentDocument; if (d && d.activeElement && d.activeElement !== d.body) { a = d.activeElement; continue; } } catch (e) {} }
          break;
        }
        return a;
      }
      // Elements of a same-origin iframe belong to its window: use its getComputedStyle and its element classes.
      const cs = n => (n.ownerDocument.defaultView || window).getComputedStyle(n);
      const pointer = el => { try { return cs(el).cursor === 'pointer'; } catch (e) { return false; } };
      function interactive(el, r) {
        if (INTERACTIVE.has(r)) return true;
        if (el.hasAttribute('onclick') || el.tabIndex >= 0 && el.hasAttribute('tabindex')) return true;
        return pointer(el) && !(el.parentElement && pointer(el.parentElement)) && el.textContent.trim().length > 0 && el.children.length < 4;
      }
      function kids(n) {
        if (n.shadowRoot) return Array.from(n.shadowRoot.childNodes);   // an open shadow root renders instead of the light children
        if (n.tagName === 'SLOT') { const a = n.assignedNodes({ flatten: true }); return a.length ? a : Array.from(n.childNodes); }
        if (n.tagName === 'IFRAME' || n.tagName === 'FRAME') { try { const d = n.contentDocument; if (d && d.body) return [d.body]; } catch (e) {} return []; }
        return Array.from(n.childNodes);
      }
      function offscreen(el) {
        const r = el.getBoundingClientRect(), w = el.ownerDocument.defaultView;
        return r.bottom < 0 || r.right < 0 || r.top > w.innerHeight || r.left > w.innerWidth;
      }
      const hrefOf = el => { try { const u = new URL(el.href, location.href); return u.origin === location.origin ? u.pathname + u.search + u.hash : u.href; } catch (e) { return el.getAttribute('href'); } };
      function describe(el) {
        if (!el || el.nodeType !== 1) return '';
        const r = role(el) || el.tagName.toLowerCase(), n = name(el, r);
        return r + (n ? ' ' + q(n) : '') + ' ' + refOf(el);
      }

      function snapshot(o) {
        const all = o.filter === 'all', max = o.max || 30000, lines = [];
        let size = 0, omitted = 0;
        const root = o.ref ? byRef(o.ref) : document.body || document.documentElement;
        if (!root) return { error: 'Unknown ref ' + o.ref + ': take a new snapshot.' };
        const emit = (depth, s) => { if (size > max) { omitted++; return; } const line = (all ? '  '.repeat(Math.min(depth, 30)) : '') + '- ' + s; lines.push(line); size += line.length + 1; };
        const stack = [[root, 0]];
        let visited = 0;
        while (stack.length) {
          const [n, depth] = stack.pop();
          if (++visited > 60000) { omitted++; break; }
          if (n.nodeType === 3) {
            if (all) { const t = clip(n.data, 200); if (t) emit(depth, 'text: ' + t); }
            continue;
          }
          if (n.nodeType !== 1 || SKIP.has(n.tagName)) continue;
          if (n.getAttribute('aria-hidden') === 'true' || n.hasAttribute('inert')) continue;
          let st; try { st = cs(n); } catch (e) { st = null; }
          if (st && st.display === 'none') continue;
          const visible = !st || (st.visibility !== 'hidden' && st.visibility !== 'collapse');
          const r = role(n);
          let d = depth, named = false;
          if (visible && r) {
            const isI = interactive(n, r);
            if (isI || r === 'heading' || (all && STRUCT.has(r))) {   // headings: where on the page the controls are
              const rect = n.getBoundingClientRect();
              if (!isI || rect.width > 0 || rect.height > 0 || n.tagName === 'INPUT' && st && st.opacity === '0') {
                const nm = name(n, r), v = value(n, r), ss = states(n, r);
                let s = r + (nm ? ' ' + q(nm) : '') + ' ' + refOf(n);
                if (v != null && v !== '') s += ' value=' + q(v);
                if (r === 'link' && n.href) s += ' → ' + clip(hrefOf(n), 120);
                if (ss.length) s += ' [' + ss.join(', ') + ']';
                if (offscreen(n)) s += ' (offscreen)';
                if (r === 'iframe') { let cross = true; try { cross = !n.contentDocument; } catch (e) {} if (cross) s += ' (other origin: listed under Frames below)'; }
                emit(depth, s); d = depth + 1;
                named = all && nm && ['link', 'button', 'heading', 'option', 'tab', 'cell', 'columnheader', 'menuitem', 'listitem', 'checkbox', 'radio'].includes(r) && !n.querySelector('a, button, input, select, textarea, [role]');
              }
            }
          } else if (visible && interactive(n, null) && !all) {
            emit(depth, 'generic ' + q(textOf(n)) + ' ' + refOf(n) + ' [clickable]' + (offscreen(n) ? ' (offscreen)' : ''));
          }
          if (named) continue;   // its text is already its name
          if (n.tagName === 'SELECT' && !all) continue;
          const k = kids(n);
          for (let i = k.length - 1; i >= 0; i--) stack.push([k[i], d]);
        }
        return { text: lines.join('\n') + (omitted ? '\n… (' + omitted + ' more nodes not shown: snapshot a part with ref, or use find)' : ''),
                 url: location.href, title: document.title, token, count: lines.length };
      }

      // ── Actions ──
      function reveal(el) { if (offscreen(el)) el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); }
      function deepAt(x, y, doc = document) {
        let el = doc.elementFromPoint(x, y);
        while (el && el.shadowRoot) { const inner = el.shadowRoot.elementFromPoint(x, y); if (!inner || inner === el) break; el = inner; }
        if (el && el.tagName === 'IFRAME') { try { const d = el.contentDocument; if (d) { const r = el.getBoundingClientRect(); const inner = deepAt(x - r.left - el.clientLeft, y - r.top - el.clientTop, d); if (inner) return inner; } } catch (e) {} }
        return el;
      }
      const mods = m => ({ shiftKey: !!m.shift, ctrlKey: !!m.ctrl, altKey: !!m.alt, metaKey: !!m.meta });
      function fire(el, type, x, y, o = {}) {
        const E = type.startsWith('pointer') ? PointerEvent : MouseEvent;
        const init = Object.assign({ bubbles: !['mouseenter', 'mouseleave', 'pointerenter', 'pointerleave'].includes(type), cancelable: true, composed: true,
          view: el.ownerDocument.defaultView, clientX: x, clientY: y, screenX: x, screenY: y, button: o.button || 0, buttons: o.buttons || 0,
          detail: o.detail || 0, pointerId: 1, pointerType: 'mouse', isPrimary: true }, mods(o.mods || {}));
        return el.dispatchEvent(new E(type, init));
      }
      function focusable(el) { return el.tabIndex >= 0 || el.isContentEditable || ['INPUT', 'SELECT', 'TEXTAREA', 'BUTTON'].includes(el.tagName) || (el.tagName === 'A' && el.hasAttribute('href')); }
      function point(el) { reveal(el); const r = el.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height }; }
      function hover(el, x, y) {
        for (const t of ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'pointermove', 'mousemove']) fire(el, t, x, y);
      }
      function click(el, o = {}, at) {
        const p = at || point(el);
        let target = el, note = '';
        const top = deepAt(p.x, p.y);
        if (top && (top === el || el.contains(top))) target = top;
        else if (top && !at) note = ' (it was covered by ' + describe(top) + '; clicked it directly)';
        else if (top) target = top;
        const button = o.button === 'right' ? 2 : o.button === 'middle' ? 1 : 0, clicks = Math.max(1, Math.min(3, o.clicks || 1));
        hover(target, p.x, p.y);
        for (let i = 1; i <= clicks; i++) {
          const opt = { button, buttons: 1 << (button === 1 ? 2 : button === 2 ? 1 : 0), detail: i, mods: o.mods };
          // A cancelled pointerdown suppresses the compatibility mouse events (but not the click), as in a real browser.
          const pd = fire(target, 'pointerdown', p.x, p.y, opt), go = pd && fire(target, 'mousedown', p.x, p.y, opt);
          if (go && i === 1) { const f = target.closest && (target.closest('input, select, textarea, button, a[href], [tabindex], [contenteditable]') || null); if (f && focusable(f)) f.focus({ preventScroll: true }); }
          fire(target, 'pointerup', p.x, p.y, Object.assign({}, opt, { buttons: 0 }));
          if (pd) fire(target, 'mouseup', p.x, p.y, Object.assign({}, opt, { buttons: 0 }));
          if (button === 0) fire(target, 'click', p.x, p.y, Object.assign({}, opt, { buttons: 0 }));
          else if (button === 1) fire(target, 'auxclick', p.x, p.y, Object.assign({}, opt, { buttons: 0 }));
        }
        if (button === 0 && clicks === 2) fire(target, 'dblclick', p.x, p.y, { detail: 2, mods: o.mods });
        if (button === 2) fire(target, 'contextmenu', p.x, p.y, { button: 2, mods: o.mods });
        return { ok: true, did: (button === 2 ? 'Right-clicked ' : clicks === 2 ? 'Double-clicked ' : 'Clicked ') + describe(el) + note };
      }
      const proto = el => { const w = el.ownerDocument.defaultView || window; return (el.tagName === 'TEXTAREA' ? w.HTMLTextAreaElement : el.tagName === 'SELECT' ? w.HTMLSelectElement : w.HTMLInputElement).prototype; };
      // The native setter, not the element's own property: frameworks (React) track values through an instance override.
      const setValue = (el, v) => Object.getOwnPropertyDescriptor(proto(el), 'value').set.call(el, v);
      const isField = el => el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && TEXTISH.has((el.getAttribute('type') || '').toLowerCase()));
      function caretToEnd(el) {
        const sel = el.ownerDocument.getSelection();
        if (sel && sel.anchorNode && el.contains(sel.anchorNode)) return;
        const r = el.ownerDocument.createRange(); r.selectNodeContents(el); r.collapse(false); sel.removeAllRanges(); sel.addRange(r);
      }
      function keyInfo(k) {
        const named = { Enter: 13, Tab: 9, Escape: 27, Backspace: 8, Delete: 46, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39, Home: 36, End: 35, PageUp: 33, PageDown: 34, ' ': 32 };
        const code = k.length === 1 ? (/[a-z]/i.test(k) ? 'Key' + k.toUpperCase() : /[0-9]/.test(k) ? 'Digit' + k : k === ' ' ? 'Space' : '') : k;
        return { key: k, code, keyCode: named[k] || (k.length === 1 ? k.toUpperCase().charCodeAt(0) : 0) };
      }
      function key(el, type, k, m = {}) {
        return el.dispatchEvent(new KeyboardEvent(type, Object.assign({ key: k.key, code: k.code, keyCode: k.keyCode, which: k.keyCode, bubbles: true, cancelable: true, composed: true }, mods(m))));
      }
      function insert(el, text, inputType = 'insertText') {
        if (!el.dispatchEvent(new InputEvent('beforeinput', { inputType, data: text, bubbles: true, cancelable: true, composed: true }))) return;
        if (el.isContentEditable) { caretToEnd(el); el.ownerDocument.execCommand(inputType === 'insertLineBreak' ? 'insertLineBreak' : 'insertText', false, text); return; }
        let s = null, e = null; try { s = el.selectionStart; e = el.selectionEnd; } catch (x) {}
        if (s == null) { s = e = el.value.length; }
        if (el.maxLength > 0 && el.value.length - (e - s) + text.length > el.maxLength) return;
        setValue(el, el.value.slice(0, s) + text + el.value.slice(e));
        try { el.setSelectionRange(s + text.length, s + text.length); } catch (x) {}
        el.dispatchEvent(new InputEvent('input', { inputType, data: text, bubbles: true, composed: true }));
      }
      function typeText(el, text) {
        if (!isField(el) && !el.isContentEditable) return { error: describe(el) + ' is not a text field: click the field first, or type with its ref.' };
        if (deepActive() !== el) el.focus({ preventScroll: true });
        for (const ch of text) {
          const k = keyInfo(ch === '\n' ? 'Enter' : ch);
          const go = key(el, 'keydown', k);
          if (go) {
            if (ch === '\n') { if (el.tagName === 'TEXTAREA' || el.isContentEditable) insert(el, '\n', 'insertLineBreak'); else { implicitSubmit(el); } }
            else { key(el, 'keypress', k); insert(el, ch); }
          }
          key(el, 'keyup', k);
        }
        if (!el.isContentEditable) el.dispatchEvent(new Event('change', { bubbles: true }));
        return { ok: true, did: 'Typed ' + text.length + ' characters into ' + describe(el) };
      }
      function implicitSubmit(el) {
        const f = el.form || (el.closest && el.closest('form'));
        if (!f) return '';
        const btn = f.querySelector('button:not([type]), button[type=submit], input[type=submit], input[type=image]');
        if (btn) { if (!btn.disabled) click(btn); return ' and submitted the form'; }
        if (f.requestSubmit) f.requestSubmit(); else f.submit();
        return ' and submitted the form';
      }
      function fill(el, v) {
        const t = el.tagName, ty = (el.getAttribute('type') || '').toLowerCase();
        if (t === 'INPUT' && ty === 'file') return { error: 'File uploads are refused: the learner attaches files themselves.' };
        if (t === 'SELECT') return select(el, [v]);
        if (t === 'INPUT' && (ty === 'checkbox' || ty === 'radio')) return check(el, !/^(false|0|no|off|unchecked)$/i.test(String(v)));
        if (el.isContentEditable) {
          el.focus({ preventScroll: true });
          const r = el.ownerDocument.createRange(); r.selectNodeContents(el); const s = el.ownerDocument.getSelection(); s.removeAllRanges(); s.addRange(r);
          el.ownerDocument.execCommand(v === '' ? 'delete' : 'insertText', false, v);
          return { ok: true, did: 'Filled ' + describe(el) };
        }
        if (t !== 'TEXTAREA' && t !== 'INPUT') return { error: describe(el) + " can't be filled: it isn't a form field." };
        if (el.disabled || el.readOnly) return { error: describe(el) + ' is disabled or read-only.' };
        el.focus({ preventScroll: true });
        el.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertReplacementText', data: String(v), bubbles: true, cancelable: true, composed: true }));
        setValue(el, String(v));
        el.dispatchEvent(new InputEvent('input', { inputType: 'insertReplacementText', data: String(v), bubbles: true, composed: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return { ok: true, did: 'Filled ' + describe(el) + (el.value !== String(v) ? ' (the page changed it to ' + q(el.value) + ')' : '') };
      }
      function select(el, values) {
        if (el.tagName !== 'SELECT') return { error: describe(el) + " isn't a <select>: click it, then click the option's ref." };
        const want = values.map(v => String(v).trim().toLowerCase());
        const opts = Array.from(el.options), picked = opts.filter(o => want.includes(o.value.toLowerCase()) || want.includes(o.text.trim().toLowerCase()));
        if (!picked.length) return { error: 'No option matches ' + values.join(', ') + '. Options: ' + opts.map(o => q(o.text)).join(', ') };
        el.focus({ preventScroll: true });
        opts.forEach(o => { o.selected = picked.includes(o) && (el.multiple || o === picked[0]); });
        el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true }));
        return { ok: true, did: 'Selected ' + picked.map(o => q(o.text)).join(', ') + ' in ' + describe(el) };
      }
      function check(el, want) {
        const r = role(el);
        const on = () => el.tagName === 'INPUT' ? el.checked : el.getAttribute('aria-checked') === 'true';
        if (!['checkbox', 'radio', 'switch', 'menuitemcheckbox', 'menuitemradio'].includes(r)) return { error: describe(el) + " isn't a checkbox or radio button." };
        if (on() !== want) click(el);
        return on() === want ? { ok: true, did: (want ? 'Checked ' : 'Unchecked ') + describe(el) } : { error: describe(el) + " didn't change state (the page may block it)." };
      }
      function tabbables(doc) {
        return Array.from(doc.querySelectorAll('a[href], button, input, select, textarea, [tabindex], [contenteditable]'))
          .filter(e => e.tabIndex >= 0 && !e.disabled && e.getClientRects().length && cs(e).visibility !== 'hidden')
          .sort((a, b) => (a.tabIndex || 1e9) - (b.tabIndex || 1e9));
      }
      function press(combo, el) {
        const parts = combo.split('+').filter(Boolean), m = {};
        let k = parts.pop() || combo;
        for (const p of parts.map(s => s.toLowerCase())) { if (['cmd', 'command', 'meta', 'super'].includes(p)) m.meta = true; else if (['ctrl', 'control'].includes(p)) m.ctrl = true; else if (['alt', 'option'].includes(p)) m.alt = true; else if (p === 'shift') m.shift = true; }
        const alias = { return: 'Enter', enter: 'Enter', esc: 'Escape', escape: 'Escape', tab: 'Tab', space: ' ', backspace: 'Backspace', delete: 'Delete',
          up: 'ArrowUp', down: 'ArrowDown', left: 'ArrowLeft', right: 'ArrowRight', arrowup: 'ArrowUp', arrowdown: 'ArrowDown', arrowleft: 'ArrowLeft',
          arrowright: 'ArrowRight', page_down: 'PageDown', pagedown: 'PageDown', page_up: 'PageUp', pageup: 'PageUp', home: 'Home', end: 'End' };
        k = alias[k.toLowerCase()] || k;
        const target = el || deepActive() || document.body, info = keyInfo(k);
        let did = 'Pressed ' + combo;
        if (key(target, 'keydown', info, m)) {
          const field = isField(target) || target.isContentEditable;
          if (k === 'Enter') {
            if (target.tagName === 'TEXTAREA' || target.isContentEditable) insert(target, '\n', 'insertLineBreak');
            else if (target.tagName === 'INPUT') did += implicitSubmit(target);
            else if (target.matches && target.matches('button, a[href], [role=button], [role=link], summary')) { click(target); did += ' (activated ' + describe(target) + ')'; }
          } else if (k === ' ' && target.matches && target.matches('button, [role=button], input[type=checkbox], input[type=radio], [role=checkbox], summary')) { click(target); did += ' (toggled ' + describe(target) + ')'; }
          else if (k === 'Tab') {
            const list = tabbables(target.ownerDocument || document), i = list.indexOf(target);
            const n = list[(i + (m.shift ? -1 : 1) + list.length) % Math.max(1, list.length)];
            if (n) { n.focus(); did += ' → focus on ' + describe(n); }
          } else if ((k === 'Backspace' || k === 'Delete') && field && !target.isContentEditable) {
            let s = target.selectionStart, e = target.selectionEnd;
            if (s == null) { s = e = target.value.length; }
            if (s === e) { if (k === 'Backspace') s = Math.max(0, s - 1); else e = Math.min(target.value.length, e + 1); }
            setValue(target, target.value.slice(0, s) + target.value.slice(e)); try { target.setSelectionRange(s, s); } catch (x) {}
            target.dispatchEvent(new InputEvent('input', { inputType: k === 'Backspace' ? 'deleteContentBackward' : 'deleteContentForward', bubbles: true, composed: true }));
          } else if (target.isContentEditable && (k === 'Backspace' || k === 'Delete')) target.ownerDocument.execCommand(k === 'Backspace' ? 'delete' : 'forwardDelete');
          else if ((k === 'ArrowDown' || k === 'ArrowUp') && target.tagName === 'SELECT') {
            const i = Math.max(0, Math.min(target.options.length - 1, target.selectedIndex + (k === 'ArrowDown' ? 1 : -1)));
            target.selectedIndex = i; target.dispatchEvent(new Event('input', { bubbles: true })); target.dispatchEvent(new Event('change', { bubbles: true }));
          } else if (k.toLowerCase() === 'a' && (m.meta || m.ctrl) && field) { target.select ? target.select() : target.ownerDocument.execCommand('selectAll'); }
          else if (k.length === 1 && !m.meta && !m.ctrl && field) { key(target, 'keypress', info, m); insert(target, m.shift ? k.toUpperCase() : k); }
        }
        key(target, 'keyup', info, m);
        return { ok: true, did };
      }
      function scrollable(el) {
        for (let e = el; e && e !== document.body && e !== document.documentElement; e = e.parentElement || (e.getRootNode && e.getRootNode().host)) {
          const s = cs(e);
          if (/(auto|scroll|overlay)/.test(s.overflowY + s.overflowX) && (e.scrollHeight > e.clientHeight + 1 || e.scrollWidth > e.clientWidth + 1)) return e;
        }
        return document.scrollingElement || document.documentElement;
      }
      function scroll(o) {
        const el = o.ref ? byRef(o.ref) : null;
        if (o.ref && !el) return { error: 'Unknown ref ' + o.ref + ': take a new snapshot.' };
        if (el && !o.direction) { el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); return { ok: true, did: 'Scrolled ' + describe(el) + ' into view' }; }
        const x = o.x != null ? o.x : innerWidth / 2, y = o.y != null ? o.y : innerHeight / 2;
        const at = el || deepAt(x, y) || document.documentElement, box = scrollable(at);
        const n = (o.amount || 5) * 100, dx = o.direction === 'left' ? -n : o.direction === 'right' ? n : 0, dy = o.direction === 'up' ? -n : o.direction === 'down' ? n : 0;
        const go = at.dispatchEvent(new WheelEvent('wheel', { deltaX: dx, deltaY: dy, deltaMode: 0, clientX: x, clientY: y, bubbles: true, cancelable: true, composed: true }));
        const before = [box.scrollLeft, box.scrollTop];
        if (go) box.scrollBy({ left: dx, top: dy, behavior: 'instant' });
        const moved = box.scrollLeft !== before[0] || box.scrollTop !== before[1];
        const end = box.scrollTop + box.clientHeight >= box.scrollHeight - 2;
        return { ok: true, did: 'Scrolled ' + o.direction + (box === document.scrollingElement ? ' the page' : ' ' + describe(box)) + (moved ? '' : ' (it did not move' + (end ? ': already at the end' : '') + ')') + (end && moved ? ' — reached the end' : '') };
      }
      function find(query) {
        const needle = String(query).toLowerCase(), out = [], seen = new Set();
        const walk = root => {
          const tw = (root.ownerDocument || document).createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
          for (let n = tw.currentNode; n && out.length < 25; n = tw.nextNode()) {
            if (n.nodeType === 1) {
              if (n.shadowRoot) walk(n.shadowRoot);
              if (n.tagName === 'IFRAME') { try { if (n.contentDocument && n.contentDocument.body) walk(n.contentDocument.body); } catch (e) {} }
              const attrs = ['aria-label', 'placeholder', 'title', 'alt', 'value'].map(a => n.getAttribute && n.getAttribute(a) || '').join(' ').toLowerCase();
              if (attrs.includes(needle) && role(n) && !seen.has(n)) { seen.add(n); out.push(describe(n) + (offscreen(n) ? ' (offscreen)' : '')); }
              continue;
            }
            if (n.nodeType !== 3) continue;   // the walk's root can be a shadow root
            const t = n.data, i = t.toLowerCase().indexOf(needle);
            if (i < 0 || !n.parentElement || SKIP.has(n.parentElement.tagName)) continue;
            let el = n.parentElement;
            for (let e = el; e; e = e.parentElement) { const r = role(e); if (r && interactive(e, r)) { el = e; break; } }
            if (seen.has(el) || !el.getClientRects().length) continue;
            seen.add(el);
            out.push(describe(el) + ' — …' + clip(t.slice(Math.max(0, i - 40), i + needle.length + 40), 120) + '…' + (offscreen(el) ? ' (offscreen)' : ''));
          }
        };
        walk(document.body || document.documentElement);
        return { matches: out, token };
      }
      function field(el) {
        return { type: el.getAttribute('type') || el.tagName.toLowerCase(), autocomplete: el.getAttribute('autocomplete') || '',
                 name: [el.name, el.id, el.getAttribute('data-testid')].filter(Boolean).join(' '),
                 label: [name(el, role(el)), el.getAttribute('placeholder')].filter(Boolean).join(' ') };
      }
      function need(o) { const el = byRef(o.ref); if (!el) throw new Error('Unknown ref ' + o.ref + ': take a new snapshot (refs belong to the page they came from).'); return el; }
      // Every call says which frame prefix its refs carry (f2. in a frame of another origin), so results name them right,
      // and which document its refs came from: every document numbers from ref_1, so a ref from the previous page must
      // never land on whatever has that number now.
      const guard = f => o => {
        prefix = (o && o.prefix) || '';
        if (o && o.ref && o.token !== token) return { error: 'stale' };
        let r; try { r = f(o); } catch (e) { r = { error: String(e.message || e) }; }
        if (r && typeof r === 'object' && !Array.isArray(r)) r.token = token;   // the refs in an answer belong to this document
        return r;
      };

      window.__ta = {
        token,
        snapshot: guard(snapshot),
        find: guard(o => find(o.query)),
        field: guard(o => field(o.ref ? need(o) : deepActive())),
        at: guard(o => { const el = deepAt(o.x, o.y); return el ? { ref: refOf(el), what: describe(el) } : { error: 'Nothing at (' + o.x + ', ' + o.y + ').' }; }),
        click: guard(o => { const el = o.ref ? need(o) : deepAt(o.x, o.y); if (!el) return { error: 'Nothing at that point.' };
          return click(el, o, o.ref ? null : { x: o.x, y: o.y }); }),
        hover: guard(o => { const el = o.ref ? need(o) : deepAt(o.x, o.y); if (!el) return { error: 'Nothing at that point.' };
          const p = o.ref ? point(el) : { x: o.x, y: o.y }; hover(el, p.x, p.y); return { ok: true, did: 'Hovered over ' + describe(el) }; }),
        type: guard(o => { const el = o.ref ? need(o) : deepActive(); if (!el || el === document.body) return { error: 'No field has focus: give the ref of the field to type into.' };
          const r = typeText(el, o.text); if (r.ok && o.submit) r.did += press('Enter', el).did.replace('Pressed Enter', ''); return r; }),
        fill: guard(o => fill(need(o), o.value == null ? '' : o.value)),
        select: guard(o => select(need(o), o.values)),
        check: guard(o => check(need(o), o.checked !== false)),
        key: guard(o => press(o.key, o.ref ? need(o) : null)),
        scroll: guard(scroll),
        info: guard(() => ({ url: location.href, title: document.title, w: innerWidth, h: innerHeight, sx: scrollX, sy: scrollY,
                       docH: document.documentElement.scrollHeight, focus: describe(deepActive()), token })),
        html: () => document.documentElement.outerHTML.slice(0, 3000000),
        // Resolves once the document has had no mutations for `ms` (or after `max`), and not before `min`: an action's
        // effect has landed (a click's handler may answer on a short timer, so clicks watch a little longer).
        visible: () => (document.body ? document.body.innerText : '').slice(0, 300000),
        quiet: o => new Promise(res => {
          const ms = (o && o.ms) || 100, max = (o && o.max) || 1200, min = (o && o.min) || 0, t0 = performance.now();
          let last = t0;
          const mo = new MutationObserver(() => { last = performance.now(); });
          try { mo.observe(document, { subtree: true, childList: true, attributes: true, characterData: true }); } catch (e) {}
          const tick = () => {
            const now = performance.now();
            if ((now - last >= ms && now - t0 >= min) || now - t0 >= max) { mo.disconnect(); res({ quiet: now - last >= ms, ms: Math.round(now - t0) }); }
            else setTimeout(tick, 20);
          };
          setTimeout(tick, 20);
        }),
        wait: o => o.text ? (document.body && document.body.innerText.toLowerCase().includes(String(o.text).toLowerCase()))
                 : (() => { let el = null; try { el = document.querySelector(o.selector); } catch (e) { return 'bad selector'; } return !!(el && el.getClientRects().length); })(),
        resources: () => performance.getEntriesByType('resource').slice(-150).map(e => ({ url: e.name, type: e.initiatorType, ms: Math.round(e.duration),
                       size: e.transferSize, status: e.responseStatus || null })),
      };
    })();
    """#

    /// Console and network capture in the page's own world (it has to wrap the page's console, fetch and XHR). Pages can
    /// post to it too, so what it reports is labelled untrusted like everything else from the page.
    static let logger = #"""
    (() => {
      if (window.__taLogInstalled) return; window.__taLogInstalled = true;
      const post = m => { try { window.webkit.messageHandlers.taLog.postMessage(m); } catch (e) {} };
      const fmt = a => { try { if (typeof a === 'string') return a; if (a instanceof Error) return a.name + ': ' + a.message; return JSON.stringify(a); } catch (e) { return String(a); } };
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const orig = console[level];
        console[level] = function (...args) { post({ t: 'console', level, text: args.map(fmt).join(' ').slice(0, 2000) }); return orig.apply(this, args); };
      }
      addEventListener('error', e => { if (e.message) post({ t: 'console', level: 'error', text: 'Uncaught ' + e.message + (e.filename ? ' (' + e.filename + ':' + e.lineno + ')' : '') }); });
      addEventListener('unhandledrejection', e => post({ t: 'console', level: 'error', text: 'Unhandled rejection: ' + fmt(e.reason) }));
      const of = window.fetch;
      if (of) window.fetch = function (input, init) {
        const t0 = performance.now(), url = String(input && input.url || input), method = String(init && init.method || input && input.method || 'GET').toUpperCase();
        post({ t: 'net', phase: 'start' });
        return of.apply(this, arguments).then(r => { post({ t: 'net', phase: 'end', kind: 'fetch', method, url, status: r.status, ms: Math.round(performance.now() - t0), type: r.headers.get('content-type') || '' }); return r; },
          e => { post({ t: 'net', phase: 'end', kind: 'fetch', method, url, status: 0, error: String(e), ms: Math.round(performance.now() - t0) }); throw e; });
      };
      const X = XMLHttpRequest.prototype, open = X.open, send = X.send;
      X.open = function (m, u) { this.__ta = { method: String(m).toUpperCase(), url: String(u) }; return open.apply(this, arguments); };
      X.send = function () {
        const info = this.__ta || { method: 'GET', url: '' }, t0 = performance.now();
        post({ t: 'net', phase: 'start' });
        this.addEventListener('loadend', () => post({ t: 'net', phase: 'end', kind: 'xhr', method: info.method, url: info.url, status: this.status, ms: Math.round(performance.now() - t0), type: this.getResponseHeader('content-type') || '' }));
        return send.apply(this, arguments);
      };
    })();
    """#
}
