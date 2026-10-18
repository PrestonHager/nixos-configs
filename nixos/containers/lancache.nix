# DEPRECATED: LanCache disabled in nixos/containers/default.nix (2026-06).
# Technitium serves primary LAN DNS on 192.168.5.5:53 — see technitium.nix and docs/dns-ace.md.
# Kept for reference if game CDN caching is re-enabled later.

{ config, pkgs, lib, ... }:

let
  lancacheIp = "192.168.5.5";
  dnsBindIp = "192.168.5.5";
  cacheRoot = "/stor/lancache";
  # ~1.4T free on /stor (ace); cap cache below total volume size
  cacheDiskSize = "1000g";
  lancacheEnv = {
    USE_GENERIC_CACHE = "true";
    LANCACHE_IP = lancacheIp;
    DNS_BIND_IP = dnsBindIp;
    # Technitium on host loopback :5353; reach from pod via podman0 relay (technitium.nix).
    UPSTREAM_DNS = "10.88.0.1";
    CACHE_ROOT = cacheRoot;
    CACHE_DISK_SIZE = cacheDiskSize;
    MIN_FREE_DISK = "10g";
    CACHE_INDEX_SIZE = "500m";
    CACHE_MAX_AGE = "3650d";
    TZ = "America/Chicago";
  };
in
{
  # House / game LAN DHCP DNS -> ace :53 (LanCache); non-cache queries -> Technitium -> 1.1.1.1.
  # HTTP/HTTPS published on 8084/8443 so Caddy keeps 192.168.5.5:80/443.
  # Monolithic handles HTTPS directly (upstream docker-compose deprecates sniproxy).
  networking.firewall.allowedUDPPorts = [ 53 ];
  networking.firewall.allowedTCPPorts = [ 53 ];

  systemd.tmpfiles.rules = [
    "d ${cacheRoot} 0775 root root -"
    "d ${cacheRoot}/cache 0775 root root -"
    "d ${cacheRoot}/logs 0775 root root -"
  ];

  systemd.services.pod-lancache = {
    description = "Podman pod for LanCache (monolithic + DNS)";
    wants = [ "network-online.target" "technitium-upstream-relay.service" "technitium-upstream-relay-tcp.service" ];
    after = [ "network-online.target" "technitium-upstream-relay.service" "technitium-upstream-relay-tcp.service" ];
    requiredBy = [
      "podman-lancache.service"
      "podman-lancache-dns.service"
    ];
    unitConfig.RequiresMountsFor = "/run/containers /stor";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "pod-lancache-create" ''
        set -euo pipefail
        if ! ${pkgs.podman}/bin/podman pod exists lancache; then
          ${pkgs.podman}/bin/podman pod create \
            --name lancache \
            --share net \
            -p ${dnsBindIp}:53:53/udp \
            -p ${dnsBindIp}:53:53/tcp \
            -p 8084:80/tcp \
            -p 8443:443/tcp \
            --memory 4G --cpus 0
        fi
      '';
    };
    path = [ pkgs.podman ];
  };

  virtualisation.oci-containers.containers.lancache = {
    autoStart = true;
    image = "docker.io/lancachenet/monolithic:latest";
    extraOptions = [ "--pod=lancache" ];
    environment = lancacheEnv;
    volumes = [
      "${cacheRoot}/cache:/data/cache"
      "${cacheRoot}/logs:/data/logs"
    ];
  };

  virtualisation.oci-containers.containers.lancache-dns = {
    autoStart = true;
    image = "docker.io/lancachenet/lancache-dns:latest";
    extraOptions = [ "--pod=lancache" ];
    environment = lancacheEnv;
  };
}

