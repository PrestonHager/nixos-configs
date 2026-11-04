{ config, lib, pkgs, ... }:

# Monthly rotation of the secrets ace generates and consumes itself (Valkey
# passwords, Technitium admin/PFX passwords, the update-link HMAC key and the
# wg-portal session/CSRF secrets). Secrets held in sops or by outside services
# are rotated by hand: docs/secret-rotation.md.
let
  scriptsDir = ../monitoring/scripts;
  mailScript = pkgs.writeScriptBin "ace-service-update-mail" ''
    #!${pkgs.python3}/bin/python3
    ${builtins.readFile "${scriptsDir}/ace-service-update-mail.py"}
  '';

  rotate = pkgs.writeShellApplication {
    name = "ace-secret-rotate";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      findutils
      gnugrep
      gnused
      jq
      openssl
      podman
      systemd
      util-linux
    ];
    # Checked by shellcheck at build time; the script handles its own errors.
    bashOptions = [ ];
    # SC2016: the single-quoted snippets run inside containers / php -r on purpose.
    excludeShellChecks = [ "SC2016" ];
    text = ''
      export ACE_ROTATE_STATE=/var/lib/ace-secret-rotation
      export ACE_ROTATE_PROM=/var/lib/node-exporter-textfile/ace_secret_rotation.prom
      export ACE_UPDATE_MAIL="${mailScript}/bin/ace-service-update-mail"
      export ACE_NEXTCLOUD_ENV="${config.sops.secrets."nextcloud-environment".path}"
      export ACE_GRAFANA_ENV="${config.sops.secrets."grafana-oauth-env".path}"
      ${builtins.readFile ./scripts/ace-secret-rotate.sh}
    '';
  };
in
{
  environment.systemPackages = [ rotate ];

  systemd.tmpfiles.rules = [ "d /var/lib/ace-secret-rotation 0700 root root -" ];

  systemd.services.ace-secret-rotate = {
    description = "Rotate ace's self-managed secrets (docs/secret-rotation.md)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${rotate}/bin/ace-secret-rotate all";
      TimeoutStartSec = "2h";
    };
  };

  # First Sunday of the month, 03:10: before the 04:30 nixpkgs update, and quiet.
  systemd.timers.ace-secret-rotate = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-01..07 03:10";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
  };
}
