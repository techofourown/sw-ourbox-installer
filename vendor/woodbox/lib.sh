#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# Last token handles "sudo podman" etc.
cli_base() { echo "${1##* }"; }

pick_container_cli() {
  if [[ -n "${DOCKER:-}" ]]; then
    echo "$DOCKER"
    return 0
  fi
  if command -v podman >/dev/null 2>&1; then
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
      echo podman
    else
      if command -v sudo >/dev/null 2>&1; then
        echo "sudo podman"
      else
        echo podman
      fi
    fi
    return 0
  fi
  if command -v docker >/dev/null 2>&1; then
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
      echo docker
    else
      if command -v sudo >/dev/null 2>&1; then
        echo "sudo docker"
      else
        echo docker
      fi
    fi
    return 0
  fi
  if command -v nerdctl >/dev/null 2>&1; then
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
      echo nerdctl
    else
      if command -v sudo >/dev/null 2>&1; then
        echo "sudo nerdctl"
      else
        echo nerdctl
      fi
    fi
    return 0
  fi
  die "no container CLI found (need podman, docker, or nerdctl)."
}

canonicalize_image_ref() {
  local ref="$1"
  if [[ "${ref}" != */* ]]; then
    echo "docker.io/library/${ref}"
    return 0
  fi
  local first="${ref%%/*}"
  if [[ "${first}" == *"."* || "${first}" == *":"* || "${first}" == "localhost" ]]; then
    echo "${ref}"
    return 0
  fi
  echo "docker.io/${ref}"
}
