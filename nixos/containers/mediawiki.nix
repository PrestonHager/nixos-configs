{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
in
{
  sops.secrets = {
    "mediawiki-environment" = {
      sopsFile = "${sops-path}/secrets/containers/mediawiki.yaml";
    };
  };

  # Create the mediawiki user and group
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
    "d /mw 0770 root root -"
    "d /mw/images 0770 www-data www-data -"
    "d /mw/data 0770 nm-iodine nscd -"
    "d /mw/redis 0770 nm-iodine nscd -"
    "d /mw/html 0770 www-data www-data -"
    "d /mw/apache2 0770 root root -"
  ];

  # Systemd service to create the pod required by podman containers
  systemd.services.pod-mediawiki = {
    description = "Start podman's 'mediawiki' pod";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    requiredBy = [
      "podman-mediawiki.service"
      "podman-mediawiki-db.service"
      "podman-mediawiki-redis.service"
    ];
    unitConfig = {
      RequiresMountsFor = "/run/containers";
    };
    serviceConfig = {
      Type = "oneshot";
      Restart = "no";
      ExecStart = pkgs.writeShellScript "pod-mediawiki" ''
        ${pkgs.podman}/bin/podman pod exists mediawiki || \
        ${pkgs.podman}/bin/podman pod create -p 8090:80 -h loftiawiki.org \
        --memory 8G --cpus 0 mediawiki
      '';
    };
    path = [ pkgs.podman ];
  };

  # Define the container
  virtualisation.oci-containers.containers = {
    "mediawiki" = {
      autoStart = true;

      # User and group to run the container as
      user = "root:root";

      # Volumes to make persistent in the host/container
      volumes = [
        "/etc/passwd:/etc/passwd:ro"
        "/etc/group:/etc/group:ro"
        "/mw/images:/var/www/html/images"
        "/mw/html:/var/www/html"
        "/mw/apache2:/etc/apache2"
      ];

      environment = {
      };

      dependsOn = [ "mediawiki-db" "mediawiki-redis" ];
      extraOptions = [ "--pod=mediawiki" ];

      # Finally, the mediawiki image and version
      image = "docker.io/prestonhager/mediawiki-redis:latest";
    };
    "mediawiki-db" = {
      autoStart = true;

      user = "root:root";

      volumes = [
        "/mw/data:/var/lib/mysql"
      ];

      cmd = ["--transaction-isolation=READ-COMMITTED" "--log-bin=msqyld-bin" "--binlog-format=ROW"];

      environment = {
        MARIADB_DATABASE = "mediawiki";
        MARIADB_USER = "mediawiki";
      };

      dependsOn = [ "mediawiki-redis" ];
      extraOptions = [
        "--pod=mediawiki"
        "--env-file=${config.sops.secrets."mediawiki-environment".path}"
      ];

      image = "mariadb:latest";
    };
    # Redis is not required, but is a great cache system
    "mediawiki-redis" = {
      autoStart = true;

      user = "root:root";

      volumes = [
        "/mw/redis:/data"
      ];

      cmd = [ "redis-server" "--save" "59" "1" "--loglevel" "warning" ];

      extraOptions = [ "--pod=mediawiki" ];

      image = "redis:latest";
    };
  };
}

