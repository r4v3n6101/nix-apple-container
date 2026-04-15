# Options

## `services.containerization`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Install the CLI, start the runtime, enable the module |
| `user` | string | `config.system.primaryUser` | User to run container commands as (activation scripts run as root) |
| `package` | package | *built from .pkg* | Override the container CLI package |
| `images` | attrs of packages | `{}` | nix2container images to load (buildImage or pullImage) |
| `preserveImagesOnDisable` | bool | `false` | Keep loaded images when the module is disabled |
| `preserveVolumesOnDisable` | bool | `false` | Keep named volume data when the module is disabled. Best-effort based on known runtime directory layout. Bind mounts are always preserved (they live on the host) |

## `services.containerization.kernel`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| *(top-level)* | package | *kata 3.26.0 arm64* | Flat file derivation of the kernel binary — symlinked as `default.kernel-arm64` in the runtime |

The runtime default kernel is separate from the per-builder kernel used by
`linux-builder.<arch>.kernel`.

## `services.containerization.containers.<name>`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `image` | string | *required* | Image name:tag (from `images.*` or a registry — the runtime pulls automatically) |
| `autoStart` | bool | `false` | Run via launchd user agent on login. When false, the name is reserved (prevents drift cleanup) but no container is created |
| `cmd` | list of strings | `[]` | Override the image CMD |
| `env` | attrs of strings | `{}` | Environment variables |
| `volumes` | list of strings | `[]` | Volume mounts (macOS 26+). `host:container` for bind mounts or `name:container` for named volumes. Every entry must contain a `:` |
| `autoCreateMounts` | bool | `true` | Create host directories for volume mounts if they don't exist |
| `entrypoint` | string or null | `null` | Override the image entrypoint |
| `user` | string or null | `null` | Run as UID or UID:GID |
| `workdir` | string or null | `null` | Override working directory |
| `init` | bool | `false` | Run init for signal forwarding and zombie reaping |
| `ssh` | bool | `false` | Forward SSH agent from host |
| `network` | string or null | `null` | Attach to custom network (macOS 26+). The module does not create or manage networks — use `container network` commands manually |
| `readOnly` | bool | `false` | Read-only root filesystem |
| `labels` | attrs of strings | `{}` | Container labels for metadata |
| `extraArgs` | list of strings | `[]` | Extra arguments passed to `container run` (e.g. `--publish`, `--cpus`, `--memory`) |

## `services.containerization.linux-builder`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `image` | string | `"ghcr.io/halfwhey/nix-builder:<builder-version>-nix<version>"` | Builder container image (multi-arch, shared by aarch64 and x86_64) |

The default image (`ghcr.io/halfwhey/nix-builder`) is built from the `builder/Dockerfile` in this repo -- a minimal `nixos/nix` image with sshd. Uses a known SSH key pair (builder only listens on localhost, same security model as nixpkgs' `darwin.linux-builder`).

Builder Nix configuration is fully declarative:
- **`nix.enable = true`** (plain nix-darwin): uses `nix.buildMachines`, `nix.distributedBuilds`, and `nix.settings`.
- **Determinate Nix**: uses `determinateNix.buildMachines`, `determinateNix.distributedBuilds`, and `determinateNix.customSettings.builders-use-substitutes`. Requires the [Determinate nix-darwin module](https://docs.determinate.systems/guides/nix-darwin/):

  <details>
  <summary>Determinate Nix flake setup</summary>

  ```nix
  # flake.nix
  {
    inputs = {
      determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/3";
      # ... your other inputs
    };

    outputs = { determinate, nix-darwin, ... }: {
      darwinConfigurations.myhost = nix-darwin.lib.darwinSystem {
        modules = [
          determinate.darwinModules.default
          # ... your other modules
          {
            determinateNix.enable = true;
          }
        ];
      };
    };
  }
  ```

  > **First-time setup**: nix-darwin may refuse to activate with `Unexpected files in /etc` mentioning `nix.custom.conf`. This happens because the Determinate installer created the file before nix-darwin can manage it ([nix-darwin#1298](https://github.com/nix-darwin/nix-darwin/issues/1298)). Rename it and rebuild:
  > ```bash
  > sudo mv /etc/nix/nix.custom.conf /etc/nix/nix.custom.conf.before-nix-darwin
  > ```

  </details>

**Bootstrap**: First rebuild starts the builder. Second rebuild can use it for Linux derivations (e.g. nix2container images with `aarch64-linux` packages).

> **Migration**: The old `linuxBuilder.*` option names still work but emit a deprecation warning. Update to `linux-builder.aarch64.*` (per-arch options) and `linux-builder.image` (shared image).

## `services.containerization.linux-builder.aarch64`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Run a Nix builder container for aarch64-linux builds |
| `cores` | int | `4` | Number of CPUs to allocate to the container |
| `kernel` | null or package | `null` | Kernel passed to this builder via `container run --kernel`. `null` uses the runtime default kernel |
| `memory` | string | `"1024M"` | Amount of memory to allocate to the container |
| `sshPort` | port | `31022` | Host port for SSH to the builder |
| `maxJobs` | int | `4` | Max parallel build jobs |
| `speedFactor` | int | `1` | Relative speed of the builder (arbitrary integer for Nix scheduler prioritization) |

## `services.containerization.linux-builder.x86_64`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Run a builder container for x86_64-linux builds |
| `cores` | int | `4` | Number of CPUs to allocate to the x86_64 builder container |
| `kernel` | null or package | *kata 3.24.0 arm64* | Kernel passed to this builder via `container run --kernel`. Defaults to a Rosetta-compatible kernel |
| `memory` | string | `"1024M"` | Amount of memory to allocate to the x86_64 builder container |
| `sshPort` | port | `31023` | Host port for SSH to the x86_64 builder |
| `maxJobs` | int | `4` | Max parallel build jobs |
| `speedFactor` | int | `1` | Relative speed of the x86_64 builder |

Both builders share the same image and SSH key. The x86_64 builder runs with `--platform linux/amd64`, uses the runtime name `nix-builder-amd64`, and uses a dedicated Rosetta-compatible kernel by default. Performance is lower than native aarch64 builds but enables building `x86_64-linux` derivations without a separate x86 machine.
