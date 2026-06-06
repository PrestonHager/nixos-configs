{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  ncRoot = "/stor/nextcloud";
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

  systemd.tmpfiles.rules = [
    "d ${ncRoot} 0770 root root -"
    "d ${ncRoot}/data 0770 www-data www-data -"
    "d ${ncRoot}/mysql 0770 nm-iodine nscd -"
    "d ${ncRoot}/redis 0770 nm-iodine nscd -"
  ];

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
      RequiresMountsFor = "/run/containers /stor";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "pod-nextcloud" ''
        ${pkgs.podman}/bin/podman pod exists nextcloud || \
        ${pkgs.podman}/bin/podman pod create -p 127.0.0.1:8083:80 -h cloud.prestonhager.com nextcloud
      '';
    };
    path = [ pkgs.podman ];
  };

  virtualisation.oci-containers.containers = {
    nextcloud = {
      autoStart = true;
      user = "root:root";
      volumes = [
        "/etc/passwd:/etc/passwd:ro"
        "/etc/group:/etc/group:ro"
        "${ncRoot}/data/:/var/www/html/"
      ];
      environment = {
        APACHE_PORT = "80";
        APACHE_IP_BINDING = "0.0.0.0";
        APACHE_BODY_LIMIT = "0";
        NEXTCLOUD_ADMIN_USER = "nextcloud-admin";
        MYSQL_DATABASE = "nextcloud";
        MYSQL_USER = "nextcloud";
        MYSQL_HOST = "nextcloud-db";
        REDIS_HOST = "nextcloud-redis";
        TRUSTED_PROXIES = "127.0.0.1,::1";
        NEXTCLOUD_TRUSTED_DOMAINS = "cloud.prestonhager.com";
        OVERWRITEHOST = "cloud.prestonhager.com";
        OVERWRITEPROTOCOL = "https";
        OVERWRITECLIURL = "https://cloud.prestonhager.com";
        PHP_MEMORY_LIMIT = "8G";
        PHP_UPLOAD_LIMIT = "128G";
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
      image = "docker.io/library/nextcloud:latest";
    };
    nextcloud-db = {
      autoStart = true;
      user = "root:root";
      volumes = [
        "${ncRoot}/mysql:/var/lib/mysql:z"
      ];
      cmd = [ "--transaction-isolation=READ-COMMITTED" "--log-bin=mysqld-bin" "--binlog-format=ROW" ];
      environment = {
        MARIADB_DATABASE = "nextcloud";
        MARIADB_USER = "nextcloud";
      };
      dependsOn = [ "nextcloud-redis" ];
      extraOptions = [
        "--pod=nextcloud"
        "--env-file=${config.sops.secrets."nextcloud-db-environment".path}"
      ];
      image = "docker.io/library/mariadb:latest";
    };
    nextcloud-redis = {
      autoStart = true;
      user = "root:root";
      volumes = [
        "${ncRoot}/redis:/data"
      ];
      cmd = [ "redis-server" "--save" "60" "1" "--loglevel" "warning" ];
      extraOptions = [ "--pod=nextcloud" ];
      image = "docker.io/library/redis:latest";
    };
  };
}
