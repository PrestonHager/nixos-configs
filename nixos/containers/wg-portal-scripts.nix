{ config, pkgs, ... }:

let
  lanIfs = [ "eno1" "eno3" ];

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
  '';

  post-up-script = pkgs.writeShellScript "wg-portal-postup" ''
    ${shared-script}

    echo "Setting up routing for container ''${CONTAINER_NAME} on ''${VETH}"

    # Route WireGuard subnet via container veth
    ip route replace 192.168.20.0/24 dev ''${VETH}

    for LAN_IF in ''${LAN_IFS[@]}; do
      # Forwarding rules (add if missing)
      if ! iptables-save | grep -F -- "-A FORWARD -i ''${VETH} -o $LAN_IF -j ACCEPT" >/dev/null; then
        iptables -A FORWARD -i ''${VETH} -o $LAN_IF -j ACCEPT
      fi

      if ! iptables-save | grep -F -- "-A FORWARD -i $LAN_IF -o ''${VETH} -j ACCEPT" >/dev/null; then
        iptables -A FORWARD -i $LAN_IF -o ''${VETH} -j ACCEPT
      fi

      # NAT rules (add if missing)
      if ! iptables-save -t nat | grep -F -- "-A POSTROUTING -s 192.168.20.0/24 -o $LAN_IF -j MASQUERADE" >/dev/null; then
        iptables -t nat -A POSTROUTING -s 192.168.20.0/24 -o $LAN_IF -j MASQUERADE
      fi
    done
  '';

  cleanup-script = pkgs.writeShellScript "wg-portal-cleanup" ''
    ${shared-script}

    echo "Cleaning up routing for container ''${CONTAINER_NAME} on ''${VETH}"

    # Remove route
    ip route del 192.168.20.0/24 dev ''${VETH} 2>/dev/null || true

    for LAN_IF in ''${LAN_IFS[@]}; do
      # Remove forwarding rules (only if exist)
      while iptables-save | grep -F -- "-A FORWARD -i ''${VETH} -o $LAN_IF -j ACCEPT" >/dev/null; do
        iptables -D FORWARD -i ''${VETH} -o $LAN_IF -j ACCEPT
      done

      while iptables-save | grep -F -- "-A FORWARD -i $LAN_IF -o ''${VETH} -j ACCEPT" >/dev/null; do
        iptables -D FORWARD -i $LAN_IF -o ''${VETH} -j ACCEPT
      done

      # Remove NAT rules (only if exist)
      while iptables-save -t nat | grep -F -- "-A POSTROUTING -s 192.168.20.0/24 -o $LAN_IF -j MASQUERADE" >/dev/null; do
        iptables -t nat -D POSTROUTING -s 192.168.20.0/24 -o $LAN_IF -j MASQUERADE
      done
    done
  '';

in {
  systemd.services."wg-portal-sidecar" = {
    description = "Routing + firewall sidecar for WireGuard Podman container";
    after = [ "podman-wg-portal.service" ];
    requires = [ "podman-wg-portal.service" ];
    partOf = [ "podman-wg-portal.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      ExecStart = [ post-up-script ];
      ExecStop  = [ cleanup-script ];

      Environment = "\"PATH=${pkgs.podman}/bin:${pkgs.iptables}/bin:/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin\"";
    };

    wantedBy = [ "multi-user.target" ];
  };
}


