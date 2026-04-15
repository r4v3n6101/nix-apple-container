#!/usr/bin/env bash
set -euo pipefail

# Update nixos/nix base image to the latest release
#
# Note: the published builder tag is derived from builder/IMAGE_VERSION plus
# this base image version (e.g. v1-nix2.34.6). This script only updates the
# base nix version in builder/Dockerfile.

CURRENT=$(sed -n 's/^FROM nixos\/nix:\(.*\)/\1/p' builder/Dockerfile)
LATEST=$(curl -s "https://hub.docker.com/v2/repositories/nixos/nix/tags?page_size=100" \
  | jq -r '.results[].name' \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
  | sort -V | tail -1)

if [ "$CURRENT" = "$LATEST" ]; then
  echo "nixos/nix is up to date ($CURRENT)"
  exit 0
fi

echo "Updating nixos/nix: $CURRENT → $LATEST"

sed -i '' "s|^FROM nixos/nix:.*|FROM nixos/nix:${LATEST}|" builder/Dockerfile

echo "Updated builder/Dockerfile to nixos/nix:$LATEST"
