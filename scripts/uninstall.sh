#!/usr/bin/env bash
set -euo pipefail

PRESERVE_IMAGES=false
PRESERVE_VOLUMES=false
CONFIRM=true

usage() {
  cat <<'EOF'
Usage: nix-apple-container-uninstall [OPTIONS]

Standalone teardown for nix-apple-container. Performs the same cleanup as
setting enable = false in the nix-darwin module.

Options:
  --yes                Skip confirmation prompt
  --preserve-images    Keep container images
  --preserve-volumes   Keep named volume data
  --help               Show this help
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes) CONFIRM=false ;;
    --preserve-images) PRESERVE_IMAGES=true ;;
    --preserve-volumes) PRESERVE_VOLUMES=true ;;
    --help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
  shift
done

APP_SUPPORT="$HOME/Library/Application Support/com.apple.container"
AGENT_DIR="$HOME/Library/LaunchAgents"

echo "nix-apple-container: uninstall"
echo ""
echo "This will:"
echo "  - Unload container launchd agents"
echo "  - Stop the container runtime"
if [ "$PRESERVE_IMAGES" = true ]; then
  echo "  - Remove kernels and staging (images preserved)"
else
  echo "  - Remove kernels, staging, and images"
fi
if [ "$PRESERVE_IMAGES" = false ] && [ "$PRESERVE_VOLUMES" = false ]; then
  echo "  - Remove all runtime state ($APP_SUPPORT)"
fi
echo "  - Clear macOS defaults and package receipt"
echo "  - Remove builder SSH keys from /etc/nix"
echo ""

if [ "$CONFIRM" = true ]; then
  printf "Proceed? [y/N] "
  read -r answer
  case "$answer" in
    [yY]) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

# 1. Unload launchd agents
found_agents=false
if [ -d "$AGENT_DIR" ]; then
  for plist in "$AGENT_DIR"/dev.apple.container.*.plist; do
    [ -f "$plist" ] || continue
    found_agents=true
    agent_name="$(basename "$plist" .plist)"
    echo "Unloading agent $agent_name..."
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
  done
fi
if [ "$found_agents" = false ]; then
  echo "No launchd agents found."
fi

# 2. Stop runtime
if [ -d "$APP_SUPPORT" ]; then
  if command -v container &>/dev/null; then
    echo "Stopping container runtime..."
    container system stop 2>/dev/null || true
  else
    echo "container CLI not found in PATH, skipping runtime stop."
  fi
else
  echo "No runtime state found, skipping runtime stop."
fi

# 3. Remove kernels and staging
if [ -d "$APP_SUPPORT" ]; then
  echo "Removing kernels and staging..."
  rm -rf "$APP_SUPPORT/kernels"
  rm -rf "$APP_SUPPORT/content/ingest"
fi

# 4. Remove images (unless --preserve-images)
if [ "$PRESERVE_IMAGES" = false ] && [ -d "$APP_SUPPORT/content" ]; then
  echo "Removing images..."
  rm -rf "$APP_SUPPORT/content"
fi

# 5. Remove entire APP_SUPPORT (unless either preserve flag)
if [ "$PRESERVE_IMAGES" = false ] && [ "$PRESERVE_VOLUMES" = false ] && [ -d "$APP_SUPPORT" ]; then
  echo "Removing $APP_SUPPORT..."
  rm -rf "$APP_SUPPORT"
fi

# 6. Delete defaults
echo "Clearing macOS defaults..."
defaults delete com.apple.container 2>/dev/null || true

# 7. Remove current user's builder SSH keys
if [ -f "$HOME/.ssh/nix-builder_ed25519" ] || [ -f "$HOME/.ssh/nix-builder_ed25519.pub" ]; then
  echo "Removing builder SSH keys from $HOME/.ssh..."
  rm -f "$HOME/.ssh/nix-builder_ed25519" "$HOME/.ssh/nix-builder_ed25519.pub"
fi

# 8-9. These steps may require sudo
need_sudo=false
if pkgutil --pkg-info com.apple.container-installer &>/dev/null; then
  need_sudo=true
fi
if [ -f /etc/nix/builder_ed25519 ] || [ -f /etc/nix/builder_ed25519.pub ]; then
  need_sudo=true
fi

if [ "$need_sudo" = true ]; then
  echo ""
  echo "The following steps require administrator privileges:"
fi

# 8. Forget pkg receipt
if pkgutil --pkg-info com.apple.container-installer &>/dev/null; then
  echo "Removing package receipt..."
  sudo pkgutil --forget com.apple.container-installer 2>/dev/null || true
fi

# 9. Remove legacy builder SSH keys
if [ -f /etc/nix/builder_ed25519 ] || [ -f /etc/nix/builder_ed25519.pub ]; then
  echo "Removing legacy builder SSH keys..."
  sudo rm -f /etc/nix/builder_ed25519 /etc/nix/builder_ed25519.pub
fi

echo ""
echo "Done."
