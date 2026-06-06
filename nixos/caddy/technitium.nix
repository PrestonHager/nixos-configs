{ config, ... }:

{
  services.caddy.virtualHosts."dns.prestonhager.com".extraConfig = ''
    reverse_proxy http://localhost:5380
  '';
}
