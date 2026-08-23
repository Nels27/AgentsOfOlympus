# Phase 2: Signal Gateway — Design

## Context

Phase 1 (Hermes Core) is merged to `main`. At Phase 1 wrap-up, Signal
replaced Telegram as the project's messaging platform (recorded in the
vault's `Implementation Strategy.md` and this repo's `docs/ARCHITECTURE.md`,
both already updated and merged). This spec covers Phase 2 per the vault's
§7 ("Signal Command and Scheduling"): wiring Signal into Hermes as a real,
working messaging channel.

Unlike Telegram's single-bot-token model, Signal integration is genuinely
more involved — verified against Hermes's own docs and real command
execution during this design pass, not assumed:

- Hermes talks to Signal through a **separate, required daemon**:
  `signal-cli` (Java-based), running its own HTTP JSON-RPC server that
  Hermes calls into. This is a second container to design and run, not an
  env var.
- Linking is **account-linking under an existing Signal account** (the
  same mechanism as linking Signal Desktop — scan a QR code from
  Settings → Linked Devices), not a fresh, independent bot identity.
- **Decision: link as a device on the operator's personal Signal
  account**, not a dedicated/separate number. Accepted tradeoff: if that
  personal account ever becomes inaccessible (lost phone + fresh Signal
  account rather than a number migration), the linked-device session
  breaks and needs re-linking. The link procedure itself (see Components)
  is fast and fully repeatable, so this was judged an acceptable risk
  rather than a blocker.
- `signal-cli`'s linked-device session state
  (`~/.local/share/signal-cli/` per its own docs, though this project
  pins an explicit path instead of trusting an assumed default — see
  Components) is a **directory of session data, not a single value**, so
  it does not fit the Phase 0 SOPS `secrets/` pipeline (one-secret-per-file,
  designed for single values like `api_server_key`). It's backed up as its
  own volume instead, the same tier of sensitivity as `~/.hermes/` itself.

## Goals

- `signal-cli` running as its own Compose service on the `olympus`
  network, linked to the operator's personal Signal account as a
  secondary device.
- Hermes configured to use that daemon as its Signal transport
  (`SIGNAL_HTTP_URL`, `SIGNAL_ACCOUNT`), enabled via `hermes gateway setup`.
- A documented, repeatable linking procedure that works headlessly (no
  GUI on the host) — verified live during this design pass, not copied
  from a doc that might not apply to a containerized, headless setup.
- Access locked to the operator's own identity; any future user goes
  through Hermes's pairing system. `SIGNAL_ALLOW_ALL_USERS` never set to
  `true`.
- Phase gate: DM round-trip works over Signal; a test cron job fires and
  delivers to the operator's Signal thread; a paired-user revocation takes
  effect immediately.

## Non-goals

- No terminal-backend confinement (Docker socket proxy, hardened worker
  image, egress firewall) for the ephemeral specialist agents Hermes will
  eventually spawn per-task — that's Phase 3. This phase only wires the
  Signal transport into Hermes itself.
- No dedicated/separate phone number for the bot — explicitly decided
  against for now (see Context).
- No LangGraph/Ollama routing changes — unrelated to this phase.
- Not solving `signal-cli`'s behavior across a Signal "Change Number"
  event — unverified (see Open questions); out of scope to investigate
  further for this slice.

## Components

1. **`signal-cli` image, verified by actually pulling and running it
   during this design pass** (not just trusted from docs):
   `registry.gitlab.com/packaging/signal-cli/signal-cli-jre@sha256:87ee76a3d4204a0d271ce2789b8d8b3ac5e715a06fe9ac80d4369c5fe982c078`.
   Confirmed real subcommands via `--help`: `link -n NAME`, `daemon
   [--http [HOST:PORT]]` (defaults to `localhost:8080` — must be set
   explicitly to `0.0.0.0:8080` so it's reachable from Hermes's separate
   container, not just within its own), top-level `-a ACCOUNT`/`--account`
   and `-d DATA_DIR`/`--data-dir` flags (precede the subcommand).

   **`jre` variant, not `native`** — discovered during implementation
   (Task 3): the `native` (GraalVM-compiled) variant threw a recurring,
   though non-fatal, `ClassCastException` in its message-receive handling
   (`RetrieveDeviceNameAction`), matching a documented pattern of
   reflection/type-metadata bugs across several upstream `signal-cli`
   issues specific to native-image builds. Verified live: ran the same
   real message through both variants against the same linked-account
   data — `native` threw the exception, `jre` processed it with zero
   occurrences. Tradeoff accepted: `jre` uses more memory at rest (~183MB
   vs. ~77MB), worth it for correctness given ample headroom on this host.

2. **Volume.** Host path `~/.signal-cli` bind-mounted to an explicit
   container path, `/data` (passed via `-d /data` to every invocation —
   both the one-time `link` step and the persistent `daemon` step, so they
   share session state). Pinned explicitly rather than trusting the
   image's default: two different docs disagreed on what that default
   even is (`$HOME/.local/share/signal-cli` vs `/var/lib/signal-cli`), so
   guessing wasn't safe.

