// Gleam for Highlight.js, written for My AI Teacher — highlight.js ships none.
hljs.registerLanguage('gleam', hljs => ({
  name: 'Gleam',
  keywords: {
    keyword: ['as', 'assert', 'auto', 'case', 'const', 'echo', 'fn', 'if', 'import', 'let', 'opaque', 'panic', 'pub', 'todo',
      'type', 'use'],
    literal: ['True', 'False', 'Nil'],
  },
  contains: [
    hljs.COMMENT(/\/\//, /$/),
    { scope: 'string', begin: /"/, end: /"/, contains: [hljs.BACKSLASH_ESCAPE] },
    { scope: 'meta', match: /@[a-z_]+/ },                                     // @external, @deprecated
    { scope: 'number', match: /\b(?:0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|[0-9][0-9_]*(?:\.[0-9_]*)?(?:e-?[0-9]+)?)\b/, relevance: 0 },
    { scope: 'type', match: /\b[A-Z][A-Za-z0-9]*\b/ },
    { match: [/\bfn/, /\s+/, /[a-z_][a-z0-9_]*/], scope: { 1: 'keyword', 3: 'title.function' } },
    { scope: 'operator', match: /\|>|<>|->|\.\.|[-+*/]\.?|==|!=|<=?\.?|>=?\.?|&&|\|\|/, relevance: 0 },
  ],
}));
