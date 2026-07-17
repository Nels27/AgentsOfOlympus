# Compose + Secrets Scaffolding — Design

## Context

AgentsOfOlympus is a greenfield project. `docs/ARCHITECTURE.md` describes a target
directory tree with five largely independent subsystems: compose/secrets
scaffolding, an Ollama model-serving service, the Hermes agent, a LangGraph
orchestration/MCP layer, a sandboxed worker image, and an observability stack.
None of it exists yet — `orchestration-server/`, `services/*`, and `runbooks/`
are empty directories.

This spec covers the **first slice only**: the compose and secrets scaffolding
that every later service plugs into. It deliberately does not implement any
real service (Hermes, LangGraph, Ollama, etc.) — those are separate specs.

Deploy target: a single home server/NUC, always-on, single host (no cluster).

There is a pre-existing, already-approved implementation plan for this whole
project: `Implementation Strategy.md` in the "Claude Code Grey Matter"
Obsidian vault (`status: approved-for-implementation`, dated 2026-07-11). It
covers six phases (Hermes core, Telegram/cron, worker confinement, LangGraph
tier, observability, supply chain/backups/portability) on named hardware (a
Beelink SER8, "Olympus"). This spec's scope corresponds to that plan's
**§4, Phase 0** ("Repository Layout"), and adopts two of its binding
decisions that our earlier design pass didn't have visibility into:

- **Shell scripting conventions** (plan §4): `setup.sh` exports
  `SCRIPTS_ROOT` with `set -euo pipefail`; child scripts carry source
  guards; constants are `readonly` in `lib/constants.sh`. Our
  `decrypt-secrets.sh` is a child script under this convention, not a
  standalone one-off.
- **Pantheon naming (plan Appendix A)**: Compose network names are canon —
  `olympus` (gateway/reasoning tier), `delphi` (inference tier,
  `internal: true`), `argus_net` (observability). This slice declares all
  three now even though no services attach to them yet, since the
  segmentation is already a settled decision and there's no benefit to
  inventing a placeholder name we'd rename in the next slice.

## Goals

- A `compose.yaml` skeleton with the three trust-boundary networks
  (`olympus`, `delphi`, `argus_net`), ready for services to be added
  incrementally.
- A secrets-at-rest story using SOPS + age: encrypted files safe to commit,
  one secret per file, decrypted on demand rather than kept in plaintext at
  rest.
- Non-sensitive config (ports, `TZ`, model names) in `.env`, with a committed
  `.env.example` for onboarding.
- A repeatable, scriptable path from "fresh clone" to "secrets available to
  containers" that a future `runbooks/restore.md` can document as a tested
  procedure.

## Non-goals

- No real service containers (Hermes, LangGraph, worker-image, Ollama,
  observability) — those get their own specs once this scaffolding lands.
- No `renovate.json` — deferred until there's dependency content
  (pinned image tags) for it to track.
- No multi-host/cluster design — single host only.
- No just-in-time per-container secret decryption (`sops exec-env` in
  entrypoints) — deferred until real services exist to design entrypoints
  for. See "Alternatives considered."

## Directory layout

```
orchestration-server/
├── compose.yaml              # shared network + secrets block, no services yet
├── .env                      # non-sensitive config: ports, TZ, model names (gitignored)
├── .env.example               # committed template with the same keys
├── .sops.yaml                 # SOPS config: age recipient, path rule for secrets/*
├── secrets/                   # SOPS+age encrypted, one secret per file, committed
│   └── .gitkeep                # empty for now; real secrets land with the services that need them
└── scripts/
    ├── setup.sh                # exports SCRIPTS_ROOT, set -euo pipefail, sources lib/constants.sh
    ├── lib/
    │   └── constants.sh         # readonly constants (paths, network names, etc.)
    └── decrypt-secrets.sh      # decrypts secrets/* -> secrets.dec/*, 0600 perms; source-guarded child script
```

`secrets/telegram_bot_token` and `secrets/hosted_provider_key` from
`ARCHITECTURE.md`'s proposed tree are examples of what will eventually live
here, not deliverables of this slice — no service exists yet to consume
them. This slice ships the encrypted-storage mechanism; verification (below)
uses a throwaway dummy secret to prove the mechanism works end to end.