3. **Linking procedure (manual, one-time, run by the operator — real
   account credentials, not scriptable, same pattern as Phase 1's `hermes
   setup`/`hermes model`).**

   ```bash
   mkdir -p ~/.signal-cli
   docker run --rm -v ~/.signal-cli:/data \
     registry.gitlab.com/packaging/signal-cli/signal-cli-jre@sha256:87ee76a3d4204a0d271ce2789b8d8b3ac5e715a06fe9ac80d4369c5fe982c078 \
     -d /data link -n "HermesAgent" > /tmp/signal-link.txt 2>&1
   ```

   The timing and output-format behavior here **was** verified live during
   this design pass — running the bare command (no volume, no `-d`) took
   ~20-40 seconds (JVM cold start + a round trip to Signal's servers)
   before it printed a `sgnl://linkdevice?uuid=...&pub_key=...` URI to
   stdout, then blocked waiting for the phone-side scan. No garbled-QR
   terminal issue (a known `signal-cli` quirk in some setups) since there's
   no TTY for it to render into in the first place; the plain-text URI is
   what gets captured. The `-v .../-d /data` combination above is this
   project's volume design (Component 2) layered on top of that verified
   base behavior — the flag itself is confirmed to exist via `--help`, but
   this exact combined invocation wasn't independently re-run; low risk,
   worth a real test during implementation rather than assuming it's
   identical. Once the URI is captured, render it as a scannable image:

   ```bash
   grep -o 'sgnl://linkdevice[^[:space:]]*' /tmp/signal-link.txt | qrencode -o ~/signal-link.png -s 12 -m 4
   ```

   Open `signal-link.png` (via the IDE, or Windows file explorer — same
   filesystem) and scan it: Signal app → Settings → Linked Devices → Link
   New Device.

4. **`compose.yaml` `signal-cli` service.** No host port exposure at all
   — unlike Hermes's own gateway API, only Hermes (another container on
   the same `olympus` network) needs to reach this one, so there's nothing
   to bind to loopback:

   ```yaml
   signal-cli:
     image: registry.gitlab.com/packaging/signal-cli/signal-cli-jre@sha256:87ee76a3d4204a0d271ce2789b8d8b3ac5e715a06fe9ac80d4369c5fe982c078
     container_name: signal-cli
     command: ["-a", "${SIGNAL_ACCOUNT}", "-d", "/data", "daemon", "--http", "0.0.0.0:8080"]
     restart: unless-stopped
     volumes:
       - ${HOME}/.signal-cli:/data
     networks:
       - olympus
   ```

5. **Hermes-side enablement (manual, interactive — run by the operator,
   per Hermes's own docs: `hermes gateway setup`, select Signal from the
   menu).** Needs `SIGNAL_HTTP_URL`/`SIGNAL_ACCOUNT` reachable to validate
   against the now-running daemon. Once confirmed working, add to the
   `hermes` service's `environment:` block in `compose.yaml`:
   `SIGNAL_HTTP_URL: http://signal-cli:8080` and `SIGNAL_ACCOUNT:
   ${SIGNAL_ACCOUNT}`. Add `depends_on: [signal-cli]` to `hermes` so it
   doesn't start before the daemon it needs is at least running (not a
   strict health-checked dependency — YAGNI for now).

6. **Access control.** `SIGNAL_ALLOWED_USERS` set to the operator's own
   identity (exact format — phone number vs. Signal's internal UUID — not
   documented anywhere found; verify at implementation time by inspecting
   what a real pairing attempt actually produces, same rigor as Phase 1's
   CLI verification). `SIGNAL_ALLOW_ALL_USERS` never set to `true` — same
   RCE-adjacent reasoning as the generic `GATEWAY_ALLOW_ALL_USERS` rule.
   Unknown senders fall through to Hermes's pairing system (`hermes
   pairing approve signal CODE`) — confirmed platform-agnostic, not
   Signal-specific, so this part of the vault's original (pre-Signal)
   design carries over unchanged.

## Bring-up sequence

Order matters — the daemon just serves an already-linked session, so
there's nothing to serve until linking happens first:

1. Manual: run the linking procedure (Component 3), scan the QR, confirm
   linked.
2. `docker compose up -d signal-cli` — daemon now serving the linked
   session.
3. Manual: `hermes gateway setup`, select Signal.
4. Wire `SIGNAL_HTTP_URL`/`SIGNAL_ACCOUNT` into the `hermes` service,
   `docker compose up -d hermes` to pick up the change.
5. Phase gate verification (see Goals).

## Error handling

No custom error-handling code — operator-driven setup plus declarative
Compose config, same posture as Phase 1. `restart: unless-stopped` covers
crash recovery for `signal-cli`, same as it does for `hermes`. If the link
ever breaks (device removed from the phone's Linked Devices list, account
issues), the fix *is* re-running the linking procedure — fast and fully
repeatable, not a special code path.

## Open questions

One item resolved during implementation, one still genuinely open:

1. **`SIGNAL_ALLOWED_USERS`'s exact identity format — resolved.** Not
   documented anywhere found during research, but turned out not to need
   guessing: Hermes's own `hermes gateway setup` wizard sets it
   automatically (written to `~/.hermes/.env`, not `config.yaml`), and a
   length-only check (never exposing the actual value) confirmed it
   matches `SIGNAL_ACCOUNT`'s length — both 12 characters, consistent with
   E.164 phone format. No manual access-control step was needed.
2. **`signal-cli`'s behavior across a Signal "Change Number" event** for a
   linked device — whether it resyncs gracefully or requires re-linking.
   Not investigated further; out of scope for this slice per Non-goals.
   The operator accepted the broader "personal account" risk with this
   specific sub-question still open.
