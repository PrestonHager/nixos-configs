{ config, docsSite, ... }:

let
  caddyLib = import ./lib.nix;
in
{
  services.caddy.virtualHosts."serverdocs.prestonhager.com".extraConfig = ''
    ${caddyLib.securityHeaders}
    ${caddyLib.lanOnly ''
      @bootstrapPubkey path /ssh/id_ed25519.pub
      header @bootstrapPubkey Content-Type "text/plain; charset=utf-8"
      header @bootstrapPubkey Content-Disposition "inline"

      root * ${docsSite}
      try_files {path} {path}/ /index.html
      file_server
    ''}
  '';
}