`secrets.dec/` (plaintext decrypt output) and `.env` are added to a
repo-root `.gitignore` (which doesn't currently exist and needs creating).

## Secrets flow

- `.sops.yaml` at the repo root declares the age public key as recipient and
  scopes encryption to `secrets/**`, so `sops` knows how to encrypt/decrypt
  those files without per-invocation flags.
- The age **private** key lives outside the repo, at SOPS's default lookup
  path `~/.config/sops/age/keys.txt` on the host. Never committed.
- `scripts/decrypt-secrets.sh` iterates `secrets/*`, runs `sops -d` into
  `secrets.dec/<filename>`, and `chmod 600`s each output file. It writes to a
  temp location and moves files into place atomically (or cleans up on
  failure) so `secrets.dec/` is never left partially populated. It follows
  the homelab shell conventions: a source guard at the top, relies on
  `SCRIPTS_ROOT` and any shared constants from `lib/constants.sh` (populated
  by `scripts/setup.sh`), and runs under `set -euo pipefail`.
- `compose.yaml` references `secrets.dec/*` via Docker Compose's native
  top-level `secrets:` key (file-based secrets), mounting each as
  `/run/secrets/<name>` inside a container — not environment variables, so
  they don't leak into `docker inspect` or process listings.
- Future restore runbook: clone repo → place age key at
  `~/.config/sops/age/keys.txt` → `./scripts/decrypt-secrets.sh` →
  `docker compose up`.

## compose.yaml and .env scope

- `compose.yaml` defines the three canon networks — `olympus` (gateway),
  `delphi` (inference tier, `internal: true` so it has no route to the
  internet), and `argus_net` (observability) — plus the top-level `secrets:`
  block pointing at `secrets.dec/*`. No service entries yet — those arrive
  with each service's own spec, at which point they attach to the
  appropriate one of these three networks per the trust-boundary design.
  Compose profiles (called out in `ARCHITECTURE.md` for optional layers) are
  introduced once there are real services to gate behind them.
- `.env` holds only non-sensitive values (ports, `TZ`, model names),
  consumed via Compose's automatic `.env` interpolation.
- `.env.example` is a committed copy of `.env`'s keys with placeholder/sane
  defaults; onboarding is `cp .env.example .env`.
- Definition of done for this slice: `docker compose up` brings up all three
  empty networks with no errors, `docker compose down` tears them down
  cleanly. No service or port to check yet.

## Verification

Manual verification (no automated test framework needed for shell/config
scaffolding):

1. Generate a throwaway age keypair, encrypt a dummy secret with `sops`, run
   `decrypt-secrets.sh`, confirm `secrets.dec/` gets correct plaintext with
   `0600` perms.
2. `docker compose config` to validate `compose.yaml` syntax.
3. `docker compose up` / `down` to confirm the network + secrets scaffolding
   starts and tears down cleanly with zero services.
4. `git status` after generating `secrets.dec/` and `.env` to confirm
   `.gitignore` keeps them untracked.

## Error handling

- `decrypt-secrets.sh` fails fast with a clear message and non-zero exit if:
  `sops` isn't installed, the age key file is missing, or any individual
  secret fails to decrypt (e.g. wrong key). It does not leave `secrets.dec/`
  partially populated on failure.
- Docker Compose's own behavior — refusing to start if a referenced secret
  file doesn't exist — is sufficient on the compose side; no extra handling
  needed there.

## Alternatives considered

**Secrets runtime flow** — three options were evaluated:

1. **Decrypt-on-demand script → gitignored plaintext dir** (chosen). Simple,
   uniform across all future services regardless of language/base image,
   pairs naturally with a "run script, then compose up" restore runbook.
   Trade-off: plaintext secrets sit on disk (mitigated by `0600` + gitignore)
   for as long as the stack runs, and a rotated secret requires remembering
   to re-run the script. This matches the approved plan's own decision
   record ("Hardened Option 2": Compose file-based secrets + SOPS/age +
   `.env` for non-sensitive config only), arrived at independently during
   this design pass before the existing plan was found — a second point of
   agreement, not just adopted wholesale.
2. **direnv-style auto-decrypt on shell entry.** Rejected: poor fit for a
   headless server that isn't driven by an interactive login shell.
3. **Just-in-time per-container decryption** (`sops exec-env` in each
   entrypoint). Most secure — plaintext never touches host disk — but
   requires a SOPS-aware entrypoint per service, and there are no real
   service containers in this slice to design that pattern against. Revisit
   per-service as Hermes/LangGraph/etc. are built; the encrypted `secrets/`
   source of truth is identical either way, only the decrypt mechanism
   changes, so switching later isn't a breaking change to this slice.

## Open questions

None — all sections were reviewed and approved during design.
