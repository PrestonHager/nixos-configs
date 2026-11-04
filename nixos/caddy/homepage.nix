{ homepageSite, ... }:

# Public home page for the lab (apps/homepage). Unlike the other vhosts this
# one is deliberately open to the internet: it only describes the lab in
# general terms and links the member guide. Keep hostnames of servers, IPs,
# versions and topology out of it (they belong on serverdocs, LAN-only).
#
# DNS: Cloudflare CNAME `homelab` -> ip1.lc1.nm.us.prestonhager.com (DNS only,
# grey), like the other ace apps; Technitium mirrors it for the LAN
# (nixos/containers/technitium-zones.nix).
let
  caddyLib = import ./lib.nix;
in
{
  services.caddy.virtualHosts."homelab.prestonhager.com".extraConfig = ''
    ${caddyLib.securityHeaders}
    header {
      Content-Security-Policy "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; manifest-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
      Permissions-Policy "camera=(), microphone=(), geolocation=(), interest-cohort=()"
      X-Frame-Options "DENY"
      Cross-Origin-Opener-Policy "same-origin"
      -Server
    }
    @assets path /assets/* /style.css /site.js
    header @assets Cache-Control "public, max-age=3600"
    encode zstd gzip
    root * ${homepageSite}
    file_server
    handle_errors 404 {
      rewrite * /404.html
      file_server
    }
  '';
}
