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
