{ config, pkgs, lib, ... }:

let
  cfg = config.homelab.security;
  eveLog = "/var/log/suricata/eve.json";
  suricataYaml = pkgs.writeText "suricata.yaml" ''
    %YAML 1.1
    ---
    vars:
      address-groups:
        HOME_NET: "[192.168.5.0/24]"
        EXTERNAL_NET: "!$HOME_NET"
    default-log-dir: /var/log/suricata/
    outputs:
      - eve-log:
          enabled: true
          filetype: regular
          filename: ${eveLog}
          types:
            - alert
            - dns
            - flow
    af-packet:
      - interface: bond0
        cluster-id: 99
        cluster-type: cluster_flow
        defrag: true
    detect-engine:
      - profile: medium
    rule-files:
      - /etc/suricata/rules/local.rules
  '';
  localRules = pkgs.writeText "suricata-local.rules" ''
    # Homelab tuning — alert on SYN scans (controlled test: nmap -sS)
    alert tcp any any -> $HOME_NET any (msg:"ET SCAN SYN Scan detected"; flags:S; threshold: type both, track by_src, count 20, seconds 60; sid:9000001; rev:1;)
  '';
in {
  options.homelab.security.suricata = {
    enable = lib.mkEnableOption "Suricata IDS on ace (host NIC; SPAN optional)";
  };

  config = lib.mkIf (cfg.enable && cfg.suricata.enable && cfg.role == "central") {
    environment.etc."suricata/suricata.yaml".source = suricataYaml;
    environment.etc."suricata/rules/local.rules".source = localRules;

    systemd.services.suricata = {
      description = "Suricata IDS (IDS mode)";
      after = [ "network-online.target" "systemd-modules-load.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = [
          "${pkgs.coreutils}/bin/mkdir -p /var/log/suricata"
          "${pkgs.coreutils}/bin/chown suricata:suricata /var/log/suricata"
        ];
        ExecStart = "${pkgs.suricata}/bin/suricata -c /etc/suricata/suricata.yaml -i bond0 --af-packet";
        Restart = "on-failure";
        AmbientCapabilities = [ "CAP_NET_RAW" "CAP_NET_ADMIN" ];
      };
    };

    users.users.suricata = {
      isSystemUser = true;
      group = "suricata";
    };
    users.groups.suricata = {
      members = lib.optionals cfg.promtail.enable [ "alloy" ];
    };

    systemd.tmpfiles.rules = [
      "d /var/log/suricata 0750 suricata suricata -"
    ];
  };
}
