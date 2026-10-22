// The exercise editor's CodeMirror: core, editing commands, search, autocomplete, linting UI and the languages the
// app runs. Bundled into Resources/web/vendor/codemirror.js (window.CM) by `npm run build`.
export { EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, drawSelection, dropCursor,
  rectangularSelection, crosshairCursor, highlightSpecialChars } from '@codemirror/view';
export { EditorState, Compartment } from '@codemirror/state';
export { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands';
export { searchKeymap, highlightSelectionMatches } from '@codemirror/search';
export { autocompletion, closeBrackets, closeBracketsKeymap, completionKeymap } from '@codemirror/autocomplete';
export { bracketMatching, indentOnInput, foldGutter, foldKeymap, syntaxHighlighting, defaultHighlightStyle,
  HighlightStyle, StreamLanguage, indentUnit } from '@codemirror/language';
export { tags } from '@lezer/highlight';
export { python } from '@codemirror/lang-python';
export { javascript } from '@codemirror/lang-javascript';
export { cpp } from '@codemirror/lang-cpp';
export { rust } from '@codemirror/lang-rust';
export { go } from '@codemirror/lang-go';
export { java } from '@codemirror/lang-java';
export { html } from '@codemirror/lang-html';
export { css } from '@codemirror/lang-css';
export { json } from '@codemirror/lang-json';
export { markdown } from '@codemirror/lang-markdown';
export { sql } from '@codemirror/lang-sql';
export { swift } from '@codemirror/legacy-modes/mode/swift';
export { ruby } from '@codemirror/legacy-modes/mode/ruby';
export { shell } from '@codemirror/legacy-modes/mode/shell';
export { toml } from '@codemirror/legacy-modes/mode/toml';
export { yaml } from '@codemirror/legacy-modes/mode/yaml';
