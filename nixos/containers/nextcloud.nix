{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
in
{
  sops.secrets = {
    "nextcloud-environment" = {
      sopsFile = "${sops-path}/secrets/containers/nextcloud.yaml";
    };
    "nextcloud-db-environment" = {
      sopsFile = "${sops-path}/secrets/containers/nextcloud.yaml";
    };
  };

  # Create the nextcloud user and group
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
    "d /nc 0770 root root -"
    "d /nc/data 0770 www-data www-data -"
    "d /nc/mysql 0770 nm-iodine nscd -"
    "d /nc/redis 0770 nm-iodine root -"
  ];

  # Systemd service to create the pod required by podman containers
  systemd.services.pod-nextcloud = {
    description = "Start podman's 'nextcloud' pod";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    requiredBy = [
      "podman-nextcloud.service"
      "podman-nextcloud-db.service"
      "podman-nextcloud-redis.service"
    ];
    unitConfig = {
      RequiresMountsFor = "/run/containers";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "pod-nextcloud" ''
        ${pkgs.podman}/bin/podman pod exists nextcloud || \
        ${pkgs.podman}/bin/podman pod create -p 8083:80 -p "[::1]:8083:80" -h cloud.prestonhager.com nextcloud
      '';
    };
    path = [ pkgs.podman ];
  };

  # Define the container
  virtualisation.oci-containers.containers = {
    "nextcloud" = {
      autoStart = true;

      # Ports are defined in the pod creation
      # User and group to run the container as
      user = "root:root";

      # Volumes to make persistent in the host/container
      volumes = [
        "/etc/passwd:/etc/passwd:ro"
        "/etc/group:/etc/group:ro"
        "/nc/data/:/var/www/html/"
        "/nc/mysql:/var/lib/mysql"
  #      "/run/podman/podman.sock:/var/run/docker.sock:ro"
      ];

      environment = {
        # Apache settings
        APACHE_PORT = "80";
        APACHE_IP_BINDING = "127.0.0.1";
        APACHE_BODY_LIMIT = "0";
        # Automatic admin user
        NEXTCLOUD_ADMIN_USER = "nextcloud-admin";
        # Maria DB connection
        MYSQL_DATABASE = "nextcloud";
        MYSQL_USER = "nextcloud";
        # NOTE: maybe hosts need to be 127.0.0.1 or localhost?
        MYSQL_HOST = "nextcloud-db";
        # Redis connection
        REDIS_HOST = "nextcloud-redis";
        # Nextcloud domain configurations
        TRUSTED_PROXIES = "192.168.8.50,192.168.8.52";
        NEXTCLOUD_TRUSTED_DOMAINS = "cloud.prestonhager.com";
        OVERWRITEHOST = "cloud.prestonhager.com";
        OVERWRITEPROTOCOL = "https";
        OVERWRITECLIURL = "https://cloud.prestonhager.com";
        # Overwrite the default memory and upload limits for PHP
        PHP_MEMORY_LIMIT = "8G";
        PHP_UPLOAD_LIMIT = "128G";
        # SMTP connection for email notifications
        SMTP_HOST = "smtp.mail.me.com";
        SMTP_SECURE = "ssl";
        SMTP_PORT = "587";
        SMTP_NAME = "prestonhager@icloud.com";
        MAIL_FROM_ADDRESS = "admin@prestonhager.com";
        MAIL_DOMAIN = "prestonhager.com";
      };

      dependsOn = [ "nextcloud-db" "nextcloud-redis" ];
      extraOptions = [
        "--pod=nextcloud"
        "--env-file=${config.sops.secrets."nextcloud-environment".path}"
      ];

      # Finally, the nextcloud image and version
      image = "nextcloud:latest";
    };
    "nextcloud-db" = {
      autoStart = true;

      user = "root:root";

      volumes = [
        "/nc/mysql:/var/lib/mysql:z"
      ];

      cmd = ["--transaction-isolation=READ-COMMITTED" "--log-bin=msqyld-bin" "--binlog-format=ROW"];

      environment = {
        MARIADB_DATABASE = "nextcloud";
        MARIADB_USER = "nextcloud";
      };

      dependsOn = [ "nextcloud-redis" ];
      extraOptions = [
        "--pod=nextcloud"
        "--env-file=${config.sops.secrets."nextcloud-db-environment".path}"
      ];

      image = "mariadb:latest";
    };
    # Redis is not required, but is a great cache system
    "nextcloud-redis" = {
      autoStart = true;

      user = "root:root";

      volumes = [
        "/nc/redis:/data"
      ];

      cmd = [ "redis-server" "--save" "59" "1" "--loglevel" "warning" ];

      extraOptions = [ "--pod=nextcloud" ];

      image = "redis:latest";
    };
  };
}

