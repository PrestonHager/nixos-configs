{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  pterodactylImages = import ./pterodactyl-docker.nix {
    inherit pkgs sops-path;
  };
  testEnvFile = "/var/lib/pterodactyl-test/pterodactyl.env";
  testPanelDir = "/home/prestonh/Projects/panel";
  setupMarker = "/var/lib/pterodactyl-test/setup-complete";
  adminCredentialsFile = "/var/lib/pterodactyl-test/admin-credentials";

  setupScript = pkgs.writeShellScript "pterodactyl-test-setup" ''
    set -euo pipefail

    MARKER=${setupMarker}
    ADMIN_FILE=${adminCredentialsFile}
    ENV_FILE=${testEnvFile}
    PANEL=${testPanelDir}

    if [ -f "$MARKER" ]; then
      exit 0
    fi

    if [ ! -f "$ENV_FILE" ]; then
      echo "pterodactyl-test-setup: missing $ENV_FILE (run pterodactyl-test-env first)" >&2
      exit 1
    fi

    # shellcheck disable=SC1090
    set -a
    source "$ENV_FILE"
    set +a

    PODMAN=${pkgs.podman}/bin/podman
    exec_panel() {
      "$PODMAN" exec \
        -e HOME=/var/www/pterodactyl \
        -e COMPOSER_HOME=/tmp/composer \
        -e GIT_CONFIG_COUNT=1 \
        -e GIT_CONFIG_KEY_0=safe.directory \
        -e GIT_CONFIG_VALUE_0=/var/www/pterodactyl \
        --env-file="$ENV_FILE" \
        pterodactyl-test "$@"
    }

    echo "pterodactyl-test-setup: waiting for test pod containers..."
    for _ in $(seq 1 90); do
      if "$PODMAN" container inspect pterodactyl-test-db --format '{{.State.Running}}' 2>/dev/null | grep -q true \
        && "$PODMAN" container inspect pterodactyl-test-redis --format '{{.State.Running}}' 2>/dev/null | grep -q true \
        && "$PODMAN" container inspect pterodactyl-test --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
        break
      fi
      sleep 2
    done

    echo "pterodactyl-test-setup: waiting for MariaDB..."
    for _ in $(seq 1 60); do
      if exec_panel mysql -h127.0.0.1 -P3306 -uroot -p"$MARIADB_ROOT_PASSWORD" -e "SELECT 1" &>/dev/null; then
        break
      fi
      sleep 2
    done

    echo "pterodactyl-test-setup: ensuring database and user exist..."
    exec_panel mysql -h127.0.0.1 -P3306 -uroot -p"$MARIADB_ROOT_PASSWORD" <<EOF
CREATE DATABASE IF NOT EXISTS \`$DB_DATABASE\`;
CREATE USER IF NOT EXISTS '$DB_USERNAME'@'%' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON \`$DB_DATABASE\`.* TO '$DB_USERNAME'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

    echo "pterodactyl-test-setup: waiting for Redis..."
    for _ in $(seq 1 30); do
      if exec_panel redis-cli -h "$REDIS_HOST" -p "''${REDIS_PORT:-6379}" ping 2>/dev/null | grep -q PONG; then
        break
      fi
      sleep 2
    done

    if [ ! -f "$PANEL/vendor/autoload.php" ]; then
      echo "pterodactyl-test-setup: installing Composer dependencies..."
      exec_panel sh -c 'cd /var/www/pterodactyl && composer install --no-dev --optimize-autoloader'
    fi

    echo "pterodactyl-test-setup: running migrations..."
    exec_panel php /var/www/pterodactyl/artisan migrate --force --seed

    echo "pterodactyl-test-setup: clearing config cache..."
    exec_panel php /var/www/pterodactyl/artisan config:clear
    exec_panel php /var/www/pterodactyl/artisan view:clear

    USER_COUNT=$(exec_panel php -r '
      require "/var/www/pterodactyl/vendor/autoload.php";
      $app = require "/var/www/pterodactyl/bootstrap/app.php";
      $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
      echo \Pterodactyl\Models\User::count();
    ')

    if [ "$USER_COUNT" = "0" ]; then
      ADMIN_EMAIL="''${PTERODACTYL_TEST_ADMIN_EMAIL:-admin@test.panel.prestonhager.com}"
      ADMIN_USERNAME="''${PTERODACTYL_TEST_ADMIN_USERNAME:-admin}"
      ADMIN_PASSWORD=$(${pkgs.openssl}/bin/openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20)

      echo "pterodactyl-test-setup: creating initial admin user..."
      exec_panel php /var/www/pterodactyl/artisan p:user:make \
        --email="$ADMIN_EMAIL" \
        --username="$ADMIN_USERNAME" \
        --name-first=Admin \
        --name-last=User \
        --password="$ADMIN_PASSWORD" \
        --admin=1

      umask 077
      cat > "$ADMIN_FILE" <<EOF
# Initial test panel admin (created once by pterodactyl-test-setup.service)
email=$ADMIN_EMAIL
username=$ADMIN_USERNAME
password=$ADMIN_PASSWORD
url=$APP_URL
EOF
      chmod 0600 "$ADMIN_FILE"
      chown root:root "$ADMIN_FILE"
      echo "pterodactyl-test-setup: admin credentials written to $ADMIN_FILE"
    else
      echo "pterodactyl-test-setup: users already exist ($USER_COUNT), skipping admin creation"
    fi

    touch "$MARKER"
    chmod 0644 "$MARKER"
    echo "pterodactyl-test-setup: complete"
'';
in
{
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
      APP_KEY=$(${pkgs.php83}/bin/php -r "echo 'base64:'.base64_encode(random_bytes(32));")
      HASHIDS=$(rand_pass)
      cat > "$ENV" <<EOF
APP_ENV=production
APP_DEBUG=true
APP_THEME=pterodactyl
APP_TIMEZONE=UTC
APP_URL=https://test.panel.prestonhager.com
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

  systemd.services.pterodactyl-test-panel-perms = {
    description = "Keep test panel checkout owned by prestonh:users with group access for the container";
    wantedBy = [ "multi-user.target" ];
    before = [
      "podman-pterodactyl-test.service"
      "pterodactyl-test-setup.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      # Prevent the container entrypoint from running its broken first-boot setup.
      touch ${testPanelDir}/.setup_done
      chown prestonh:users ${testPanelDir}/.setup_done
      chmod o+x /home/prestonh
      ${pkgs.acl}/bin/setfacl -m u:caddy:x /home/prestonh
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

  # Re-applied every boot; prestonh home is often 0700 and blocks Caddy from /assets.
  systemd.services.pterodactyl-test-caddy-access = {
    description = "Allow Caddy to read test panel files under prestonh home";
    wantedBy = [ "multi-user.target" ];
    before = [ "caddy.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      chmod o+x /home/prestonh
      ${pkgs.acl}/bin/setfacl -m u:caddy:x /home/prestonh
    '';
  };

  systemd.services.pterodactyl-test-setup = {
    description = "One-time database migration and admin user for the test Pterodactyl panel";
    wantedBy = [ "multi-user.target" ];
    after = [
      "podman-pterodactyl-test.service"
      "podman-pterodactyl-test-db.service"
      "podman-pterodactyl-test-redis.service"
      "pterodactyl-test-panel-perms.service"
    ];
    wants = [
      "podman-pterodactyl-test.service"
      "podman-pterodactyl-test-db.service"
      "podman-pterodactyl-test-redis.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "30min";
      ExecStart = setupScript;
    };
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

  virtualisation.oci-containers.containers = {
    pterodactyl-test = {
      autoStart = true;
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
