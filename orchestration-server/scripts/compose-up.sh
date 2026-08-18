#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/setup.sh"

"${SCRIPT_DIR}/decrypt-secrets.sh"

if [[ -f "${SECRETS_DEC_DIR}/api_server_key" ]]; then
  API_SERVER_KEY="$(cat "${SECRETS_DEC_DIR}/api_server_key")"
  export API_SERVER_KEY
fi

cd "${SCRIPTS_ROOT}/.."
exec docker compose "$@"
