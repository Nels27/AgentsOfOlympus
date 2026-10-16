# AgentsOfOlympus — Project Context

Hermes AI Agent Orchestration Server for the homelab, replacing the
OpenClaw agent stack. Fully containerized, portable, modular Docker
Compose deployment on a Beelink SER8 ("Olympus"), commanded remotely via
Signal. Repo: `AgentsOfOlympus`, branch `main`. Authoritative phased plan
lives in Obsidian (`Implementation Strategy.md`), not in the repo;
`docs/ARCHITECTURE.md` in-repo holds a directory-tree sketch only.

## Decisions of record

| Area | Choice |
|---|---|
| Agent framework | Hermes (NousResearch/hermes-agent), official Docker image |
| Reasoning tier | Hybrid — hosted API (Anthropic) for interactive reasoning, local models (Ollama) for the worker tier |
| Worker orchestration | LangGraph service, exposed to Hermes as an MCP server (streamable HTTP) |
| Secrets | Compose file-based secrets, SOPS+age encryption at rest, `.env` for non-sensitive config only |
| Remote access | Signal via a separate `signal-cli` daemon; Hermes's `hermes-signal` toolset talks to it. Zero inbound ports. |
| Upgrades | Pinned image digests, reviewed compose commits; no in-chat self-update |
| Timezone | `America/New_York` set explicitly |

## Pantheon naming convention

Olympus = host · Hermes = gateway · Hephaestus = LangGraph tier ·
Pythia = Ollama · delphi = inference network · Cerberus = docker-socket-proxy ·
Hades = secrets layer · Styx = egress firewall · Themis = approval gates ·
Argus = observability · Mnemosyne = backups · Iris = Tailscale

## Standing policies

- Every project Hermes does dev work on needs branch protection (PR-only,
  no direct pushes to main) — a per-repo GitHub setting, not infrastructure
  this project builds.
- Merged branches are deliberately left in place (not deleted) as a
  rollback option — a standing preference, re-confirmed each time before
  any cleanup.
- `hermes -z "<prompt>"` is the correct non-interactive CLI flag
  (`hermes chat -z` is not a real subcommand).

## Phase status (as of 2026-08-30)

**Phase 0 — Repository Layout: complete, merged to `main`** (2026-07-19).
Compose networks, `.env`/`.sops.yaml` per-deployer split, secrets
scaffolding.

**Phase 1 — Hermes Core: complete, merged to `main`** (2026-08-18).
Hosted-provider + Ollama-endpoint registration, `hermes` gateway service
running, CLI smoke test passed.

**Phase 2 — Signal Command and Scheduling: complete, merged to `main`**
(2026-08-23). `signal-cli` daemon linked as a device on the operator's own
Signal account; DM round-trip and cron delivery both passed. Pairing
revocation untested (documented gap, no second identity available).
Signal has no "home channel" — every delivery needs an explicit
`signal:+<E.164>` target.

**Phase 3 — Terminal Backend Confinement (Security Core): complete,
merged to `main` via PR #7** (2026-08-23). Delivered:
- `terminal.backend: docker` on Hermes, resource-limited, runs as host user.
- `cerberus` (digest-pinned `docker-socket-proxy`) mediates all Docker API
  access between Hermes and `dockerd` on its own `cerberus_net` — no raw
  socket access, no other service can reach it.
- Worker image extends Hermes's default base with `git`/`ripgrep`.
- Egress control via `sniproxy` (SNI-based filtering, not IP-allowlisting
  — IP allowlisting proved unreliable live against rotating DNS) plus
  source-scoped `DOCKER-USER` firewall rules on a dedicated `styx_net`.

All four phase-gate checks passed (no secrets in worker env, disallowed
domain blocked, host paths unreachable, `DOCKER_HOST`-via-proxy working
end-to-end), verified through Hermes's real invocation path.

**Phase 4 — LangGraph Worker Tier: design complete, implementation not
started.** Design spec committed on branch
`phase-4-langgraph-worker-tier` (current branch, not yet merged).

- **Deviates from the original plan:** the vault named SilentScribe as
  the pilot workload, but SilentScribe's own pipeline turned out to be
  only ~20% built (manifest loader only). Phase 4 instead targets a new,
  generically-useful pilot: a codebase knowledge-graph/documentation tool.
  SilentScribe can be wired in later as an additional MCP tool once its
  own pipeline is finished.
- Pythia (Ollama) + Hephaestus (LangGraph) run on `delphi`
  (`internal: true`, zero egress). Hermes gains `delphi` as a second
  network to reach Hephaestus's MCP endpoint.
- Three narrow MCP tools: `build_knowledge_graph(repo)`,
  `job_status(job_id)`, `query_knowledge_graph(repo, query)` — not
  arbitrary local-model execution.
- Pipeline: `parse_repo` (deterministic `tree-sitter`, tiered fallback:
  full parse → file-level → opaque leaf) → `enrich_with_llm` (per-node
  Ollama summarization, the slow async step) → `render_outputs`
  (`graph.json` + `digest.md`, build artifacts only, never written back
  into the source repo).
- Async job model: receipt immediately, Signal delivery on completion via
  Hermes's existing Phase 2 cron system polling `job_status` (delphi has
  no egress, so Hephaestus can't message Signal directly).
- Consistent with Phase 3 confinement: source repos read-only, only the
  output volume writable, no secrets passed to Hephaestus/Pythia at all.
- Open questions: exact Ollama model(s) for enrichment; production values
  for `REPOS_ROOT`/`GRAPH_OUTPUT_ROOT` (dev is `~/Repos` on WSL2); whether/
  when SilentScribe gets wired in later.
- Phase gate target: a `build_knowledge_graph("AgentsOfOlympus")` job
  dispatched from Signal completes, delivers via Signal, and produces a
  real queryable graph for this repo.

## Also still open

Compartmentalizing the dev Hermes instance onto its own machine (Lenovo
ThinkCentre M710q candidate) — discussed at Phase 1, untouched since.

## Where to look for more detail

- Obsidian vault, "Claude Code Grey Matter" → `Projects/AgentsOfOlympus/`:
  `Project Overview.md`, `Implementation Strategy.md` (full six-phase
  plan, decisions of record, hardware budget), `Phase Status/*.md`
  (per-phase session notes with live corrections found during execution).
- Repo: `docs/superpowers/specs/` and `docs/superpowers/plans/` hold the
  per-phase design specs and implementation plans actually executed
  against.
