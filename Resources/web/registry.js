// Extension points for the transcript renderer. Component files register here; app.js (the core) calls them.
// Adding a feature = adding a file under components/ — the core does not change.
(function () {
  'use strict';
  const R = {
    fences: {},        // fence language -> (code, ctx, env) => html          (```chart, ```vocab, …)
    toolCards: {},     // tool name -> (block, result, pending, ctx) => html | null
    questionTypes: {}, // question type -> { render(q, qi, state, ctx), read(el, q, qi, state), review(q, grade, given, ctx) }
    processors: [],    // (rootElement, ctx) => void, run on freshly inserted DOM
    mdPlugins: [],     // (markdownIt) => void
    actions: {},       // data-act value -> (element, event, ctx) => void
    inputs: [],        // (event, ctx) => void for input/change events
    footers: [],       // (message, turnMessages, ctx) => html   rendered under a finished reply
    registerFence(names, fn) { [].concat(names).forEach(n => { this.fences[n] = fn; }); },
    registerToolCard(names, fn) { [].concat(names).forEach(n => { this.toolCards[n] = fn; }); },
    registerQuestionType(names, impl) { [].concat(names).forEach(n => { this.questionTypes[n] = impl; }); },
    registerProcessor(fn) { this.processors.push(fn); },
    registerMarkdown(fn) { this.mdPlugins.push(fn); },
    registerAction(names, fn) { [].concat(names).forEach(n => { this.actions[n] = fn; }); },
    registerInput(fn) { this.inputs.push(fn); },
    registerFooter(fn) { this.footers.push(fn); },
  };
  window.TeacherUI = R;
})();
