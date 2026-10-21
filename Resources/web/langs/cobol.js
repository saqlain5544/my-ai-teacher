// COBOL for Highlight.js, written for My AI Teacher — highlight.js ships none.
hljs.registerLanguage('cobol', hljs => ({
  name: 'COBOL',
  aliases: ['cob', 'cbl', 'cpy'],
  case_insensitive: true,
  keywords: {
    $pattern: /[A-Za-z][A-Za-z0-9-]*/,
    keyword: ['identification', 'environment', 'data', 'procedure', 'division', 'section', 'program-id', 'author',
      'working-storage', 'local-storage', 'linkage', 'file', 'file-control', 'input-output', 'configuration', 'fd', 'sd', 'select',
      'assign', 'organization', 'access', 'record', 'pic', 'picture', 'value', 'values', 'occurs', 'times', 'depending', 'redefines',
      'usage', 'comp', 'comp-3', 'binary', 'packed-decimal', 'display', 'accept', 'move', 'to', 'from', 'into', 'giving', 'add',
      'subtract', 'multiply', 'divide', 'compute', 'remainder', 'rounded', 'if', 'else', 'end-if', 'evaluate', 'when', 'other',
      'end-evaluate', 'perform', 'until', 'varying', 'by', 'thru', 'through', 'end-perform', 'go', 'goback', 'stop', 'run', 'call',
      'using', 'returning', 'open', 'close', 'read', 'write', 'rewrite', 'delete', 'start', 'input', 'output', 'extend', 'at', 'end',
      'not', 'and', 'or', 'is', 'initialize', 'string', 'unstring', 'delimited', 'size', 'inspect', 'tallying', 'replacing',
      'continue', 'exit', 'copy', 'set', 'search', 'invalid', 'key', 'with', 'no', 'advancing', 'upon', 'function', 'of', 'in'],
    literal: ['zero', 'zeros', 'zeroes', 'space', 'spaces', 'high-value', 'high-values', 'low-value', 'low-values', 'quote', 'quotes', 'true', 'false'],
  },
  contains: [
    hljs.COMMENT(/\*>/, /$/),
    hljs.COMMENT(/^.{6}\*/, /$/),                                             // fixed format: * in column 7
    { scope: 'string', begin: /"/, end: /"/ }, { scope: 'string', begin: /'/, end: /'/ },
    { scope: 'number', match: /^\s*(?:0[1-9]|[1-4][0-9]|66|77|88)\b/ },          // level numbers
    { scope: 'number', match: /\b[0-9]+(?:\.[0-9]+)?\b/, relevance: 0 },
    { scope: 'title.function', match: /^\s{0,8}[A-Za-z0-9][A-Za-z0-9-]*(?=\.\s*$)/ },   // paragraph names
  ],
}));
