{ config, ... }:

let
  cfg = config.services.containerization;

  userHome =
    if config.users.users ? ${cfg.user} then
      config.users.users.${cfg.user}.home
    else
      "/Users/${cfg.user}";

  launchAgentsDir = "/Library/LaunchAgents";
  runtimeLabel = "nix-apple-container.runtime";
  userBuilderKey = "${userHome}/.ssh/nix-builder_ed25519";
  userBuilderPubKey = "${userHome}/.ssh/nix-builder_ed25519.pub";
  systemBuilderKey = "/etc/nix/builder_ed25519";
  systemBuilderPubKey = "/etc/nix/builder_ed25519.pub";
  resolverRelativePath = "resolver/containerization.test";
in
{
  inherit
    launchAgentsDir
    resolverRelativePath
    runtimeLabel
    systemBuilderKey
    systemBuilderPubKey
    userBuilderKey
    userBuilderPubKey
    userHome
    ;
}
