{
  config,
  lib,
  ...
}:

let
  common = import ./common.nix { inherit config; };
  cfg = config.services.containerization;
  inherit (common)
    launchAgentsDir
    resolverRelativePath
    runtimeLabel
    userHome
    ;

  userAgentDir = "${userHome}/Library/LaunchAgents";
  systemAgentDir = launchAgentsDir;
  systemDaemonDir = "/Library/LaunchDaemons";

  mkLegacyLaunchdCleanup =
    {
      directory,
      patterns,
      message,
      preRemove ? "",
      removeCommand ? ''rm -f "$plist"'',
    }:
    ''
      CONTAINER_UID=$(id -u "${cfg.user}" 2>/dev/null || echo "")
      if [ -d "${directory}" ]; then
        for plist in ${lib.concatMapStringsSep " " (pattern: "\"${pattern}\"") patterns}; do
          [ -f "$plist" ] || continue
          agent_name="$(basename "$plist" .plist)"
          echo "nix-apple-container: removing legacy ${message} $agent_name..."
          ${preRemove}
          ${removeCommand}
        done
      fi
    '';

  userDomainBootout = ''
    if [ -n "$CONTAINER_UID" ]; then
      launchctl bootout "gui/$CONTAINER_UID/$agent_name" 2>/dev/null || true
      launchctl bootout "user/$CONTAINER_UID/$agent_name" 2>/dev/null || true
    fi
  '';

  # nix-darwin skips userLaunchd cleanup when no user agents remain in the
  # current config. Remove stale container user agents explicitly on disable.
  legacyUserAgentCleanup = mkLegacyLaunchdCleanup {
    directory = userAgentDir;
    patterns = [
      "${userAgentDir}/${runtimeLabel}.plist"
      "${userAgentDir}/dev.apple.container.*.plist"
    ];
    message = "user launch agent";
    preRemove = ''
      if [ -n "$CONTAINER_UID" ]; then
        launchctl asuser "$CONTAINER_UID" sudo --user="${cfg.user}" -- launchctl unload "$plist" 2>/dev/null || true
      fi
      ${userDomainBootout}
    '';
    removeCommand = ''sudo --user="${cfg.user}" -- rm -f "$plist"'';
  };

  # One broken migration placed container jobs in /Library/LaunchAgents.
  legacySystemAgentCleanup = mkLegacyLaunchdCleanup {
    directory = systemAgentDir;
    patterns = [
      "${systemAgentDir}/${runtimeLabel}.plist"
      "${systemAgentDir}/dev.apple.container.*.plist"
    ];
    message = "system launch agent";
    preRemove = userDomainBootout;
  };

  # Another broken revision moved the runtime and container jobs into system
  # LaunchDaemons, which puts Apple container in the wrong launchd domain.
  legacySystemDaemonCleanup = mkLegacyLaunchdCleanup {
    directory = systemDaemonDir;
    patterns = [
      "${systemDaemonDir}/${runtimeLabel}.plist"
      "${systemDaemonDir}/dev.apple.container.*.plist"
    ];
    message = "system launch daemon";
    preRemove = ''
      launchctl bootout "system/$agent_name" 2>/dev/null || true
      launchctl unload "$plist" 2>/dev/null || true
    '';
  };
in
{
  imports = [
    # Backward compat: linuxBuilder.* → linux-builder.aarch64.* / linux-builder.image
    (lib.mkRenamedOptionModule
      [ "services" "containerization" "linuxBuilder" "enable" ]
      [ "services" "containerization" "linux-builder" "aarch64" "enable" ]
    )
    (lib.mkRenamedOptionModule
      [ "services" "containerization" "linuxBuilder" "image" ]
      [ "services" "containerization" "linux-builder" "image" ]
    )
    (lib.mkRenamedOptionModule
      [ "services" "containerization" "linuxBuilder" "sshPort" ]
      [ "services" "containerization" "linux-builder" "aarch64" "sshPort" ]
    )
    (lib.mkRenamedOptionModule
      [ "services" "containerization" "linuxBuilder" "maxJobs" ]
      [ "services" "containerization" "linux-builder" "aarch64" "maxJobs" ]
    )
    (lib.mkRenamedOptionModule
      [ "services" "containerization" "linuxBuilder" "speedFactor" ]
      [ "services" "containerization" "linux-builder" "aarch64" "speedFactor" ]
    )
    (lib.mkRenamedOptionModule
      [ "services" "containerization" "linuxBuilder" "cores" ]
      [ "services" "containerization" "linux-builder" "aarch64" "cores" ]
    )
    (lib.mkRenamedOptionModule
      [ "services" "containerization" "linuxBuilder" "memory" ]
      [ "services" "containerization" "linux-builder" "aarch64" "memory" ]
    )
  ];

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      environment.etc."${resolverRelativePath}".knownSha256Hashes = [
        # Accept the previously hand-written resolver file on first migration
        # so activation can replace it with the declarative /etc symlink.
        "99b89c6edbb7edea675a76545841411eec5cca0d6222be61769f83f5828691b6"
      ];

      system.activationScripts.preActivation.text = lib.mkBefore ''
        # Older broken revisions placed Apple container jobs in legacy user
        # LaunchAgents or in system LaunchDaemons. Remove those before the
        # current launchd setup takes over cleanly.
        ${legacyUserAgentCleanup}
        ${legacySystemDaemonCleanup}
      '';

      system.activationScripts.etc.text = lib.mkAfter ''
        if [ -e /etc/resolver/containerization.test.before-nix-darwin ]; then
          rm /etc/resolver/containerization.test.before-nix-darwin
        fi
      '';
    })

    (lib.mkIf (!cfg.enable) {
      system.activationScripts.postActivation.text = lib.mkBefore ''
        ${legacyUserAgentCleanup}
        ${legacySystemAgentCleanup}
        ${legacySystemDaemonCleanup}
      '';
    })
  ];
}
