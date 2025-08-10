{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
in
{
  sops.secrets = {
    "phorge-environment" = {
      sopsFile = "${sops-path}/secrets/containers/phorge.yaml";
    };
  };

  # Create the phorge user and group
  users.users = {
    www-data = {
      isSystemUser = true;
      group = "www-data";
      extraGroups = [ "podman" ];
    };
    mysql = {
      isSystemUser = true;
      group = "mysql";
      extraGroups = [ "www-data" ];
    };
  };
  users.groups = {
    www-data = {};
    mysql = {};
  };

  # Create the data directory
  systemd.tmpfiles.rules = [
    "d /phorge 0770 root root -"
    "d /phorge/data 0770 nm-iodine nscd -"
    "d /phorge/redis 0770 nm-iodine nscd -"
    "d /phorge/html 0770 www-data www-data -"
    "d /phorge/arcanist 0770 www-data www-data -"
    "d /phorge/apache2 0770 root root -"
  ];

  # Systemd service to create the pod required by podman containers
  systemd.services.pod-phorge = {
    description = "Start podman's 'phorge' pod";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    requiredBy = [
      "podman-phorge.service"
      "podman-phorge-db.service"
      "podman-phorge-redis.service"
    ];
    unitConfig = {
      RequiresMountsFor = "/run/containers";
    };
    serviceConfig = {
      Type = "oneshot";
      Restart = "no";
      ExecStart = pkgs.writeShellScript "pod-phorge" ''
        ${pkgs.podman}/bin/podman pod exists phorge || \
        ${pkgs.podman}/bin/podman pod create -p 8091:80 -h loftiawiki.org \
        --memory 8G --cpus 0 phorge
      '';
    };
    path = [ pkgs.podman ];
  };

  # Define the container
  virtualisation.oci-containers.containers = {
    "phorge" = {
      autoStart = true;

      # User and group to run the container as
      user = "root:root";

      # Volumes to make persistent in the host/container
      volumes = [
        "/etc/passwd:/etc/passwd:ro"
        "/etc/group:/etc/group:ro"
        "/phorge/html:/var/www/html"
        "/phorge/arcanist:/var/www/arcanist"
        "/phorge/apache2:/etc/apache2"
      ];

      environment = {
        PHORGE_BASE_URI = "phorge.loftiawiki.org";
      };

      dependsOn = [ "phorge-db" "phorge-redis" ];
      extraOptions = [
        "--pod=phorge"
        "--env-file=${config.sops.secrets."phorge-environment".path}"
      ];

      # Create a custom docker file to install PHP with the required extensions
      image = "phorge:latest";
      imageFile = import ./phorge-docker.nix {
        inherit pkgs sops-path;
      };
    };
    "phorge-db" = {
      autoStart = true;

      user = "root:root";

      volumes = [
        "/phorge/data:/var/lib/mysql"
      ];

      cmd = ["--transaction-isolation=READ-COMMITTED" "--log-bin=msqyld-bin" "--binlog-format=ROW"];

      environment = {
        MARIADB_DATABASE = "phorge";
        MARIADB_USER = "phorge";
      };

      dependsOn = [ "phorge-redis" ];
      extraOptions = [
        "--pod=phorge"
        "--env-file=${config.sops.secrets."phorge-environment".path}"
      ];

      image = "mariadb:latest";
    };
    # Redis is not required, but is a great cache system
    "phorge-redis" = {
      autoStart = true;

      user = "root:root";

      volumes = [
        "/phorge/redis:/data"
      ];

      cmd = [ "redis-server" "--save" "59" "1" "--loglevel" "warning" ];

      extraOptions = [ "--pod=phorge" ];

      image = "redis:latest";
    };
  };
}

