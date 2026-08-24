# Phase 3: Terminal Backend Confinement — Design

## Context

Phase 2 (Signal Gateway) is merged to `main`. This spec covers Phase 3 per
the vault's `Implementation Strategy.md` §8 ("Terminal Backend Confinement
— Security Core"): confining what Hermes's terminal/tool-execution
capability can actually do, since a Signal-reachable agent with shell
access is remote code execution by design.

The vault's original design assumed a specific Hermes architecture that
turned out not to match reality, verified against Hermes's own docs during
this design pass (not assumed):

- **One persistent container, not per-task ephemeral containers.** Hermes
  starts a single long-lived container on first use and routes every
  terminal/file/execute_code call through `docker exec` into that same
  container for the life of the gateway process. The vault's original
  five-layer framing (built around frequent create/destroy cycles) doesn't
  quite match this — revised to four layers below.
- **Hermes already implements much of "Layer 3" itself.** When
  `TERMINAL_BACKEND=docker` is configured, Hermes applies `--cap-drop ALL`
  (restoring only `DAC_OVERRIDE`/`CHOWN`/`FOWNER`), `--security-opt
  no-new-privileges`, `--pids-limit 256`, and size-limited tmpfs
  automatically. `docker_run_as_host_user: true` gives non-root. This
  isn't something to build from scratch — just configure correctly.
- **The socket proxy controls *operations*, not *images*.** Tecnativa's
  `docker-socket-proxy` allowlists which Docker API endpoints are reachable
  (container create/exec/attach/remove), but has no concept of restricting
  *which image* gets used for those operations — that constraint has to
  come from Hermes's own `terminal.docker_image` config, a separate
  enforcement point.
- **Hermes's own approval-gate mechanism (`approvals.deny`, the vault's
  originally-planned "Layer 5") explicitly does not apply to isolated
  container backends** — confirmed via Hermes's own security docs: "the
  container itself provides the security boundary" for container-executed
  commands, and deny rules only apply to host-reaching backends (local,
  SSH, host-mounted Docker). Since Layers 1-4 below all commit to the
  isolated Docker backend, there is no working command-level approval gate
  for this project. **Folded into Layer 4 (egress) instead** — hard
  network-level blocks on disallowed destinations, not a runtime approval
  prompt. This is a real capability gap versus the vault's original intent
  (it can't distinguish read/dev-work reachability from a destructive
  push to the same host), resolved for now via a different mechanism
  entirely — see the "Branch protection" section below.

## Goals

- `TERMINAL_BACKEND=docker` configured on Hermes, with sensible resource
  limits (`container_cpu`, `container_memory`) and `docker_run_as_host_user:
  true`.
- A `docker-socket-proxy` (Tecnativa) sitting between Hermes and `dockerd`,
  allowlisting only container create/exec/attach/remove — Hermes never
  sees the raw Docker socket.
