#!/usr/bin/env bash
set -euo pipefail

# Print system info for bug reports

# macOS and arch are always available
MACOS_VERSION=$(sw_vers -productVersion)
MACOS_BUILD=$(sw_vers -buildVersion)
ARCH=$(uname -m)

# Nix
if command -v nix >/dev/null 2>&1; then
  NIX_VERSION=$(nix --version)
else
  NIX_VERSION="not found"
fi

# Apple Container CLI
if command -v container >/dev/null 2>&1; then
  CONTAINER_VERSION=$(container --version 2>&1)
else
  CONTAINER_VERSION="not found"
fi

echo "macOS: $MACOS_VERSION ($MACOS_BUILD)"
echo "Arch: $ARCH"
echo "Nix: $NIX_VERSION"
echo "Apple Container: $CONTAINER_VERSION"

# nix-darwin and nixpkgs from flake.lock
if [ "${1:-}" != "" ]; then
  FLAKE_LOCK="$1/flake.lock"
else
  FLAKE_LOCK=""
fi

if [ -z "$FLAKE_LOCK" ] || [ ! -f "$FLAKE_LOCK" ]; then
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "(jq not found — skipping flake input info)" >&2
  exit 0
fi

# Find a locked flake input by GitHub owner/repo (regardless of input name)
flake_input_info() {
  local owner="$1" repo="$2"
  jq -r --arg owner "$owner" --arg repo "$repo" '
    .nodes | to_entries[] |
    select(
      .value.locked.type == "github" and
      .value.locked.owner == $owner and
      .value.locked.repo == $repo
    ) |
    .value.locked |
    "github:" + .owner + "/" + .repo + "/" + (.rev[0:7]) +
    " (" + (.lastModified | todate | .[0:10]) + ")"
  ' "$FLAKE_LOCK" 2>/dev/null | head -1
}

DARWIN_INFO=$(flake_input_info "LnL7" "nix-darwin")
NIXPKGS_INFO=$(flake_input_info "NixOS" "nixpkgs")

[ -n "$DARWIN_INFO" ] && echo "nix-darwin: $DARWIN_INFO"
[ -n "$NIXPKGS_INFO" ] && echo "nixpkgs: $NIXPKGS_INFO"
