// Zig for Highlight.js (0.11 to 0.17 syntax: old keywords kept for older code), written for My AI Teacher — highlight.js ships no Zig grammar.
hljs.registerLanguage('zig', hljs => {
  const IDENT = /[A-Za-z_][A-Za-z0-9_]*/;
  const ESCAPE = { scope: 'char.escape', match: /\\(?:x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]+\}|[nrt'"\\])/ };
  return {
    name: 'Zig',
    aliases: ['zon'],
    keywords: {
      keyword: ['addrspace', 'align', 'allowzero', 'and', 'anyframe', 'anytype', 'asm', 'async', 'await', 'break', 'callconv',
        'catch', 'comptime', 'const', 'continue', 'defer', 'else', 'enum', 'errdefer', 'error', 'export', 'extern', 'fn', 'for',
        'if', 'inline', 'linksection', 'noalias', 'noinline', 'nosuspend', 'opaque', 'or', 'orelse', 'packed', 'pub', 'resume',
        'return', 'struct', 'suspend', 'switch', 'test', 'threadlocal', 'try', 'union', 'unreachable', 'usingnamespace', 'var',
        'volatile', 'while'],
      type: ['anyerror', 'anyopaque', 'bool', 'c_char', 'c_int', 'c_long', 'c_longdouble', 'c_longlong', 'c_short', 'c_uint',
        'c_ulong', 'c_ulonglong', 'c_ushort', 'comptime_float', 'comptime_int', 'f16', 'f32', 'f64', 'f80', 'f128', 'isize',
        'noreturn', 'type', 'usize', 'void'],
      literal: ['true', 'false', 'null', 'undefined'],
    },
    contains: [
      hljs.COMMENT(/\/\//, /$/),                                                // also /// and //! doc comments
      { scope: 'string', begin: /\\\\/, end: /$/ },                             // a multiline string line
      { scope: 'string', begin: /"/, end: /"/, illegal: /\n/, contains: [ESCAPE] },
      { scope: 'string', begin: /'/, end: /'/, illegal: /\n/, contains: [ESCAPE] },
      { scope: 'variable', begin: /@"/, end: /"/, contains: [ESCAPE] },          // @"quoted identifier"
      { scope: 'built_in', match: /@[A-Za-z_][A-Za-z0-9_]*/ },                  // @import, @intCast, @This…
      { scope: 'type', match: /\b[iu](?:0|[1-9][0-9]{0,4})\b/ },                // arbitrary-width ints: u8, i32, u7
      { scope: 'number', relevance: 0, variants: [
        { match: /\b0x[0-9a-fA-F_]+(?:\.[0-9a-fA-F_]+)?(?:[pP][-+]?[0-9_]+)?\b/ },
        { match: /\b0o[0-7_]+\b/ },
        { match: /\b0b[01_]+\b/ },
        { match: /\b[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][-+]?[0-9_]+)?\b/ },
      ] },
      { match: [/\bfn/, /\s+/, IDENT], scope: { 1: 'keyword', 3: 'title.function' } },
      { match: [/\b(?:const|var)/, /\s+/, IDENT], scope: { 1: 'keyword', 3: 'variable' } },
      { match: [/\berror/, /\./, IDENT], scope: { 1: 'keyword', 3: 'symbol' } },  // error.OutOfMemory
      { match: [/\b(?:break|continue)/, /\s+/, /:[A-Za-z_][A-Za-z0-9_]*/], scope: { 1: 'keyword', 3: 'symbol' } },
      { scope: 'symbol', match: /\b[A-Za-z_][A-Za-z0-9_]*:(?=\s*(?:while|for|inline|\{))/ },   // blk: { … }
      { scope: 'title.function.invoke', relevance: 0,   // a call, never a keyword followed by "(": if (…), while (…)
        match: /\b(?!(?:if|while|for|switch|catch|return|try|fn|and|or|orelse|comptime|inline|align|callconv|addrspace|linksection|struct|union|enum|opaque|asm|suspend|resume|defer|errdefer|test)\b)[A-Za-z_][A-Za-z0-9_]*(?=\s*\()/ },
    ],
  };
});
