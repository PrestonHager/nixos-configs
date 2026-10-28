{ config, pkgs, lib, ... }:

let
  cfg = config.homelab.security;
  dataDir = "/var/lib/loki";
  lanIp = "192.168.5.5";
  lokiYaml = pkgs.writeText "loki-config.yaml" ''
    auth_enabled: false
    server:
      # LAN address only: alloy on ace/crux/nova/mars and Grafana (podman0 -> 192.168.5.5)
      # push/query here; nixos-fw limits 3100 to those sources. gRPC is only used by the
      # single-binary components talking to themselves, so it stays on loopback.
      http_listen_address: ${lanIp}
      http_listen_port: 3100
      grpc_listen_address: 127.0.0.1
      grpc_listen_port: 9096
    common:
      instance_addr: 127.0.0.1
      path_prefix: ${dataDir}
      storage:
        filesystem:
          chunks_directory: ${dataDir}/chunks
          rules_directory: ${dataDir}/rules
      replication_factor: 1
      ring:
        kvstore:
          store: inmemory
    schema_config:
      configs:
        - from: 2024-01-01
          store: tsdb
          object_store: filesystem
          schema: v13
          index:
            prefix: index_
            period: 24h
    limits_config:
      retention_period: 720h
    compactor:
      working_directory: ${dataDir}/compactor
      retention_enabled: true
      delete_request_store: filesystem
  '';
in {
  options.homelab.security.loki = {
    enable = lib.mkEnableOption "Loki log store (central ace only)";
  };

  config = lib.mkIf (cfg.enable && cfg.loki.enable && cfg.role == "central") {
    systemd.services.loki = {
      description = "Grafana Loki log aggregation";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      # Keep retrying if bond0's address is not up yet at boot.
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        Type = "simple";
        User = "loki";
        Group = "loki";
        ExecStart = "${pkgs.grafana-loki}/bin/loki -config.file=${lokiYaml}";
        Restart = "on-failure";
        RestartSec = "5s";
        StateDirectory = "loki";
        ReadWritePaths = [ dataDir ];
      };
    };

    users.users.loki = {
      isSystemUser = true;
      group = "loki";
      home = dataDir;
    };
    users.groups.loki = { };

    systemd.tmpfiles.rules = [
      "d ${dataDir} 0750 loki loki -"
      "d ${dataDir}/chunks 0750 loki loki -"
      "d ${dataDir}/rules 0750 loki loki -"
      "d ${dataDir}/compactor 0750 loki loki -"
    ];

    # Push clients only (crux, nova); no blanket allowedTCPPorts.
    networking.firewall.extraCommands = lib.mkAfter ''
      iptables -A nixos-fw -p tcp -s 192.168.5.6 --dport 3100 -j nixos-fw-accept
      iptables -A nixos-fw -p tcp -s 192.168.5.7 --dport 3100 -j nixos-fw-accept
      iptables -A nixos-fw -p tcp -s 192.168.5.15 --dport 3100 -j nixos-fw-accept
    '';
  };
}
