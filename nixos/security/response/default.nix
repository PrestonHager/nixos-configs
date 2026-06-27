{ config, pkgs, lib, ... }:

let
  cfg = config.homelab.security;
in {
  config = lib.mkIf (cfg.enable && cfg.role == "central") {
    # Phase 3 response stubs — manual approval required before any automated block.
    environment.etc."homelab-security/response/README.md".text = builtins.readFile ./response/README.md;

    environment.etc."homelab-security/response/block-ip-technitium.sh" = {
      source = ./response/block-ip-technitium.sh;
      mode = "0750";
    };

    environment.etc."homelab-security/response/block-ip-nftables.sh" = {
      source = ./response/block-ip-nftables.sh;
      mode = "0750";
    };

    environment.etc."homelab-security/response/port-shutdown-playbook.md".text =
      builtins.readFile ./response/port-shutdown-playbook.md;

    systemd.services.homelab-security-response-stubs = {
      description = "Marker service for Phase 3 response playbook stubs";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.coreutils}/bin/true";
      };
      wantedBy = [ "multi-user.target" ];
    };
  };
}
