# Phase 3: Terminal Backend Confinement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Confine what Hermes's terminal/tool-execution capability can do — Docker-backed execution routed through a socket proxy (Hermes never sees the raw socket), a hardened worker image, and egress control on the real `DOCKER-USER` chain.

**Architecture:** `tecnativa/docker-socket-proxy` sits between Hermes and `dockerd`, reachable via `DOCKER_HOST`. Hermes's own Docker backend (one persistent container, `docker exec` per command) creates its worker container through that proxy, using a custom image extending Hermes's own default with `git`+`ripgrep`. `nftables` rules on the real `DOCKER-USER` chain (applied via a privileged `--net=host` container in this Docker-Desktop/WSL2 dev environment) restrict worker egress.

**Tech Stack:** `tecnativa/docker-socket-proxy`, Docker Compose v2, `nikolaik/python-nodejs:python3.11-nodejs20` base image, `nftables`.

**Spec:** `docs/superpowers/specs/2026-08-23-phase3-terminal-confinement-design.md`

## Global Constraints

- **Naming/network correction, discovered live during Task 3 (via an automated security review, not caught during design):** the socket proxy service is named `cerberus` (matching the vault's Appendix A pantheon naming — "the gatekeeper... permits only specific, enumerated passage" — missed in the original Task 1 wording below, which still says `docker-socket-proxy` throughout as originally written), digest-pinned rather than `:latest`, and lives on its own dedicated internal network (`cerberus_net`, shared only with `hermes`) rather than the shared `olympus` network. The review correctly flagged that `signal-cli` had no legitimate reason to be able to reach a service with container create/exec permissions, even though it never actually used that access. Confirmed via `docker network inspect` that `signal-cli` has no path to `cerberus_net` after the fix. Read `docker-socket-proxy`/`olympus` below as `cerberus`/`cerberus_net` wherever they conflict with this note.
- Socket proxy env vars: `CONTAINERS=1`, `POST=1`, `EXEC=1`, `INFO=1` — discovered live that `INFO=1` is required or Hermes's own health check reports a false "daemon not running," even though actual container operations work without it.
- `terminal.backend` must be set via `hermes config set terminal.backend docker` — there is no `TERMINAL_BACKEND` env var (confirmed absent; don't reintroduce this wrong assumption).
- Worker container: `docker_run_as_host_user: true`, `container_cpu: 2`, `container_memory: 2048` (MB) — sensible bounds for this host's ~16 CPU/16GB Docker Desktop allocation, shared with the rest of the stack.
- The worker image and its container lifecycle are managed by **Hermes itself** (its own Docker backend logic), not by `compose.yaml` — only the socket proxy is a Compose service.
- `nftables`/`DOCKER-USER` chain edits happen via a privileged `--net=host` container (the "sudo equivalent" in this Docker-Desktop/WSL2 environment — neither `nft` nor `iptables` is installed natively here, and `dockerd` runs in Docker Desktop's own internal VM, not this WSL distro). Never remove or reorder past Docker Desktop's own existing rules on that chain (ports 3128/5555/53) — insert scoped rules, don't flush the chain.
- No secrets in the worker container's environment, ever.

---

### Task 1: Add the `docker-socket-proxy` service to `compose.yaml`

**Files:**
- Modify: `orchestration-server/compose.yaml`

**Interfaces:**
- Produces: a running socket proxy on `olympus`, reachable at `http://docker-socket-proxy:2375` from other containers on that network — consumed by Task 3's Hermes wiring.

- [ ] **Step 1: Read the current file**

```bash
cat orchestration-server/compose.yaml
```

- [ ] **Step 2: Add the service**

```yaml
  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy:latest
    container_name: docker-socket-proxy
    environment:
      CONTAINERS: "1"
      POST: "1"
      EXEC: "1"
      INFO: "1"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - olympus
```

No host port mapping — same reasoning as `signal-cli` in Phase 2, only Hermes (on the same network) needs to reach it.

- [ ] **Step 3: Bring it up and verify the allowlist**

```bash
cd orchestration-server
docker compose up -d docker-socket-proxy
sleep 2
docker compose ps docker-socket-proxy
```

Expected: `Up`.

```bash
docker run --rm --network olympus curlimages/curl:latest -s -o /dev/null -w "containers: %{http_code}\n" http://docker-socket-proxy:2375/containers/json
docker run --rm --network olympus curlimages/curl:latest -s -o /dev/null -w "info: %{http_code}\n" http://docker-socket-proxy:2375/info
docker run --rm --network olympus curlimages/curl:latest -s -o /dev/null -w "volumes (should be denied): %{http_code}\n" http://docker-socket-proxy:2375/volumes
```

Expected: `containers: 200`, `info: 200`, `volumes: 403`.

- [ ] **Step 4: Commit**

```bash
cd ..
git add orchestration-server/compose.yaml
git commit -m "feat: add docker-socket-proxy service (CONTAINERS/POST/EXEC/INFO only)"
```

---

### Task 2: Build the worker image

**Files:**
- Create: `services/worker-image/Dockerfile`

**Interfaces:**
- Produces: a locally-built, tagged image (`agents-of-olympus/worker:latest`, then digest-pinned once built) — consumed by Task 3's `terminal.docker_image` config.

- [ ] **Step 1: Write the Dockerfile**

```dockerfile
FROM nikolaik/python-nodejs:python3.11-nodejs20

RUN apt-get update && \
    apt-get install -y --no-install-recommends git ripgrep && \
    rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 2: Build it**

```bash
docker build -t agents-of-olympus/worker:latest services/worker-image/
```

- [ ] **Step 3: Verify the toolchain**

```bash
docker run --rm agents-of-olympus/worker:latest sh -c "git --version && rg --version && python3 --version && node --version"
```

Expected: all four print version info without error.

- [ ] **Step 4: Get the digest and pin it**

```bash
docker inspect agents-of-olympus/worker:latest --format='{{index .RepoDigests 0}}' 2>&1 || echo "local build, no registry digest -- tag-based reference is what this project uses until/unless it's pushed to a registry"
```

Local builds don't get a pushable digest unless pushed to a registry — note this in the spec/plan if it applies (this project doesn't currently push custom images anywhere), and reference the image by its local tag (`agents-of-olympus/worker:latest`) in Task 3's Hermes config instead of a digest, consistent with there being no registry to pin against yet.

- [ ] **Step 5: Commit**

```bash
git add services/worker-image/Dockerfile
git commit -m "feat: add worker image (extends Hermes default with git+ripgrep)"
```

---

### Task 3: Configure Hermes to use the Docker backend through the proxy

**Files:**
- Modify: `orchestration-server/compose.yaml` (add `DOCKER_HOST` env var + `depends_on: docker-socket-proxy` to the `hermes` service)

**Interfaces:**
- Consumes: the proxy from Task 1, the worker image from Task 2.
- Produces: Hermes's `terminal.backend` config, verified via `hermes doctor`.

- [ ] **Step 1: Add `DOCKER_HOST` and the new dependency to the `hermes` service**

```yaml
    depends_on:
      - signal-cli
      - docker-socket-proxy
    environment:
      API_SERVER_ENABLED: "true"
      API_SERVER_KEY: ${API_SERVER_KEY}
      SIGNAL_HTTP_URL: http://signal-cli:8080
      SIGNAL_ACCOUNT: ${SIGNAL_ACCOUNT}
      DOCKER_HOST: tcp://docker-socket-proxy:2375
```

- [ ] **Step 2: Validate and bring up**

Per your stated preference, this resolves secrets — hand this to yourself to run rather than me:

```bash
cd orchestration-server
export UID
export GID=$(id -g)
./scripts/compose-up.sh up -d hermes
```

- [ ] **Step 3: Configure `terminal.backend` and related settings**

```bash
docker exec hermes hermes config set terminal.backend docker
docker exec hermes hermes config set terminal.docker_image agents-of-olympus/worker:latest
docker exec hermes hermes config set terminal.docker_run_as_host_user true
docker exec hermes hermes config set terminal.container_cpu 2
docker exec hermes hermes config set terminal.container_memory 2048
```

- [ ] **Step 4: Verify via `hermes doctor`**

```bash
docker exec hermes hermes doctor 2>&1 | grep -iE "docker|terminal"
```

Expected: `✓ docker (daemon running)` — confirmed live during design this is the correct success signal (it read `✗ docker daemon not running` before `INFO=1` was added to the proxy).

- [ ] **Step 5: Restart Hermes to pick up the new terminal backend cleanly**

```bash
export UID
export GID=$(id -g)
./scripts/compose-up.sh restart hermes
```

- [ ] **Step 6: Commit**

```bash
git add orchestration-server/compose.yaml
git commit -m "feat: wire hermes to docker-socket-proxy, configure docker terminal backend"
```

---

### Task 4: Egress control on the real `DOCKER-USER` chain

**Files:** None in the repo — this is a live host/Docker-Desktop-VM firewall change, not something `compose.yaml` expresses. Document the exact rules applied in a comment block for reference (see Step 3).

**Interfaces:**
- Consumes: nothing from earlier tasks directly (operates on Docker's network layer, not a specific container).

- [ ] **Step 1: Confirm current chain state (read-only, safe)**

```bash
docker run --rm --privileged --net=host alpine sh -c "apk add --no-cache iptables >/dev/null 2>&1; iptables -L DOCKER-USER -n"
```

Expected: the existing Docker Desktop rules (ports 3128/5555/53, `ACCEPT`, then a catch-all `REJECT`) — confirmed present during design. Do not remove or reorder past these.

- [ ] **Step 2: Resolve IPs and insert allow rules in one script**

`nftables`/`iptables` don't match on domain name, only IP — this script
resolves the allowlist domains, finds the existing catch-all `REJECT`
rule's line number dynamically (not hardcoded, since it can shift), and
inserts one `ACCEPT` rule per resolved IP immediately before it, all in a
single privileged `--net=host` container so it's one atomic operation
rather than manual multi-step editing:

```bash
docker run --rm --privileged --net=host alpine sh -c '
apk add --no-cache iptables bind-tools >/dev/null 2>&1
REJECT_LINE=$(iptables -L DOCKER-USER -n --line-numbers | grep REJECT | head -1 | awk "{print \$1}")
if [ -z "$REJECT_LINE" ]; then
  echo "No REJECT rule found in DOCKER-USER -- expected one from Docker Desktop own setup. Stopping rather than guessing where to insert." >&2
  exit 1
fi
for host in pypi.org files.pythonhosted.org registry.npmjs.org github.com raw.githubusercontent.com objects.githubusercontent.com codeload.github.com; do
  for ip in $(dig +short "$host" | grep -E "^[0-9]+\."); do
    echo "Allowing $host -> $ip"
    iptables -I DOCKER-USER "$REJECT_LINE" -d "$ip" -j ACCEPT
    REJECT_LINE=$((REJECT_LINE + 1))
  done
done
echo "--- final chain ---"
iptables -L DOCKER-USER -n --line-numbers
'
```

**Known limitation, flagged not solved**: these IPs can change over time
(especially GitHub's, which uses a large, rotating range) — a real
brittleness of IP-based rules for domains without stable IPs. This script
would need periodic re-running (or a cron job wrapping it) to stay
accurate; not built here. If this proves too brittle in practice, revisit
with a filtering HTTP proxy on the worker network instead (the spec's
originally-considered alternative), which matches on hostname (SNI) rather
than IP.

**Correction, found live during Task 5 phase-gate verification:** Step 3
below as originally written tested a standalone `docker run --network
olympus` container, which is NOT the container Hermes's own terminal
backend actually creates. Hermes's persistent worker container
(`terminal.docker_network: true` in its config) attaches to the default
`bridge` network with no way to name a specific network directly — there
is no `docker_network_name`-style key. `sniproxy`/`styx_net`/the
`DOCKER-USER` rules above had **zero effect** on Hermes's real worker
containers until this was found and fixed: verified live via
`docker ps --format "table {{.Names}}\t{{.Networks}}"` showing Hermes's
actual worker containers (named `hermes-<hex>`, per `container_persistent:
true` reused across invocations) on `bridge`, not `styx_net`.

Fixed via Hermes's `terminal.docker_extra_args` escape hatch (raw args
passed to the underlying `docker create`/`docker run` Hermes uses):

```bash
docker exec hermes hermes config set terminal.docker_extra_args '["--network=styx_net", "--dns=172.31.0.10"]'
```

Because `container_persistent: true` reuses one existing worker container
per session, any already-running worker containers must be removed for a
fresh one to pick up the new args on next invocation:

```bash
docker ps --filter "name=hermes-" --format "{{.Names}}" | xargs -r docker rm -f
```

This config lives in `/opt/data/config.yaml` inside the `hermes`
container, bind-mounted from `${HOME}/.hermes` on the host — it persists
across container restarts without needing a repo change.

- [ ] **Step 3: Verify from inside Hermes's real worker container (not a standalone test container)**

```bash
docker exec hermes hermes -z "run the shell command: curl -s -o /dev/null -w 'github.com: %{http_code}\n' --max-time 5 https://github.com"
docker exec hermes hermes -z "run the shell command: curl -s -o /dev/null -w 'example.com: %{http_code}\n' --max-time 5 https://example.com || echo BLOCKED"
```

Expected: `github.com` succeeds (200 or a redirect code), `example.com` is blocked/unreachable.

- [ ] **Step 4: No commit for the firewall rules themselves** (they're host/VM state, not repo state) — but document what was applied:

```bash
cat >> docs/ARCHITECTURE.md <<'EOF'

<!-- Phase 3 egress rules applied to the real DOCKER-USER chain (not
     expressible in compose.yaml -- see docs/superpowers/plans/2026-08-23-phase3-terminal-confinement.md
     Task 4 for the exact procedure). Re-apply after any Docker Desktop
     reset or host rebuild. -->
EOF
git add docs/ARCHITECTURE.md
git commit -m "docs: note Phase 3 egress rules live outside compose.yaml, must be reapplied"
```

---

### Task 5: Phase gate verification

**Files:** None — verification only.

**Interfaces:**
- Consumes: everything from Tasks 1-4.

- [ ] **Step 1: Print environment from inside the real worker container — confirm no secrets**

```bash
docker exec hermes hermes -z "run the shell command: env | sort"
```

Review the output yourself (per your stated preference, since this could theoretically surface something unexpected) — expected: no `API_SERVER_KEY`, `SIGNAL_ACCOUNT`, or any credential-shaped values, since the worker container is a separate container from Hermes's own gateway container and never receives its secrets.

- [ ] **Step 2: Confirm a disallowed domain is blocked**

```bash
docker exec hermes hermes -z "run the shell command: curl -s -o /dev/null -w '%{http_code}' --max-time 5 https://example.com || echo BLOCKED"
```

Expected: `BLOCKED` or a connection failure — confirms Task 4's egress rules apply to Hermes's actual real worker container, not just the standalone test container from Task 4 Step 4.

- [ ] **Step 3: Confirm a host path is unreachable**

```bash
docker exec hermes hermes -z "run the shell command: cat /etc/hostname && ls / && cat /home/nelson/.bashrc 2>&1 || echo NO-HOST-ACCESS"
```

Expected: the container's own `/etc/hostname`/`/` are visible (its own filesystem), but the host path `/home/nelson/.bashrc` is not reachable — `NO-HOST-ACCESS` or a "No such file" error.

- [ ] **Step 4: Confirm `DOCKER_HOST`-via-proxy works for a real Hermes invocation (not just the standalone tests from Tasks 1/3)**

```bash
docker exec hermes hermes -z "run the shell command: echo phase3-live-worker-test-ok"
```

Expected: `phase3-live-worker-test-ok` — confirms the full chain (Hermes → proxy → dockerd → worker container → exec) works end-to-end for a real invocation, not just isolated component tests.

- [ ] **Step 5: No commit** — this task is verification only. This completes Phase 3's phase gate.

Update the vault's Phase Status note for Phase 3 to reflect completion before starting Phase 4 (LangGraph Worker Tier).
