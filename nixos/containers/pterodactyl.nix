{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  pterodactylImages = import ./pterodactyl-docker.nix {
    inherit pkgs sops-path;
  };
  inherit (pterodactylImages) panelUpdateEnvStock version;
  # Host /etc/hosts maps *.prestonhager.com → 127.0.0.1; inside the pod that is
  # loopback, not Caddy on the host. Override so server-side OAuth token calls work.
  zitadelDomain = "zitadel.prestonhager.com";

  # Valkey requires a password. Generated once on the host (no nix-secrets entry) and
  # handed to Valkey as a config file. The panel entrypoint re-exports the persisted
  # /pterodactyl/html/.env over the container env, so REDIS_PASSWORD is kept in sync
  # there; REDISCLI_AUTH (env file) lets `podman exec pterodactyl redis-cli` health
  # checks authenticate.
  redisAuthDir = "/var/lib/redis-auth/pterodactyl";
  redisAuthScript = pkgs.writeShellScript "pterodactyl-redis-auth" ''
    set -euo pipefail
    umask 077
    dir=${redisAuthDir}
    install -d -m 0700 /var/lib/redis-auth "$dir"
    if [ ! -s "$dir/password" ]; then
      od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "$dir/password.tmp"
      mv -f "$dir/password.tmp" "$dir/password"
    fi
    pw="$(cat "$dir/password")"
    uid="$(id -u pterodactyl)"
    gid="$(id -g pterodactyl)"
    printf 'requirepass %s\n' "$pw" > "$dir/valkey.conf.tmp"
    chown "$uid:$gid" "$dir/valkey.conf.tmp"
    chmod 0400 "$dir/valkey.conf.tmp"
    mv -f "$dir/valkey.conf.tmp" "$dir/valkey.conf"
    printf 'REDIS_PASSWORD=%s\nREDISCLI_AUTH=%s\n' "$pw" "$pw" > "$dir/app.env.tmp"
    mv -f "$dir/app.env.tmp" "$dir/app.env"

    # Rewrite REDIS_PASSWORD in the panel's .env in place (keeps owner/mode); printf is
    # a builtin, so the password never reaches a command line.
    envf=/pterodactyl/html/.env
    cur=""
    if [ -f "$envf" ]; then
      cur="$(grep '^REDIS_PASSWORD=' "$envf" | head -n1 | cut -d= -f2- || true)"
    fi
    if [ -f "$envf" ] && [ "$cur" != "$pw" ]; then
      grep -v '^REDIS_PASSWORD=' "$envf" > "$dir/panel.env.tmp" || true
      printf 'REDIS_PASSWORD=%s\n' "$pw" >> "$dir/panel.env.tmp"
      cat "$dir/panel.env.tmp" > "$envf"
      rm -f "$dir/panel.env.tmp" /pterodactyl/html/bootstrap/cache/config.php
    fi
  '';
in
{
  imports = [
    ./pterodactyl-stock-reset.nix
    ./pterodactyl-blueprint.nix
    ./pterodactyl-blueprint-extensions-configure.nix
    ./pterodactyl-sso.nix
    ./pterodactyl-extensions.nix
  ];
  sops.secrets = {
    "pterodactyl-env" = {
      sopsFile = "${sops-path}/secrets/containers/pterodactyl.yaml";
      mode = "0640";
      owner = "pterodactyl";
      group = "pterodactyl";
    };
    "pterodactyl-router-ssh-key" = {
      sopsFile = "${sops-path}/secrets/containers/pterodactyl.yaml";
      mode = "0600";
      owner = "pterodactyl";
      group = "pterodactyl";
    };
  };

  # Create the pterodactyl user and group
  users.users.pterodactyl = {
    isSystemUser = true;
    description = "Pterodactyl";
    group = "pterodactyl";
    # Service account: no password login. (It used to take a hash from the
    # pterodactyl-password sops key, which can now be dropped from nix-secrets.)
    hashedPassword = "!";
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

  systemd.services.pterodactyl-redis-auth = {
    description = "Generate the Pterodactyl Valkey password and config";
    before = [
      "podman-pterodactyl.service"
      "podman-pterodactyl-redis.service"
    ];
    requiredBy = [
      "podman-pterodactyl.service"
      "podman-pterodactyl-redis.service"
    ];
    after = [ "systemd-tmpfiles-setup.service" ];
    path = [ pkgs.coreutils pkgs.gnugrep ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = redisAuthScript;
    };
  };

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
      RemainAfterExit = true;
      Restart = "no";
      ExecStart = pkgs.writeShellScript "pod-pterodactyl" ''
        set -euo pipefail
        podman=${pkgs.podman}/bin/podman
        hostGw="$(${pkgs.iproute2}/bin/ip -4 -o addr show podman0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
        if [ -z "''${hostGw}" ]; then
          hostGw="10.88.0.1"
        fi

        pod_network_ok() {
          $podman container exists pterodactyl 2>/dev/null || return 0
          $podman container exists pterodactyl-redis 2>/dev/null || return 0
          $podman exec pterodactyl redis-cli -h 127.0.0.1 ping 2>/dev/null | grep -q PONG
        }

        pod_hosts_ok() {
          $podman pod inspect pterodactyl --format '{{range .InfraConfig.HostAdd}}{{.}} {{end}}' 2>/dev/null \
            | grep -q "${zitadelDomain}:''${hostGw}"
        }

        if $podman pod exists pterodactyl && { ! pod_network_ok || ! pod_hosts_ok; }; then
          if ! pod_network_ok; then
            echo "pod-pterodactyl: panel cannot reach redis in pod; recreating pod"
          else
            echo "pod-pterodactyl: missing Zitadel host-gateway mapping; recreating pod"
          fi
          $podman pod stop -t 30 pterodactyl || true
          $podman pod rm -f pterodactyl
        fi

        # Publish on loopback only: Caddy is the sole client, and netavark DNATs
        # published ports ahead of nixos-fw, so 0.0.0.0 exposed raw FastCGI to the LAN.
        $podman pod exists pterodactyl || \
        $podman pod create -p 127.0.0.1:9001:9000 \
          --add-host=${zitadelDomain}:''${hostGw} \
          --add-host=host.containers.internal:host-gateway \
          --memory 8G --cpus 0 pterodactyl
      '';
    };
    path = [ pkgs.podman pkgs.coreutils pkgs.gnugrep pkgs.iproute2 pkgs.gawk ];
  };

  systemd.services.pterodactyl-pod-network-check = {
    description = "Ensure Pterodactyl pod containers share network namespace";
    after = [
      "podman-pterodactyl.service"
      "podman-pterodactyl-db.service"
      "podman-pterodactyl-redis.service"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "10min";
      ExecStart = pkgs.writeShellScript "pterodactyl-pod-network-check" ''
        set -euo pipefail
        podman=${pkgs.podman}/bin/podman

        if $podman exec pterodactyl redis-cli -h 127.0.0.1 ping 2>/dev/null | grep -q PONG; then
          echo "pterodactyl-pod-network-check: pod network OK"
          exit 0
        fi

        echo "pterodactyl-pod-network-check: redis unreachable from panel; recreating pod" >&2
        systemctl stop podman-pterodactyl.service podman-pterodactyl-db.service podman-pterodactyl-redis.service 2>/dev/null || true
        systemctl stop pod-pterodactyl.service 2>/dev/null || true
        $podman pod stop -t 30 pterodactyl 2>/dev/null || true
        $podman pod rm -f pterodactyl 2>/dev/null || true
        systemctl start pod-pterodactyl.service
        systemctl start podman-pterodactyl-db.service podman-pterodactyl-redis.service
        sleep 2
        systemctl start podman-pterodactyl.service
        sleep 5
        $podman exec pterodactyl redis-cli -h 127.0.0.1 ping | grep -q PONG
        $podman exec pterodactyl php /var/www/pterodactyl/artisan config:clear
        $podman exec pterodactyl php /var/www/pterodactyl/artisan cache:clear
      '';
    };
    path = [ pkgs.podman pkgs.coreutils pkgs.systemd pkgs.gnugrep pkgs.procps ];
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
        "/pterodactyl/secrets:/pterodactyl/secrets:ro"
        "${config.sops.secrets."pterodactyl-env".path}:/var/www/pterodactyl/.env.initial:U"
      ];

      environment = panelUpdateEnvStock // {
        ENV_FILE = "${config.sops.secrets."pterodactyl-env".path}";
      };

      extraOptions = [
        "--pod=pterodactyl"
        "--env-file=${config.sops.secrets."pterodactyl-env".path}"
        "--env-file=/pterodactyl/secrets/blueprint-extensions.env"
        "--env-file=${redisAuthDir}/app.env"
        # The Nix-built runtime image has no /tmp; PHP (uploads, composer
        # during SSO setup) needs a writable temp dir.
        "--tmpfs=/tmp:rw,mode=1777,size=512m"
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

      image = "mariadb:12.3.2";
    };
    # Redis is not required, but is a great cache system
    "pterodactyl-redis" = {
      autoStart = true;

      user = "pterodactyl:pterodactyl";

      volumes = [
        "/etc/passwd:/etc/passwd:ro"
        "/etc/group:/etc/group:ro"
        "/pterodactyl/redis:/data"
        "${redisAuthDir}/valkey.conf:/etc/valkey-auth.conf:ro"
      ];

      # Pod-local (the panel uses REDIS_HOST=127.0.0.1) and password-protected.
      cmd = [ "redis-server" "/etc/valkey-auth.conf" "--bind" "127.0.0.1" "--save" "59" "1" "--loglevel" "warning" ];

      extraOptions = [ "--pod=pterodactyl" ];

      image = "docker.io/valkey/valkey@sha256:081c2f5cb575efc901aa80ff9cdbd1ec6a301682fd35e1ebb4b0990a4a4a8507"; # valkey 8.1.10-alpine (BSD fork of Redis; cache/sessions only)
    };
  };
}