- A worker image extending Hermes's own default
  (`nikolaik/python-nodejs:python3.11-nodejs20`) with `git` and `ripgrep`
  (per the vault's stated toolchain), digest-pinned.
- Egress control on the real `DOCKER-USER` `nftables` chain (verified
  reachable in this Docker-Desktop/WSL2 dev environment via a privileged
  `--net=host` container — see Components), allowlisting package
  registries/GitHub/documentation domains, default-deny otherwise.
- **Secrets rule (absolute, unchanged from the vault):** the worker
  container receives no secrets, ever. Nothing sensitive lives in
  environment variables passed to it.
- Phase gate: from the worker container, (a) printed environment shows no
  secrets; (b) a disallowed domain is unreachable; (c) a host path is
  unreachable (container isolation, not a policy the container can be
  tricked out of); (d) `DOCKER_HOST` routed through the socket proxy
  actually works for Hermes's real invocations, not just a bare `docker`
  CLI smoke test.

## Non-goals

- No nested/ephemeral specialist-agent container spawning from within the
  persistent worker container — that's Phase 4 (LangGraph Worker Tier)'s
  job, via narrow predefined pipeline signatures exposed as an MCP server,
  not arbitrary container orchestration. Explicitly decided against
  building this into Phase 3.
- No attempt to replicate Hermes's own approval-gate mechanism for the
  container backend — confirmed unsupported by Hermes itself, not a gap
  this project's infrastructure can close. See Context.
- Not configuring branch protection on any downstream project's own GitHub
  repo (Meridian Sigma or otherwise) — that's a setting on those repos
  themselves, outside this project's infrastructure and outside this
  agent's access. See "Branch protection" below for the standing policy
  this depends on.
- No disk quota enforcement (`container_disk` requires overlay2 on
  XFS+pquota per Hermes's own docs — not guaranteed on this host); CPU/
  memory/pids limits and capability dropping are the actual containment
  boundary, disk quota is a nice-to-have deferred indefinitely.

## Branch protection — standing policy, not built by this phase

**Decided during design:** any project this orchestration server does
development work on must have branch protection preventing direct pushes
to its main/protected branch — work always lands as a PR for human review,
never a direct push. This generalizes beyond Meridian Sigma to every
future project Hermes touches, and is how AgentsOfOlympus's own repo has
operated the entire time (every phase has gone through a feature branch +
PR, confirmed by this project's own git history).

This is **not infrastructure Phase 3 builds** — it's a per-repository
GitHub setting on whatever project Hermes is pointed at, configured by the
human operator when a new project is brought under Hermes's management,
not something enforceable from AgentsOfOlympus's side. It's recorded here
as a hard prerequisite: **egress reachability to a project's git host
being allowed assumes that project's branch protection is already in
place** — reachability alone provides no protection on its own.

## Components

1. **`terminal.backend: docker` + resource limits.** Hermes config, not new
   infrastructure. **Correction, verified live:** there is no
   `TERMINAL_BACKEND` env var — that was an incorrect extrapolation from
   Phase 1's confirmed `TERMINAL_DOCKER_IMAGE`/`TERMINAL_DOCKER_FORWARD_ENV`
   examples, which are all `docker_*` sub-keys, not `backend` itself.
   Setting `backend` requires `hermes config set terminal.backend docker`
   (a real CLI subcommand, confirmed working and persisting to
   `config.yaml`). `docker_run_as_host_user: true` (non-root inside the
   container), `container_cpu`/`container_memory` set to sensible bounds
   (exact values TBD at implementation time based on this host's actual
   headroom, not guessed here).

2. **Socket proxy.** `tecnativa/docker-socket-proxy`, env vars
   `CONTAINERS=1`, `POST=1`, `EXEC=1`, **and `INFO=1`** — everything else
   left at its default-deny. Hermes's container gets `DOCKER_HOST` pointed
   at the proxy instead of a mounted socket.

   **Fully verified live, including a real debugging chain worth
   recording:** the raw `docker` CLI respects `DOCKER_HOST` and works fine
   through the proxy (`docker version` succeeded immediately). But
   `hermes doctor` initially still reported `docker daemon not running`
   even with a working `DOCKER_HOST` and `terminal.backend: docker` set
   correctly. Root cause, found by testing `docker info` directly (not
   just `docker version`): **the proxy's default-deny posture blocks the
   `/info` endpoint** unless `INFO=1` is explicitly set, and Hermes's own
   internal Docker health check calls `docker info`, not just `docker
   version` — a real 403 from the proxy, not a Hermes/DOCKER_HOST
   incompatibility. Adding `INFO=1` resolved it completely: `hermes
   doctor` now reports `✓ docker (daemon running)`. This was nearly
   misdiagnosed as "Hermes doesn't respect DOCKER_HOST" (which would have
   blocked the whole socket-proxy approach) before finding the real,
   much simpler cause.

   Also confirmed harmless dead end during this investigation: a
   `socat`-bridged local socket file forwarding to the proxy's TCP
   endpoint (to see if Hermes's check needed a literal socket path
   present) was **not** the fix — `INFO=1` was. Not needed in the final
   design; noted here only so a future reader doesn't re-attempt it
   independently while debugging something similar.

3. **Worker image.** `FROM nikolaik/python-nodejs:python3.11-nodejs20`
   (Hermes's own default base), add `git` and `ripgrep` via the
   distro's package manager, digest-pin the result once built. Most other
   hardening (capability dropping, non-root, pids limits, tmpfs sizing)
   comes from Hermes's own Docker backend config (Component 1), not this
   image.

4. **Egress control (absorbs the former "Layer 5" approval-gate concern).**
   `nftables` rules on the real `DOCKER-USER` chain. In this dev
   environment, `dockerd` runs inside Docker Desktop's own internal VM
   (confirmed via `hostname` inside a `--net=host` container: literally
   `docker-desktop`, a separate machine from this WSL distro) — so rules
   are applied via a privileged `--net=host` container as a one-off
   administrative action (the "sudo equivalent" for this environment),
   not native host `nft`/`iptables` (neither is even installed in this WSL
   distro). Confirmed live: this technique successfully reads Docker
   Desktop's real `DOCKER-USER` chain, which already carries its own
   internal rules (ports 3128/5555/53, then a catch-all `REJECT`) — our
   rules need to insert allow-rules before that catch-all, scoped to the
   worker network's interface specifically, not all Docker traffic.
   **Caution carried into implementation:** those existing Docker
   Desktop-owned rules (3128/5555/53) must not be removed or reordered
   past — they're Docker Desktop's own internal plumbing, unrelated to our
   policy, and flushing/rewriting the whole chain instead of inserting
   scoped rules risks breaking Docker Desktop itself, not just our worker
   network. This is dev-environment-specific; the eventual bare-metal
   Beelink host won't have this pre-existing chain content to preserve.
   Allowlist: package registries (PyPI, npm), GitHub, documentation
   domains (exact list finalized at implementation time). Everything else
   denied by default. No attempt to distinguish read vs. write access to
   any allowed git host (see Branch protection above for how that gap is
   actually covered).

## Error handling

No custom error-handling code — declarative Compose/firewall config,
verified live rather than assumed, same posture as every prior phase.

## Testing / Phase gate

Translating the vault's phase gate into concrete checks, from inside the
actual worker container (not a bare test container):

1. Print environment — confirm no secrets present (matches the absolute
   secrets rule).
2. Attempt to reach a disallowed domain — confirm blocked by the egress
   rules.
3. Attempt to touch a host path — confirm it fails (container isolation
   itself, not a policy that could be socially engineered around).
4. Confirm `DOCKER_HOST`-via-proxy actually works for a real Hermes
   invocation (not just a standalone `docker` CLI test against the proxy)
   — this is the one item flagged as unverified in Component 2, and
   verifying it live is itself part of the phase gate, not a precondition
   assumed to already hold.

## Open questions

1. **Exact egress allowlist domains** — package registries/GitHub/docs
   domains named generically in the vault; the precise list gets finalized
   during implementation, not guessed here.
2. **Resource limit values** (`container_cpu`/`container_memory`) — sensible
   bounds based on this host's actual headroom, determined at
   implementation time.

~~3. Whether Hermes's docker CLI invocations respect DOCKER_HOST~~ —
**resolved** during design. They do; the real blocker was the proxy's
`/info` endpoint being denied by default (`INFO=1` fixes it), not a
DOCKER_HOST incompatibility. See Component 2.
