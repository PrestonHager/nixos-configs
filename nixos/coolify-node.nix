# Coolify deploy server: lets the Coolify control plane on ace
# (nixos/containers/coolify.nix) deploy apps to this host's Docker.
#
# Coolify connects as root over SSH with its own key (the private half lives
# encrypted in Coolify's database, under Keys & Tokens). It runs its Traefik
# proxy here, published on port 80 only: TLS for app domains terminates on
# ace's Caddy, which forwards here (nixos/caddy/coolify.nix).
#
# Coolify does not list NixOS as a supported OS, so servers are registered
# with is_reachable/is_usable set directly (docs/coolify-ace.md). The host
# must enable virtualisation.docker itself (mars does in hosts/mars).
{ config, lib, pkgs, ... }:

let
  cfg = config.homelab.coolifyNode;
  aceIp = "192.168.5.5";
  # Coolify needs a shell (and a pty for its web terminal) but no forwarding,
  # and only ever connects from ace.
  coolifyPubkey =
    ''from="${aceIp}",no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBCfJJj4EyDq69eyD8CYWv7ek44QbLrZ41ZNMIfUlrVq coolify@ace'';

  # Inbound to published container ports.
  #
  # Docker-published ports are DNATed and reach containers through FORWARD, so
  # nixos-fw (INPUT) never sees them; DOCKER-USER is Docker's hook for that.
  # Everything arrives on the LAN interface: LAN clients with private source
  # addresses, and internet clients that coolify-edge port-forwards through
  # the router's static NAT, which keep their public source addresses. So:
  #   - replies to container-initiated connections pass;
  #   - ace may reach the Traefik proxy on port 80 (Caddy forwards app
  #     domains there);
  #   - any other new connection from a private, CGNAT/tailnet or link-local
  #     source is dropped, whatever local address or port it was sent to;
  #   - public sources reach whatever Coolify publishes (only coolify-edge's
  #     forwards can deliver them).
  ingress = "coolify-ingress";
  privateV4 = [ "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "100.64.0.0/10" "169.254.0.0/16" ];
  privateV6 = [ "fc00::/7" "fe80::/10" ];

  ingressSetup = ipt: privates: aceRule: ''
    ${ipt} -N DOCKER-USER 2>/dev/null || true
    ${ipt} -N ${ingress} 2>/dev/null || true
    ${ipt} -F ${ingress}
    ${ipt} -A ${ingress} ! -i ${cfg.lanInterface} -j RETURN
    ${ipt} -A ${ingress} -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
    ${aceRule}
    ${lib.concatMapStrings (s: "${ipt} -A ${ingress} -s ${s} -j DROP\n") privates}
    while ${ipt} -D DOCKER-USER -j ${ingress} 2>/dev/null; do :; done
    ${ipt} -I DOCKER-USER 1 -j ${ingress}
  '';
  ingressTeardown = ipt: ''
    while ${ipt} -D DOCKER-USER -j ${ingress} 2>/dev/null; do :; done
    ${ipt} -F ${ingress} 2>/dev/null || true
    ${ipt} -X ${ingress} 2>/dev/null || true
  '';

  # Earlier single-rule forms (2026-10-18 and 2026-10-20), removed on start.
  oldRules = [
    "-p tcp -m conntrack --ctorigdstport 80 --ctdir ORIGINAL ! -s ${aceIp} -j DROP"
    "-p tcp -m conntrack --ctorigdst ${cfg.address} --ctorigdstport 80 --ctdir ORIGINAL ! -s ${aceIp} -j DROP"
  ];
in
{
  options.homelab.coolifyNode = {
    address = lib.mkOption {
      type = lib.types.str;
      example = "192.168.5.15";
      description = "This host's LAN IPv4 address.";
    };
    lanInterface = lib.mkOption {
      type = lib.types.str;
      example = "eno1";
      description = ''
        The LAN interface. New connections arriving on it from private
        sources may reach published container ports only when they come from
        ace to port 80 (the Coolify proxy).
      '';
    };
  };

  config = {
    users.users.root.openssh.authorizedKeys.keys = [ coolifyPubkey ];

    # Coolify's server validation requires git, curl and jq on the host.
    environment.systemPackages = with pkgs; [ git curl jq ];

    # Outbound: app containers get the internet, not the LAN, the tailnet or
    # this host (nixos/security/container-egress.nix). Traefik reaches apps
    # over Docker networks (bridge to bridge), which stays allowed.
    homelab.security.containerEgress = {
      enable = true;
      bridges = [ "docker0" "br+" ];
      allow = [
        # Docker copies the host's resolvers (ace first) into containers on
        # the default bridge and forwards from its embedded DNS on the others.
        { address = aceIp; proto = "udp"; port = 53; }
        { address = aceIp; proto = "tcp"; port = 53; }
        # coolify-sentinel (default bridge) pushes metrics to
        # https://coolify.prestonhager.com, which split-horizon DNS resolves
        # to ace's Caddy. Only docker0: Coolify puts apps on its own networks.
        { address = aceIp; proto = "tcp"; port = 443; interface = "docker0"; }
      ];
    };

    networking.firewall.extraCommands = ''
      iptables -N DOCKER-USER 2>/dev/null || true
      ${lib.concatMapStrings (r: "iptables -D DOCKER-USER ${r} 2>/dev/null || true\n") oldRules}
      ${ingressSetup "iptables" privateV4
        "iptables -A ${ingress} -s ${aceIp} -p tcp -m conntrack --ctorigdstport 80 --ctdir ORIGINAL -j RETURN"}
      ${lib.optionalString config.networking.enableIPv6 (ingressSetup "ip6tables" privateV6 "")}
    '';
    networking.firewall.extraStopCommands = ''
      ${ingressTeardown "iptables"}
      ${lib.optionalString config.networking.enableIPv6 (ingressTeardown "ip6tables")}
    '';
  };
}
