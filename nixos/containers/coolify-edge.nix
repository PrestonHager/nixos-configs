# coolify-edge: sends traffic that ace does not serve itself to Coolify's apps
# on the deploy server (mars). Script: ./coolify/edge-sync.py; docs/coolify-ace.md.
#
#   coolify-edge-ask        Caddy's on-demand TLS "ask" endpoint on
#                           127.0.0.1:9180. Says yes only to hostnames an app,
#                           preview or service in Coolify uses, inside
#                           `zones`. nixos/caddy/coolify.nix has the catch-all
#                           site that asks it and proxies to the node's :80.
#   coolify-edge-nat        (timer, every minute) mirrors the host ports that
#                           Coolify apps and public databases publish on the
#                           managed nodes as static NAT on Astracap, through the
#                           Pterodactyl port-forward key (user pterofwd).
#   coolify-edge-dns        (timer, every minute) CNAMEs for Coolify hostnames
#                           in the zones: Cloudflare -> ip1.lc1… (with the
#                           Caddy DNS-01 token) and Technitium -> ace for the
#                           LAN. *.apps names are covered by the wildcard.
#
# Guard rails (environment below, details in edge-sync.py): only the Root
# Team's apps; ace's own hostnames and names with reserved labels (login,
# admin, vault, ...) are never accepted; databases are not forwarded unless
# opted in; at most COOLIFY_EDGE_MAX_PORTS ports and no range wider than
# COOLIFY_EDGE_MAX_RANGE; every router/DNS change is logged at warning level.
# The ask endpoint caches misses so unknown SNI floods do not hit the DB.
#
# All read Coolify's database with `podman exec coolify-db psql`; nothing on
# the Coolify side has to be configured. The NAT and DNS units only call the
# router / DNS APIs when the wanted set changed or every 15 minutes, which also
# restores NAT after a router reboot (running-config only, like the Pterodactyl
# extension's) and LAN records after technitium-sync-zones re-imports the zone.
{ config, lib, pkgs, ... }:

