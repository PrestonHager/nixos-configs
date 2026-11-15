{ config, pkgs, ... }:

let
  # bond0 is the LACP aggregate that actually carries 192.168.5.0/24.
  # eno1/eno3 are only its members, so routing egress never selects them
  # and the MASQUERADE/FORWARD rules below never matched anything.
  lanIfs = [ "bond0" ];

  shared-script = ''
    set -euo pipefail
    set -x

    CONTAINER_NAME="wg-portal"
    LAN_IFS=(${builtins.concatStringsSep " " lanIfs})

    PID=$("${pkgs.podman}/bin/podman" inspect -f '{{.State.Pid}}' "$CONTAINER_NAME")

    NETNS_NAME="wgportalns"
    mkdir -p /var/run/netns
    ln -sf /proc/$PID/ns/net /var/run/netns/$NETNS_NAME

    # container interface index
    IDX=$(ip netns exec $NETNS_NAME cat /sys/class/net/eth0/iflink)

    # host veth
    VETH=$(ip link | awk -v idx=$IDX '$1 == idx ":" {print $2}' | tr -d ':')
    # Strip the @ifXXX suffix if present
    VETH=''${VETH%@*}

    if [ -z "$VETH" ]; then
      echo "Error: could not determine veth for container $CONTAINER_NAME" >&2
      rm -f /var/run/netns/$NETNS_NAME
      exit 1
    fi

    # cleanup temporary netns symlink
    rm -f /var/run/netns/$NETNS_NAME

    # The veth is a port of the podman bridge, so L3 only ever sees the bridge
    # (podman0) as the interface: "-i/-o $VETH" iptables rules never match, and
    # a "dev $VETH" route makes the host ARP for each VPN client address on the
    # veth, which the container never answers -- every LAN reply to a VPN
    # client was dropped. Route the tunnel subnet via the container's IP.
    BRIDGE=$(basename "$(readlink /sys/class/net/$VETH/master)")
    CIP=$("${pkgs.podman}/bin/podman" inspect -f '{{.NetworkSettings.IPAddress}}' "$CONTAINER_NAME")

    if [ -z "$BRIDGE" ] || [ -z "$CIP" ]; then
      echo "Error: could not determine bridge/IP for container $CONTAINER_NAME" >&2
      exit 1
    fi
  '';

  post-up-script = pkgs.writeShellScript "wg-portal-postup" ''
    ${shared-script}

    echo "Setting up routing for container ''${CONTAINER_NAME} via ''${CIP} on ''${BRIDGE}"

    # Route WireGuard subnet via the container
    ip route replace 192.168.20.0/24 via ''${CIP} dev ''${BRIDGE}

    for LAN_IF in ''${LAN_IFS[@]}; do
      # Forwarding rules (add if missing). iptables -C, not a grep of
      # iptables-save: the save output reorders matches (-d before -i).
      iptables -C FORWARD -s 192.168.20.0/24 -o $LAN_IF -j ACCEPT 2>/dev/null \
        || iptables -A FORWARD -s 192.168.20.0/24 -o $LAN_IF -j ACCEPT

      iptables -C FORWARD -i $LAN_IF -d 192.168.20.0/24 -j ACCEPT 2>/dev/null \
        || iptables -A FORWARD -i $LAN_IF -d 192.168.20.0/24 -j ACCEPT

      # NAT rules (add if missing)
      iptables -t nat -C POSTROUTING -s 192.168.20.0/24 -o $LAN_IF -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s 192.168.20.0/24 -o $LAN_IF -j MASQUERADE
    done
  '';

  cleanup-script = pkgs.writeShellScript "wg-portal-cleanup" ''
    ${shared-script}

    echo "Cleaning up routing for container ''${CONTAINER_NAME} via ''${CIP} on ''${BRIDGE}"

    # Remove route
    ip route del 192.168.20.0/24 2>/dev/null || true

    for LAN_IF in ''${LAN_IFS[@]}; do
      # Remove forwarding rules (only if exist)
      while iptables -D FORWARD -s 192.168.20.0/24 -o $LAN_IF -j ACCEPT 2>/dev/null; do :; done
      while iptables -D FORWARD -i $LAN_IF -d 192.168.20.0/24 -j ACCEPT 2>/dev/null; do :; done

      # Remove NAT rules (only if exist)
      while iptables -t nat -D POSTROUTING -s 192.168.20.0/24 -o $LAN_IF -j MASQUERADE 2>/dev/null; do :; done
    done
  '';

in {
  systemd.services."wg-portal-sidecar" = {
    description = "Routing + firewall sidecar for WireGuard Podman container";
    after = [
      "podman-wg-portal.service"
      # nixos-fw.service is restarted on every activation and rebuilds the
      # nat/filter tables from scratch via iptables-restore, which silently
      # drops the MASQUERADE/FORWARD rules installed below. Order after it and
      # tie it to it so a firewall reload re-runs this oneshot and restores
      # them; otherwise VPN routing breaks after every rebuild until the
      # service is restarted by hand.
      "nixos-fw.service"
    ];
    requires = [ "podman-wg-portal.service" ];
    partOf = [
      "podman-wg-portal.service"
      "nixos-fw.service"
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      ExecStart = [ post-up-script ];
      ExecStop  = [ cleanup-script ];

      Environment = [ "PATH=${pkgs.podman}/bin:${pkgs.iptables}/bin:/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin" ];
    };

    wantedBy = [ "multi-user.target" ];
  };
}


