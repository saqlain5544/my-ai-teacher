// Solidity for Highlight.js, written for My AI Teacher — highlight.js ships none.
hljs.registerLanguage('solidity', hljs => ({
  name: 'Solidity',
  aliases: ['sol'],
  keywords: {
    keyword: ['pragma', 'solidity', 'import', 'from', 'as', 'contract', 'interface', 'library', 'abstract', 'is', 'function',
      'modifier', 'event', 'error', 'struct', 'enum', 'mapping', 'constructor', 'fallback', 'receive', 'returns', 'return', 'if',
      'else', 'for', 'while', 'do', 'break', 'continue', 'emit', 'revert', 'new', 'delete', 'try', 'catch', 'using', 'unchecked',
      'assembly', 'public', 'private', 'internal', 'external', 'pure', 'view', 'payable', 'virtual', 'override', 'constant',
      'immutable', 'memory', 'storage', 'calldata', 'transient', 'indexed', 'anonymous', 'type', 'let', 'switch', 'case', 'default'],
    type: ['address', 'bool', 'string', 'bytes', 'byte', 'int', 'uint', 'fixed', 'ufixed'],
    literal: ['true', 'false'],
    built_in: ['msg', 'block', 'tx', 'abi', 'this', 'super', 'selfdestruct', 'keccak256', 'sha256', 'ripemd160', 'ecrecover',
      'require', 'assert', 'addmod', 'mulmod', 'gasleft', 'blockhash', 'wei', 'gwei', 'ether', 'seconds', 'minutes', 'hours', 'days', 'weeks'],
  },
  contains: [
    hljs.C_LINE_COMMENT_MODE, hljs.C_BLOCK_COMMENT_MODE, hljs.APOS_STRING_MODE, hljs.QUOTE_STRING_MODE,
    { scope: 'string', begin: /(?:hex|unicode)"/, end: /"/ },
    { scope: 'type', match: /\b(?:u?int(?:8|16|24|32|40|48|56|64|72|80|88|96|104|112|120|128|136|144|152|160|168|176|184|192|200|208|216|224|232|240|248|256)|bytes(?:[1-9]|[12][0-9]|3[0-2]))\b/ },
    { scope: 'number', match: /\b(?:0x[0-9a-fA-F_]+|[0-9][0-9_]*(?:\.[0-9_]+)?(?:e[0-9]+)?)\b/, relevance: 0 },
    { match: [/\b(?:contract|interface|library|struct|enum|event|error|modifier)/, /\s+/, /[A-Za-z_$][\w$]*/], scope: { 1: 'keyword', 3: 'title.class' } },
    { match: [/\bfunction/, /\s+/, /[A-Za-z_$][\w$]*/], scope: { 1: 'keyword', 3: 'title.function' } },
  ],
}));
