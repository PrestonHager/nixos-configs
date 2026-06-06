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
    certs = {
      "portunus.prestonhager.com" = {
        postRun = ''
          #!/usr/bin/env bash
          # Ensure Let's Encrypt root certificates are downloaded
          curl -s -o /etc/ssl/certs/isrgrootx1.pem https://letsencrypt.org/certs/isrgrootx1.pem
          curl -s -o /etc/ssl/certs/isrgrootx2.pem https://letsencrypt.org/certs/isrg-root-x2.pem
          # Merge the chain.pem with the ISRG root certificates
          cat chain.pem /etc/ssl/certs/isrgrootx1.pem /etc/ssl/certs/isrgrootx2.pem > ca.merged.pem
          chown acme:nginx ca.merged.pem
          chmod 640 ca.merged.pem
        '';
      };
    };
  };
}
