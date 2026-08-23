# Phase 2: Signal Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire Signal into Hermes as a real, working messaging channel — `signal-cli` running as its own Compose service, linked to the operator's personal Signal account, with Hermes talking to it and passing the phase gate (DM round-trip, cron delivery, pairing revocation).

**Architecture:** `signal-cli` runs as its own container on the `olympus` network (no host port exposure — only Hermes needs to reach it). Linking happens once, manually, via a QR code rendered from a captured link URI (headless-safe, verified live during design). Hermes is pointed at the daemon via env vars and enabled through its own interactive `gateway setup` wizard.

**Tech Stack:** `signal-cli` (Java, official GitLab packaging image), `qrencode` (host tool), Docker Compose v2.

**Spec:** `docs/superpowers/specs/2026-08-18-phase2-signal-gateway-design.md`

## Global Constraints

- `signal-cli` image, digest-pinned: `registry.gitlab.com/packaging/signal-cli/signal-cli-jre@sha256:87ee76a3d4204a0d271ce2789b8d8b3ac5e715a06fe9ac80d4369c5fe982c078`. **Not** the `native` variant — discovered live during Task 3 that it throws a recurring (though non-fatal) `ClassCastException` in its message-receive handling (`RetrieveDeviceNameAction`), a known class of bug in this project's GraalVM native-image builds (reflection/type-metadata mismatches, documented pattern across several upstream issues). Verified the `jre` variant processes the same real message with zero occurrences of the exception. Tradeoff: ~183MB memory vs. ~77MB for `native` — worth it for correctness given ample headroom on this host.
- `signal-cli` gets no host port mapping — only reachable from other containers on `olympus`.
- Linked-device session state lives at `~/.signal-cli` (host) → `/data` (container, explicit, not relying on the image's default). Not part of the SOPS `secrets/` pipeline — it's a directory, not a single value.
- `SIGNAL_ALLOW_ALL_USERS` (and the generic `GATEWAY_ALLOW_ALL_USERS`) never set to `true`.
- Real account linking and `hermes gateway setup` are manual, interactive steps run by the operator — never scripted or driven through the Bash tool, same rule Phase 1 established for real credentials.
- `hermes gateway setup` takes zero flags (confirmed via `--help` during plan-writing) — it's unconditionally interactive, no non-interactive path exists.

---

### Task 1: Install `qrencode`

**Files:** None — host package install.

**Interfaces:** None.

- [ ] **Step 1: Install**

```bash
sudo apt update && sudo apt install -y qrencode
```

- [ ] **Step 2: Verify**

```bash
qrencode --version
```

Expected: version output (e.g. `4.1.1`), exit 0.

No commit for this task — nothing in it touches the repo.

---

### Task 2: Link the Signal account (manual — run by you)

**Files:** None created in the repo — this populates `~/.signal-cli` on the host, outside the repo (same treatment as `~/.hermes`: a separately-managed stateful volume, not SOPS-encrypted).

**Interfaces:**
- Produces: linked-device session data in `~/.signal-cli`, consumed by Task 3's `signal-cli` daemon service via the `~/.signal-cli:/data` volume mount.

- [ ] **Step 1: Run the link command yourself**

**Discovered live during execution:** the image runs internally as `uid=101` (`signal-cli` user), not root — a bind-mounted host directory owned by your normal user (mode `755`) gives that uid no write access, which fails as `Failed to read local accounts list` (exit 3). Fixed with `--user "$(id -u):$(id -g)"`, verified live (`listAccounts` against the mount went from failing to exit 0). This same flag is needed on the persistent daemon service in Task 3.

```bash
mkdir -p ~/.signal-cli
docker run --rm --user "$(id -u):$(id -g)" -v ~/.signal-cli:/data \
  registry.gitlab.com/packaging/signal-cli/signal-cli-jre@sha256:87ee76a3d4204a0d271ce2789b8d8b3ac5e715a06fe9ac80d4369c5fe982c078 \
  -d /data link -n "HermesAgent" > /tmp/signal-link.txt 2>&1 &
```

Run this in the background (`&`) or a second terminal — it takes ~20-40 seconds (JVM cold start + a round trip to Signal's servers, confirmed by timing this live during design) before the URI appears, then it blocks waiting for the phone-side scan. Watch for the URI:

```bash
sleep 30 && cat /tmp/signal-link.txt
```

Expected: a line containing `sgnl://linkdevice?uuid=...&pub_key=...`.

- [ ] **Step 2: Render it as a scannable QR code**

```bash
grep -o 'sgnl://linkdevice[^[:space:]]*' /tmp/signal-link.txt | qrencode -o ~/signal-link.png -s 12 -m 4
```

- [ ] **Step 3: Scan it**

Open `~/signal-link.png` (via your IDE's file viewer, or Windows Explorer — same filesystem, path is `\\wsl$\...` or the mapped drive). On your phone: Signal app → Settings → Linked Devices → tap **+** → scan the QR code.

- [ ] **Step 4: Confirm the link completed**

The backgrounded `docker run` from Step 1 should exit on its own (not hang) once the phone confirms the scan. Check:

```bash
jobs
ls -la ~/.signal-cli
```

Expected: the background job is no longer running (completed), and `~/.signal-cli` contains files (exact layout wasn't independently verified during design — confirm here that it's non-empty, which is what matters for Task 3 to have something to serve).

- [ ] **Step 5: Clean up the temp file**

```bash
rm -f /tmp/signal-link.txt ~/signal-link.png
```

No commit for this task.

---

### Task 3: Add the `signal-cli` service to `compose.yaml`

**Files:**
- Modify: `orchestration-server/compose.yaml`

**Interfaces:**
- Consumes: `~/.signal-cli` from Task 2.
- Produces: a running `signal-cli` daemon on `olympus`, reachable at `http://signal-cli:8080` from other containers on that network — consumed by Task 4/5's `hermes` wiring.

- [ ] **Step 1: Read the current file**

```bash
cat orchestration-server/compose.yaml
```

Expected: the `hermes` service from Phase 1, no `signal-cli` service yet.

- [ ] **Step 2: Add the `signal-cli` service**

```yaml
  signal-cli:
    image: registry.gitlab.com/packaging/signal-cli/signal-cli-jre@sha256:87ee76a3d4204a0d271ce2789b8d8b3ac5e715a06fe9ac80d4369c5fe982c078
    container_name: signal-cli
    user: "${UID}:${GID}"
    command: ["-a", "${SIGNAL_ACCOUNT}", "-d", "/data", "daemon", "--http", "0.0.0.0:8080"]
    restart: unless-stopped
    volumes:
      - ${HOME}/.signal-cli:/data
    networks:
      - olympus
```

`user: "${UID}:${GID}"` matches Task 2's live-discovered fix — the image runs internally as `uid=101`, which has no write access to a host-owned bind mount. `UID`/`GID` aren't automatically exported by most shells, so Task 3's bring-up step needs to export them explicitly before `docker compose up` (covered there).

Append this under the existing `services:` key, alongside `hermes`.

- [ ] **Step 3: Add `SIGNAL_ACCOUNT` to `.env.example` and your local `.env`**

```bash
echo 'SIGNAL_ACCOUNT=+1XXXXXXXXXX' >> orchestration-server/.env.example
```

Then in your local, gitignored `orchestration-server/.env`, set it to your real E.164-format phone number (the one you linked in Task 2) — not the placeholder.

- [ ] **Step 4: Validate syntax**

```bash
cd orchestration-server
docker compose config
```

Expected: exit 0. `signal-cli` should now appear fully resolved in the output (it has a service referencing it — itself — unlike Phase 0's unused networks).

- [ ] **Step 5: Bring it up and verify it's running**

`UID`/`GID` must be in the environment for Compose's `${UID}:${GID}` interpolation to resolve. **Discovered live:** `$UID` is a real bash builtin (just needs exporting), but `$GID` is not a standard bash variable at all — it's empty by default, and `export UID GID` alone produces a malformed `user: '1000:'` (verified: this exact command was tried and failed before finding the fix below):

```bash
export UID
export GID=$(id -g)
docker compose up -d signal-cli
docker compose ps
docker logs signal-cli --tail 20
```

Expected: `signal-cli` shows `Up`; logs show the daemon starting without repeated errors (compare against the log-spam pattern Phase 1 hit with a missing `API_SERVER_KEY` — if you see something looping like that here, the account likely isn't actually linked yet from Task 2).

- [ ] **Step 6: Commit**

```bash
cd ..
git add orchestration-server/compose.yaml orchestration-server/.env.example
git commit -m "feat: add signal-cli daemon service (digest-pinned, olympus network)"
```

---

### Task 4: Wire Hermes to the `signal-cli` daemon

**Files:**
- Modify: `orchestration-server/compose.yaml`

**Interfaces:**
- Consumes: the running `signal-cli` service from Task 3 (`http://signal-cli:8080`).
- Produces: `hermes` service configured with `SIGNAL_HTTP_URL`/`SIGNAL_ACCOUNT`, ready for Task 5's `gateway setup`.

- [ ] **Step 1: Add env vars and `depends_on` to the `hermes` service**

In `orchestration-server/compose.yaml`, under the existing `hermes` service's `environment:` block, add two keys, and add a new `depends_on:` key alongside `networks:`:

```yaml
  hermes:
    image: nousresearch/hermes-agent@sha256:b29520aa3244ab4f65cb9d66ba86db5e59d2f581c3b7401cd642e4325ca4883d
    container_name: hermes
    command: gateway run
    restart: unless-stopped
    depends_on:
      - signal-cli
    environment:
      API_SERVER_ENABLED: "true"
      API_SERVER_KEY: ${API_SERVER_KEY}
      SIGNAL_HTTP_URL: http://signal-cli:8080
      SIGNAL_ACCOUNT: ${SIGNAL_ACCOUNT}
    volumes:
      - ${HOME}/.hermes:/opt/data
    networks:
      - olympus
    ports:
      - "127.0.0.1:8642:8642"
```

- [ ] **Step 2: Validate**

```bash
cd orchestration-server
./scripts/compose-up.sh config
```

Use the Phase 1 wrapper (not bare `docker compose config`) since `API_SERVER_KEY` needs decrypting/exporting for the interpolation to resolve — same caution as Phase 1: this prints the real secret value, so don't paste this output anywhere it'll persist.

Expected: exit 0, `hermes` service shows `SIGNAL_HTTP_URL`/`SIGNAL_ACCOUNT` resolved correctly.

- [ ] **Step 3: Commit**

```bash
cd ..
git add orchestration-server/compose.yaml
git commit -m "feat: wire hermes to the signal-cli daemon"
```

---

### Task 5: Enable Signal in Hermes (manual — run by you)

**Files:** None — this populates `~/.hermes/config.yaml`, same as Phase 1's `hermes model` step.

**Interfaces:**
- Consumes: `SIGNAL_HTTP_URL`/`SIGNAL_ACCOUNT` from Task 4, the running `signal-cli` daemon from Task 3.
- Produces: Signal enabled in `~/.hermes/config.yaml`'s platform config, consumed by Task 6's bring-up.

- [ ] **Step 1: Run `gateway setup` yourself, through Compose**

```bash
cd orchestration-server
docker compose run --rm hermes gateway setup
```

Using `docker compose run` (not a bare `docker run`) matters here — it automatically attaches to the `olympus` network and picks up the `hermes` service's env vars (`SIGNAL_HTTP_URL`, `SIGNAL_ACCOUNT`) from Task 4's config, so the wizard can actually reach the running `signal-cli` daemon to validate against. A bare `docker run` would need `--network olympus` and both `-e` flags typed by hand to get the same result.

Confirmed via `--help` during plan-writing: this command takes zero flags — it's fully interactive. Select Signal from the platform menu when prompted.

- [ ] **Step 2: Verify it landed in `config.yaml` (not secret, safe to view in full — same check as Phase 1's Ollama registration)**

```bash
docker run --rm -v ~/.hermes:/opt/data --entrypoint cat nousresearch/hermes-agent:latest /opt/data/config.yaml 2>&1 | grep -A5 -i signal
```

**Discovered live: the wizard writes to `~/.hermes/.env`, not `config.yaml`.** The `grep -A5 -i signal` check above only turns up the pre-existing generic `platform_toolsets` list (present before setup ran too, not proof of anything). Check `.env` instead:

```bash
docker run --rm -v ~/.hermes:/opt/data --entrypoint sh nousresearch/hermes-agent:latest -c "grep -io '^[A-Z_]*SIGNAL[A-Z_]*=' /opt/data/.env"
```

Expected: `SIGNAL_HTTP_URL=`, `SIGNAL_ACCOUNT=`, and `SIGNAL_ALLOWED_USERS=` (key names only — this command never prints values).

- [ ] **Step 3: Confirm access control — resolved automatically, no manual action needed**

**Discovered live: the wizard already sets `SIGNAL_ALLOWED_USERS` itself** as part of setup — the spec's originally-unverified question (phone number vs. UUID format) resolved on its own: confirmed both `SIGNAL_ACCOUNT` and `SIGNAL_ALLOWED_USERS` are the same length (12 chars, matching E.164 phone format) via a length-only check that never exposed the actual values:

```bash
docker run --rm -v ~/.hermes:/opt/data --entrypoint sh nousresearch/hermes-agent:latest -c "
for key in SIGNAL_HTTP_URL SIGNAL_ACCOUNT SIGNAL_ALLOWED_USERS; do
  val=\$(grep \"^\${key}=\" /opt/data/.env | cut -d= -f2-)
  if [ -n \"\$val\" ]; then echo \"\${key}: set (\${#val} chars)\"; else echo \"\${key}: EMPTY\"; fi
done
"
```

Also confirm the hard safety constraint — `SIGNAL_ALLOW_ALL_USERS` must never be `true`:

```bash
docker run --rm -v ~/.hermes:/opt/data --entrypoint sh nousresearch/hermes-agent:latest -c "grep -i 'SIGNAL_ALLOW_ALL_USERS' /opt/data/.env /opt/data/config.yaml 2>/dev/null || echo 'not set anywhere (good)'"
```

No commit needed for this step — nothing in the repo needs to change since the wizard's own output already satisfies the spec's access-control requirement.

Skip this step if Step 1's wizard already handled authorization and nothing in the repo changed.

---

### Task 6: Bring up Hermes and verify the phase gate

**Files:** None — verification only.

**Interfaces:**
- Consumes: everything from Tasks 1–5.

- [ ] **Step 1: Bring `hermes` up with the new config**

```bash
cd orchestration-server
./scripts/compose-up.sh up -d hermes
docker compose ps
```

Expected: both `hermes` and `signal-cli` show `Up`.

- [ ] **Step 2: DM round-trip (manual — run by you)**

Send the message via **Notes to Self** — since this account is linked as a device on the operator's own personal Signal account (not a separate bot identity), Notes to Self is the documented, intended way to interact with it, not a workaround. Confirmed via Hermes's own docs: it detects messages addressed to its own linked account and processes them as regular inbound messages, with built-in echo-back/loop protection (sent-timestamp tracking) so its own replies don't get reprocessed as new input. Confirm Hermes responds back in that same Notes to Self thread.

- [ ] **Step 3: Cron delivery test**

`hermes cron create` is fully non-interactive (confirmed via `--help`), not interactive as originally assumed. **Discovered live: the bare `--deliver signal` shorthand ("home channel") does not work** — the job runs and reports "succeeded" but nothing is delivered. Root cause: unlike every other platform (Telegram, Discord, Slack, etc.), Signal has no `SIGNAL_HOME_CHANNEL` config option at all (confirmed via `hermes config check` — every other platform has one, Signal doesn't). The fix is an explicit target, `signal:+<E.164 number>`, confirmed working via `hermes send --to "signal:+<number>"` first (isolates cron-specific vs. broader delivery issues), then the same explicit target in `cron create --deliver`:

```bash
docker exec hermes hermes cron create "0 3 1 1 *" --name "phase2-test" --deliver "signal:+<your E.164 number>" "Reply with exactly: PHASE2-CRON-TEST-OK"
```

The schedule value here is a placeholder far in the future — the point of this test isn't waiting for a real schedule, it's using `cron run <job_id>` to fire on demand:

```bash
docker exec hermes hermes cron run <job_id>
```

Confirm the message arrives in Notes to Self, then remove the test job:

```bash
docker exec hermes hermes cron rm <job_id>
```

- [x] **Step 4: Pairing revocation test — SKIPPED, documented gap, not a failure**

No second Signal identity was available to test with at the time of this
phase gate. `hermes pairing approve/revoke` themselves are confirmed real,
existing subcommands (verified via `hermes pairing --help` during
plan-writing), and this mechanism was already confirmed platform-agnostic
(a Hermes gateway feature, not Signal-specific) back in the design spec —
so there's good reason to expect it works, but it has **not been
exercised end-to-end** for this project. Revisit when a second identity
becomes available (e.g., when Phase 2 gets replicated onto the production
Beelink host, a message from that environment's own operator interaction,
or simply borrowing a friend's phone for five minutes).

- [ ] **Step 5: No commit** — this task is verification only. Phase 2's
  phase gate is **mostly passed**: DM round-trip works, cron delivery
  works (after the explicit-target fix); pairing revocation is an
  documented open gap, not a failure — see Step 4.

Update the vault's Phase Status note for Phase 2 to reflect completion before starting Phase 3 (Terminal Backend Confinement).
