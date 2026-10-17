{ config, pkgs, lib, ... }:

let
  cfg = config.homelab.security;
in {
  options.homelab.security = {
    enable = lib.mkEnableOption "Homelab IDS Phase 1–2 security agents (audit, fail2ban, drift checks)";

    hostName = lib.mkOption {
      type = lib.types.str;
      description = "Short hostname label for logs and metrics (ace, crux, nova).";
    };

    role = lib.mkOption {
      type = lib.types.enum [ "central" "node" ];
      default = "node";
      description = ''
        central = ace (syslog receiver, Cisco backup, Loki, Suricata).
        node = crux/nova (forward logs, local agents only).
      '';
    };

    phase2 = {
      enable = lib.mkEnableOption "Phase 2 detection (AIDE, privilege audit rules, nix-store verify)";
    };

    cisco = {
      enable = lib.mkEnableOption "Cisco syslog receiver (central only)";
      backup = {
        enable = lib.mkEnableOption "Scheduled SSH running-config backup (requires sops cisco.yaml)";
      };
      astracapHost = lib.mkOption { type = lib.types.str; default = "192.168.5.1"; };
      astraquasarHost = lib.mkOption { type = lib.types.str; default = "192.168.5.3"; };
      backupDir = lib.mkOption { type = lib.types.str; default = "/var/lib/cisco-config-backup"; };
    };

    lokiUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://192.168.5.5:3100";
      description = "Loki push/query URL for Promtail and Grafana datasource.";
    };

    gitDrift = {
      remote = lib.mkOption { type = lib.types.str; default = "origin"; };
      branch = lib.mkOption { type = lib.types.str; default = "dell-poweredge-r730xd"; };
    };

    nodeExporter = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run node_exporter with textfile collector for drift metrics. Set false when the host already exports metrics (e.g. crux).";
      };
    };
  };

  imports = [
    ./audit.nix
    ./fail2ban.nix
    ./git-drift.nix
    ./aide.nix
    ./nix-store-verify.nix
    ./cisco-syslog.nix
    ./cisco-backup.nix
    ./node-metrics.nix
    ./response/default.nix
  ];
}
