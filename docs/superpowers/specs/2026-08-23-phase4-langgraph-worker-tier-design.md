# Phase 4: LangGraph Worker Tier — Design

## Context

Phase 3 (Terminal Backend Confinement) is merged to `main`. This spec
covers Phase 4 per the vault's `Implementation Strategy.md` §9 ("LangGraph
Worker Tier"): standing up the local-model worker tier — Ollama +
LangGraph, exposed to Hermes as an MCP server over streamable HTTP with
narrow, predefined tool signatures rather than arbitrary local-model
execution.

**Deviation from the vault's original pilot workload, decided during
design:** the vault named SilentScribe (`run_silentscribe`,
`summarize_corpus`) as the pilot. Checked live against SilentScribe's own
repo (`~/Repos/SilentScribe`) and its vault status doc — only the
manifest loader is built and tested; the CLI entry point, extractors, LLM
client, and note writer are all still "planned, not implemented" (~70% of
its own pipeline). Rather than block Phase 4 on finishing a separate
project, this phase builds the real infrastructure (Ollama, LangGraph,
MCP server, narrow tool signatures) against a **new pilot workload**
that's actually achievable now: a codebase knowledge-graph/documentation
tool, generically useful across every project this host works on, not
tied to any one repo. SilentScribe can be wired in later as an additional
tool once its own pipeline is finished — the MCP interface pattern
doesn't change either way.

## Goals

- Ollama (**Pythia**) and the LangGraph service (**Hephaestus**) running
  on `delphi` (`internal: true`, zero internet egress — unchanged from
  the vault's original network segmentation).
- Hephaestus exposes an MCP server (streamable HTTP) with three narrow
  tools: `build_knowledge_graph`, `job_status`, `query_knowledge_graph`
  (see Components below).
- Hermes gains a second network membership (`delphi`, alongside its
  existing `olympus`/`cerberus_net`) so it can reach Hephaestus's MCP
  endpoint. `delphi` remaining `internal: true` still means neither
  Hephaestus nor Pythia gets an internet route — Hermes's own internet
  access is unaffected, it comes from its other network memberships.
- A pilot tool (`build_knowledge_graph`) that produces two artifacts per
  target repo: a real, structurally-accurate knowledge graph (JSON) and a
  flattened Markdown digest derived from it — both build artifacts, never
  written back into the source repo.
- Async job model (receipt now, Signal delivery on completion) — required
  because local-model inference at single-digit tokens/sec makes
  synchronous replies unacceptable, per the vault's hybrid-tier rationale
  (§2, §3).
- Phase gate: a `build_knowledge_graph` run dispatched from Signal against
  this repo (`AgentsOfOlympus`) completes, delivers via Signal, and
  produces a real, queryable graph.

## Non-goals

- Not finishing SilentScribe's own pipeline (extractors, LLM client, note
  writer, `scribe.py`) — that's separate work in SilentScribe's own repo,
  sequenced by its own build-order doc. This phase does not block on it
  and does not preclude wiring it in later as an additional MCP tool.
- Not giving the worker tier write access to source repos, or any ability
  to commit/PR changes itself — consistent with Phase 3's branch-
  protection-via-PR standing policy. All source repo mounts are read-only;
  the only writable mount is the dedicated output directory.
- Not building the graph structure via LLM reasoning. Structural
  extraction (nodes/edges) is deterministic static analysis
  (`tree-sitter`); the LLM's role is bounded to per-node natural-language
  summarization, never inventing graph structure.
- No remote/git-clone capability for the worker tier — `delphi` has zero
  egress by design. Target repos must already exist as local clones under
  `REPOS_ROOT` for an unrelated reason (active development, or Phase 3's
  own confined terminal-backend dev work against that same repo).

## Components

1. **Pythia (Ollama).** Standard Ollama container on `delphi`, own model-
   storage volume. Model residency policy per the vault §3 (Qwen2.5-
   Coder-14B resident, a 7-8B general model resident, third slot on
   demand) — exact models used by this phase's enrichment step finalized
   at implementation time.

2. **Hephaestus (LangGraph service).** Python 3.12 service, `services/
   langgraph/` (Dockerfile + pipeline definition + MCP server entrypoint).
   Each `build_knowledge_graph` job runs as a LangGraph graph with three
   sequential nodes, using LangGraph's own checkpointer/state persistence
   as the job-tracking mechanism — no separate job database:

   - **`parse_repo`** (deterministic, no LLM): walks `/repos/<name>`
     (read-only bind mount, see Volumes below) applying a tiered
     fallback so coverage gaps degrade node *detail*, never break the
     job:
     - **Tier 1 — full structural parse:** `tree-sitter` has a grammar
       for the file's language (covers ~100+ languages). Produces real
       symbol-level nodes (functions/classes) and real edges (imports/
       calls) — accurate, not LLM-hallucinated.
     - **Tier 2 — file-level fallback:** no grammar available, or the
       file isn't meaningfully "code." Whole file becomes one node;
       edges inferred loosely via textual cross-reference, not deep
       parsing.
     - **Tier 3 — opaque leaf:** binary/generated/vendored content
       (lockfiles, minified bundles, images). Recorded as a node with
       path/size/type metadata only, explicitly marked unanalyzed,
       excluded from the LLM enrichment budget.

     Every node is tagged with the tier that produced it, so nothing
     consuming the graph mistakes a Tier 2 guess for Tier 1 ground truth.
     A single malformed file degrades that one node's tier rather than
     failing the whole run.

   - **`enrich_with_llm`**: for each Tier 1/2 node, one Ollama call
     generates a short natural-language summary attached to that node.
     Tier 3 nodes are skipped. This is the slow step (single-digit
     tokens/sec) — the reason the job is async. Ollama
     unreachable/timeout on a given node leaves that node's summary
     `unavailable` rather than failing the job; partial results beat
     total failure for something async and re-runnable.

   - **`render_outputs`**: writes `graph.json` (full node/edge/summary
     structure — the source of truth `query_knowledge_graph` traverses)
     and `digest.md` (a flattened, pruned Markdown rendering of the same
     graph — what gets loaded for fast context-priming, low-value Tier 3
     leaves pruned) to `GRAPH_OUTPUT_ROOT/<repo-name>/`.

