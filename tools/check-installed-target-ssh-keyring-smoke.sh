#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# shellcheck disable=SC1091
OURBOX_PREPARE_INSTALLER_LIBRARY_ONLY=1 source "${ROOT}/tools/prepare-installer-media.sh"

OURBOX_INSTALLED_TARGET_SSH_KEYSTORE_ROOT="${TMP}/keyring"

skip_output_file="${TMP}/skip-output.txt"
interactive_select_installed_target_ssh_key <<< $'\n' >"${skip_output_file}"
[[ -z "${SELECTED_INSTALLED_TARGET_SSH_MODE}" ]] || {
  echo "expected installed-target SSH selection mode to stay disabled when the operator skips SSH setup" >&2
  exit 1
}
[[ -z "${SELECTED_INSTALLED_TARGET_SSH_KEY_NAME}" ]] || {
  echo "expected no installed-target SSH key name after the operator skips SSH setup" >&2
  exit 1
}
[[ ! -e "${OURBOX_INSTALLED_TARGET_SSH_KEYSTORE_ROOT}" ]] || {
  echo "expected SSH skip path to avoid creating a key store" >&2
  exit 1
}
skip_output="$(<"${skip_output_file}")"
[[ "${skip_output}" == *"This step is optional."* ]] || {
  echo "expected SSH skip prompt to explain that installed-target SSH is optional" >&2
  exit 1
}

disable_installed_target_ssh_key_selection
select_installed_target_ssh_key_by_name "shared-dev"

[[ "${SELECTED_INSTALLED_TARGET_SSH_MODE}" == "host-generated-authorized-key" ]] || {
  echo "expected installed-target SSH key selection mode to be set" >&2
  exit 1
}
[[ "${SELECTED_INSTALLED_TARGET_SSH_KEY_NAME}" == "shared-dev" ]] || {
  echo "unexpected selected installed-target SSH key name: ${SELECTED_INSTALLED_TARGET_SSH_KEY_NAME}" >&2
  exit 1
}
[[ -f "${OURBOX_INSTALLED_TARGET_SSH_KEYSTORE_ROOT}/shared-dev/id_ed25519" ]] || {
  echo "expected private key to be created in the keyring" >&2
  exit 1
}
[[ -f "${OURBOX_INSTALLED_TARGET_SSH_KEYSTORE_ROOT}/shared-dev/id_ed25519.pub" ]] || {
  echo "expected public key to be created in the keyring" >&2
  exit 1
}
[[ "${SELECTED_INSTALLED_TARGET_SSH_PUBLIC_KEY_FINGERPRINT}" =~ ^SHA256:[A-Za-z0-9+/=]+$ ]] || {
  echo "expected a valid SSH public key fingerprint" >&2
  exit 1
}

select_installed_target_ssh_key_by_name "stable-lab-box"
mapfile -t stored_keys < <(list_installed_target_ssh_key_names)
[[ "${#stored_keys[@]}" -eq 2 ]] || {
  echo "expected two named installed-target SSH keys in the keyring" >&2
  exit 1
}

delete_installed_target_ssh_key_by_name "shared-dev"
[[ ! -d "${OURBOX_INSTALLED_TARGET_SSH_KEYSTORE_ROOT}/shared-dev" ]] || {
  echo "expected named key deletion to remove the selected key directory" >&2
  exit 1
}

delete_all_installed_target_ssh_keys
[[ ! -d "${OURBOX_INSTALLED_TARGET_SSH_KEYSTORE_ROOT}" ]] || {
  echo "expected delete-all to remove the installed-target SSH keyring directory" >&2
  exit 1
}
[[ -z "${SELECTED_INSTALLED_TARGET_SSH_KEY_NAME}" ]] || {
  echo "expected delete-all to clear any active installed-target SSH key selection" >&2
  exit 1
}

printf '[%s] installed-target SSH keyring smoke passed\n' "$(date -Is)"
