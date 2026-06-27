{ config, lib, ... }:

let
  cfg = config.homelab.security;
in {
  config = lib.mkIf (cfg.enable && cfg.phase2.enable) {
    services.aide = {
      enable = true;
      rules = ''
        /etc p+i+u+g+sha256
        /root p+i+u+g+sha256
        !/etc/nixos/.git
        !/etc/nixos/result
        /var/lib/systemd p+i+u+g+sha256
      '';
    };
  };
}
