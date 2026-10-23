{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
in
{
  sops.secrets = {
    "wg-portal-config" = {
      sopsFile = "${sops-path}/secrets/containers/wg-portal-config.yaml";
    };
  };

  imports = [
    ./wg-portal-scripts.nix
  ];

  # Create the wireguard user and group
  users.users = {
    wireguard = {
      isSystemUser = true;
      group = "wireguard";
    };
    wg-portal = {
      isSystemUser = true;
      description = "Wireguard Portal";
      group = "wg-portal";
      extraGroups = [ "wireguard" ];
    };
  };
  users.groups = {
    wireguard = {};
    wg-portal = {};
  };

  # open the firewall for wireguard port
  networking.firewall.allowedUDPPorts = [
    51825
  ];

  # Setup NAT forwarding from the wireguard interface to the local network.
  #networking.firewall.extraCommands = ''
  #  iptables -t nat -A POSTROUTING -s 192.168.20.0/24 -o eno1 -j MASQUERADE
  #  iptables -t nat -A POSTROUTING -s 192.168.20.0/24 -o eno3 -j MASQUERADE
  #  iptables -A FORWARD -s 192.168.20.0/24 -d 192.168.8.0/24 -j ACCEPT
  #  iptables -A FORWARD -s 192.168.8.0/24 -d 192.168.20.0/24 -j ACCEPT
  #'';

  # wg-portal creates wg0 itself; load the module on the host instead of granting
  # the container CAP_SYS_MODULE.
  boot.kernelModules = [ "wireguard" ];

  # Create the data directory. wg0.conf holds the interface PrivateKey: keep it 0600.
  systemd.tmpfiles.rules = [
    "d /srv/wireguard/etc 0770 wireguard wireguard -"
    "z /srv/wireguard/etc/wg0.conf 0600 root root -"
    "d /srv/wireguard/data 0770 wireguard wireguard -"
  ];

  # Define the container
  virtualisation.oci-containers.containers."wg-portal" = {
    autoStart = true;

    # Add wireguard and web portal ports
    ports = [
      "51825:51825/udp"
      # Web UI: Caddy only. Metrics: Caddy plus Prometheus via the podman0 gateway.
      # Not 0.0.0.0: netavark DNATs ahead of nixos-fw.
      "127.0.0.1:8888:8888/tcp"
      "127.0.0.1:8787:8787/tcp"
      "10.88.0.1:8787:8787/tcp"
    ];

    # Add network admin capabilities and use the host network
    extraOptions = [
      #"--network=host"
      "--cap-add=NET_ADMIN"
      # No SYS_MODULE: the wireguard module is loaded by the host (boot.kernelModules
      # above), so the container cannot load arbitrary kernel modules.
      #"--cap-add=NET_RAW"
      # Host /etc/hosts maps the vhost to 127.0.0.1, which is the container's own
      # loopback; point it at Caddy on the host so the Zitadel OIDC login works.
      "--add-host=zitadel.prestonhager.com:host-gateway"
      # The image declares VOLUME /app/config; only config.yaml is bind-mounted,
      # so every run created an anonymous volume. Back image volumes with tmpfs.
      "--image-volume=tmpfs"
    ];

    # User and group to run the container as
    #user = "wg-portal:wg-portal";
    user = "root:root";

    # Volumes to make persistent in the host/container
    volumes = [
      "/etc/passwd:/etc/passwd:ro"
      "/etc/group:/etc/group:ro"
      "/srv/wireguard/etc/:/etc/wireguard/"
      "/srv/wireguard/data/:/app/data"
      "${config.sops.secrets."wg-portal-config".path}:/app/config/config.yaml:ro"
    ];

    environment = {
    };

    # Finally, the wireguard image and version
    image = "docker.io/wgportal/wg-portal:v2.3.1";
  };

  # wg-portal (root in the container) rewrites wg0.conf when peers change, and it has
  # been written world-readable before. Re-tighten it whenever it changes, not only at
  # boot/activation via tmpfiles.
  systemd.paths.wg-portal-conf-perms = {
    wantedBy = [ "multi-user.target" ];
    pathConfig.PathChanged = "/srv/wireguard/etc/wg0.conf";
  };
  systemd.services.wg-portal-conf-perms = {
    description = "Restrict wg0.conf (WireGuard private key) to root";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "-${pkgs.coreutils}/bin/chmod 0600 /srv/wireguard/etc/wg0.conf";
    };
  };
}
