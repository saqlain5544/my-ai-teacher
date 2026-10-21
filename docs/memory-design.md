# Memory design: a learner model, not an append log

## What the evidence says (short)

| Source | Idea | What we take |
|---|---|---|
| **mem0** (Chhikara et al., 2025, arXiv:2504.19413) | Extract candidate facts, retrieve similar existing ones, then the LLM picks **ADD / UPDATE / DELETE / NOOP** against them. Fewer tokens and better accuracy than full-context or plain RAG on LOCOMO. | Reflection gets the related memories (with ids) and returns ops. A deterministic layer checks every op: durability filter, dedup merge, history. |
| **Letta / MemGPT** (Packer et al., 2023, arXiv:2310.08560) and **sleep-time compute** (Lin et al., 2025, arXiv:2504.13171) | A small, labelled **core memory block** is always in context. Archival memory is searched on demand. A background agent consolidates memory between sessions, off the critical path. | `coreBlock()` stays small and stable for each lesson (prompt caching). It is built from structured sections, not a dump. Consolidation runs in the background in two passes: a deterministic local pass and an optional LLM pass. |
| **Zep / Graphiti** (Rasmussen et al., 2025, arXiv:2501.13956) | A temporal knowledge graph: entities plus edges with validity intervals. Superseded facts are invalidated, not lost. Retrieval is hybrid (BM25 + embeddings + graph). | A concept graph (nodes, subject tags, prerequisite and related edges). `memory_history` keeps every superseded version (provenance). Retrieval is hybrid lexical + embedding + concept routing. |
| **A-MEM** (Xu et al., 2025, arXiv:2502.12110) | Zettelkasten-style notes with keywords and links. New notes link to old ones and can refine them. | Memories link to concept nodes, so misconceptions and goals hang off the concept they are about. Concepts link across subjects. |
| **Generative Agents** (Park et al., 2023, arXiv:2304.03442) | Retrieval score = recency + importance + relevance. Periodic *reflection* writes higher-level insights. | The ranking adds a small importance and recency prior to relevance. Relevance must clear the bar on its own. Consolidation may add cross-subject insights. |
| **Knowledge tracing**: BKT (Corbett & Anderson, 1994), DKT (Piech et al., 2015), and FSRS (Ye, 2022–24) | Mastery is a latent per-skill probability updated from evidence. Forgetting follows a power law. | We **reuse** `StudyStore` (BKT `mastery` table, FSRS cards). The graph caches the latest BKT estimate for each concept through an incremental sync and never re-implements it. |
| **Prerequisite graphs** (e.g. Pan et al., 2017; Liang et al., 2015; knowledge-space theory, Doignon & Falmagne) | Concepts form a DAG of prerequisites. Weak prerequisites explain failures downstream. | `concept_edges(rel = prereq / related / part_of)`. Recall for a concept surfaces weak prerequisites. Subjects are tags, so one concept can belong to several subjects (Arabic + poetry → "Arabic prosody"). Subject dependencies come from the edges. |

## Decisions

1. **The data model** has three parts:
   - **Memories**: the existing table, with new columns `concept_id`, `status`, `evidence` and `norm`.
   - **Concept nodes**: `concepts`, `concept_aliases`, `concept_subjects` and `concept_edges`. These live in the learner DB only.
   - **History**: the `memory_history` table.

   Kinds stay the same (profile, preference, goal, knowledge, misconception, episode, fact). *Knowledge* now becomes a concept node with mastery, not a sentence.
2. **Only durable facts are stored.** A deterministic `MemoryPolicy` rejects writes that can be derived from elsewhere:
   - one-off requests ("asked for the derivative of sin(x²)");
   - one-off results (quiz scores are already in BKT);
   - session-bound statements ("today…");
   - app or tool mechanics;
   - fragments that are too short.

   Facts the learner explicitly asked to keep bypass the filter.
3. **The system updates rather than adds.** Writes go through dedup:
   - an exact `norm` hash bucket catches identical facts;
   - an in-memory inverted term index finds candidates;
   - an embedding LSH (8 bands × 10 bits) also finds candidates;
   - only those candidates are verified with cosine + stem Jaccard.

   This is O(candidates), not O(N). A merge bumps `evidence` and keeps the longer or more specific text. Contradictions are resolved by the LLM (UPDATE with history), because deterministic "slot" heuristics would wrongly overwrite facts that are both true ("speaks Arabic" and "speaks French").
4. **Retrieval is lean.** Each candidate gets three evidence signals:
   - lexical: IDF-weighted stem overlap, saturating;
   - semantic: NLEmbedding cosine, rescaled;
   - concept routing: the query names a known concept.

   The signals are combined with noisy-OR. NLEmbedding is weak (unrelated sentences often score 0.3–0.6), so semantic evidence alone carries little weight. Auto-recall injects **0–2** items, never what the core block already holds, and only above a threshold calibrated on a labelled set (`MemoryQualityTests`).
5. **Scale.** Each store keeps an in-memory index (docs, postings, normalised vectors, LSH buckets) rebuilt from SQLite. `PRAGMA data_version` detects writes from other processes, such as the CLI. Search is linear, using vDSP dot products. Dedup is sub-linear.
6. **Consolidation.** The local pass, run on every reflection, does the following:
   - merges duplicates and concepts that share an alias;
   - decays unused, non-explicit items and archives them;
   - caps episodes;
   - syncs mastery.

   The LLM pass (weekly, or after 10+ new items) merges, rewrites, links concepts and resolves contradictions. Op application is deterministic and unit-tested.
7. **One tool.** `memory` with `action: search|save|update|forget` (≈200 tokens of schema) replaces the 4 tools. Ids: `12` learner memory, `f12` folder memory, `c7` concept.

Measured results are in the PR/commit message and `MemoryQualityTests` output.
