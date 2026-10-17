{ config, ... }:

{
  # Comment or uncomment the following imports to customize nginx
  imports = [
    # Reverse proxy configuration
    ./reverse-proxy.nix
  ];

  # Enable the HTTP/HTTPS ports on the firewall
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  security.acme = {
    acceptTerms = true;
    defaults.email = "admin+acme@prestonhager.com";
  };
}
