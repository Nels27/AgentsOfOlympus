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
