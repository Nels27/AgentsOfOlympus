#!/usr/bin/env bash
if [[ -n "${OLYMPUS_SETUP_SOURCED:-}" ]]; then
  return 0
fi
readonly OLYMPUS_SETUP_SOURCED=1

set -euo pipefail

export SCRIPTS_ROOT
SCRIPTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPTS_ROOT}/lib/constants.sh"
