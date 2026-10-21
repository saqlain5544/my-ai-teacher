// Odin for Highlight.js, written for My AI Teacher — highlight.js ships none.
hljs.registerLanguage('odin', hljs => ({
  name: 'Odin',
  keywords: {
    keyword: ['package', 'import', 'foreign', 'proc', 'struct', 'enum', 'union', 'bit_set', 'bit_field', 'map', 'dynamic',
      'distinct', 'using', 'when', 'where', 'if', 'else', 'for', 'in', 'not_in', 'switch', 'case', 'fallthrough', 'defer',
      'return', 'break', 'continue', 'or_else', 'or_return', 'or_break', 'or_continue', 'do', 'cast', 'transmute', 'auto_cast',
      'matrix', 'context'],
    type: ['int', 'uint', 'i8', 'i16', 'i32', 'i64', 'i128', 'u8', 'u16', 'u32', 'u64', 'u128', 'uintptr', 'f16', 'f32', 'f64',
      'complex64', 'complex128', 'quaternion256', 'bool', 'b8', 'b16', 'b32', 'b64', 'string', 'cstring', 'rune', 'rawptr',
      'any', 'typeid', 'byte'],
    literal: ['true', 'false', 'nil'],
    built_in: ['len', 'cap', 'size_of', 'align_of', 'offset_of', 'type_of', 'typeid_of', 'make', 'new', 'free', 'delete',
      'append', 'clear', 'min', 'max', 'abs', 'clamp', 'swizzle', 'assert', 'panic'],
  },
  contains: [
    hljs.C_LINE_COMMENT_MODE, hljs.COMMENT(/\/\*/, /\*\//, { contains: ['self'] }),   // block comments nest
    { scope: 'string', begin: /"/, end: /"/, illegal: /\n/, contains: [hljs.BACKSLASH_ESCAPE] },
    { scope: 'string', begin: /`/, end: /`/ },
    { scope: 'string', begin: /'/, end: /'/, illegal: /\n/, contains: [hljs.BACKSLASH_ESCAPE] },
    { scope: 'meta', match: /#\+?[a-z_]+|@\(?[a-z_]*/ },                     // #+build, #partial, @(private)
    { scope: 'number', match: /\b(?:0[xbo][0-9a-fA-F_]+|[0-9][0-9_]*(?:\.[0-9_]+)?(?:[eE][-+]?[0-9]+)?[ij]?)\b/, relevance: 0 },
    { match: [/\b[A-Za-z_][A-Za-z0-9_]*/, /\s*::\s*/, /proc\b/], scope: { 1: 'title.function', 3: 'keyword' } },
    { match: [/\b[A-Z][A-Za-z0-9_]*/, /\s*::\s*/, /(?:struct|enum|union|distinct)\b/], scope: { 1: 'title.class', 3: 'keyword' } },
  ],
}));
