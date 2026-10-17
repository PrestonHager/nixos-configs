{ config, pkgs, ... }:

let
  nodeDomains = {
    crux = "crux.lc1.nm.us.prestonhager.com";
    nova = "nova.lc1.nm.us.prestonhager.com";
    elara = "elara.lc1.nm.us.prestonhager.com";
    zenith = "zenith.lc1.nm.us.prestonhager.com";
  };
  domain = nodeDomains.${config.networking.hostName} or (throw "No TLS domain for host ${config.networking.hostName}");
in {
  systemd.services.link-letsencrypt = {
    description = "Expose this node's Lets Encrypt certificate for Wings";
    after = [ "mnt-pterodactyl\\x2dshare.mount" "remote-fs.target" ];
    requires = [ "mnt-pterodactyl\\x2dshare.mount" ];
    before = [ "wings.service" ];
    unitConfig.ConditionPathIsMountPoint = "/mnt/pterodactyl-share";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "link-letsencrypt" ''
        set -euo pipefail
        cert_dir="/mnt/pterodactyl-share/${domain}"
        mkdir -p /etc/letsencrypt
        ln -sfn /mnt/pterodactyl-share /etc/letsencrypt/live
        if [ ! -d "$cert_dir" ]; then
          echo "Certificate directory not ready yet: $cert_dir (live symlink still created)" >&2
        fi
      '';
      RemainAfterExit = true;
    };
  };
}
