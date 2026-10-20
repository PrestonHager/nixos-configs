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
  coolifyPubkey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBCfJJj4EyDq69eyD8CYWv7ek44QbLrZ41ZNMIfUlrVq coolify@ace";
  # Docker-published ports are DNATed and reach containers through FORWARD,
  # so nixos-fw (INPUT) never sees them. DOCKER-USER is Docker's hook for that.
  # Match only connections addressed to this host itself: container egress also
  # passes through FORWARD, and without --ctorigdst this dropped every
  # outbound plain-HTTP request (apt, egg installers, Coolify builds).
  dropNonAce = "-p tcp -m conntrack --ctorigdst ${cfg.address} --ctorigdstport 80 --ctdir ORIGINAL ! -s ${aceIp} -j DROP";
  # The first version of the rule (2026-10-18) lacked --ctorigdst.
  oldDropNonAce = "-p tcp -m conntrack --ctorigdstport 80 --ctdir ORIGINAL ! -s ${aceIp} -j DROP";
in
{
  options.homelab.coolifyNode.address = lib.mkOption {
    type = lib.types.str;
    example = "192.168.5.15";
    description = ''
      This host's LAN IPv4 address. The DOCKER-USER rule drops port 80
      connections addressed to it unless they come from ace, so only ace's
      Caddy can reach the Coolify proxy.
    '';
  };

  config = {
    users.users.root.openssh.authorizedKeys.keys = [ coolifyPubkey ];

    # Coolify's server validation requires git, curl and jq on the host.
    environment.systemPackages = with pkgs; [ git curl jq ];

    networking.firewall.extraCommands = ''
      iptables -N DOCKER-USER 2>/dev/null || true
      iptables -D DOCKER-USER ${oldDropNonAce} 2>/dev/null || true
      iptables -D DOCKER-USER ${dropNonAce} 2>/dev/null || true
      iptables -I DOCKER-USER ${dropNonAce}
    '';
    networking.firewall.extraStopCommands = ''
      iptables -D DOCKER-USER ${dropNonAce} 2>/dev/null || true
    '';
  };
}