let
  marsIp = "192.168.5.15";
  askPort = 9180;
  routerKey = config.sops.secrets."pterodactyl-router-ssh-key".path;
  routerSshConfig = pkgs.writeText "coolify-edge-router-ssh-config" ''
    Host astracap
      HostName 192.168.5.1
      User pterofwd
      IdentityFile ${routerKey}
      IdentitiesOnly yes
      IdentityAgent none
      KexAlgorithms +diffie-hellman-group14-sha1
      HostKeyAlgorithms +ssh-rsa
      PubkeyAcceptedAlgorithms +ssh-rsa
      UserKnownHostsFile /var/lib/coolify-edge/known_hosts
      StrictHostKeyChecking accept-new
  '';
  script = ./coolify/edge-sync.py;
  python = "${pkgs.python3}/bin/python3";

  # Every hostname ace's Caddy serves itself (and its aliases). Coolify must
  # never get a certificate, a CNAME or traffic for one of these.
  ownHosts = lib.unique (lib.filter (h: h != "" && !(lib.hasInfix "*" h) && !(lib.hasInfix ":" h))
    (map (h: lib.removePrefix "https://" (lib.removePrefix "http://" h))
      (lib.concatLists (lib.mapAttrsToList (name: vh: [ name ] ++ (vh.serverAliases or [ ]))
        config.services.caddy.virtualHosts))));

  environment = {
    PODMAN = "${pkgs.podman}/bin/podman";
    SSH = "${pkgs.openssh}/bin/ssh";
    # Coolify server IPs whose published ports are forwarded from the WAN.
    COOLIFY_EDGE_NODES = marsIp;
    # Only the Root Team's apps (team 0) are routed; with self-registration
    # off (coolify/instance-settings.php) it is the only team anyway.
    COOLIFY_EDGE_TEAM_IDS = "0";
    # Hostnames the catch-all may get certificates for. Caddy issues them with
    # the Cloudflare DNS-01 token (acme-dns.nix), so only zones on that
    # Cloudflare account work. *.apps.prestonhager.com has its own wildcard site.
    COOLIFY_EDGE_ZONES = "prestonhager.com";
    # Never routed to Coolify: ace's own vhosts, and any name with one of these
    # labels below the zone (so an app cannot claim e.g. login.prestonhager.com
    # or admin.foo.prestonhager.com for phishing).
    COOLIFY_EDGE_DENY_HOSTS = lib.concatStringsSep " " ownHosts;
    COOLIFY_EDGE_DENY_LABELS = lib.concatStringsSep " " [
      "login" "sso" "auth" "oauth" "oidc" "id" "account" "accounts"
      "vault" "admin" "mail" "smtp" "imap" "mx" "autodiscover" "autoconfig"
      "www" "zitadel" "panel" "cloud" "grafana" "prometheus" "metrics"
      "coolify" "dns" "ns" "ns1" "ns2" "wg" "vpn" "update" "matrix" "git"
      "ace" "mars" "crux" "elara" "lc1" "internal" "ip1" "acme"
    ];
    # Databases are not forwarded from the WAN unless this is "1".
    COOLIFY_EDGE_FORWARD_PUBLIC_DATABASES = "0";
    # Refuse to sync when more than this many ports would be forwarded, and
    # skip any single range wider than COOLIFY_EDGE_MAX_RANGE ports.
    COOLIFY_EDGE_MAX_PORTS = "50";
    COOLIFY_EDGE_MAX_RANGE = "20";
    # Never forwarded: SSH, DNS, HTTP(S), DoT and other ports that belong to
    # ace / the router or are common attack surface (mail, SMB, NFS, RDP,
    # SNMP, LDAP, Technitium, Prometheus).
    COOLIFY_EDGE_BLOCKED_PORTS = lib.concatStringsSep " " (map toString [
      21 22 23 25 53 80 111 135 137 138 139 161 162 389 443 445 465 587 636
      853 993 995 2049 3380 3389 5380 9090 9100
    ]);
    COOLIFY_EDGE_WAN_INTERFACE = "GigabitEthernet0/0";
    COOLIFY_EDGE_ROUTER_SSH_CONFIG = "${routerSshConfig}";
    COOLIFY_EDGE_ROUTER_HOST = "astracap";
    COOLIFY_EDGE_STATE = "/var/lib/coolify-edge/nat.json";
    # DNS for custom app hostnames (same targets as the hand-made records).
    COOLIFY_EDGE_DNS_STATE = "/var/lib/coolify-edge/dns.json";
    COOLIFY_EDGE_DNS_SKIP = "apps.prestonhager.com";
    COOLIFY_EDGE_PUBLIC_TARGET = "ip1.lc1.nm.us.prestonhager.com";
    COOLIFY_EDGE_LAN_TARGET = "ace.internal.prestonhager.com";
    COOLIFY_EDGE_DNS_COMMENT = "managed by coolify-edge (nixos-configs)";
    COOLIFY_EDGE_TECHNITIUM_API = "http://127.0.0.1:5380";
    COOLIFY_EDGE_TECHNITIUM_PASSWORD_FILE = "/stor/technitium/secrets/admin-password";
  };

  # Sandbox for all three units. They run as root because they need
  # `podman exec` into coolify-db (root's container storage) and the router
  # key; the rest of the system is read-only to them. Podman writes its
  # exec-session state under /var/lib/containers and /run.
  hardening = {
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    ReadWritePaths = [ "-/var/lib/containers" "-/run/containers" "-/run/libpod" "-/run/crun" ];
    StateDirectory = "coolify-edge";
    StateDirectoryMode = "0700";
    RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK" ];
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectClock = true;
    RestrictRealtime = true;
  };

  # Shared by the two timer-driven jobs.
  syncUnit = description: job: extraAfter: {
    inherit description environment;
    after = [ "podman-coolify-db.service" "network-online.target" ] ++ extraAfter;
    wants = [ "network-online.target" ];
    requires = [ "podman-coolify-db.service" ];
    serviceConfig = hardening // {
      Type = "oneshot";
      TimeoutStartSec = "3min";
      ExecStart = "${python} ${script} ${job}";
    };
  };
  everyMinute = description: {
    inherit description;
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "1min";
    };
  };
in
{
  systemd.services.coolify-edge-ask = {
    description = "Caddy on-demand TLS ask endpoint for Coolify app domains";
    after = [ "podman-coolify-db.service" ];
    wants = [ "podman-coolify-db.service" ];
    before = [ "caddy.service" ];
    wantedBy = [ "multi-user.target" ];
    inherit environment;
    serviceConfig = hardening // {
      ExecStart = "${python} ${script} serve --listen 127.0.0.1 --port ${toString askPort}";
      Restart = "always";
      RestartSec = 5;
    };
  };

  systemd.services.coolify-edge-nat =
    syncUnit "Mirror Coolify published ports as static NAT on Astracap" "nat" [ ];
  systemd.timers.coolify-edge-nat = everyMinute "Sync Coolify published ports to Astracap every minute";

  systemd.services.coolify-edge-dns = lib.recursiveUpdate
    (syncUnit "CNAMEs in Cloudflare and Technitium for Coolify app hostnames" "dns"
      [ "podman-technitium.service" "technitium-sync-zones.service" ])
    {
      # CLOUDFLARE_API_TOKEN: the scoped DNS-edit token Caddy uses for DNS-01.
      serviceConfig.EnvironmentFile = config.sops.secrets."cloudflare-acme-env".path;
    };
  systemd.timers.coolify-edge-dns = everyMinute "Sync Coolify app hostnames to DNS every minute";

  # The catch-all site in nixos/caddy/coolify.nix asks here before issuing.
  services.caddy.globalConfig = lib.mkAfter ''
    on_demand_tls {
      ask http://127.0.0.1:${toString askPort}/ask
    }
  '';
}
