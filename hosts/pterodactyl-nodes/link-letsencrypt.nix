{ config, pkgs, lib, ... }:

let
  nodeDomains = {
    crux = "crux.lc1.nm.us.prestonhager.com";
    nova = "nova.lc1.nm.us.prestonhager.com";
    elara = "elara.lc1.nm.us.prestonhager.com";
    zenith = "zenith.lc1.nm.us.prestonhager.com";
  };
  domain = nodeDomains.${config.networking.hostName} or (throw "No TLS domain for host ${config.networking.hostName}");
  share = "/mnt/pterodactyl-share";
  mountUnit = "mnt-pterodactyl\\x2dshare.mount";
in {
  systemd.services.link-letsencrypt = {
    description = "Expose this node's Lets Encrypt certificate for Wings";
    # Wants, not Requires, on the NFS mount: it is nofail, so if ace is
    # unreachable at boot the mount just fails, and Requires would turn that
    # into a 'dependency' failure here (and in Wings) that nothing retries.
    # Instead this unit starts the mount itself and retries until it is up.
    wants = [ mountUnit ];
    after = [ mountUnit "remote-fs.target" ];
    before = [ "wings.service" ];
    wantedBy = [ "multi-user.target" ];
    # Keep retrying for as long as the share is missing.
    startLimitIntervalSec = 0;
    path = [ pkgs.util-linux ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "link-letsencrypt" ''
        set -euo pipefail
        share=${share}
        if ! mountpoint -q "$share"; then
          # Re-attempt a mount that failed earlier (e.g. at boot).
          systemctl start ${lib.escapeShellArg mountUnit} || true
        fi
        if ! mountpoint -q "$share"; then
          echo "$share is not mounted; will retry" >&2
          exit 1
        fi
        cert_dir="$share/${domain}"
        mkdir -p /etc/letsencrypt
        ln -sfn "$share" /etc/letsencrypt/live
        if [ ! -d "$cert_dir" ]; then
          echo "Certificate directory not ready yet: $cert_dir (live symlink still created)" >&2
        fi
      '';
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 30;
    };
  };
}
