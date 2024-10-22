{ config, pkgs, ... }:

{
  # Create the nextcloud user and group
  users.users = {
    www-data = {
      isSystemUser = true;
#      description = "Nextcloud";
      group = "www-data";
    };
    mysql = {
      isSystemUser = true;
      description = "MySQL";
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
    "d /nc 0770 www-data www-data -"
    "d /nc/data 0770 www-data www-data -"
    "d /nc/mysql 0770 www-data www-data -"
  ];

  # Systemd service to create the pod required by podman containers
  systemd.services.pod-nextcloud = {
    description = "Start podman's 'nextcloud' pod";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    requiredBy = [
      "podman-nextcloud.service"
      "podman-mariadb.service"
    ];
    unitConfig = {
      RequiresMountsFor = "/run/containers";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "-${pkgs.podman}/bin/podman pod create nextcloud -p 8083:9000";
    };
    path = [pkgs.podman];
  };

  # Define the container
  virtualisation.oci-containers.containers = {
    "nextcloud" = {
      autoStart = true;

      # <hostPort>:<containerPort>
#      ports = [
#        "8083:9000"
#      ];

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
  #      TRUSTED_PROXIES = "cloud.prestonhager.com";
  #      APACHE_RUN_USER = "www-data";
  #      APACHE_RUN_GROUP = "www-data";
      };

      dependsOn = [ "nextcloud-db" ];
      extraOptions = [ "--pod=nextcloud" ];

      # Finally, the nextcloud image and version
      image = "nextcloud:fpm";
    };
    "nextcloud-db" = {
      autoStart = true;

      user = "mysql:mysql";

      volumes = [
        "/nc/mysql/:/var/lib/mysql/"
      ];

      cmd = ["--transaction-isolation=READ-COMMITTED" "--log-bin=msqyld-bin" "--binlog-format=ROW"];

      environment = {
        MARIADB_ALLOW_EMPTY_ROOT_PASSWORD = "1";
        MARIADB_ROOT_PASSWORD = "";
        MARIADB_PASSWORD = "";
        MARIADB_DATABASE = "nextcloud";
        MARIADB_USER = "nextcloud";
      };

      extraOptions = [ "--pod=nextcloud" ];

      image = "mariadb:latest";
    };
  };
}

