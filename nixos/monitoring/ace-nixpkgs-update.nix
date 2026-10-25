{ config, pkgs, ... }:

# Nightly nixpkgs update for ace: see scripts/ace-nixpkgs-update.sh and
# docs/monitoring-ace.md ("Nightly nixpkgs updates").
let
  scriptsDir = ./scripts;

  mailScript = pkgs.writeScriptBin "ace-service-update-mail" ''
    #!${pkgs.python3}/bin/python3
    ${builtins.readFile "${scriptsDir}/ace-service-update-mail.py"}
  '';

  updateScript = pkgs.writeShellScript "ace-nixpkgs-update" ''
    export ACE_NIXOS_DIR=/etc/nixos
    export ACE_NIXPKGS_PROM=/var/lib/node-exporter-textfile/ace_nixpkgs.prom
    export ACE_UPDATE_MAIL="${mailScript}/bin/ace-service-update-mail"
    export ACE_NEXTCLOUD_ENV="${config.sops.secrets."nextcloud-environment".path}"
    export ACE_GRAFANA_ENV="${config.sops.secrets."grafana-oauth-env".path}"
    ${builtins.readFile "${scriptsDir}/ace-nixpkgs-update.sh"}
  '';
in
{
  systemd.services.ace-nixpkgs-update = {
    description = "Nightly nixpkgs update for ace (build, switch, commit flake.lock)";
    after = [ "network-online.target" "sops-nix.service" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [
      bash
      coreutils
      gnused
      jq
      git
      openssh
      nix
      config.system.build.nixos-rebuild
      util-linux
      iproute2
      curl
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = updateScript;
      # A full rebuild can take a while on a nixpkgs bump with many rebuilds.
      TimeoutStartSec = "3h";
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };

  systemd.timers.ace-nixpkgs-update = {
    description = "Nightly nixpkgs update for ace";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # After the 03:30 restic backup, so a bad update has a fresh snapshot behind it.
      OnCalendar = "*-*-* 04:30:00";
      RandomizedDelaySec = "20min";
      Persistent = true;
    };
  };
}
