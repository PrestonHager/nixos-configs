{ pkgs, ... }:

let
  technitiumVersion = "15.4.0";
  dataRoot = "/stor/technitium";
  technitiumDnsIp = "192.168.5.5";
  technitiumDnsPort = 5353;
  dohBackendPort = 8053;
  dotPort = 853;
  adminPasswordFile = "${dataRoot}/secrets/admin-password";
in
{
  imports = [
    ./technitium-zones.nix
    ./technitium-protocols.nix
    ./technitium-sso.nix
  ];

  # Primary LAN DNS: Technitium on bond0 :53 (LanCache removed — it slowed resolution).
  networking.firewall.allowedUDPPorts = [ 53 ];
  networking.firewall.allowedTCPPorts = [ 53 ];

  systemd.tmpfiles.rules = [
    "d ${dataRoot} 0755 root root -"
    "d ${dataRoot}/logs 0755 root root -"
    "d ${dataRoot}/secrets 0700 root root -"
  ];

  virtualisation.oci-containers.containers.technitium = {
    autoStart = true;
    image = "docker.io/technitium/dns-server:${technitiumVersion}";
    ports = [
      "${technitiumDnsIp}:53:53/udp"
      "${technitiumDnsIp}:53:53/tcp"
      "127.0.0.1:${toString technitiumDnsPort}:53/udp"
      "127.0.0.1:${toString technitiumDnsPort}:53/tcp"
      "127.0.0.1:5380:5380/tcp"
      # Admin API reachable from podman containers via host.containers.internal
      # (pterodactyl dnsrecords extension). Gateway IP only — not exposed on LAN.
      "10.88.0.1:5380:5380/tcp"
      # DNS-over-HTTP backend for Caddy-terminated DoH (RFC 8484 /dns-query).
      "127.0.0.1:${toString dohBackendPort}:${toString dohBackendPort}/tcp"
      # Native DNS-over-TLS (Caddy LE cert exported to PKCS#12).
      "${toString dotPort}:${toString dotPort}/tcp"
    ];
    environment = {
      # Primary domain for this server (not the automatic ip1.lc1.* style names).
      DNS_SERVER_DOMAIN = "internal.prestonhager.com";
      DNS_SERVER_ADMIN_PASSWORD_FILE = "/etc/technitium/admin-password";
      DNS_SERVER_FORWARDERS = "1.1.1.1, 1.0.0.1";
      DNS_SERVER_FORWARDER_PROTOCOL = "Udp";
      DNS_SERVER_RECURSION = "AllowOnlyForPrivateNetworks";
      DNS_SERVER_LOG_FOLDER_PATH = "/var/log/technitium/dns";
      DNS_SERVER_LOG_USING_LOCAL_TIME = "true";
      # Honored only on first boot (existing /etc/dns config); technitium-sync-protocols applies via API.
      DNS_SERVER_OPTIONAL_PROTOCOL_DNS_OVER_HTTP = "true";
    };
    volumes = [
      "${dataRoot}:/etc/dns"
      "${dataRoot}/logs:/var/log/technitium/dns"
      "${dataRoot}/certs:/etc/dns/certs:ro"
      "${adminPasswordFile}:/etc/technitium/admin-password:ro"
    ];
  };
}
