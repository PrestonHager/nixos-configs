{ config, ... }:

let
  caddyLib = import ./lib.nix;
in
{
  # Public on purpose: the confirm/deny links in upgrade mails are opened from
  # anywhere. GET only shows a confirmation page; the action needs a POST
  # (nixos/monitoring/scripts/ace-service-update-http.py), so mail link
  # scanners cannot approve an upgrade.
  services.caddy.virtualHosts."update.prestonhager.com" = {
    extraConfig = ''
      ${caddyLib.securityHeaders}
      reverse_proxy 127.0.0.1:8765
    '';
  };
}
