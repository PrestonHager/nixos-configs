{ config, pkgs, lib, inputs, ... }:

let
  scriptsDir = ./scripts;
  registryPath = "/etc/ace-service-update/registry.json";
  publicUrl = "https://update.prestonhager.com";
  httpPort = 8765;
  stateDir = "/var/lib/ace-service-update";
  nixosDir = "/etc/nixos";

  mailScript = pkgs.writeScriptBin "ace-service-update-mail" ''
    #!${pkgs.python3}/bin/python3
    ${builtins.readFile "${scriptsDir}/ace-service-update-mail.py"}
  '';

  confirmMailScript = pkgs.writeScriptBin "ace-service-update-confirm-mail" ''
    #!${pkgs.python3}/bin/python3
    ${builtins.readFile "${scriptsDir}/ace-service-update-confirm-mail.py"}
  '';

  httpScript = pkgs.writeScriptBin "ace-service-update-http" ''
    #!${pkgs.python3}/bin/python3
    ${builtins.readFile "${scriptsDir}/ace-service-update-http.py"}
  '';

  bumpScript = pkgs.writeShellScript "ace-service-update-bump" ''
    export ACE_REGISTRY="${registryPath}"
    export ACE_NIXOS_DIR="${nixosDir}"
    ${builtins.readFile "${scriptsDir}/ace-service-update-bump.sh"}
  '';

  autoUpdateScript = pkgs.writeShellScript "ace-service-auto-update-run" ''
    export ACE_REGISTRY="${registryPath}"
    export ACE_NIXOS_DIR="${nixosDir}"
    export ACE_UPDATE_STATE="${stateDir}"
    export ACE_VERSIONS_PROM="/var/lib/node-exporter-textfile/ace_versions.prom"
    export ACE_UPDATE_MAIL="${mailScript}/bin/ace-service-update-mail"
    export ACE_UPDATE_CONFIRM_MAIL="${confirmMailScript}/bin/ace-service-update-confirm-mail"
    export ACE_UPDATE_BUMP="${bumpScript}"
    export ACE_NEXTCLOUD_ENV="${config.sops.secrets."nextcloud-environment".path}"
    export ACE_GRAFANA_ENV="${config.sops.secrets."grafana-oauth-env".path}"
    export ACE_UPDATE_PUBLIC_URL="${publicUrl}"
    ${builtins.readFile "${scriptsDir}/ace-service-auto-update.sh"}
  '';

  dispatchScript = pkgs.writeShellScript "ace-service-update-dispatch" ''
    export ACE_REGISTRY="${registryPath}"
    export ACE_UPDATE_STATE="${stateDir}"
    export ACE_VERSIONS_PROM="/var/lib/node-exporter-textfile/ace_versions.prom"
    ${builtins.readFile "${scriptsDir}/ace-service-update-dispatch.sh"}
  '';

  runtimeEnvFile = pkgs.writeTextFile {
    name = "ace-service-update.env";
    text = lib.concatStringsSep "\n" [
      "ACE_UPDATE_STATE=${stateDir}"
      "ACE_VERSIONS_PROM=/var/lib/node-exporter-textfile/ace_versions.prom"
      "ACE_NIXOS_DIR=${nixosDir}"
      "ACE_REGISTRY=${registryPath}"
      "ACE_UPDATE_PUBLIC_URL=${publicUrl}"
      "ACE_UPDATE_HTTP_PORT=${toString httpPort}"
      "ACE_NEXTCLOUD_ENV=${config.sops.secrets."nextcloud-environment".path}"
      "ACE_GRAFANA_ENV=${config.sops.secrets."grafana-oauth-env".path}"
      "ACE_UPDATE_MAIL=${mailScript}/bin/ace-service-update-mail"
      "ACE_UPDATE_CONFIRM_MAIL=${confirmMailScript}/bin/ace-service-update-confirm-mail"
      "ACE_UPDATE_BUMP=${bumpScript}"
    ];
  };

in {
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 root root -"
    "d ${stateDir}/approved 0700 root root -"
    "d ${stateDir}/denied 0700 root root -"
    "d ${stateDir}/locks 0700 root root -"
    "d ${stateDir}/pending 0700 root root -"
    "d ${stateDir}/log 0700 root root -"
  ];

  environment.etc."ace-service-update/registry.json".source = "${scriptsDir}/ace-service-update-registry.json";

  systemd.services.ace-service-update-http = {
    description = "Ace service update approval HTTP handler";
    after = [ "network.target" "sops-nix.service" ];
    wantedBy = [ "multi-user.target" ];
    environmentFiles = [ runtimeEnvFile ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${httpScript}/bin/ace-service-update-http";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  systemd.services."ace-service-auto-update@" = {
    description = "Auto-update Ace service %i";
    after = [
      "network-online.target"
      "ace-version-check.service"
      "sops-nix.service"
    ];
    wants = [ "network-online.target" ];
    environmentFiles = [ runtimeEnvFile ];
    path = with pkgs; [
      bash
      coreutils
      jq
      git
      nix
      config.system.build.nixos-rebuild
      podman
      util-linux
      openssl
      gawk
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${autoUpdateScript} %i";
    };
  };

  systemd.services.ace-service-update-dispatch = {
    description = "Dispatch auto-updates for out-of-date Ace services";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = dispatchScript;
    };
  };

  systemd.services.ace-version-check = {
    serviceConfig.ExecStartPost = dispatchScript;
  };

  environment.systemPackages = [
    mailScript
    confirmMailScript
    httpScript
  ];
}
