---
name: read-long-documents
description: Work through a long PDF, paper, book chapter, log or large file — summarise it, find what matters, or answer questions about it with page or line references.
---

# Reading long documents

1. **Get the shape first.** `read` the start (title, contents, abstract, headings). For a large file, `grep` for the
   headings or key terms to find where things are before reading in full.
2. **Read in passes, by section.** `read` with `offset`/`limit` a section at a time; don't load the whole thing when
   the question concerns part of it. For several files, read the independent ones in one step.
3. **Keep notes as you go**, per section: the claim, the evidence, the page or line. Your notes, not the raw text, are
   what you build the answer from.
4. **Answer the question asked.** A summary for someone deciding something leads with the conclusion and what it means
   for them; a study summary keeps the structure and the definitions.
5. **Cite locations**: page numbers for PDFs, `path:line` for files, section names otherwise. Quote sparingly and
   exactly; paraphrase the rest.
6. **Say what you skipped** (appendices, tables you didn't check) so the reader knows the limits.

For questions over many documents, hand each document to an `explore` sub-agent (`task`) with the same question and
merge their reports.
