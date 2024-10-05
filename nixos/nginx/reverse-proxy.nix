{ config, ... }:

{
  # Enable the HTTP/HTTPS ports on the firewall
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  security.acme = {
    acceptTerms = true;
    defaults.email = "admin+acme@prestonhager.com";
  };

  services.nginx = {
    enable = true;
    virtualHosts = let
      SSL = {
        enableACME = true;
        forceSSL = true;
      };
    in {
      "cloud.prestonhager.com" = (SSL // {
        locations."/".proxyPass = "http://localhost:8080/";
      });
      "vault.prestonhager.com" = (SSL // {
        locations."/".proxyPass = "http://localhost:8081/";
      });
      "net.prestonhager.com" = (SSL // {
        locations."/".proxyPass = "http://localhost:8082/";
      });
    };
  };
}
