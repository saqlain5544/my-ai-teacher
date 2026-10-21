// HCL / Terraform / OpenTofu for Highlight.js, written for My AI Teacher — highlight.js ships none.
hljs.registerLanguage('hcl', hljs => {
  const INTERP = { scope: 'subst', begin: /[$%]\{/, end: /\}/, keywords: { literal: ['true', 'false', 'null'] } };
  return {
    name: 'HCL',
    aliases: ['terraform', 'tf', 'tfvars', 'opentofu', 'nomad'],
    keywords: {
      keyword: ['for', 'in', 'if', 'else', 'endif', 'endfor', 'dynamic', 'content', 'each', 'count', 'var', 'local', 'module',
        'data', 'path', 'terraform', 'self'],
      literal: ['true', 'false', 'null'],
      type: ['string', 'number', 'bool', 'list', 'map', 'set', 'object', 'tuple', 'any'],
    },
    contains: [
      hljs.HASH_COMMENT_MODE, hljs.C_LINE_COMMENT_MODE, hljs.C_BLOCK_COMMENT_MODE,
      { scope: 'string', begin: /<<-?\s*([A-Z_]+)\s*$/, end: /^\s*[A-Z_]+\s*$/, contains: [INTERP] },   // heredoc
      { scope: 'string', begin: /"/, end: /"/, contains: [hljs.BACKSLASH_ESCAPE, INTERP] },
      { scope: 'number', match: /\b[0-9]+(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?\b/, relevance: 0 },
      // resource "aws_instance" "web" {  /  provider "aws" {  /  locals {
      { match: [/^\s*(?:resource|data|provider|variable|output|module|locals|terraform|backend|required_providers|provisioner|moved|import|check|removed|job|group|task)\b/],
        scope: { 1: 'keyword' } },
      { scope: 'attr', match: /^\s*[A-Za-z_][\w-]*(?=\s*=(?!=))/ },
      { scope: 'title.function.invoke', match: /\b[a-z_][a-z0-9_]*(?=\()/, relevance: 0 },
    ],
  };
});
