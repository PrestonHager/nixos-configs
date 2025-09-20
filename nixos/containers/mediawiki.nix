{ config, pkgs, lib ? pkgs.lib, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  # NOTE: only enable this upgrade option if you are upgrading mediawiki
  # you should add the following to your main installations LocalSettings.php
  #   $adminTask = ( PHP_SAPI === 'cli' || defined( 'MEDIAWIKI_INSTALL' ) );
  #   $wgReadOnly = $adminTask ? false : 'Upgrading to MediaWiki 1.44.0';
  # then download the latest mediawiki tarball and extract it to
  # /mw/mediawiki-<version>, move all of the necessary files
  # see https://www.mediawiki.org/wiki/Manual:Upgrading#Other_files
  # then enable the upgrade option and run the upgrade script inside the upgrade
  # container (not the main container)
  #   sudo podman exec mediawiki-upgrade php maintenance/run.php update
  # if all goes well, you can then move the new mediawiki-<verion> into /mw/html
  # and delete or backup the old mediawiki directory
  # make sure to disable the upgrade option after as well!
  mediawiki = {
    enableUpgrade = true;
    upgradeVersion = "1.45.3";
    version = "1.44.0";
    # Run nix-shell -p nix-prefetch-docker --run "nix-prefetch-docker --image-name mediawiki --image-tag <VERSION>-fpm-alpine"
    # then paste the nix data below when upgrading version
    dockerImage = {
    };
    upgradeDockerImage = {
      imageName = "mediawiki";
      imageDigest = "sha256:95989cf1a61a1476f65ff8db8abfe10d54b9f5769ef0a3cb433ace81673d2f20";
      hash = "sha256-roD1HrBppnuO6kybxT3KRP7H5n9cWjR+/cUv1sKw4Pw=";
      finalImageName = "mediawiki";
      finalImageTag = "1.45.3-fpm-alpine";
    };
  };
in
{
  # declare any secrets such as passwords
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
    daemon = {
      isSystemUser = true;
      group = "daemon";
    };
  };
  users.groups = {
    www-data = {};
    mysql = {};
    daemon = {};
  };

  # Create the data directory
  systemd.tmpfiles.rules = [
    "d /mw 0770 root root -"
    "d /mw/images 0770 www-data www-data -"
    "d /mw/data 0770 nm-iodine nscd -"
    "d /mw/redis 0770 nm-iodine nscd -"
    "d /mw/html 0770 www-data www-data -"
    "d /mw/apache2 0770 root root -"
    "d /mw/run 0770 root root -"
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
        ${pkgs.podman}/bin/podman pod create -p 8090:80 -p 8091:9000 -h loftiawiki.org \
        --memory 8G --cpus 0 mediawiki
      '';
    };
    path = [ pkgs.podman ];
  };
  systemd.services.pod-mediawiki-upgrade = lib.mkIf mediawiki.enableUpgrade {
    description = "Start podman's 'mediawiki-upgrade' pod";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    requiredBy = [
      "podman-mediawiki-upgrade.service"
      "podman-mediawiki-db.service"
      "podman-mediawiki-redis.service"
    ];
    unitConfig = {
      RequiresMountsFor = "/run/containers";
    };
    serviceConfig = {
      Type = "oneshot";
      Restart = "no";
      ExecStart = pkgs.writeShellScript "pod-mediawiki-upgrade" ''
        ${pkgs.podman}/bin/podman pod exists mediawiki-upgrade || \
        ${pkgs.podman}/bin/podman pod create -p 8100:80 -p 8101:9000 -h upgrade.loftiawiki.org \
        --memory 8G --cpus 0 mediawiki-upgrade
      '';
    };
    path = [ pkgs.podman ];
  };

  # Define the container
  virtualisation.oci-containers.containers = {
    # See mediawiki.enableUpgrade for more info
    "mediawiki-upgrade" = lib.mkIf mediawiki.enableUpgrade {
      autoStart = true;

      user = "root:root";

      volumes = [
        "/etc/passwd:/etc/passwd:ro"
        "/etc/group:/etc/group:ro"
        "/mw/images:/var/www/html/images"
        "/mw/mediawiki-${mediawiki.upgradeVersion}:/var/www/html"
        "/mw/apache2:/etc/apache2"
        "/mw/run:/run"
      ];

      environment = {};

      dependsOn = [ "mediawiki-db" "mediawiki-redis" ];
      extraOptions = [ "--pod=mediawiki-upgrade" ];

      image = "mediawiki-redis:${mediawiki.upgradeVersion}";
      imageFile = import ./mediawiki-docker.nix {
        inherit pkgs;
        version = mediawiki.upgradeVersion;
        dockerImage = mediawiki.upgradeDockerImage;
      };
    };
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
      #image = "mediawiki-redis:${mediawiki.version}";
      #imageFile = import ./mediawiki-docker.nix { inherit pkgs; version = mediawiki.version; };
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

