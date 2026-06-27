{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  pterodactylImages = import ./pterodactyl-docker.nix {
    inherit pkgs sops-path;
  };
  inherit (pterodactylImages) panelUpdateEnvStock version;
in
{
  imports = [
    ./pterodactyl-stock-reset.nix
    ./pterodactyl-blueprint.nix
    ./pterodactyl-sso.nix
  ];
  sops.secrets = {
    "pterodactyl-env" = {
      sopsFile = "${sops-path}/secrets/containers/pterodactyl.yaml";
      mode = "0640";
      owner = "pterodactyl";
      group = "pterodactyl";
    };
    "pterodactyl-password" = {
      sopsFile = "${sops-path}/secrets/containers/pterodactyl.yaml";
      mode = "0640";
    };
  };

  # Create the pterodactyl user and group
  users.users.pterodactyl = {
    isSystemUser = true;
    description = "Pterodactyl";
    group = "pterodactyl";
    hashedPasswordFile = config.sops.secrets."pterodactyl-password".path;
  };
  users.groups.pterodactyl = {};

  # Create the data directory
  systemd.tmpfiles.rules = [
    "d /pterodactyl/html 0770 pterodactyl pterodactyl -"
    "d /pterodactyl/data 0770 pterodactyl pterodactyl -"
    "d /pterodactyl/redis 0770 pterodactyl pterodactyl -"
    "d /pterodactyl/sockets 0770 pterodactyl pterodactyl -"
    "d /pterodactyl/sockets/mysqld 0770 pterodactyl pterodactyl -"
    "d /pterodactyl/sockets/php 0770 pterodactyl pterodactyl -"
  ];

  # Systemd service to create the pod required by podman containers
  systemd.services.pod-pterodactyl = {
    description = "Start podman's 'pterodactyl' pod";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    requiredBy = [
      "podman-pterodactyl.service"
      "podman-pterodactyl-db.service"
      "podman-pterodactyl-redis.service"
    ];
    unitConfig = {
      RequiresMountsFor = "/run/containers";
    };
    serviceConfig = {
      Type = "oneshot";
      Restart = "no";
      ExecStart = pkgs.writeShellScript "pod-pterodactyl" ''
        ${pkgs.podman}/bin/podman pod exists pterodactyl || \
        ${pkgs.podman}/bin/podman pod create -p 9001:9000 \
          --memory 8G --cpus 0 pterodactyl
      '';
    };
    path = [ pkgs.podman ];
  };

  # Define the container
  virtualisation.oci-containers.containers = {
    "pterodactyl" = {
      autoStart = true;

      # User and group to run the container as
      user = "pterodactyl:pterodactyl";

      # Volumes to make persistent in the host/container
      volumes = [
        "/etc/passwd:/etc/passwd:ro"
        "/etc/group:/etc/group:ro"
        "/pterodactyl/html:/var/www/pterodactyl"
        "/pterodactyl/sockets/mysqld:/run/mysqld"
        "/pterodactyl/sockets/php:/run/php-fpm"
        "${config.sops.secrets."pterodactyl-env".path}:/var/www/pterodactyl/.env.initial:U"
      ];

      environment = panelUpdateEnvStock // {
        ENV_FILE = "${config.sops.secrets."pterodactyl-env".path}";
      };

      extraOptions = [
        "--pod=pterodactyl"
        "--env-file=${config.sops.secrets."pterodactyl-env".path}"
      ];

      # Finally, the pterodactyl runtime image and version
      image = "pterodactyl-runtime:v${version}";
      imageFile = pterodactylImages.runtimeImage;
    };

    "pterodactyl-db" = {
      autoStart = true;

      user = "pterodactyl:pterodactyl";

      volumes = [
        "/etc/passwd:/etc/passwd:ro"
        "/etc/group:/etc/group:ro"
        "/pterodactyl/data:/var/lib/mysql"
        "/pterodactyl/sockets/mysqld:/var/run/mysqld"
      ];

      cmd = ["--transaction-isolation=READ-COMMITTED" "--log-bin=mysqld-bin" "--binlog-format=ROW"];

      dependsOn = [ "pterodactyl-redis" ];
      extraOptions = [
        "--pod=pterodactyl"
        #"--env-file=${config.sops.secrets."pterodactyl-env".path}"
        "--env-file=${config.sops.secrets."pterodactyl-env".path}"
      ];

      image = "mariadb:latest";
    };
    # Redis is not required, but is a great cache system
    "pterodactyl-redis" = {
      autoStart = true;

      user = "pterodactyl:pterodactyl";

      volumes = [
        "/etc/passwd:/etc/passwd:ro"
        "/etc/group:/etc/group:ro"
        "/pterodactyl/redis:/data"
      ];

      cmd = [ "redis-server" "--save" "59" "1" "--loglevel" "warning" ];

      extraOptions = [ "--pod=pterodactyl" ];

      image = "redis:latest";
    };
  };
}
