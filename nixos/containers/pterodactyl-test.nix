{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  pterodactylImages = import ./pterodactyl-docker.nix {
    inherit pkgs sops-path;
  };
  testEnvFile = "/var/lib/pterodactyl-test/pterodactyl.env";
  testPanelDir = "/home/prestonh/Projects/panel";
in
{
  # Container processes stay pterodactyl; group "users" matches prestonh's primary group.
  users.users.pterodactyl.extraGroups = [ "users" ];

  systemd.tmpfiles.rules = [
    "d /pterodactyl-test/data 0770 pterodactyl pterodactyl -"
    "d /pterodactyl-test/redis 0770 pterodactyl pterodactyl -"
    "d /pterodactyl-test/sockets 0770 pterodactyl pterodactyl -"
    "d /pterodactyl-test/sockets/mysqld 0770 pterodactyl pterodactyl -"
    "d /pterodactyl-test/sockets/php 0770 pterodactyl pterodactyl -"
    "d /var/lib/pterodactyl-test 0750 pterodactyl pterodactyl -"
  ];

  systemd.services.pterodactyl-test-env = {
    description = "Create isolated environment file for the test Pterodactyl panel";
    wantedBy = [ "multi-user.target" ];
    before = [
      "pod-pterodactyl-test.service"
      "podman-pterodactyl-test.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      ENV=${testEnvFile}
      if [ -f "$ENV" ]; then
        exit 0
      fi
      rand_pass() {
        ${pkgs.openssl}/bin/openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20
      }
      DB_PASS=$(rand_pass)
      ROOT_PASS=$(rand_pass)
      APP_KEY=$(${pkgs.openssl}/bin/openssl rand -base64 32 | ${pkgs.coreutils}/bin/base64 -w0 | ${pkgs.gnused}/bin/sed 's/^/base64:/')
      HASHIDS=$(rand_pass)
      cat > "$ENV" <<EOF
APP_ENV=production
APP_DEBUG=true
APP_THEME=pterodactyl
APP_TIMEZONE=UTC
APP_URL=https://testpanel.prestonhager.com
APP_LOCALE=en
APP_ENVIRONMENT_ONLY=true
APP_KEY=$APP_KEY

LOG_CHANNEL=daily
LOG_DEPRECATIONS_CHANNEL=null
LOG_LEVEL=debug

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=panel_test
DB_USERNAME=pterodactyl_test
DB_PASSWORD=$DB_PASS

MARIADB_ROOT_PASSWORD=$ROOT_PASS

REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379

CACHE_DRIVER=redis
QUEUE_CONNECTION=redis
SESSION_DRIVER=redis

HASHIDS_SALT=$HASHIDS
HASHIDS_LENGTH=8

MAIL_MAILER=log
EOF
      chown pterodactyl:pterodactyl "$ENV"
      chmod 0640 "$ENV"
    '';
  };

  systemd.services.pod-pterodactyl-test = {
    description = "Start podman's 'pterodactyl-test' pod";
    wants = [
      "network-online.target"
      "pterodactyl-test-env.service"
      "pterodactyl-test-panel-perms.service"
    ];
    after = [
      "network-online.target"
      "pterodactyl-test-env.service"
      "pterodactyl-test-panel-perms.service"
    ];
    requiredBy = [
      "podman-pterodactyl-test.service"
      "podman-pterodactyl-test-db.service"
      "podman-pterodactyl-test-redis.service"
    ];
    unitConfig.RequiresMountsFor = "/run/containers";
    serviceConfig = {
      Type = "oneshot";
      Restart = "no";
      ExecStart = pkgs.writeShellScript "pod-pterodactyl-test" ''
        ${pkgs.podman}/bin/podman pod exists pterodactyl-test || \
        ${pkgs.podman}/bin/podman pod create -p 9002:9000 \
          --memory 4G --cpus 0 pterodactyl-test
      '';
    };
    path = [ pkgs.podman ];
  };

  systemd.services.pterodactyl-test-panel-perms = {
    description = "Keep test panel checkout owned by prestonh:users with group access for the container";
    wantedBy = [ "multi-user.target" ];
    before = [ "podman-pterodactyl-test.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      install -d -o prestonh -g users -m 2775 ${testPanelDir}
      chown -R prestonh:users ${testPanelDir}
      find ${testPanelDir} -type d -exec chmod 2775 {} +
      find ${testPanelDir} -type f -exec chmod 0664 {} +
      for dir in storage bootstrap/cache vendor; do
        if [ -d "${testPanelDir}/$dir" ]; then
          ${pkgs.acl}/bin/setfacl -R -m u:pterodactyl:rwx "${testPanelDir}/$dir"
          ${pkgs.acl}/bin/setfacl -R -d -m u:pterodactyl:rwx "${testPanelDir}/$dir"
        fi
      done
    '';
  };

  virtualisation.oci-containers.containers = {
    pterodactyl-test = {
      autoStart = true;
      # Primary group "users" so new files under setgid dirs stay group-writable.
      user = "pterodactyl:users";
      volumes = [
        "/etc/passwd:/etc/passwd:ro"
        "/etc/group:/etc/group:ro"
        "${testPanelDir}:/var/www/pterodactyl"
        "/pterodactyl-test/sockets/mysqld:/run/mysqld"
        "/pterodactyl-test/sockets/php:/run/php-fpm"
        "${testEnvFile}:/var/www/pterodactyl/.env:U"
      ];
      extraOptions = [
        "--pod=pterodactyl-test"
        "--env-file=${testEnvFile}"
      ];
      image = "pterodactyl-runtime:v1.11.11";
      imageFile = pterodactylImages.runtimeImage;
    };

    pterodactyl-test-db = {
      autoStart = true;
      user = "pterodactyl:pterodactyl";
      volumes = [
        "/etc/passwd:/etc/passwd:ro"
        "/etc/group:/etc/group:ro"
        "/pterodactyl-test/data:/var/lib/mysql"
        "/pterodactyl-test/sockets/mysqld:/var/run/mysqld"
      ];
      cmd = [ "--transaction-isolation=READ-COMMITTED" "--log-bin=msqyld-bin" "--binlog-format=ROW" ];
      dependsOn = [ "pterodactyl-test-redis" ];
      extraOptions = [
        "--pod=pterodactyl-test"
        "--env-file=${testEnvFile}"
      ];
      image = "mariadb:latest";
    };

    pterodactyl-test-redis = {
      autoStart = true;
      user = "pterodactyl:pterodactyl";
      volumes = [
        "/etc/passwd:/etc/passwd:ro"
        "/etc/group:/etc/group:ro"
        "/pterodactyl-test/redis:/data"
      ];
      cmd = [ "redis-server" "--save" "59" "1" "--loglevel" "warning" ];
      extraOptions = [ "--pod=pterodactyl-test" ];
      image = "redis:latest";
    };
  };
}
