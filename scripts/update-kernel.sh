#!/usr/bin/env bash
set -euo pipefail

# Update kata-containers kernel to the latest release

REPO="kata-containers/kata-containers"
CURRENT_URL=$(grep 'url = ' kernel.nix | sed 's/.*"\(.*\)".*/\1/')
CURRENT_VER=$(echo "$CURRENT_URL" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

LATEST=$(gh release view --repo "$REPO" --json tagName -q .tagName)

if [ "$CURRENT_VER" = "$LATEST" ]; then
  echo "kata-containers kernel is up to date ($CURRENT_VER)"
  exit 0
fi

echo "Updating kata-containers kernel: $CURRENT_VER → $LATEST"

URL="https://github.com/$REPO/releases/download/${LATEST}/kata-static-${LATEST}-arm64.tar.zst"
HASH=$(nix-prefetch-url --type sha256 "$URL" 2>/dev/null | xargs nix hash convert --hash-algo sha256 --to sri)

# Update kernel.nix
sed -i '' "s|${CURRENT_VER}|${LATEST}|g" kernel.nix
sed -i '' "s|hash = \".*\"|hash = \"${HASH}\"|" kernel.nix

# Find the vmlinux binary name in the new tarball
echo "Fetching tarball to detect vmlinux binary name..."
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
curl -sL "$URL" | zstd -d | tar -tf - | grep 'vmlinux-' | head -1 > "$TMPDIR/vmlinux_path"
VMLINUX_PATH=$(cat "$TMPDIR/vmlinux_path")

if [ -z "$VMLINUX_PATH" ]; then
  echo "WARNING: could not detect vmlinux binary path in tarball"
  echo "You must manually update the binaryPath default in default.nix"
  exit 1
fi

echo "Detected vmlinux path: $VMLINUX_PATH"

# Update the default binaryPath in default.nix
CURRENT_BINARY=$(grep 'default = "opt/kata' default.nix | sed 's/.*"\(.*\)".*/\1/')
if [ -n "$CURRENT_BINARY" ] && [ "$CURRENT_BINARY" != "$VMLINUX_PATH" ]; then
  sed -i '' "s|${CURRENT_BINARY}|${VMLINUX_PATH}|" default.nix
  echo "Updated default.nix binaryPath: $VMLINUX_PATH"
fi

echo "Updated kernel.nix to $LATEST (hash: $HASH)"
