# Keep Docker containers off the LAN.
#
# Docker masquerades container traffic to the host's own address and accepts
# everything leaving a container bridge (DOCKER-FORWARD `-i <bridge> -j
# ACCEPT`), so by default a container can open connections to every LAN host
# (router, switch, ace's NFS/Loki/SSH, other nodes) and, through the bridge
# gateway, to the host's own services. Game servers and Coolify apps only need
# the internet, so:
#
#   FORWARD (DOCKER-USER, which Docker evaluates before its own rules):
#     traffic from a container bridge to a private, CGNAT/tailnet, link-local
#     or ULA destination is dropped, unless it goes to another container bridge
#     (Docker's own rules decide that) or matches `allow`.
#   INPUT (nixos-fw):
#     new connections from a container bridge to the host itself are refused.
#
# Replies (RELATED,ESTABLISHED) always pass, so published ports keep working.
# Rules live in their own chains, rebuilt on every firewall (re)start, with a
# single jump from DOCKER-USER, so the setup is idempotent.
{ config, lib, ... }:

let
  cfg = config.homelab.security.containerEgress;

  dispatch = "homelab-docker-user";
  egress = "homelab-ctr-egress";
  drop = "homelab-ctr-drop";

  allowRule = ipt: a:
    "${ipt} -A ${egress}"
    + lib.optionalString (a.interface != null) " -i ${a.interface}"
    + " -d ${a.address} -p ${a.proto} --dport ${toString a.port} -j RETURN\n";

  isV6 = a: lib.hasInfix ":" a.address;

  setup = ipt: blocked: allows: ''
    ${ipt} -N DOCKER-USER 2>/dev/null || true
    for c in ${dispatch} ${egress} ${drop}; do
      ${ipt} -N "$c" 2>/dev/null || true
      ${ipt} -F "$c"
    done

    ${ipt} -A ${drop} -m limit --limit 6/min --limit-burst 20 -j LOG --log-level 4 --log-prefix "ctr-egress-drop: "
    ${ipt} -A ${drop} -j DROP

    ${ipt} -A ${dispatch} -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
    ${lib.concatMapStrings (b: "${ipt} -A ${dispatch} -i ${b} -j ${egress}\n") cfg.bridges}
    # Container to container (same or another Docker network): Docker's own
    # DOCKER/isolation rules decide.
    ${lib.concatMapStrings (b: "${ipt} -A ${egress} -o ${b} -j RETURN\n") cfg.bridges}
    ${lib.concatMapStrings (allowRule ipt) allows}
    ${lib.concatMapStrings (d: "${ipt} -A ${egress} -d ${d} -j ${drop}\n") blocked}

    while ${ipt} -D DOCKER-USER -j ${dispatch} 2>/dev/null; do :; done
    ${ipt} -I DOCKER-USER 1 -j ${dispatch}

    # The host itself. nixos-fw is rebuilt from scratch on every start, so -I
    # cannot duplicate; position 1 puts it ahead of allowedTCPPorts.
    ${lib.optionalString cfg.blockHostAccess (lib.concatMapStrings (b:
      "${ipt} -I nixos-fw 1 -i ${b} -m conntrack --ctstate NEW -j nixos-fw-refuse\n"
    ) cfg.bridges)}
  '';

  teardown = ipt: ''
    while ${ipt} -D DOCKER-USER -j ${dispatch} 2>/dev/null; do :; done
    for c in ${dispatch} ${egress} ${drop}; do
      ${ipt} -F "$c" 2>/dev/null || true
    done
    for c in ${dispatch} ${egress} ${drop}; do
      ${ipt} -X "$c" 2>/dev/null || true
    done
  '';
in
{
  options.homelab.security.containerEgress = {
    enable = lib.mkEnableOption "blocking Docker containers from the LAN and the host";

    bridges = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "docker0" "br+" ];
      example = [ "pterodactyl0" "docker0" "br+" ];
      description = ''
        Container bridge interfaces (iptables syntax, `+` is a wildcard).
        `br+` covers Docker's user-defined networks (br-<id>); do not use it
        on a host with its own `br*` bridges for VMs or the LAN.
      '';
    };

    blockedIPv4 = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "10.0.0.0/8"
        "172.16.0.0/12"
        "192.168.0.0/16"
        "100.64.0.0/10" # CGNAT / Tailscale
        "169.254.0.0/16"
      ];
      description = "IPv4 destinations containers may not reach (except other container bridges).";
    };

    blockedIPv6 = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "fc00::/7" # ULA (LAN and tailnet)
        "fe80::/10"
      ];
      description = "IPv6 destinations containers may not reach (except other container bridges).";
    };

    allow = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          address = lib.mkOption { type = lib.types.str; };
          proto = lib.mkOption { type = lib.types.enum [ "tcp" "udp" ]; };
          port = lib.mkOption { type = lib.types.port; };
          interface = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Only from this container bridge (null = any).";
          };
        };
      });
      default = [ ];
      description = "Narrow exceptions: LAN services containers must reach.";
    };

    blockHostAccess = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Refuse new connections from container bridges to the host itself.";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.extraCommands = lib.mkAfter ''
      ${setup "iptables" cfg.blockedIPv4 (lib.filter (a: !isV6 a) cfg.allow)}
      ${lib.optionalString config.networking.enableIPv6
        (setup "ip6tables" cfg.blockedIPv6 (lib.filter isV6 cfg.allow))}
    '';
    networking.firewall.extraStopCommands = ''
      ${teardown "iptables"}
      ${lib.optionalString config.networking.enableIPv6 (teardown "ip6tables")}
    '';
  };
}
