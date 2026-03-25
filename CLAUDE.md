# CLAUDE.md

Technical reference for working on nix-apple-container.

## Architecture

This is a nix-darwin module that wraps Apple's [Containerization](https://github.com/apple/containerization) framework.

- `default.nix` — the nix-darwin module
- `package.nix` — derivation that extracts the `container` CLI from Apple's signed `.pkg`
- `kernel.nix` — fetchurl derivation for the kata-containers kernel tarball
- `builder_ed25519` / `builder_ed25519.pub` — known SSH key pair for the linux builder (intentionally public, same model as nixpkgs' `darwin.linux-builder`)

The flake exposes `darwinModules.default`, `packages.aarch64-darwin.default`, and `packages.aarch64-darwin.kernel`.

## How the package works

The `container` CLI is distributed as a flat `.pkg` (not a `.dmg`). Extraction:

1. `xar -xf` the `.pkg` — produces a `Payload` file at the top level (no sub-packages)
2. `gunzip -dc Payload | cpio -i` — extracts to `./bin/` and `./libexec/`
3. Binaries: `bin/container`, `bin/container-apiserver`
4. Plugins: `libexec/container/plugins/{container-runtime-linux,container-core-images,container-network-vmnet}/`

The `.pkg` does NOT extract to `usr/local/` — files are at the root of the payload. This was discovered by manual inspection; the initial assumption of `usr/local/bin/` was wrong.

## How the module works

### Activation script ordering

nix-darwin activation order: `preActivation` → `launchd` → `userLaunchd` → `postActivation`.

The module uses:
- `preActivation`: runtime start, kernel install, image loading, stale image marker cleanup, mount dir creation, GC
- Main activation (nix-darwin): loads/unloads launchd agents (starts/stops containers)
- `postActivation`: reconcile stale agents, stop undeclared containers, builder SSH setup

### Activation (enable = true)

`preActivation`:
1. Creates module state directory (`/var/lib/nix-apple-container`)
2. `container system status` — check if runtime is running; only start if not (fails loudly on error, no `|| true`)
3. Kernel identity tracking — installs kernel if kernels dir is empty OR if `${kernelIdentity}` marker differs from stored value. This ensures kernel changes in config are applied (not just first-time install). Marker stored at `/var/lib/nix-apple-container/kernel-identity`.
4. Loads nix2container images if any declared in `images.*` (must happen before launchd starts containers). Each load runs in a subshell with `set -e` and `trap` for temp file cleanup.
5. Cleans stale image markers (always runs, even when `images = {}`)
6. Creates mount directories for containers with `autoCreateMounts = true` (only for absolute host paths)
7. Runs GC if `gc.automatic = true`

`postActivation`:
1. Unloads stale launchd agents (`dev.apple.container.*.plist`) not in current config
2. Stops and removes containers not declared in config

### Containers (autoStart = true)

Declared as `launchd.user.agents` (NOT `launchd.daemons`). This is critical because:
- The container runtime stores state per-user under `~/Library/Application Support/`
- `launchd.daemons` run as root, which puts state under `/var/root/` — wrong user context
- `launchd.user.agents` run as the logged-in user

Each container's `ProgramArguments` points to a wrapper script (`mkContainerRunScript`) that:
1. Stops and removes any existing container with the same name
2. Optionally pulls the image (if `pull = "always"`)
3. `exec container run ...` with all configured flags

This wrapper ensures config changes are applied cleanly — when the plist changes, nix-darwin reloads the agent, the new wrapper cleans up the old container VM, and starts fresh. The `--detach` flag is NOT used because launchd manages the process lifecycle.

### Teardown (enable = false)

Guarded by `if [ -d "$APP_SUPPORT" ]` — only runs if container state exists (prevents noisy no-ops on first import with `enable = false`).

When disabled:
1. Unloads all module-owned launchd agents (`dev.apple.container.*.plist`) — runs before system stop to prevent KeepAlive restart loops
2. `container system stop` — deregisters launchd services, stops containers
3. Removes `$APP_SUPPORT/kernels` (cheap to reinstall from Nix store)
4. Removes `$APP_SUPPORT/apiserver` (regenerated on system start)
5. If `teardown.removeImages = true`: removes `$APP_SUPPORT/content` and the entire directory
6. `defaults delete com.apple.container`
7. `pkgutil --forget com.apple.container-installer` (if receipt exists)
8. Removes builder files (`/etc/nix/builder_ed25519*`, `/etc/nix/nix.custom.conf`, `/etc/nix/machines`, `/etc/ssh/ssh_config.d/200-nix-builder.conf`) if present
9. Removes module state directory (`/var/lib/nix-apple-container`)

### Linux builder (linuxBuilder.enable = true)

Runs `nixos/nix` as an Apple container with sshd, configured as a Nix remote builder for aarch64-linux builds. Uses a known SSH key pair committed to the repo (same security model as nixpkgs' `darwin.linux-builder` — builder only listens on localhost).

Builder config uses backend-specific declarative options when possible:
- When `config.nix.enable = true` (plain nix-darwin): sets `nix.buildMachines`, `nix.distributedBuilds`, `nix.settings.builders-use-substitutes` declaratively. nix-darwin writes the files and handles daemon restarts.
- When `config.nix.enable = false` (Determinate Nix): writes idempotently to `/etc/nix/nix.custom.conf` and `/etc/nix/machines`. Only restarts the daemon when content changes.
- In all backends: SSH key (`/etc/nix/builder_ed25519`) and SSH config (`/etc/ssh/ssh_config.d/200-nix-builder.conf`) are always managed imperatively but idempotently. SSH config is needed because `nix.buildMachines` has no port field (we use `hostName = "nix-builder"` as an SSH alias) and `StrictHostKeyChecking no` is required (builder generates a new host key on every restart).

When disabled: removes `/etc/nix/builder_ed25519*`, `/etc/nix/nix.custom.conf`, `/etc/nix/machines`, `/etc/ssh/ssh_config.d/200-nix-builder.conf`. Container is removed by reconciliation. Declarative `nix.buildMachines` is cleared automatically by nix-darwin when the `lib.mkIf` condition becomes false.

### nix2container images (images.*)

Loads OCI images built with nix2container into the container runtime at activation time. nix2container produces a tiny JSON metadata file — layers are streamed on-the-fly from Nix store paths via a patched skopeo, avoiding full tarballs in the store.

Loading pipeline: `copyTo oci:<tmpdir>` → `tar -C $tmpdir -cf $tmpdir.tar .` → `container image load -i $tmpdir.tar` → cleanup. Each load runs in a subshell with `set -e` and `trap` for guaranteed temp file cleanup on failure.

**Critical**: Image loading runs in `preActivation` (not postActivation) because launchd starts containers between pre and post. A container with `pull = "never"` needs its image present before it starts.

**Idempotency**: Marker files at `/var/lib/nix-apple-container/images/<name>` store the `copyTo` store path. Image is only re-loaded when the store path changes (i.e., image content changed). Stale marker cleanup runs unconditionally (not gated on `images != {}`) so markers are cleaned up even when all images are removed from config.

**Apple `container image load` only accepts OCI Image Layout tar archives** — NOT Docker tarballs. The `oci:` directory output + manual tar produces the correct format.

### Root vs user context

`darwin-rebuild switch` runs activation scripts as root. All `container` CLI calls must use `sudo -u <user> --` to run as the actual user. The `user` option defaults to `config.system.primaryUser`.

The teardown script resolves the user's home directory via `eval echo "~$CONTAINER_USER"` rather than relying on `$HOME` (which is `/var/root` during activation).

## Idempotency and cleanup principles

Every activation script and feature MUST follow these rules:

### Idempotency

- **Guard before acting**: Check state before modifying. Don't start the runtime if already running (`system status`). Don't install the kernel if the identity marker matches. Don't append to `known_hosts` if the key is already present.
- **No unconditional appends**: Never `>> file` without checking if the content is already there. Use `grep -qF` to deduplicate.
- **No unconditional restarts**: Don't restart daemons unless config actually changed. nix-darwin's plist diffing handles launchd agents. The Nix daemon reads `/etc/nix/machines` on demand.
- **Activation scripts run on every rebuild**: Assume they run repeatedly with no config changes. They must produce no side effects in that case.

### Cleanup (enable/disable lifecycle)

Every feature that creates state outside the Nix store MUST clean it up when disabled:

| Component | State created | Cleanup when disabled |
|-----------|--------------|----------------------|
| Module (`enable`) | `~/Library/Application Support/com.apple.container/`, defaults, pkg receipt, `/var/lib/nix-apple-container/` | Teardown block with `!cfg.enable` guard; also removes builder files |
| Containers (`autoStart`) | Launchd agents (`dev.apple.container.*.plist`), running container VMs | postActivation reconciliation unloads agents + stops/removes containers; teardown also unloads agents before system stop |
| Linux builder (`linuxBuilder.enable`) | `/etc/nix/builder_ed25519*`, `/etc/ssh/ssh_config.d/200-nix-builder.conf`, `/etc/nix/nix.custom.conf` (imperative path only), `/etc/nix/machines` (imperative path only), `nix.buildMachines` (declarative path) | `!cfg.linuxBuilder.enable` block removes files + restarts daemon; declarative options cleared by nix-darwin |
| Kernel | `/var/lib/nix-apple-container/kernel-identity` marker | Marker removed with state dir on `!cfg.enable` |
| Images (`images.*`) | `/var/lib/nix-apple-container/images/` markers, loaded images in container store | Stale markers cleaned unconditionally; image data cleaned by `gc.pruneImages`; marker dir removed on `!cfg.enable` |
| Mount directories (`autoCreateMounts`) | Host directories for volumes (absolute paths only) | NOT cleaned up (user data, intentionally preserved) |

### nix-darwin's `userLaunchd` limitation

nix-darwin's user agent cleanup script is gated by `mkIf (... || userLaunchAgents != [])`. When ALL user agents are removed from config, the cleanup script never runs. Our module handles this explicitly in postActivation by globbing `dev.apple.container.*.plist` files and unloading stale agents.

### Plist filename convention

Plist filenames are derived from `serviceConfig.Label`, NOT the nix-darwin attribute name. Our agents use `Label = "dev.apple.container.${name}"`, so plists are `dev.apple.container.${name}.plist`. The reconciliation glob pattern must match this.

## Garbage collection

`gc.pruneContainers` is an enum:
- `"none"` — skip
- `"stopped"` — `container prune` (removes all stopped containers)
- `"running"` — lists all containers via `container ls --format json`, compares names against declared `containers.<name>` attrs, stops+removes undeclared ones, then prunes stopped

The `"running"` mode uses `jq` to parse the JSON output. The `jq` binary is referenced as `${pkgs.jq}/bin/jq` to avoid a runtime dependency.

`gc.pruneImages` runs `container image prune` which removes **dangling** (untagged) images, not all unused images. The option description reflects this.

Note: Containers removed from config are always stopped during postActivation reconciliation, regardless of GC settings. GC is for cleaning up ad-hoc containers created outside the Nix config.

## Bugs encountered during development

### `.pkg` payload path assumption
Initial code assumed the `.pkg` extracted to `usr/local/bin/`. Actual structure is flat: `bin/`, `libexec/` at root. The `installPhase` silently produced empty `$out/bin/` and `$out/libexec/` directories. Fixed by inspecting the actual payload with `xar -xf` + `cpio -i` manually.

### Duplicate `launchd.daemons` attribute
Defining `launchd.daemons."container-runtime"` as a named attr AND `launchd.daemons = lib.mapAttrs' ...` in the same `config` block causes a Nix evaluation error: "attribute already defined". Fixed by merging into a single attrset with `//`.

### `container system start` as a launchd daemon
Running `container system start` as a persistent `KeepAlive = true` daemon causes an infinite loop: the command registers its own launchd services (API server), exits, launchd restarts it, it tries to register again. The log shows endless "Registering API server with launchd... Verifying apiserver is running...". Fixed by moving `system start` to the activation script (runs once) and removing the launchd daemon.

### Root user context during activation
`darwin-rebuild switch` runs as root. `container image pull` stores data under `$HOME/Library/Application Support/com.apple.container/`. When run as root, this becomes `/var/root/Library/...` — the wrong location. The container runtime running as the actual user can't find the images. Error: `NSCocoaErrorDomain Code=4 ... couldn't be moved to "sha256"`. Fixed by wrapping all container CLI calls with `sudo -u <user> --`.

### Kernel install prompt
`container system start` prompts interactively: "Install the recommended default kernel from [URL]? [Y/n]:". This hangs non-interactive environments. The `--enable-kernel-install` flag auto-accepts, but `container system kernel set --recommended` is more explicit. The module now uses `--disable-kernel-install` on `system start` and handles the kernel separately with a check-then-install pattern.

### Kernel re-installation on every rebuild
`container system kernel set --recommended` ran unconditionally, re-downloading ~277MB on every rebuild. Fixed two ways: (1) kernel is now a Nix derivation (`kernel.nix`) installed via `--tar <nix-store-path>` — no network download; (2) only runs if `kernels/` directory is empty.

## Apple Containerization quirks

### One VM per container
Unlike Docker (single VM hosting all containers), each container runs in its own lightweight VM with a dedicated Linux kernel. The framework provides the kernel (kata-containers) and a Swift-based init system (vminitd) as PID 1.

### Kernel source
The Linux kernel comes from [kata-containers](https://github.com/kata-containers/kata-containers/releases). The specific file extracted is `opt/kata/share/kata-containers/vmlinux-*` from the release tarball. Installed to `~/Library/Application Support/com.apple.container/kernels/` with a `default.kernel-arm64` symlink.

### Networking
- macOS 15: limited networking, no container-to-container, no custom networks
- macOS 26: full networking support, custom networks, direct IP access
- Port forwarding: `--publish host:container` syntax, uses vmnet framework
- Each container gets its own IP on the vmnet subnet (default `192.168.64.0/24`)
- Containers named `foo` get DNS entry `foo.test` automatically
- No `--hostname` flag — use `--name` instead
- Known issue: VPN activation breaks container networking ([#1307](https://github.com/apple/container/issues/1307))
- Known issue: single file volume mounts fail intermittently ([#1251](https://github.com/apple/container/issues/1251))

### Container data location
All state under `~/Library/Application Support/com.apple.container/`:
- `kernels/` — Linux kernels + `default.kernel-arm64` symlink
- `content/blobs/` — image layers
- `content/ingest/` — temporary download staging

### container system start internals
`container system start` is NOT a long-running daemon. It:
1. Registers the API server with launchd
2. Verifies it's running
3. Optionally installs the kernel
4. Exits

The API server itself runs as a separate launchd service managed by the container framework, not by nix-darwin.

## nix-darwin quirks

### No deactivation hooks
nix-darwin has no "on module removed" lifecycle hook. Cleanup happens via:
- `launchd.daemons` / `launchd.user.agents`: auto-diffed and removed by nix-darwin's activation
- Custom state: must use `lib.mkIf (!cfg.enable)` to run cleanup when the module is still imported but disabled
- If the module import is removed entirely, no cleanup runs — user must handle manually or keep the import with `enable = false` first

### Activation script ordering
`system.activationScripts.postActivation.text` with `lib.mkAfter` runs after other activation. Multiple modules appending to the same script are concatenated. Use `lib.mkMerge` with separate `lib.mkIf` blocks for enable/disable logic.

### launchd.daemons vs launchd.user.agents
- `launchd.daemons` → `/Library/LaunchDaemons/` — runs as root
- `launchd.user.agents` → `~/Library/LaunchAgents/` — runs as logged-in user
- Container commands MUST use `launchd.user.agents` due to per-user state

## Useful links

### Apple Containerization
- Repository: https://github.com/apple/containerization (framework)
- CLI tool: https://github.com/apple/container
- Command reference: https://github.com/apple/container/blob/main/docs/command-reference.md
- How-to guide: https://github.com/apple/container/blob/main/docs/how-to.md
- Technical overview: https://github.com/apple/container/blob/main/docs/technical-overview.md
- Building from source: https://github.com/apple/container/blob/main/BUILDING.md
- SystemStart.swift (kernel install logic): https://github.com/apple/container/blob/e5f9abd8ff3136f27fde9ffc9abed4195c4ac9ef/Sources/ContainerCommands/System/SystemStart.swift#L138

### Kata Containers (kernel)
- Releases: https://github.com/kata-containers/kata-containers/releases
- Kernel binary path in tarball: `opt/kata/share/kata-containers/vmlinux-*`

### nix-darwin
- Repository: https://github.com/LnL7/nix-darwin
- Launchd module: `modules/system/launchd.nix` (handles service diff/cleanup)
- Activation scripts: `modules/system/activation-scripts.nix`
- OpenSSH module (enable/disable pattern): `modules/services/openssh.nix`

### Nix container image building
- dockerTools docs: https://ryantm.github.io/nixpkgs/builders/images/dockertools/
- nix.dev tutorial: https://nix.dev/tutorials/nixos/building-and-running-docker-images.html
- nix2container (alternative): https://github.com/nlewo/nix2container

### macOS .pkg packaging in Nix
- NixOS Discourse: https://discourse.nixos.org/t/how-to-define-derivations-for-macos-pkg-archives-in-nix/6252
- undmg (for .dmg files): https://github.com/matthewbauer/undmg
- nixpkgs platform notes: https://ryantm.github.io/nixpkgs/stdenv/platform-notes/
