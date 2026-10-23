# Shared Caddyfile fragments for ace's vhosts. Not a module: import it with
#   let caddyLib = import ./lib.nix; in ...
#
# Caddy sorts sibling `handle` blocks by matcher (path matchers first, longest
# path first), so a top-level `respond @notLan 403` or a `handle @notLan` next
# to `handle /some/path` blocks does NOT reliably run first. Every guard here
# therefore wraps the private routes in one `handle @homelab_lan { ... }` with
# a matcher-less `handle { respond 403 }` as the fallback. Public carve-outs
# (webhooks, DoH, ...) go in their own `handle <path>` blocks next to it.
#
# remote_ip matches the TCP peer address (Caddy has no trusted_proxies set),
# so X-Forwarded-For cannot be used to get in.
rec {
  # Who counts as "home": loopback (ace itself, blackbox probes, containers
  # that resolve vhosts through /etc/hosts), the server LAN, the Tailscale
  # tailnet, and WireGuard VPN clients (wg-portal routes 192.168.20.0/24 to
  # the host unNATed, so Caddy sees the client address).
  #
  # Deliberately NOT included:
  #   10.0.0.0/8      the ISP modem side (10.0.0.0/24) is outside our control
  #   192.168.0.0/16  only 192.168.5.0/24 is ours; 192.168.8.0/24 is retired
  #   10.88.0.0/16    podman bridge: containers that serve the internet could
  #                   otherwise be used to reach private vhosts (SSRF)
  lanRanges = [
    "127.0.0.0/8"
    "::1/128"
    "192.168.5.0/24" # server LAN
    "100.64.0.0/10" # Tailscale tailnet (tailscale0), IPv4
    "fd7a:115c:a1e0::/48" # Tailscale tailnet, IPv6
    "192.168.20.0/24" # WireGuard VPN clients (wg-portal)
  ];

  lanRangesStr = builtins.concatStringsSep " " lanRanges;

  # Named matcher for lanRanges. Define it once per site, at the top level.
  lanMatcher = ''
    @homelab_lan remote_ip ${lanRangesStr}
  '';

  # `body` for lanRanges, 403 for everyone else. Needs lanMatcher in the
  # same site; may be nested inside a `handle <path> { ... }` to guard only
  # that path.
  lanGuard = body: ''
    handle @homelab_lan {
      ${body}
    }
    handle {
      respond "Forbidden" 403
    }
  '';

  # Whole site LAN/tailnet/VPN-only. Use at most once per site.
  lanOnly = body: lanMatcher + lanGuard body;

  # Pterodactyl Wings nodes behind ace (TLS certs from Caddy, websocket
  # proxying for the panel). Only enabled nodes get a vhost and certificate;
  # nova and zenith are disconnected.
  wingsNodes = {
    crux = { ip = "192.168.5.6"; enable = true; };
    elara = { ip = "192.168.5.8"; enable = true; };
    nova = { ip = "192.168.5.7"; enable = false; };
    zenith = { ip = "192.168.5.9"; enable = false; };
  };
  wingsDomain = name: "${name}.lc1.nm.us.prestonhager.com";
  activeWingsNodes = builtins.filter (n: wingsNodes.${n}.enable) (builtins.attrNames wingsNodes);

  # Baseline response headers for public vhosts. `?` only sets a header the
  # upstream did not send, so apps with their own policy keep it. No
  # includeSubDomains/preload: some names under the zone are not HTTPS-only.
  securityHeaders = ''
    header {
      ?Strict-Transport-Security "max-age=31536000"
      ?X-Content-Type-Options "nosniff"
      ?Referrer-Policy "strict-origin-when-cross-origin"
    }
  '';
}
