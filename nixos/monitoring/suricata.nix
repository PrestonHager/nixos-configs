{ config, pkgs, lib, ... }:

let
  cfg = config.homelab.security;
  eveLog = "/var/log/suricata/eve.json";
  # suricata-update writes the merged ET Open ruleset and its classification
  # config here; refreshed daily by suricata-update.timer.
  ruleDir = "/var/lib/suricata/rules";
  # The suricata-update script in pkgs.suricata needs PyYAML, which its
  # interpreter does not have.
  suricataUpdatePython = pkgs.python3.withPackages (p: [ p.pyyaml ]);
  suricataYaml = pkgs.writeText "suricata.yaml" ''
    %YAML 1.1
    ---
    vars:
      # ET Open rules reference these groups; a rule naming an undefined one
      # fails to load.
      address-groups:
        HOME_NET: "[192.168.5.0/24]"
        EXTERNAL_NET: "!$HOME_NET"
        HTTP_SERVERS: "$HOME_NET"
        SMTP_SERVERS: "$HOME_NET"
        SQL_SERVERS: "$HOME_NET"
        DNS_SERVERS: "$HOME_NET"
        TELNET_SERVERS: "$HOME_NET"
        AIM_SERVERS: "$EXTERNAL_NET"
        DC_SERVERS: "$HOME_NET"
        DNP3_SERVER: "$HOME_NET"
        DNP3_CLIENT: "$HOME_NET"
        MODBUS_CLIENT: "$HOME_NET"
        MODBUS_SERVER: "$HOME_NET"
        ENIP_CLIENT: "$HOME_NET"
        ENIP_SERVER: "$HOME_NET"
      port-groups:
        HTTP_PORTS: "80"
        SHELLCODE_PORTS: "!80"
        ORACLE_PORTS: 1521
        SSH_PORTS: 22
        DNP3_PORTS: 20000
        MODBUS_PORTS: 502
        FILE_DATA_PORTS: "[$HTTP_PORTS,110,143]"
        FTP_PORTS: 21
        GENEVE_PORTS: 6081
        VXLAN_PORTS: 4789
        TEREDO_PORTS: 3544
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
    default-rule-path: ${ruleDir}
    rule-files:
      - suricata.rules
      - /etc/suricata/rules/local.rules
    classification-file: ${ruleDir}/classification.config
    reference-config-file: ${pkgs.suricata}/etc/suricata/reference.config
  '';
  # Busy clients open many connections to the public web ports; counting those
  # as a scan alerted on ordinary internet traffic. A real port scan touches
  # other ports too, so 80/443 are left out of the count.
  localRules = pkgs.writeText "suricata-local.rules" ''
    # Homelab tuning — alert on SYN scans (controlled test: nmap -sS)
    alert tcp any any -> $HOME_NET ![80,443] (msg:"ET SCAN SYN Scan detected"; flags:S; threshold: type both, track by_src, count 20, seconds 60; priority:2; sid:9000001; rev:2;)
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
      after = [ "network-online.target" "systemd-modules-load.service" "suricata-update.service" ];
      wants = [ "network-online.target" "suricata-update.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ suricataYaml localRules ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.suricata}/bin/suricata -c /etc/suricata/suricata.yaml -i bond0 --af-packet";
        # SIGUSR2 reloads rules without restarting; SIGHUP reopens eve.json.
        ExecReload = "${pkgs.coreutils}/bin/kill -USR2 $MAINPID";
        Restart = "on-failure";
        AmbientCapabilities = [ "CAP_NET_RAW" "CAP_NET_ADMIN" ];
      };
    };

    # Fetch the latest ET Open ruleset, test it against the running config, and
    # reload Suricata. A failed download or test keeps the previous rules.
    systemd.services.suricata-update = {
      description = "Update Suricata rules (ET Open)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "suricata";
        ExecStart = lib.concatStringsSep " " [
          "${suricataUpdatePython}/bin/python3 ${pkgs.suricata}/bin/suricata-update"
          "--suricata ${pkgs.suricata}/bin/suricata"
          "--suricata-conf /etc/suricata/suricata.yaml"
          "--data-dir /var/lib/suricata"
          "--output ${ruleDir}"
          "--no-reload"
        ];
        ExecStartPost = "-${pkgs.systemd}/bin/systemctl try-reload-or-restart --no-block suricata.service";
      };
    };

    systemd.timers.suricata-update = {
      description = "Daily Suricata rule update";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        RandomizedDelaySec = "1h";
        Persistent = true;
      };
    };

    # eve.json was never rotated and reached 81 GB. Suricata reopens it on SIGHUP.
    services.logrotate.settings.suricata = {
      files = eveLog;
      frequency = "daily";
      rotate = 7;
      compress = true;
      delaycompress = true;
      missingok = true;
      notifempty = true;
      postrotate = "${pkgs.systemd}/bin/systemctl kill -s HUP suricata.service";
    };

    users.users.suricata = {
      isSystemUser = true;
      group = "suricata";
    };
    users.groups.suricata = {
      members = lib.optionals cfg.promtail.enable [ "alloy" ];
    };

    # Suricata runs as root; the group lets Alloy read eve.json. The directory
    # is root-owned so logrotate will rotate in it.
    systemd.tmpfiles.rules = [
      "d /var/log/suricata 0750 root suricata -"
    ];
  };
}
