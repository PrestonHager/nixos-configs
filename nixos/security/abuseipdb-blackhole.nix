{ config, pkgs, lib, inputs, ... }:

# Block addresses AbuseIPDB is highly confident are malicious, at the edge router.
#
# ace fetches the AbuseIPDB blacklist (abuseipdb-blackhole-sync, every 6 h) and
# announces each address as a /32 over BGP from BIRD. Astracap accepts only /32s
# from ace, points them at Null0, and loose uRPF on its WAN interface drops any
# packet sourced from them (remote-triggered blackholing). Routes are learned, not
# configured: they never touch the router's 256 KB NVRAM, and a router lookup is a
# CEF route lookup, not a linear ACL walk. If ace or the session goes away, the
# routes are withdrawn and nothing is blocked (fail-open).
#
# Router side, API key and operations: docs/network-abuseipdb-blackhole.md.
let
  cfg = config.homelab.security.abuseipdbBlackhole;
  sec = config.homelab.security;
  stateDir = "/var/lib/abuseipdb-blackhole";
  routesFile = "${stateDir}/routes.conf";
  textfileDir = "/var/lib/node-exporter-textfile";
  sops-path = builtins.toString inputs.nix-secrets;

  syncScript = pkgs.writeShellScript "abuseipdb-blackhole-sync" ''
    exec ${pkgs.python3}/bin/python3 -I ${./abuseipdb-blackhole-sync.py} "$@"
  '';
in
{
  options.homelab.security.abuseipdbBlackhole = {
    enable = lib.mkEnableOption "AbuseIPDB blacklist announced to Astracap as BGP blackhole routes";

    apiKeyConfigured = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Set once nix-secrets has `abuseipdb-api-key` in secrets/hosts/ace/abuseipdb.yaml.
        Until then the sync runs, reports itself unconfigured and announces nothing.
      '';
    };

    routerConfigured = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Set once Astracap has the BGP neighbour for ace (see the doc). It only turns on
        the "BGP session down" alert, so an unconfigured router does not page.
      '';
    };

    minConfidence = lib.mkOption {
      type = lib.types.ints.between 25 100;
      default = 95;
      description = ''
        Minimum AbuseIPDB confidence score to block. Below 100 needs a paid AbuseIPDB plan;
        a free (Standard) account always gets the 100% list, which is a subset.
      '';
    };

    maxPrefixes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10000;
      description = "Most addresses to announce (highest confidence, most recently reported first). Keep below the router's maximum-prefix.";
    };

    allowlist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "203.0.113.7/32" ];
      description = ''
        Extra IPv4 networks never to block. Private, CGNAT/tailnet, loopback, link-local
        and multicast ranges, our public address, the public resolvers, Cloudflare and
        GitHub's published ranges are always excluded.
      '';
    };

    localAs = lib.mkOption { type = lib.types.ints.positive; default = 65105; };
    routerAs = lib.mkOption { type = lib.types.ints.positive; default = 65100; };
    routerAddress = lib.mkOption { type = lib.types.str; default = sec.cisco.astracapHost; };
    localAddress = lib.mkOption { type = lib.types.str; default = "192.168.5.5"; };
  };

  config = lib.mkIf (sec.enable && cfg.enable && sec.role == "central") {
    sops.secrets."abuseipdb-api-key" = lib.mkIf cfg.apiKeyConfigured {
      sopsFile = "${sops-path}/secrets/hosts/ace/abuseipdb.yaml";
      key = "abuseipdb-api-key";
      mode = "0400";
    };

    services.bird = {
      enable = true;
      package = pkgs.bird2;
      # The route list is written at runtime; check against an empty stand-in.
      preCheckConfig = ''
        sed 's#${routesFile}#routes.conf#' "$(readlink -f bird.conf)" > bird.conf.checked
        mv bird.conf.checked bird.conf
        touch routes.conf
      '';
      config = ''
        router id ${cfg.localAddress};
        log syslog all;

        protocol device { }

        # Only BGP export: there is no `protocol kernel`, so ace itself installs none
        # of these routes.
        protocol static abuseipdb {
          ipv4;
          include "${routesFile}";
        }

        protocol bgp astracap {
          description "Astracap: AbuseIPDB blackhole routes";
          local ${cfg.localAddress} as ${toString cfg.localAs};
          neighbor ${cfg.routerAddress} as ${toString cfg.routerAs};
          # ace connects; the router side is passive. Retry every 30 s.
          connect retry time 30;
          hold time 90;
          ipv4 {
            import none;
            export where proto = "abuseipdb" && net.len = 32;
            next hop self;
          };
        }
      '';
    };

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 root bird -"
      # BIRD will not start if the include is missing; start with no routes.
      "f ${routesFile} 0640 root bird -"
    ];

    systemd.services.abuseipdb-blackhole-sync = {
      description = "Fetch the AbuseIPDB blacklist and announce it to Astracap";
      after = [ "network-online.target" "bird.service" ];
      wants = [ "network-online.target" ];
      path = [ config.services.bird.package ];
      environment = {
        ABUSEIPDB_KEY_FILE = lib.optionalString cfg.apiKeyConfigured config.sops.secrets."abuseipdb-api-key".path;
        ABUSEIPDB_STATE_DIR = stateDir;
        ABUSEIPDB_ROUTES_FILE = routesFile;
        ABUSEIPDB_PROM = "${textfileDir}/abuseipdb_blackhole.prom";
        ABUSEIPDB_MIN_CONFIDENCE = toString cfg.minConfidence;
        ABUSEIPDB_MAX_PREFIXES = toString cfg.maxPrefixes;
        ABUSEIPDB_ALLOWLIST = lib.concatStringsSep " " cfg.allowlist;
        ABUSEIPDB_ROUTER_EXPECTED = if cfg.routerConfigured then "1" else "0";
        ABUSEIPDB_BIRD_CONF = "/etc/bird/bird.conf";
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = syncScript;
        StateDirectory = "abuseipdb-blackhole";
        StateDirectoryMode = "0750";
      };
    };

    # A Standard (free) AbuseIPDB account may download the blacklist 5 times a day.
    # Not Persistent: a catch-up run must not fire during boot or a switch.
    systemd.timers.abuseipdb-blackhole-sync = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 01,07,13,19:15:00";
        RandomizedDelaySec = "20min";
        Persistent = false;
      };
    };

    # BGP session state for the metrics between syncs.
    systemd.services.abuseipdb-blackhole-bgp-state = {
      description = "Export BIRD's BGP session state to Astracap";
      after = [ "bird.service" ];
      path = [ config.services.bird.package ];
      environment = {
        ABUSEIPDB_PROM_BGP = "${textfileDir}/abuseipdb_blackhole_bgp.prom";
        ABUSEIPDB_ROUTER_EXPECTED = if cfg.routerConfigured then "1" else "0";
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${syncScript} --bgp-state-only";
      };
    };
    systemd.timers.abuseipdb-blackhole-bgp-state = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "1min";
      };
    };
  };
}
