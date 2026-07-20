# Phase 1: Hermes Core — Design

## Context

Phase 0 (compose + secrets scaffolding) is merged to `main`. This spec
covers Phase 1 per the vault's `Implementation Strategy.md` §6 ("Hermes
Core, Proven in Layers"): standing up a real, persistent Hermes gateway
instance for the first time.

Two scope changes from the vault plan, decided during this design pass:

- **No OpenClaw migration.** The vault plan's step 2 (`hermes claw migrate`)
  is skipped entirely — starting fresh with Hermes, no prior OpenClaw state
  to bring over.
- **Ollama registration is in scope**, not deferred. The vault plan's step 4
  assumes an Ollama endpoint is already reachable; it wasn't when this
  design started, so Ollama was installed natively on the WSL host
  (`ollama` 0.32.1, running via systemd, confirmed reachable at
  `localhost:11434`) specifically so this slice could include it.

This is being built as a **real, persistent setup on this WSL dev
machine** — not a throwaway/dry-run like some of Phase 0's verification.
Hermes accumulates state (memories, sessions, skills) that's worth keeping;
replicating onto the eventual Beelink production host is treated as a
separate future step, the same pattern Phase 0 used for the age keypair.

## Goals

- A real Hermes gateway container, running persistently in Compose,
  attached to the `olympus` network (the first service to actually use one
  of Phase 0's three declared networks).
- Anthropic configured as the hosted reasoning provider, proven with a real
  CLI response.
- Ollama registered as a second, currently-unused provider, reachable from
  the containerized gateway via `host.docker.internal:11434`, so a future
  local-only migration is just a `/model` switch (per the vault plan's own
  reasoning).
- The container survives a restart with its data volume (memories,
  sessions, config) intact.

## Non-goals

- No OpenClaw migration (see Context).
- No Telegram/gateway messaging config — that's Phase 2.
- No terminal-backend confinement (Docker socket proxy, worker image,
  egress firewall) — that's Phase 3.
- No actual Ollama model pulled/loaded — registering the endpoint is enough
  for this slice; model residency policy is a later concern.
- No Tailscale — ports bind to loopback only for now; Tailscale-bound
  access is Phase 5 ("Iris").
- Not touching the Phase 0 SOPS `secrets/` pipeline for Hermes's own hosted
  provider key — see the credentials architecture note below for why.

## Credentials architecture

Hermes's own docs are explicit: it stores provider credentials in
`~/.hermes/.env` (plaintext), written by its own interactive `hermes setup`
wizard — not via Docker Compose secrets or file injection. This isn't a
conflict with Phase 0's SOPS+age pipeline: the vault's own Phase 0 backup-unit
definition already lists `~/.hermes` as its own separately-backed-up
stateful volume, distinct from and parallel to the repo's `secrets/`
directory. The SOPS pipeline stays reserved for what Phase 2 explicitly
calls for (the Telegram bot token, which needs real file-secret treatment
when the gateway is Telegram-facing) — not for Hermes's own hosted-provider
key, which Hermes wants to manage itself.

Practically: you run the setup wizard yourself, directly, entering your
real Anthropic API key at its interactive prompt. This isn't something
driven through the Bash tool — it's an interactive TTY wizard expecting
live input, and a real secret shouldn't be relayed through an intermediate
non-interactive exec anyway. Once `~/.hermes/.env` and `config.yaml` exist,
everything after that (config edits, compose service, verification) is
non-secret and can proceed normally.

## Components

1. **Ollama (native, WSL host).** Already installed and running (systemd
   service, confirmed at `localhost:11434`). No further action needed here
   beyond registering it in Hermes's config.
2. **Hermes setup wizard (interactive, run by you).**
   `mkdir -p ~/.hermes && docker run -it --rm -v ~/.hermes:/opt/data
   nousresearch/hermes-agent setup` — populates `~/.hermes/.env` (secrets)
   and `~/.hermes/config.yaml` (everything else) with your real Anthropic
   key.
3. **Ollama provider registration (interactive, run by you).** Verified
   against real `--help` output: `hermes model` is fully interactive (no
   flags for specifying a provider/endpoint directly — `--refresh`,
   `--portal-url`, and OAuth-related flags only), and `hermes config set`'s
   key schema isn't documented in `--help` alone. Rather than guess at a
   `config.yaml` schema, this is a second manual step, same pattern as the
   setup wizard: `docker run -it --rm -v ~/.hermes:/opt/data
   nousresearch/hermes-agent model`, picking/confirming Ollama as an
   available provider pointing at `http://host.docker.internal:11434`
   (Ollama runs on the host; Hermes runs in a container, so `localhost`
   would resolve to the container itself).
4. **`compose.yaml` `hermes` service.** Digest-pinned
   `nousresearch/hermes-agent@sha256:b29520aa3244ab4f65cb9d66ba86db5e59d2f581c3b7401cd642e4325ca4883d`
   (pulled and verified during this design pass — `linux/amd64`, 2.61GB),
   `command: gateway run`, `restart: unless-stopped`, `~/.hermes:/opt/data`
   volume mount, attached to the `olympus` network, `API_SERVER_ENABLED=true`
   and `HERMES_DASHBOARD=1` env vars, ports bound to loopback only:
   `127.0.0.1:8642:8642` (gateway API) and `127.0.0.1:9119:9119`
   (dashboard). No `0.0.0.0` binding anywhere, per the vault plan's network
   segmentation rule (§5: "No service binds `0.0.0.0`").
5. **Phase gate verification** (see below).

## Phase gate verification

Translating the vault plan's phase gate ("CLI answers; gateway process
healthy; container survives restart with memory intact") into concrete
checks:

1. `hermes -z "<test prompt>"` (the top-level non-interactive one-shot
   flag, confirmed against real `hermes --help` output) returns a real
   response from the Anthropic provider.
2. `docker compose up -d hermes` then `docker compose ps` shows the
   container healthy/running.
3. `docker network inspect olympus` shows the `hermes` container attached
   — the first real proof that a Phase 0 network actually works (deferred
   from Phase 0 since no service existed yet to attach to one).
4. Restart test: write something durable (send a chat message that gets
   saved to a session, or otherwise trigger a memory write), then
   `docker compose restart hermes`, then confirm that same state is still
   present afterward via the mounted `~/.hermes` volume.

## Error handling

- No custom error handling code needed for this slice — it's operator-driven
  setup (wizard) plus declarative Compose config. `restart: unless-stopped`
  is Compose's own crash-recovery mechanism for the running gateway.
- If the setup wizard is botched (wrong key, etc.), it's simply re-run — no
  destructive state to worry about undoing before the persistent gateway
  container has even started.

## Alternatives considered

**Routing the hosted-provider key through the Phase 0 SOPS pipeline
anyway**, to keep all secrets in one place regardless of what each service
prefers. Rejected: would require fighting Hermes's own documented
credential model (writing into its `.env` from outside, then keeping that
in sync with whatever `hermes config`/`hermes update` might rewrite) for no
real security benefit — `~/.hermes/.env` is already outside git, and the
vault's own backup-unit definition already treats it as separately-managed
state. Revisit only if Hermes ever supports reading secrets from
`/run/secrets/*`-style file injection natively.

## Open questions

None. Both implementation-syntax lookups flagged during design were
resolved against real `--help` output before the plan was written:
`hermes model` is interactive-only (folded into Component 3 as a second
manual step, same pattern as the setup wizard), and the top-level `-z
PROMPT` flag (seen in `hermes --help`'s usage line) is the non-interactive
smoke-test invocation, used as `hermes -z "<prompt>"`.
