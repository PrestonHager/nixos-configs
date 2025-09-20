{ config, pkgs, ... }:

# This file is for any extra TLS certificates that need requested
# They will be placed in /var/lib/caddy/.local/share/caddy/certificates
# A system service also copies these to /stor/shares/private/letsencrypt for
# other servers on the network to use

let
  domains = [
    "crux.lc1.nm.us.prestonhager.com:8080"
  ];
in {
  services.caddy.virtualHosts = builtins.listToAttrs (builtins.map (domain: {
    name = "${domain}";
    value = {
      extraConfig = ''
        reverse_proxy https://${domain}
      '';
    };
  }) domains);

  # Copy the certs to a shared location for other servers to use
  systemd.services.caddy-copy-certs = {
    description = "Copy Caddy TLS certificates to shared location";
    after = [ "caddy.service" ];
    wants = [ "caddy.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "copy-caddy-certs" ''
        cp -r /var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/* /stor/shares/private/letsencrypt/
        chown -R root:users /stor/shares/private/letsencrypt
        find /stor/shares/private/letsencrypt -type d -exec chmod 775 {} \;
        find /stor/shares/private/letsencrypt -type f -exec chmod 664 {} \;
      '';
      RemainAfterExit = true;
    };
  };
}

