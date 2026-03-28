#!/usr/bin/env bash
set -euo pipefail

# Update apple/container CLI to the latest release

REPO="apple/container"
CURRENT=$(grep 'version ?' package.nix | sed 's/.*"\(.*\)".*/\1/')
LATEST=$(gh release view --repo "$REPO" --json tagName -q .tagName)

if [ "$CURRENT" = "$LATEST" ]; then
  echo "apple/container is up to date ($CURRENT)"
  exit 0
fi

echo "Updating apple/container: $CURRENT → $LATEST"

URL="https://github.com/$REPO/releases/download/${LATEST}/container-${LATEST}-installer-signed.pkg"
HASH=$(nix-prefetch-url --type sha256 "$URL" 2>/dev/null | xargs nix hash convert --hash-algo sha256 --to sri)

sed -i '' "s|version ? \".*\"|version ? \"${LATEST}\"|" package.nix
sed -i '' "s|hash ? \".*\"|hash ? \"${HASH}\"|" package.nix

echo "Updated package.nix to $LATEST (hash: $HASH)"
