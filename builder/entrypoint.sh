#!/bin/sh
set -e

# sshd needs /run for its PID file
mkdir -p /run

# Start the Nix daemon in the background
nix-daemon &

# Run sshd in the foreground
exec "$(which sshd)" -D -e
