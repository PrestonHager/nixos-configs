{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  ncRoot = "/stor/nextcloud";
  nextcloudImage = "docker.io/library/nextcloud:31.0.14";
  clamavImage = "docker.io/clamav/clamav:stable";
  nextcloudPublicUrl = "https://cloud.prestonhager.com";
  nextcloudPushUrl = "${nextcloudPublicUrl}/push";
  nextcloudApacheHsts = pkgs.writeText "nextcloud-hsts.conf" ''
    <IfModule mod_headers.c>
      Header always set Strict-Transport-Security "max-age=15552000; includeSubDomains"
    </IfModule>
  '';
  ncRuntimeEnv = "/run/nextcloud/container.env";
  nextcloudEnvScript = pkgs.writeShellScript "nextcloud-container-env" ''
    set -euo pipefail
    mkdir -p /run/nextcloud
    ncEnv="${config.sops.secrets."nextcloud-environment".path}"
    out="${ncRuntimeEnv}"
    cp "$ncEnv" "$out"
    if ! grep -q '^MYSQL_PASSWORD=' "$out"; then
      dbPass="$(grep '^MARIADB_PASSWORD=' "$ncEnv" | cut -d= -f2- || true)"
      if [ -z "$dbPass" ]; then
        echo "nextcloud-container-env: MARIADB_PASSWORD missing from nextcloud-environment" >&2
        exit 1
      fi
      printf 'MYSQL_PASSWORD=%s\n' "$dbPass" >> "$out"
    fi
    cat >> "$out" <<'EOF'
NEXTCLOUD_ADMIN_USER=nextcloud-admin
MYSQL_DATABASE=nextcloud
MYSQL_USER=nextcloud
MYSQL_HOST=127.0.0.1
EOF
    chmod 600 "$out"
  '';
  nextcloudOccInstallScript = pkgs.writeShellScript "nextcloud-occ-install" ''
    set -euo pipefail
    for _ in $(seq 1 60); do
      if ${pkgs.podman}/bin/podman exec nextcloud true 2>/dev/null; then
        break
      fi
      sleep 2
    done

    if ! ${pkgs.podman}/bin/podman exec nextcloud true 2>/dev/null; then
      echo "nextcloud-occ-install: nextcloud container not running" >&2
      exit 1
    fi

    if ${pkgs.podman}/bin/podman exec -u www-data nextcloud php /var/www/html/occ status 2>/dev/null \
      | grep -q 'installed: true'; then
      exit 0
    fi

    set -a
    # shellcheck disable=SC1091
    . "${ncRuntimeEnv}"
    set +a

    : "''${NEXTCLOUD_ADMIN_USER:?}"
    : "''${NEXTCLOUD_ADMIN_PASSWORD:?}"
    : "''${MYSQL_DATABASE:?}"
    : "''${MYSQL_USER:?}"
    : "''${MYSQL_PASSWORD:?}"
    dbHost="''${MYSQL_HOST:-127.0.0.1}"

    for _ in $(seq 1 30); do
      if ${pkgs.podman}/bin/podman exec nextcloud-db \
        mariadb-admin ping -h127.0.0.1 -u"''${MYSQL_USER}" -p"''${MYSQL_PASSWORD}" --silent 2>/dev/null; then
        break
      fi
      sleep 2
    done

    tableCount="$(${pkgs.podman}/bin/podman exec nextcloud-db mariadb -h127.0.0.1 -u"''${MYSQL_USER}" -p"''${MYSQL_PASSWORD}" -N -D "''${MYSQL_DATABASE}" -e "SHOW TABLES LIKE 'oc_%';" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
    if [ "''${tableCount}" != "0" ] && ${pkgs.podman}/bin/podman exec nextcloud test -f /var/www/html/config/config.php; then
      if ! ${pkgs.podman}/bin/podman exec nextcloud grep -q "'installed'" /var/www/html/config/config.php 2>/dev/null; then
        echo "nextcloud-occ-install: restoring installed flag on existing database"
        ${pkgs.podman}/bin/podman exec nextcloud sed -i "/^);/i\\  'installed' => true," /var/www/html/config/config.php
      fi
      exit 0
    fi

    if ${pkgs.podman}/bin/podman exec nextcloud test -f /var/www/html/config/config.php \
      && ! ${pkgs.podman}/bin/podman exec -u www-data nextcloud php /var/www/html/occ status 2>/dev/null \
        | grep -q 'installed: true'; then
      echo "nextcloud-occ-install: removing incomplete config.php"
      ${pkgs.podman}/bin/podman exec nextcloud rm -f /var/www/html/config/config.php
    fi

    ${pkgs.podman}/bin/podman exec -u www-data nextcloud php /var/www/html/occ maintenance:install -n \
      --admin-user "''${NEXTCLOUD_ADMIN_USER}" \
      --admin-pass "''${NEXTCLOUD_ADMIN_PASSWORD}" \
      --database mysql \
      --database-name "''${MYSQL_DATABASE}" \
      --database-user "''${MYSQL_USER}" \
      --database-pass "''${MYSQL_PASSWORD}" \
      --database-host "''${dbHost}"
  '';

  nextcloudOccConfigScript = pkgs.writeShellScript "nextcloud-occ-config" ''
    set -euo pipefail
    marker="${ncRoot}/.occ-expensive-repair-done"
    for _ in $(seq 1 60); do
      if ${pkgs.podman}/bin/podman exec nextcloud true 2>/dev/null; then
        break
      fi
      sleep 2
    done

    if ! ${pkgs.podman}/bin/podman exec nextcloud true 2>/dev/null; then
      echo "nextcloud-occ-config: nextcloud container not running" >&2
      exit 1
    fi

    if ! ${pkgs.podman}/bin/podman exec nextcloud test -f /var/www/html/config/config.php; then
      echo "nextcloud-occ-config: config.php missing, skipping" >&2
      exit 0
    fi

    if ! ${pkgs.podman}/bin/podman exec -u www-data nextcloud php /var/www/html/occ status 2>/dev/null \
      | grep -q 'installed: true'; then
      echo "nextcloud-occ-config: Nextcloud not installed, skipping" >&2
      exit 0
    fi

    ${pkgs.podman}/bin/podman exec -u www-data nextcloud php /var/www/html/occ config:system:set \
      maintenance_window_start --type=integer --value=3
    ${pkgs.podman}/bin/podman exec -u www-data nextcloud php /var/www/html/occ config:system:set \
      default_phone_region --value=US
    ${pkgs.podman}/bin/podman exec -u www-data nextcloud php /var/www/html/occ config:system:set \
      strict_transport_security.enabled --type=boolean --value=true

    if [ ! -f "$marker" ]; then
      ${pkgs.podman}/bin/podman exec -u www-data nextcloud php /var/www/html/occ maintenance:repair --include-expensive
      touch "$marker"
    fi
  '';

  nextcloudOccMaintainScript = pkgs.writeShellScript "nextcloud-occ-maintain" ''
    set -euo pipefail
    podman=${pkgs.podman}/bin/podman
    occ() {
      $podman exec -u www-data nextcloud php /var/www/html/occ "$@"
    }

    for _ in $(seq 1 60); do
      if $podman exec nextcloud true 2>/dev/null; then
        break
      fi
      sleep 2
    done

    if ! $podman exec nextcloud true 2>/dev/null; then
      echo "nextcloud-occ-maintain: nextcloud container not running" >&2
      exit 1
    fi

    if ! $podman exec nextcloud test -f /var/www/html/config/config.php; then
      echo "nextcloud-occ-maintain: config.php missing, skipping" >&2
      exit 0
    fi

    if ! occ status 2>/dev/null | grep -q 'installed: true'; then
      echo "nextcloud-occ-maintain: Nextcloud not installed, skipping" >&2
      exit 0
    fi

    occ upgrade --no-interaction

    if ! occ app:list 2>/dev/null | grep -qE '(^| )- notify_push:'; then
      occ app:install notify_push
    fi
    occ app:enable notify_push

    for _ in $(seq 1 120); do
      if $podman exec nextcloud bash -c 'exec 3<>/dev/tcp/127.0.0.1/3310' 2>/dev/null; then
        $podman exec nextcloud bash -c 'exec 3<&- 3>&-' 2>/dev/null || true
        break
      fi
      sleep 5
    done

    occ config:app:set files_antivirus av_mode --value=daemon
    occ config:app:set files_antivirus av_host --value=127.0.0.1
    occ config:app:set files_antivirus av_port --value=3310 --type=integer

    for _ in $(seq 1 120); do
      if $podman exec nextcloud test -x /var/www/html/custom_apps/notify_push/bin/x86_64/notify_push; then
        break
      fi
      sleep 2
    done

    for _ in $(seq 1 60); do
      if $podman exec nextcloud bash -c 'exec 3<>/dev/tcp/127.0.0.1/7867' 2>/dev/null; then
        $podman exec nextcloud bash -c 'exec 3<&- 3>&-' 2>/dev/null || true
        break
      fi
      sleep 2
    done

    if ! occ notify_push:setup "${nextcloudPushUrl}"; then
      echo "nextcloud-occ-maintain: notify_push setup failed; retry after notify_push container is healthy" >&2
      exit 1
    fi
  '';

  nextcloudNotifyPushEntrypoint = pkgs.writeShellScript "nextcloud-notify-push-entrypoint" ''
    set -euo pipefail
    binary=/var/www/html/custom_apps/notify_push/bin/x86_64/notify_push
    for _ in $(seq 1 180); do
      if [ -x "$binary" ]; then
        export PORT=7867
        export NEXTCLOUD_URL=http://127.0.0.1
        exec "$binary" /var/www/html/config/config.php
      fi
      sleep 2
    done
    echo "nextcloud-notify-push: notify_push binary not found after waiting" >&2
    exit 1
  '';
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
    "d ${ncRoot}/clamav 0770 nm-iodine nscd -"
    "d /run/nextcloud 0750 root root -"
  ];

  systemd.services.nextcloud-container-env = {
    description = "Build Nextcloud container environment (MYSQL_PASSWORD alias)";
    wantedBy = [
      "podman-nextcloud.service"
      "podman-nextcloud-db.service"
    ];
    before = [
      "podman-nextcloud.service"
      "podman-nextcloud-db.service"
    ];
    after = [ "sops-nix.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = nextcloudEnvScript;
    };
  };

  systemd.services.nextcloud-occ-install = {
    description = "Run occ maintenance:install when Nextcloud is not installed";
    wantedBy = [ "multi-user.target" ];
    after = [
      "podman-nextcloud.service"
      "podman-nextcloud-db.service"
      "nextcloud-container-env.service"
    ];
    requires = [
      "podman-nextcloud.service"
      "podman-nextcloud-db.service"
      "nextcloud-container-env.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = nextcloudOccInstallScript;
    };
  };



  systemd.services.nextcloud-occ-config = {
    description = "Apply Nextcloud system settings and one-time expensive repair";
    wantedBy = [ "multi-user.target" ];
    after = [
      "nextcloud-occ-install.service"
      "podman-nextcloud.service"
    ];
    requires = [ "podman-nextcloud.service" ];
    unitConfig.ConditionPathExists = "${ncRoot}/data/config/config.php";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = nextcloudOccConfigScript;
    };
  };

  systemd.services.nextcloud-occ-maintain = {
    description = "Upgrade Nextcloud, configure notify_push and ClamAV";
    wantedBy = [ "multi-user.target" ];
    after = [
      "nextcloud-occ-config.service"
      "podman-nextcloud.service"
      "podman-nextcloud-clamav.service"
      "podman-nextcloud-notify-push.service"
    ];
    requires = [
      "podman-nextcloud.service"
      "podman-nextcloud-clamav.service"
    ];
    unitConfig.ConditionPathExists = "${ncRoot}/data/config/config.php";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = nextcloudOccMaintainScript;
    };
  };


  systemd.services."podman-nextcloud" = {
    requires = [ "nextcloud-container-env.service" ];
    after = [ "nextcloud-container-env.service" ];
    serviceConfig.ExecStartPre = [ nextcloudEnvScript ];
  };

  systemd.services.pod-nextcloud = {
    description = "Start podman's 'nextcloud' pod";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    requiredBy = [
      "podman-nextcloud.service"
      "podman-nextcloud-db.service"
      "podman-nextcloud-redis.service"
      "podman-nextcloud-clamav.service"
      "podman-nextcloud-notify-push.service"
    ];
    unitConfig = {
      RequiresMountsFor = "/run/containers /stor";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "pod-nextcloud" ''
        set -euo pipefail
        podman=${pkgs.podman}/bin/podman
        if $podman pod exists nextcloud; then
          ports="$($podman pod inspect nextcloud --format '{{json .InfraConfig.PortBindings}}' 2>/dev/null || echo '{}')"
          if ! echo "$ports" | grep -q 7867; then
            echo "pod-nextcloud: recreating pod to publish notify_push port 7867"
            $podman pod stop -t 30 nextcloud || true
            $podman pod rm -f nextcloud
          fi
        fi
        $podman pod exists nextcloud || \
        $podman pod create \
          -p 127.0.0.1:8083:80 \
          -p 127.0.0.1:7867:7867 \
          -h cloud.prestonhager.com \
          nextcloud
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
        "${nextcloudApacheHsts}:/etc/apache2/conf-enabled/z-nextcloud-hsts.conf:ro"
      ];
      environment = {
        APACHE_PORT = "80";
        APACHE_IP_BINDING = "0.0.0.0";
        APACHE_BODY_LIMIT = "0";
        NEXTCLOUD_ADMIN_USER = "nextcloud-admin";
        MYSQL_DATABASE = "nextcloud";
        MYSQL_USER = "nextcloud";
        # Pod shares network namespace; 127.0.0.1 forces TCP (localhost uses socket).
        MYSQL_HOST = "127.0.0.1";
        REDIS_HOST = "127.0.0.1";
        TRUSTED_PROXIES = "127.0.0.1";
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
        "--env-file=${ncRuntimeEnv}"
      ];
      image = nextcloudImage;
    };
    nextcloud-notify-push = {
      autoStart = true;
      user = "root:root";
      image = nextcloudImage;
      entrypoint = "/entrypoint.sh";
      volumes = [
        "${ncRoot}/data/config:/var/www/html/config:ro"
        "${ncRoot}/data/custom_apps:/var/www/html/custom_apps:ro"
        "${nextcloudNotifyPushEntrypoint}:/entrypoint.sh:ro"
      ];
      dependsOn = [ "nextcloud" "nextcloud-clamav" ];
      extraOptions = [ "--pod=nextcloud" ];
    };
    nextcloud-clamav = {
      autoStart = true;
      user = "root:root";
      volumes = [
        "${ncRoot}/clamav:/var/lib/clamav"
      ];
      extraOptions = [ "--pod=nextcloud" ];
      image = clamavImage;
    };
    nextcloud-db = {
      autoStart = true;
      user = "root:root";
      volumes = [
        "${ncRoot}/mysql:/var/lib/mysql:z"
      ];
      cmd = [
        "--transaction-isolation=READ-COMMITTED"
        "--log-bin=mysqld-bin"
        "--binlog-format=ROW"
        "--bind-address=0.0.0.0"
      ];
      environment = {
        MARIADB_DATABASE = "nextcloud";
        MARIADB_USER = "nextcloud";
      };
      dependsOn = [ "nextcloud-redis" ];
      extraOptions = [
        "--pod=nextcloud"
        "--env-file=${config.sops.secrets."nextcloud-db-environment".path}"
      ];
      image = "docker.io/library/mariadb:11.4";
    };
    nextcloud-redis = {
      autoStart = true;
      user = "root:root";
      volumes = [
        "${ncRoot}/redis:/data"
      ];
      cmd = [ "redis-server" "--save" "60" "1" "--loglevel" "warning" "--bind" "127.0.0.1" ];
      extraOptions = [ "--pod=nextcloud" ];
      image = "docker.io/library/redis:latest";
    };
  };
}
