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

  environment = {
    PODMAN = "${pkgs.podman}/bin/podman";
    SSH = "${pkgs.openssh}/bin/ssh";
    # Coolify server IPs whose published ports are forwarded from the WAN.
    COOLIFY_EDGE_NODES = marsIp;
    # Hostnames the catch-all may get certificates for. Caddy issues them with
    # the Cloudflare DNS-01 token (acme-dns.nix), so only zones on that
    # Cloudflare account work. *.apps.prestonhager.com has its own wildcard site.
    COOLIFY_EDGE_ZONES = "prestonhager.com";
    # SSH (router + hosts), DNS, HTTP(S) and DoT stay with ace / the router.
    COOLIFY_EDGE_BLOCKED_PORTS = "22 53 80 443 853 3380";
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

  # Shared by the two timer-driven jobs.
  syncUnit = description: job: extraAfter: {
    inherit description environment;
    after = [ "podman-coolify-db.service" "network-online.target" ] ++ extraAfter;
    wants = [ "network-online.target" ];
    requires = [ "podman-coolify-db.service" ];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "coolify-edge";
      StateDirectoryMode = "0700";
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
    serviceConfig = {
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
