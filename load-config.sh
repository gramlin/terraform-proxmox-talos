#!/bin/bash
# Load kubeconfig and talosconfig for the Talos cluster
# Usage: source load-config.sh
#    or: eval "$(./load-config.sh)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
WORKDIR="${SCRIPT_DIR}"

KUBECONFIG_FILE="${WORKDIR}/kubeconfig.yml"
TALOSCONFIG_FILE="${WORKDIR}/talosconfig.yml"

# Check if files exist
if [[ ! -f "$KUBECONFIG_FILE" ]]; then
  echo "ERROR: kubeconfig not found at $KUBECONFIG_FILE" >&2
  echo "Run './do apply' first to generate configs" >&2
  return 1 2>/dev/null || exit 1
fi

if [[ ! -f "$TALOSCONFIG_FILE" ]]; then
  echo "ERROR: talosconfig not found at $TALOSCONFIG_FILE" >&2
  echo "Run './do apply' first to generate configs" >&2
  return 1 2>/dev/null || exit 1
fi

# Export the configs
export KUBECONFIG="$KUBECONFIG_FILE"
export TALOSCONFIG="$TALOSCONFIG_FILE"

echo "✓ KUBECONFIG=$KUBECONFIG"
echo "✓ TALOSCONFIG=$TALOSCONFIG"

# If sourced, we're done. If executed, print export commands
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  echo ""
  echo "# Run this to load in your shell:"
  echo "export KUBECONFIG=\"$KUBECONFIG_FILE\""
  echo "export TALOSCONFIG=\"$TALOSCONFIG_FILE\""
fi
