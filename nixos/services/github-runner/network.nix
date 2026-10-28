# Dedicated, egress-filtered Podman network for GitHub Actions runner containers.
#
# Imported and enabled by nixos/services/github-runner.nix.
#
# Runner jobs execute code from repositories that other people can push to, as
# root inside the container. They must not be able to reach anything on the
# host or the LAN, so runners do not share the default `podman` network
# (podman0, 10.88.0.0/16) with the host's other pods. Instead:
#
#   * A separate bridge (`interface`, default ghrunner0) on its own subnet,
#     created with `isolate=true` so netavark also blocks it from other Podman
#     networks. DNS on the bridge gateway is disabled.
#   * Containers resolve through public resolvers (`dns`), because the host's
#     resolvers (Technitium on 192.168.5.5, Tailscale 100.100.100.100) are on
#     blocked ranges.
#   * raw/PREROUTING drops every packet from the bridge whose destination is a
#     local address of the host or any private, CGNAT, link-local, loopback,
#     multicast or reserved range. raw runs before routing, conntrack and
#     netavark's own FORWARD rules, so rule ordering against netavark,
#     Tailscale or libvirt cannot reopen a hole.
#   * The same drops sit at the top of FORWARD, and nixos-fw (INPUT) refuses
#     everything from the bridge ahead of the globally allowed ports (22, 53,
#     80, 443, ...). IPv6 from the bridge is dropped outright (the network is
#     IPv4-only).
#
# The bridge must never be listed in networking.firewall.trustedInterfaces;
# an assertion enforces that.
#
# The rules are deliberately not removed on firewall stop/reload: they fail
# closed. Reload re-applies them idempotently.
{ config, lib, pkgs, ... }:

let
  cfg = config.homelab.github-runner-network;

  rawChain = "homelab-ghr-egress";
  fwdChain = "homelab-ghr-fwd";

  dropRules = table: chain: ''
    iptables -t ${table} -N ${chain} 2>/dev/null || true
    iptables -t ${table} -F ${chain}
    iptables -t ${table} -A ${chain} -m addrtype --dst-type LOCAL -j DROP
  '' + lib.concatMapStrings (cidr: ''
    iptables -t ${table} -A ${chain} -d ${cidr} -j DROP
  '') cfg.blockedDestinations;
in
{
  options.homelab.github-runner-network = {
    enable = lib.mkEnableOption "the egress-filtered Podman network for GitHub runner containers";

    name = lib.mkOption {
      type = lib.types.str;
      default = "ghrunner";
      description = "Podman network name.";
    };

    interface = lib.mkOption {
      type = lib.types.strMatching "[a-zA-Z0-9_-]{1,15}";
      default = "ghrunner0";
      description = "Host bridge interface for the network (max 15 chars).";
    };

    subnet = lib.mkOption {
      type = lib.types.str;
      default = "10.250.250.0/24";
      description = ''
        IPv4 subnet for the runner bridge. Chosen well away from Podman's
        automatic 10.88/10.89 allocations. Changing it requires removing the
        existing network (see docs/github-runner.md).
      '';
    };

    dns = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      default = [ "1.1.1.1" "9.9.9.9" ];
      description = "Public resolvers written into runner containers' resolv.conf.";
    };

    blockedDestinations = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "0.0.0.0/8"
        "10.0.0.0/8"
        "100.64.0.0/10"
        "127.0.0.0/8"
        "169.254.0.0/16"
        "172.16.0.0/12"
        "192.0.0.0/24"
        "192.0.2.0/24"
        "192.168.0.0/16"
        "198.18.0.0/15"
        "198.51.100.0/24"
        "203.0.113.0/24"
        "224.0.0.0/4"
        "240.0.0.0/4"
      ];
      description = ''
        IPv4 destinations runner containers may never reach. Any address that
        is local to the host is dropped in addition to these.
      '';
    };

    unit = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "github-runner-network.service";
      description = "systemd unit that creates the network; runner units order after it.";
    };

    podmanOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = [ "--network=${cfg.name}" "--dns-search=." ]
        ++ map (d: "--dns=${d}") cfg.dns;
      description = "extraOptions that attach a container to the runner network.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = !(lib.elem cfg.interface config.networking.firewall.trustedInterfaces);
      message = ''
        homelab.github-runner-network: ${cfg.interface} must not be in
        networking.firewall.trustedInterfaces; runner jobs are untrusted.
      '';
    }];

    systemd.services.github-runner-network = {
      description = "Create the egress-filtered Podman network for GitHub runners";
      wantedBy = [ "multi-user.target" ];
      after = [ "podman.socket" "firewall.service" ];
      wants = [ "firewall.service" ];
      path = [ pkgs.podman ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        want=${lib.escapeShellArg "${cfg.interface} ${cfg.subnet}"}
        if podman network exists ${lib.escapeShellArg cfg.name}; then
          got="$(podman network inspect ${lib.escapeShellArg cfg.name} \
            --format '{{.NetworkInterface}} {{range .Subnets}}{{.Subnet}}{{end}}')"
          if [ "$got" != "$want" ]; then
            echo "github-runner-network: ${cfg.name} is '$got', expected '$want'." >&2
            echo "Stop the runners and 'podman network rm ${cfg.name}', then restart this unit." >&2
            exit 1
          fi
          exit 0
        fi
        podman network create \
          --driver bridge \
          --interface-name ${lib.escapeShellArg cfg.interface} \
          --subnet ${lib.escapeShellArg cfg.subnet} \
          --disable-dns \
          --opt isolate=true \
          ${lib.escapeShellArg cfg.name}
      '';
    };

    # Runs inside firewall-start (iptables backend). Idempotent: chains are
    # flushed and jumps are deleted before being re-inserted at position 1.
    networking.firewall.extraCommands = lib.mkAfter ''
      # --- GitHub runner network (${cfg.interface}): internet egress only ---
      ${dropRules "raw" rawChain}
      iptables -t raw -D PREROUTING -i ${cfg.interface} -j ${rawChain} 2>/dev/null || true
      iptables -t raw -I PREROUTING 1 -i ${cfg.interface} -j ${rawChain}

      ${dropRules "filter" fwdChain}
      iptables -D FORWARD -i ${cfg.interface} -j ${fwdChain} 2>/dev/null || true
      iptables -I FORWARD 1 -i ${cfg.interface} -j ${fwdChain}

      # Nothing from the runner bridge is accepted by the host itself, ahead of
      # the globally allowed ports. nixos-fw is rebuilt on every reload.
      iptables -I nixos-fw 1 -i ${cfg.interface} -j nixos-fw-refuse
      if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -t raw -D PREROUTING -i ${cfg.interface} -j DROP 2>/dev/null || true
        ip6tables -t raw -I PREROUTING 1 -i ${cfg.interface} -j DROP
        ip6tables -I nixos-fw 1 -i ${cfg.interface} -j nixos-fw-refuse 2>/dev/null || true
      fi
    '';
  };
}