3. **MCP tool signatures** (exposed by Hephaestus, called by Hermes):

   ```
   build_knowledge_graph(repo: str) -> JobReceipt
   job_status(job_id: str) -> JobStatus
   query_knowledge_graph(repo: str, query: str) -> JobResult
   ```

   - `build_knowledge_graph`: validates `repo` exists under `/repos`
     (fails fast, synchronously, if not — not buried inside an async
     job), kicks off the LangGraph run asynchronously, returns
     `{job_id}` immediately.
   - `job_status`: reads LangGraph's checkpointed state for that run —
     `pending` / `running` (current node) / `complete` (output paths) /
     `failed` (error detail).
   - `query_knowledge_graph`: synchronous. Loads the already-built
     `graph.json` for `repo` and answers structural questions by
     traversal (e.g. "what depends on module X") — pure graph lookup
     against real edges, no LLM call needed. Querying a repo with no
     built graph yet returns a clear "not built, run build_knowledge_graph
     first" error, not a silent empty result.

4. **Network and volumes** (`compose.yaml`):
   - `delphi` (existing, `internal: true`) gains Pythia and Hephaestus as
     members. Hermes joins `delphi` as a second network (alongside its
     existing `olympus`/`cerberus_net`) so it can reach Hephaestus's MCP
     endpoint.
   - `REPOS_ROOT` (new, non-secret `.env` var) bind-mounted read-only into
     Hephaestus at the fixed internal path `/repos` — tool calls take a
     repo *name*, never a host path, so dev (this WSL2 machine,
     `~/Repos`) and prod (Olympus, path TBD when that host exists) stay
     interchangeable without a code change.
   - `GRAPH_OUTPUT_ROOT` (new, non-secret `.env` var), a separate
     writable volume mirrored by repo name
     (`GRAPH_OUTPUT_ROOT/<repo-name>/graph.json`, `.../digest.md`). Build
     artifacts only, never touches git, never written back into a source
     repo.
   - Hephaestus's own container hardening, consistent with Phase 3's
     confinement philosophy even though this isn't a terminal-execution
     backend: non-root, source repos mounted `:ro`, output volume the
     only writable mount, no secrets passed in (none needed — local
     model, local files only).

## Job delivery

`delphi`'s zero-egress design means Hephaestus cannot call Signal
directly on job completion. Delivery routes back through Hermes, which
does have internet access via `signal-cli` (Phase 2): a Hermes cron job
(the existing scheduling system from Phase 2, §7) polls `job_status` at a
short interval and delivers to the pinned Signal target once a job
reaches `complete`. No new plumbing — reuses the cron system already
built.

## Error handling

- Per-node parse failures degrade that node's tier rather than failing
  the whole job (see Tier 1/2/3 fallback above).
- Ollama unreachable/timeout during enrichment: node's summary marked
  `unavailable`, job still completes.
- Unknown `repo` name: `build_knowledge_graph` fails fast, synchronously,
  at the receipt stage.
- `query_knowledge_graph` against a repo with no built graph: explicit
  "not built yet" error.

## Testing / Phase gate

1. `build_knowledge_graph("AgentsOfOlympus")` dispatched from Signal →
   receipt returned immediately.
2. Hermes's cron job polls `job_status`, delivers a Signal message on
   completion.
3. `graph.json` and `digest.md` land in
   `GRAPH_OUTPUT_ROOT/AgentsOfOlympus/`, containing real nodes for this
   repo's actual files (not placeholder/mock content).
4. `query_knowledge_graph("AgentsOfOlympus", "<a real structural
   question>")` returns a correct answer traversing real edges.

## Open questions

1. **Exact Ollama models for the enrichment step** — the vault's §3
   model-residency policy (Qwen2.5-Coder-14B + a 7-8B general model)
   predates this phase; whether the enrichment step uses the coder model,
   the general model, or a third slot is decided at implementation time
   based on real output quality, not guessed here.
2. **`REPOS_ROOT`/`GRAPH_OUTPUT_ROOT` production values** — dev value is
   `~/Repos` on this WSL2 machine; production (Olympus) values TBD when
   that host exists, per the vault's portability design (config-as-code,
   no hardcoded paths).
3. **Whether SilentScribe gets wired in as an additional tool later** —
   deliberately deferred, not blocked by anything built in this phase
   (see Non-goals).
