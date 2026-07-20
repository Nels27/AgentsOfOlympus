# Phase 1: Hermes Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a real, persistent Hermes gateway (Anthropic as hosted provider, Ollama registered as a second, currently-unused provider) as a Compose service attached to the `olympus` network, proven to survive a restart.

**Architecture:** Hermes's own interactive CLI (setup wizard, model picker) populates `~/.hermes/.env` and `~/.hermes/config.yaml` on the host — real credentials, run by you, not scripted. Everything after that (the `compose.yaml` service definition, bringing the gateway up, verifying it) is declarative and non-secret.

**Tech Stack:** Docker Compose v2, `nousresearch/hermes-agent` (digest-pinned), Ollama 0.32.1 (native WSL systemd service, already installed).

## Global Constraints

- Digest-pin the Hermes image: `nousresearch/hermes-agent@sha256:b29520aa3244ab4f65cb9d66ba86db5e59d2f581c3b7401cd642e4325ca4883d` (verified by pulling it during design — `linux/amd64`, 2.61GB). Do not use a floating tag.
- No service binds `0.0.0.0` (vault plan §5). All Hermes ports bind to `127.0.0.1` only.
- Ollama is reachable from inside the Hermes container at `http://host.docker.internal:11434`, not `localhost:11434` (Docker Desktop WSL2 backend confirmed; `localhost` inside the container resolves to the container itself).
- No OpenClaw migration, no Telegram/gateway messaging config, no terminal-backend confinement — out of scope for this slice (see spec's Non-goals).
- Real credentials (Anthropic API key, Ollama provider registration) are entered by you directly through Hermes's own interactive CLI — never typed or relayed through the Bash tool.

---

### Task 1: Hermes credentials setup (manual — run by you)

**Files:** None created by this task — it populates `~/.hermes/` on the host, outside the repo (per the spec's Credentials architecture section: `~/.hermes` is its own separately-backed-up stateful volume, not part of the repo's SOPS `secrets/` pipeline).

**Interfaces:**
- Produces: `~/.hermes/.env` (contains `ANTHROPIC_API_KEY`) and `~/.hermes/config.yaml` (contains the Ollama provider entry), both consumed by Task 3's `compose.yaml` service via the `~/.hermes:/opt/data` volume mount.

- [ ] **Step 1: Run the setup wizard yourself**

```bash
mkdir -p ~/.hermes
docker run -it --rm -v ~/.hermes:/opt/data nousresearch/hermes-agent:latest setup
```

Enter your real Anthropic API key when prompted. This is interactive — the Bash tool can't drive it (no TTY), and a real secret shouldn't be relayed through it anyway.

- [ ] **Step 2: Verify `.env` and `config.yaml` exist (safe to check yourself or ask me to)**

```bash
ls -la ~/.hermes/.env ~/.hermes/config.yaml
grep -c ANTHROPIC_API_KEY ~/.hermes/.env
```

Expected: both files exist; the `grep -c` prints `1` (confirms the key is present without printing its value).

- [ ] **Step 3: Run the interactive model picker yourself, registering Ollama**

```bash
docker run -it --rm -v ~/.hermes:/opt/data nousresearch/hermes-agent:latest model
```

When prompted for a provider/endpoint, add Ollama pointing at `http://host.docker.internal:11434` (not `localhost` — Hermes will run containerized once Task 4 stands up the gateway service, and `localhost` inside a container resolves to the container itself, not the WSL host running Ollama). Keep Anthropic as the active/default provider — Ollama should be registered as available, not switched to.

- [ ] **Step 4: Verify the Ollama entry landed in `config.yaml` (this file has no secrets, safe to view in full)**

```bash
cat ~/.hermes/config.yaml
```

Expected: some reference to a provider/endpoint pointing at `host.docker.internal:11434` alongside the existing Anthropic configuration. Confirm this yourself since the exact key structure depends on what the picker wrote (not pinned down further in the spec — the interactive picker's own output is the source of truth here, not a schema this plan can predict in advance).

No commit for this task — nothing in it touches the repo.

---

### Task 2: CLI smoke test (manual — run by you)

**Files:** None.

**Interfaces:**
- Consumes: `~/.hermes/.env`/`config.yaml` from Task 1.

- [ ] **Step 1: Run the one-shot prompt flag yourself**

```bash
docker run --rm -v ~/.hermes:/opt/data nousresearch/hermes-agent:latest -z "Reply with exactly: PHASE1-SMOKE-TEST-OK"
```

`-z PROMPT` is the top-level non-interactive one-shot flag (confirmed against real `hermes --help` output during design — not `chat -q`, which doesn't exist on this CLI). This makes a real call to Anthropic using the credentials Task 1 wrote.

- [ ] **Step 2: Confirm the response**

Expected: the container's output includes `PHASE1-SMOKE-TEST-OK` (or a close paraphrase — models don't always echo instructions verbatim) somewhere in the response text, proving the Anthropic provider path works end to end. Report the result back before continuing to Task 3.

No commit for this task.

---

### Task 3: Add the `hermes` service to `compose.yaml`

**Files:**
- Modify: `orchestration-server/compose.yaml`

**Interfaces:**
- Consumes: nothing from earlier tasks directly (Docker reads `~/.hermes` at container start, not at config-write time).
- Produces: a `hermes` service in Compose that Task 4 brings up.

- [ ] **Step 1: Read the current file**

```bash
cat orchestration-server/compose.yaml
```

Expected (as of Phase 0): just the `name:` and `networks:` blocks, no services yet.

- [ ] **Step 2: Add the `hermes` service**

Add a `services:` block so the file becomes:

```yaml
name: agents-of-olympus

networks:
  olympus:
    name: olympus
  delphi:
    name: delphi
    internal: true
  argus_net:
    name: argus_net

services:
  hermes:
    image: nousresearch/hermes-agent@sha256:b29520aa3244ab4f65cb9d66ba86db5e59d2f581c3b7401cd642e4325ca4883d
    container_name: hermes
    command: gateway run
    restart: unless-stopped
    environment:
      API_SERVER_ENABLED: "true"
      HERMES_DASHBOARD: "1"
    volumes:
      - ${HOME}/.hermes:/opt/data
    networks:
      - olympus
    ports:
      - "127.0.0.1:8642:8642"
      - "127.0.0.1:9119:9119"
```

`${HOME}` interpolates from the shell environment Compose runs in (not `.env`, since it's host-machine-specific, not project config) — confirm this resolves correctly in Step 3.

- [ ] **Step 3: Validate syntax and variable interpolation**

```bash
cd orchestration-server
docker compose config
```

Expected: exit 0. Unlike Phase 0's networks-only file, this time the output **will** show the `hermes` service fully resolved (including the `${HOME}` interpolation resolved to your actual home directory path) — Compose only omits services/networks nothing references, and now something references all three.

- [ ] **Step 4: Commit**

```bash
git add orchestration-server/compose.yaml
git commit -m "feat: add hermes gateway service (digest-pinned, olympus network, loopback-bound ports)"
```

---

### Task 4: Bring up the gateway and verify the phase gate

**Files:** None — this task only runs and verifies Task 3's service.

**Interfaces:**
- Consumes: the `hermes` service from Task 3; the credentials from Task 1.

- [ ] **Step 1: Start the gateway**

```bash
cd orchestration-server
docker compose up -d hermes
docker compose ps
```

Expected: `hermes` listed with state `Up` / `running`.

- [ ] **Step 2: Verify network attachment**

```bash
docker network inspect olympus --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}'
```

Expected: `hermes` printed — the first real proof a Phase 0 network actually works (Phase 0 couldn't prove this itself since no service existed yet to attach to one).

- [ ] **Step 3: Confirm the gateway process is healthy**

```bash
docker logs hermes --tail 50
```

Expected: no crash loop or fatal errors in the tail of the log; s6-overlay service-start lines similar to what you saw during the CLI smoke test's container init, ending in the gateway staying up (not exiting).

- [ ] **Step 4: Restart-persistence test**

```bash
docker compose restart hermes
sleep 3
docker compose ps
ls ~/.hermes/sessions/ 2>/dev/null | head -5
```

Expected: `hermes` shows `Up` again after the restart; `~/.hermes/sessions/` (or `config.yaml`/`memories/`, whichever already has content from Tasks 1–2's interactive runs) still has its prior content — proving state survives a restart via the mounted volume, not just the running container.

- [ ] **Step 5: No commit** — this task is verification only, nothing new to check in. This completes Phase 1's phase gate ("CLI answers; gateway process healthy; container survives restart with memory intact").

Update `Phase 0 Session Status.md`'s sibling note for Phase 1 in the Obsidian vault to reflect completion before starting Phase 2 (Telegram Command and Scheduling).
