# Compose + Secrets Scaffolding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the compose + secrets scaffolding for AgentsOfOlympus (Phase 0 of the approved Implementation Strategy) — SOPS+age encrypted secrets at rest, a decrypt-on-demand script, three canon Compose networks, and non-sensitive `.env` config — with no real services yet.

**Architecture:** All files live under `orchestration-server/`. Secrets are encrypted at rest with SOPS+age, one secret per file in `secrets/`, decrypted on demand by `scripts/decrypt-secrets.sh` into a gitignored `secrets.dec/`. `compose.yaml` declares the three trust-boundary networks (`olympus`, `delphi` internal, `argus_net`) but no services or `secrets:` block yet — both arrive with the first real service.

**Tech Stack:** Bash (`set -euo pipefail`, homelab shell conventions), SOPS 3.x, age 1.x, Docker Compose v2.

## Global Constraints

- All new files live under `orchestration-server/` except the repo-root `.gitignore`.
- Shell scripts follow the homelab convention from the approved Implementation Strategy §4: `setup.sh` exports `SCRIPTS_ROOT`, runs `set -euo pipefail`; child scripts carry source guards; constants are `readonly` in `lib/constants.sh`.
- Compose network names are canon per Implementation Strategy Appendix A: `olympus` (gateway), `delphi` (inference, `internal: true`), `argus_net` (observability). Do not rename.
- No real service containers, no top-level `secrets:` block in `compose.yaml`, no `renovate.json` — all deferred to later slices (see spec's Non-goals).
- `decrypt-secrets.sh` must never leave `secrets.dec/` partially populated on failure.
- Age private key lives at `~/.config/sops/age/keys.txt` (or `$SOPS_AGE_KEY_FILE` if set) — never committed.

---

### Task 1: Repo-root `.gitignore`

**Files:**
- Modify: `.gitignore` (repo root — already exists with `orchestration-server/.env` and `orchestration-server/secrets/*`; the second line is wrong and must be fixed in this task)

**Interfaces:** None (no code dependencies).

- [ ] **Step 1: Read the current `.gitignore` and fix the `secrets/*` line**

**Read the file first** — it has been edited outside this plan (most recently it gained a `.claude/hooks/*` line not tracked here) and may have changed again since this plan was written. Preserve every line except `orchestration-server/secrets/*`, which is the one bug this task fixes: it currently ignores `orchestration-server/secrets/*`, which would silently exclude the *encrypted* secrets this design commits on purpose. Only the plaintext decrypt output (`secrets.dec/`) should be ignored. Replace just that one line with `orchestration-server/secrets.dec/`, keeping everything else as found.

- [ ] **Step 2: Verify the pattern actually excludes the right paths**

```bash
mkdir -p orchestration-server/secrets.dec orchestration-server/secrets
touch orchestration-server/.env orchestration-server/secrets.dec/dummy orchestration-server/secrets/dummy_encrypted
git status --porcelain
```

Expected: `orchestration-server/.env` and `orchestration-server/secrets.dec/dummy` do **not** appear in the output; `orchestration-server/secrets/dummy_encrypted` **does** appear (as untracked, since real secrets are meant to be committed).

- [ ] **Step 3: Clean up the dummy files**

```bash
rm -rf orchestration-server/secrets.dec orchestration-server/secrets/dummy_encrypted orchestration-server/.env
rmdir orchestration-server/secrets 2>/dev/null || true
```

- [ ] **Step 4: Commit**

```bash
git add .gitignore
git commit -m "fix: stop ignoring encrypted secrets, only ignore plaintext decrypt output"
```

---

### Task 2: Shell scaffolding — `lib/constants.sh` and `setup.sh`

**Files:**
- Create: `orchestration-server/scripts/lib/constants.sh`
- Create: `orchestration-server/scripts/setup.sh`
- Test: manual (shell scaffolding — no pytest-equivalent; verified by sourcing and inspecting output, per the pattern already dry-run tested in the design pass)

**Interfaces:**
- Produces: `SCRIPTS_ROOT` (exported env var, absolute path to `orchestration-server/scripts`), `SECRETS_DIR`, `SECRETS_DEC_DIR`, `NETWORK_GATEWAY`, `NETWORK_INFERENCE`, `NETWORK_OBSERVABILITY` (all `readonly` string constants, available after sourcing `setup.sh`). Task 3 (`decrypt-secrets.sh`) consumes all of these by sourcing `setup.sh`.

- [ ] **Step 1: Create `orchestration-server/scripts/lib/constants.sh`**

```bash
#!/usr/bin/env bash
if [[ -n "${OLYMPUS_CONSTANTS_SOURCED:-}" ]]; then
  return 0
fi
readonly OLYMPUS_CONSTANTS_SOURCED=1

readonly SECRETS_DIR="${SCRIPTS_ROOT}/../secrets"
readonly SECRETS_DEC_DIR="${SCRIPTS_ROOT}/../secrets.dec"
readonly NETWORK_GATEWAY="olympus"
readonly NETWORK_INFERENCE="delphi"
readonly NETWORK_OBSERVABILITY="argus_net"
```

- [ ] **Step 2: Create `orchestration-server/scripts/setup.sh`**

```bash
#!/usr/bin/env bash
if [[ -n "${OLYMPUS_SETUP_SOURCED:-}" ]]; then
  return 0
fi
readonly OLYMPUS_SETUP_SOURCED=1

set -euo pipefail

export SCRIPTS_ROOT
SCRIPTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPTS_ROOT}/lib/constants.sh"
```

- [ ] **Step 3: Make both executable and write a throwaway test script**

```bash
chmod +x orchestration-server/scripts/setup.sh orchestration-server/scripts/lib/constants.sh
cat > /tmp/test_source.sh <<'EOF'
#!/usr/bin/env bash
source "$1/setup.sh"
echo "SCRIPTS_ROOT=${SCRIPTS_ROOT}"
echo "SECRETS_DIR=${SECRETS_DIR}"
echo "SECRETS_DEC_DIR=${SECRETS_DEC_DIR}"
echo "NETWORK_GATEWAY=${NETWORK_GATEWAY}"
echo "NETWORK_INFERENCE=${NETWORK_INFERENCE}"
echo "NETWORK_OBSERVABILITY=${NETWORK_OBSERVABILITY}"
source "$1/setup.sh"
echo "re-source OK"
EOF
bash /tmp/test_source.sh "$(pwd)/orchestration-server/scripts"
```

Expected output (paths will reflect your actual repo location):

```
SCRIPTS_ROOT=/home/nelson/Repos/AgentsOfOlympus/orchestration-server/scripts
SECRETS_DIR=/home/nelson/Repos/AgentsOfOlympus/orchestration-server/scripts/../secrets
SECRETS_DEC_DIR=/home/nelson/Repos/AgentsOfOlympus/orchestration-server/scripts/../secrets.dec
NETWORK_GATEWAY=olympus
NETWORK_INFERENCE=delphi
NETWORK_OBSERVABILITY=argus_net
re-source OK
```

The final `re-source OK` line proves the source guard works — without it, the second `source` would fail with `readonly variable` errors on `OLYMPUS_SETUP_SOURCED`/`OLYMPUS_CONSTANTS_SOURCED`.

- [ ] **Step 4: Clean up the test script**

```bash
rm /tmp/test_source.sh
```

- [ ] **Step 5: Commit**

```bash
git add orchestration-server/scripts/setup.sh orchestration-server/scripts/lib/constants.sh
git commit -m "feat: add shell scaffolding (SCRIPTS_ROOT, source-guarded constants)"
```

---

### Task 3: Age keypair + `.sops.yaml` + `secrets/` directory

**Files:**
- Create: `orchestration-server/.sops.yaml`
- Create: `orchestration-server/secrets/.gitkeep`
- Host action (not committed): age keypair at `~/.config/sops/age/keys.txt`

**Interfaces:**
- Produces: the age public key embedded in `.sops.yaml`'s `creation_rules`, which Task 4's `decrypt-secrets.sh` relies on implicitly (via `sops` reading `.sops.yaml` automatically — no direct code dependency).

- [ ] **Step 1: Generate the production age keypair (skip if you already have one)**

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
```

Expected output (your key will differ):

```
Public key: age1chygnk8nn8vqp7exreqgvmg75nzethtcn940jl4lru9946w0rd6qrcq4cy
```

The same public key is also written as a comment inside the key file itself.

- [ ] **Step 2: Extract the public key and write `.sops.yaml`**

```bash
PUBKEY=$(grep "public key:" ~/.config/sops/age/keys.txt | awk '{print $NF}')
cat > orchestration-server/.sops.yaml <<EOF
creation_rules:
  - path_regex: secrets/.*
    age: ${PUBKEY}
EOF
cat orchestration-server/.sops.yaml
```

- [ ] **Step 3: Create the (currently empty) secrets directory**

```bash
mkdir -p orchestration-server/secrets
touch orchestration-server/secrets/.gitkeep
```

- [ ] **Step 4: Verify the round trip — encrypt and decrypt a throwaway value**

```bash
cd orchestration-server
echo -n "dummy-test-token-value" > secrets/smoke_test_secret
sops --input-type binary --output-type binary -e -i secrets/smoke_test_secret
cat secrets/smoke_test_secret
```

Expected: a JSON blob containing an `"ENC[AES256_GCM,...]"` wrapped `data` field and a `sops.age[0].recipient` matching your public key — **not** the plaintext.

```bash
sops --input-type binary --output-type binary -d secrets/smoke_test_secret
```

Expected: `dummy-test-token-value` printed to stdout.

- [ ] **Step 5: Remove the throwaway secret (real secrets arrive with their consuming service)**

```bash
rm secrets/smoke_test_secret
cd ..
```

- [ ] **Step 6: Commit**

```bash
git add orchestration-server/.sops.yaml orchestration-server/secrets/.gitkeep
git commit -m "feat: configure SOPS+age for secrets/, no real secrets yet"
```

---

### Task 4: `decrypt-secrets.sh`

**Files:**
- Create: `orchestration-server/scripts/decrypt-secrets.sh`

**Interfaces:**
- Consumes: `SCRIPTS_ROOT`, `SECRETS_DIR`, `SECRETS_DEC_DIR` (from Task 2's `setup.sh`, sourced internally).
- Produces: `${SECRETS_DEC_DIR}/<name>` plaintext files (mode `0600`) for every file in `${SECRETS_DIR}` except `.gitkeep`. Exit 0 with a count on success; exit 1 with a message on `stderr` if `sops` is missing, the age key file is missing, or any decrypt fails.

- [ ] **Step 1: Create `orchestration-server/scripts/decrypt-secrets.sh`**

```bash
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/setup.sh"

if ! command -v sops >/dev/null 2>&1; then
  echo "error: sops is not installed" >&2
  exit 1
fi

AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"
if [[ ! -f "${AGE_KEY_FILE}" ]]; then
  echo "error: age key not found at ${AGE_KEY_FILE}" >&2
  exit 1
fi

shopt -s nullglob
secret_files=()
for f in "${SECRETS_DIR}"/*; do
  [[ "$(basename "${f}")" == ".gitkeep" ]] && continue
  secret_files+=("${f}")
done
shopt -u nullglob

if [[ ${#secret_files[@]} -eq 0 ]]; then
  echo "no secrets to decrypt in ${SECRETS_DIR}"
  exit 0
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

for secret_path in "${secret_files[@]}"; do
  name="$(basename "${secret_path}")"
  sops --input-type binary --output-type binary -d "${secret_path}" > "${tmp_dir}/${name}"
  chmod 600 "${tmp_dir}/${name}"
done

mkdir -p "${SECRETS_DEC_DIR}"
rm -f "${SECRETS_DEC_DIR}"/*
cp -a "${tmp_dir}/." "${SECRETS_DEC_DIR}/"

echo "decrypted ${#secret_files[@]} secret(s) into ${SECRETS_DEC_DIR}"
```

`set -euo pipefail` comes from the sourced `setup.sh` (Task 2), so any `sops -d` failure mid-loop aborts immediately via the `trap`, before `secrets.dec/` is touched — this is what keeps it from ever holding a partial decrypt.

- [ ] **Step 2: Make it executable**

```bash
chmod +x orchestration-server/scripts/decrypt-secrets.sh
```

- [ ] **Step 3: Test the success path**

```bash
cd orchestration-server
echo -n "dummy-test-token-value" > secrets/smoke_test_secret
sops --input-type binary --output-type binary -e -i secrets/smoke_test_secret
./scripts/decrypt-secrets.sh
echo "exit: $?"
ls -la secrets.dec/
stat -c '%a' secrets.dec/smoke_test_secret
cat secrets.dec/smoke_test_secret; echo
```

Expected:
```
decrypted 1 secret(s) into /home/nelson/Repos/AgentsOfOlympus/orchestration-server/scripts/../secrets.dec
exit: 0
```
followed by a directory listing showing `smoke_test_secret` at mode `600`, and `dummy-test-token-value` printed back.

- [ ] **Step 4: Test the missing-key error path**

```bash
HOME=/tmp/nonexistent-home-for-test ./scripts/decrypt-secrets.sh
echo "exit: $?"
```

Expected:
```
error: age key not found at /tmp/nonexistent-home-for-test/.config/sops/age/keys.txt
exit: 1
```

- [ ] **Step 5: Test the empty-secrets-dir path**

```bash
mv secrets/smoke_test_secret /tmp/smoke_test_secret_stash
rm -rf secrets.dec
./scripts/decrypt-secrets.sh
echo "exit: $?"
mv /tmp/smoke_test_secret_stash secrets/smoke_test_secret
```

Expected:
```
no secrets to decrypt in /home/nelson/Repos/AgentsOfOlympus/orchestration-server/scripts/../secrets
exit: 0
```

- [ ] **Step 6: Clean up the throwaway secret and decrypted output**

```bash
rm -f secrets/smoke_test_secret
rm -rf secrets.dec
cd ..
```

- [ ] **Step 7: Commit**

```bash
git add orchestration-server/scripts/decrypt-secrets.sh
git commit -m "feat: add decrypt-secrets.sh (atomic, fails fast on missing sops/age key)"
```

---

### Task 5: `.env.example`

**Files:**
- Create: `orchestration-server/.env.example`

**Interfaces:** None.

- [ ] **Step 1: Create `orchestration-server/.env.example`**

No services exist yet, so there are no real ports/model names to template. Seed it with the one setting Implementation Strategy §2 already settles as a decision of record (explicit timezone — Hermes defaults to UTC otherwise, a known failure mode):

```
TZ=America/New_York
```

- [ ] **Step 2: Verify the onboarding flow**

```bash
cp orchestration-server/.env.example orchestration-server/.env
cat orchestration-server/.env
git status --porcelain orchestration-server/
```

Expected: `.env` is **not** listed (gitignored per Task 1); `.env.example` is not listed either since it's about to be committed as tracked content in this task, not left dangling untracked.

- [ ] **Step 3: Remove the local `.env` (each developer creates their own)**

```bash
rm orchestration-server/.env
```

- [ ] **Step 4: Commit**

```bash
git add orchestration-server/.env.example
git commit -m "feat: add .env.example with TZ default"
```

---

### Task 6: `compose.yaml` — three canon networks

**Files:**
- Create: `orchestration-server/compose.yaml`

**Interfaces:** None (no services attach yet — Task 7 verifies syntax only).

- [ ] **Step 1: Create `orchestration-server/compose.yaml`**

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
```

- [ ] **Step 2: Commit**

```bash
git add orchestration-server/compose.yaml
git commit -m "feat: add compose.yaml with the three canon trust-boundary networks"
```

---

### Task 7: End-to-end verification (restore-drill-lite)

**Files:** None created — this task only runs checks across everything built in Tasks 1–6.

**Interfaces:** Exercises Task 4's `decrypt-secrets.sh` and Task 6's `compose.yaml` together.

- [ ] **Step 1: Validate `compose.yaml` syntax**

```bash
cd orchestration-server
docker compose config
echo "exit: $?"
```

Expected: exit `0`. The printed output will just be `name: agents-of-olympus\nservices: {}` — **do not expect the three networks to appear in the output.** Verified during design that Compose only echoes networks a service actually attaches to; declaring them without a consumer still schema-validates (confirmed separately: an invalid key inside one of them correctly fails `docker compose config` with exit 1) but produces no visible trace in the resolved config. Proving the networks actually come up is deferred to Phase 1, when the Hermes gateway attaches to `olympus`.

- [ ] **Step 2: Run the full decrypt flow against a throwaway secret**

```bash
echo -n "restore-drill-secret" > secrets/smoke_test_secret
sops --input-type binary --output-type binary -e -i secrets/smoke_test_secret
./scripts/decrypt-secrets.sh
cat secrets.dec/smoke_test_secret; echo
```

Expected: `decrypted 1 secret(s) into ...` followed by `restore-drill-secret`.

- [ ] **Step 3: Clean up and confirm git stays clean**

```bash
rm -f secrets/smoke_test_secret
rm -rf secrets.dec
cd ..
git status --porcelain
```

Expected: empty output — every file created during this task's verification was either removed or was already gitignored (`secrets.dec/`, and `secrets/smoke_test_secret` was deleted, not left untracked).

- [ ] **Step 4: No commit for this task** — it's verification only, nothing new to check in.

This completes Phase 0. Update `Phase 0 Session Status.md` in the Obsidian vault to reflect completion before starting Phase 1 (Hermes core).
