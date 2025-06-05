{ config, pkgs, lib, ... }:

let
  cfg = config.services.shellinaboxd;
  package = cfg.package or (pkgs.callPackage ../pkgs/shellinabox {});
  port = toString cfg.port;
  user = cfg.user;
  bindAddress = "127.0.0.1";
  execStart = "${package}/bin/shellinaboxd --no-beep --disable-ssl --port=${port} --user=${user} --group=${user} --localhost-only";
in
{
  options.services.shellinaboxd = {
    enable = lib.mkEnableOption "ShellInABox web terminal";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/shellinabox {};
      description = "The shellinabox package to use.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 4200;
      description = "Port shellinabox listens on.";
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = "shellinabox";
      description = "User to run the service as.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      description = "ShellInABox service user";
      group = cfg.user;
    };

    users.groups.${cfg.user} = { };

    systemd.services.shellinabox = {
      description = "ShellInABox Web Terminal";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = execStart;
        User = cfg.user;
        Group = cfg.user;
        Restart = "on-failure";
      };
    };

    # do not open port; only reverse proxy via localhost
  };
}
