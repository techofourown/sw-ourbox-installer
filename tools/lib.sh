#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

file_size_bytes() {
  stat -c%s "$1"
}

is_sha256_digest() {
  [[ "${1:-}" =~ ^sha256:[0-9a-f]{64}$ ]]
}

is_pinned_ref() {
  [[ "${1:-}" =~ ^[^[:space:]]+@sha256:[0-9a-f]{64}$ ]]
}

ref_repo_base() {
  local ref="$1"
  local tail="${ref##*/}"

  if [[ "${ref}" == *@* ]]; then
    printf '%s\n' "${ref%%@*}"
    return 0
  fi

  if [[ "${tail}" == *:* ]]; then
    printf '%s\n' "${ref%:*}"
  else
    printf '%s\n' "${ref}"
  fi
}
