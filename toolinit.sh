#!/usr/bin/env bash
set -euo pipefail

function die() {
  echo "$*" >&2
  exit 1
}

function require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"
}

require_cmd terraform
require_cmd talosctl
require_cmd kubectl
require_cmd jq
require_cmd yq
require_cmd qemu-img
require_cmd docker

if ! command -v kubectl-linstor >/dev/null 2>&1; then
  krew_root="$(kubectl krew root 2>/dev/null || true)"
  if [ -z "$krew_root" ]; then
    krew_root="$(kubectl krew env KREW_ROOT 2>/dev/null | awk -F= '{print $2}' | tr -d '"')"
  fi
  if [ -z "$krew_root" ]; then
    krew_root="${KREW_ROOT:-$HOME/.krew}"
  fi
  if [ -n "$krew_root" ] && [ -x "$krew_root/bin/kubectl-linstor" ]; then
    die "kubectl linstor plugin installed via krew but not found in PATH. Add: export PATH=\"${krew_root}/bin:\$PATH\""
  fi
  die "kubectl linstor plugin not installed. Install via: kubectl krew install linstor"
fi
