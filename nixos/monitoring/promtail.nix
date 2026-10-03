{ config, pkgs, lib, ... }:

let
  cfg = config.homelab.security;
  centralFileSources = lib.optionalString (cfg.role == "central") ''
    local.file_match "suricata" {
      path_targets = [{
        __address__ = "localhost",
        __path__    = "/var/log/suricata/eve.json",
        job         = "suricata",
        host        = "${cfg.hostName}",
      }]
    }

    loki.source.file "suricata" {
      targets    = local.file_match.suricata.targets
      forward_to = [loki.write.central.receiver]
    }

    local.file_match "cisco_syslog" {
      path_targets = [{
        __address__ = "localhost",
        __path__    = "/var/log/cisco-syslog/cisco.log",
        job         = "cisco-syslog",
        host        = "ace",
      }]
    }

    loki.source.file "cisco_syslog" {
      targets    = local.file_match.cisco_syslog.targets
      forward_to = [loki.write.central.receiver]
    }

    local.file_match "technitium_dns" {
      path_targets = [{
        __address__ = "localhost",
        __path__    = "/stor/technitium/logs/*.log",
        job         = "technitium-dns",
        host        = "ace",
      }]
    }

    loki.source.file "technitium_dns" {
      targets    = local.file_match.technitium_dns.targets
      forward_to = [loki.write.central.receiver]
    }
  '';
  alloyConfig = ''
    loki.write "central" {
      endpoint {
        url = "${cfg.lokiUrl}/loki/api/v1/push"
      }
    }

    loki.source.journal "systemd" {
      forward_to = [loki.write.central.receiver]
      labels = {
        job  = "systemd-journal",
        host = "${cfg.hostName}",
      }
    }

    local.file_match "audit" {
      path_targets = [{
        __address__ = "localhost",
        __path__    = "/var/log/audit/audit.log",
        job         = "audit",
        host        = "${cfg.hostName}",
      }]
    }

    loki.source.file "audit" {
      targets    = local.file_match.audit.targets
      forward_to = [loki.write.central.receiver]
    }

    ${centralFileSources}
  '';
in {
  options.homelab.security.promtail = {
    enable = lib.mkEnableOption "Grafana Alloy log shipper to central Loki (replaces Promtail)";
  };

  config = lib.mkIf (cfg.enable && cfg.promtail.enable) {
    services.alloy = {
      enable = true;
      extraFlags = [ "--disable-reporting" ];
    };

    environment.etc."alloy/config.alloy".text = alloyConfig;

    systemd.services.alloy.serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "alloy";
      Group = "alloy";
      SupplementaryGroups = [ "systemd-journal" ]
        ++ lib.optionals (cfg.role == "central" && cfg.suricata.enable) [ "suricata" ];
    };

    users.users.alloy = {
      isSystemUser = true;
      group = "alloy";
      extraGroups = [ "systemd-journal" ]
        ++ lib.optionals (cfg.role == "central" && cfg.suricata.enable) [ "suricata" ];
    };
    users.groups.alloy = { };
  };
}
