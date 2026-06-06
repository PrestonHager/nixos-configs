{ config, ... }:

{
  services.caddy = {
    virtualHosts."test.sui.prestonhager.com".extraConfig = ''
      reverse_proxy http://localhost:9000
    '';
    virtualHosts."faucet.test.sui.prestonhager.com".extraConfig = ''
      reverse_proxy http://localhost:9123
    '';
    virtualHosts."indexer.test.sui.prestonhager.com".extraConfig = ''
      reverse_proxy http://localhost:9124
    '';
  };
}

