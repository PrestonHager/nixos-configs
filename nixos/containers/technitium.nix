{ pkgs, ... }:

let
  technitiumVersion = "15.2.0";
  dataRoot = "/stor/technitium";
  upstreamRelayHost = "10.88.0.1";
  upstreamRelayPort = 53;
  technitiumDnsPort = 5353;
  adminPasswordFile = "${dataRoot}/secrets/admin-password";
in
{
  imports = [ ./technitium-zones.nix ];

  systemd.tmpfiles.rules = [
    "d ${dataRoot} 0755 root root -"
    "d ${dataRoot}/logs 0755 root root -"
    "d ${dataRoot}/secrets 0700 root root -"
  ];

  virtualisation.oci-containers.containers.technitium = {
    autoStart = true;
    image = "docker.io/technitium/dns-server:${technitiumVersion}";
    ports = [
      "127.0.0.1:${toString technitiumDnsPort}:53/udp"
      "127.0.0.1:${toString technitiumDnsPort}:53/tcp"
      "127.0.0.1:5380:5380/tcp"
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
    };
    volumes = [
      "${dataRoot}:/etc/dns"
      "${dataRoot}/logs:/var/log/technitium/dns"
      "${adminPasswordFile}:/etc/technitium/admin-password:ro"
    ];
  };

  # LanCache runs in a podman pod; its loopback is not the host loopback. Relay
  # podman-bridge :53 to Technitium on 127.0.0.1:5353 (not exposed on bond0).
  systemd.services.technitium-upstream-relay = {
    description = "Relay DNS from podman bridge to Technitium on loopback";
    after = [ "podman.service" "podman-technitium.service" "network-online.target" ];
    wants = [ "podman-technitium.service" "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = "5s";
      ExecStart = pkgs.writeShellScript "technitium-upstream-relay" ''
        set -euo pipefail
        exec ${pkgs.socat}/bin/socat \
          UDP4-LISTEN:${toString upstreamRelayPort},bind=${upstreamRelayHost},reuseaddr,fork \
          UDP4:127.0.0.1:${toString technitiumDnsPort}
      '';
    };
  };

  systemd.services.technitium-upstream-relay-tcp = {
    description = "Relay DNS (TCP) from podman bridge to Technitium on loopback";
    after = [ "podman.service" "podman-technitium.service" "network-online.target" ];
    wants = [ "podman-technitium.service" "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = "5s";
      ExecStart = pkgs.writeShellScript "technitium-upstream-relay-tcp" ''
        set -euo pipefail
        exec ${pkgs.socat}/bin/socat \
          TCP4-LISTEN:${toString upstreamRelayPort},bind=${upstreamRelayHost},reuseaddr,fork \
          TCP4:127.0.0.1:${toString technitiumDnsPort}
      '';
    };
  };
}