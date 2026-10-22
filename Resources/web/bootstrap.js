// Loads the transcript's modules from the generated manifest (components/manifest.js), then the core (app.js).
// index.html lists no component: adding one is a new file under components/ and `scripts/gen-web-manifest.py`.
// Modules marked lazy are not loaded here: the core fetches them the first time a reply uses one of their components.
// Scripts are inserted with async=false, so they run in manifest order; a module that fails to load is logged and the
// core still starts (one broken component must never take the transcript down).
(function () {
  'use strict';
  const R = window.TeacherUI;
  const M = window.TeacherManifest || { modules: [] };
  const loaded = new Map();   // src -> Promise
  function load(src) {
    if (loaded.has(src)) return loaded.get(src);
    const p = new Promise(resolve => {
      const s = document.createElement('script');
      s.src = src; s.async = false;
      s.onload = () => resolve(true);
      s.onerror = () => { console.log('module failed to load: ' + src); resolve(false); };
      document.head.appendChild(s);
    });
    loaded.set(src, p);
    return p;
  }
  R.loadModule = load;
  R.manifest = M;
  for (const m of M.modules) {
    if (m.lazy && m.lazy.length) R.defineLazy(m.lazy, m.src);
    else load(m.src);
  }
  load('app.js');
})();
