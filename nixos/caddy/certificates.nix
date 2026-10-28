{ config, pkgs, lib ? pkgs.lib, ... }:

# TLS certificates for Pterodactyl Wings nodes. Only nodes enabled in
# ./lib.nix (wingsNodes) get a vhost, a certificate and a copy job; a
# disconnected node gets none, so Caddy neither proxies to nor renews for it.
let
  caddyLib = import ./lib.nix;
  nodes = builtins.listToAttrs (map (name: {
    inherit name;
    value = caddyLib.wingsDomain name;
  }) caddyLib.activeWingsNodes);
  domains = builtins.attrValues nodes;
  caddyCertDir =
    "/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory";
  nodeNames = builtins.attrNames nodes;
in {
  services.caddy.virtualHosts = builtins.listToAttrs (map (domain: {
    name = domain;
    value = {
      extraConfig = ''
        reverse_proxy https://${domain}
      '';
    };
  }) domains);

  systemd.services.caddy-copy-certs = {
    description = "Copy node TLS certificates to per-node NFS export trees";
    after = [ "caddy.service" ];
    wants = [ "caddy.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      # Inactive after success so path/timer units can start a later copy when
      # Caddy issues a cert after the first (empty) run.
      ExecStart = pkgs.writeShellScript "copy-caddy-certs" ''
        set -euo pipefail
        src_root="${caddyCertDir}"
        if [ ! -d "$src_root" ]; then
          echo "Caddy certificate directory not found: $src_root" >&2
          exit 1
        fi
        ${lib.concatStringsSep "\n" (map (name: ''
          domain="${nodes.${name}}"
          src="$src_root/$domain"
          dest="/stor/shares/private/nodes/${name}/letsencrypt/$domain"
          if [ ! -d "$src" ]; then
            echo "Missing certificate directory for ${name}: $src (skip until Caddy issues the cert)" >&2
          else
            mkdir -p "$dest"
            ${pkgs.rsync}/bin/rsync -a --delete "$src/" "$dest/"
            # Panel-default Wings config.yml uses Let's Encrypt names; Caddy uses .crt/.key.
            ln -sfn "$domain.crt" "$dest/fullchain.pem"
            ln -sfn "$domain.key" "$dest/privkey.pem"
          fi
        '') nodeNames)}
        chown -R root:users /stor/shares/private/nodes
        find /stor/shares/private/nodes -type d -exec chmod 775 {} \;
        find /stor/shares/private/nodes -type f -exec chmod 664 {} \;
        # Private keys: root and group users only.
        find /stor/shares/private/nodes -type f -name '*.key' -exec chmod 640 {} \;
      '';
    };
  };

  systemd.paths.caddy-copy-certs = {
    description = "Sync node certs when Caddy renews TLS certificates";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = caddyCertDir;
      Unit = "caddy-copy-certs.service";
    };
  };

  systemd.timers.caddy-copy-certs = {
    description = "Daily sync of node TLS certificates to NFS export trees";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };
}
