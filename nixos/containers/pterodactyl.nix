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
in
{
  imports = [
    ./pterodactyl-stock-reset.nix
    ./pterodactyl-blueprint.nix
    ./pterodactyl-sso.nix
  ];
  sops.secrets = {
    "pterodactyl-env" = {
      sopsFile = "${sops-path}/secrets/containers/pterodactyl.yaml";
      mode = "0640";
      owner = "pterodactyl";
      group = "pterodactyl";
    };
    "pterodactyl-password" = {
      sopsFile = "${sops-path}/secrets/containers/pterodactyl.yaml";
      mode = "0640";
    };
  };

  # Create the pterodactyl user and group
  users.users.pterodactyl = {
    isSystemUser = true;
    description = "Pterodactyl";
    group = "pterodactyl";
    hashedPasswordFile = config.sops.secrets."pterodactyl-password".path;
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

        $podman pod exists pterodactyl || \
        $podman pod create -p 9001:9000 \
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
        systemctl stop podman-pterodactyl.service podman-pterodactyl-db.service podman-pterodactyl-redis.service
        $podman pod stop -t 30 pterodactyl || true
        $podman pod rm -f pterodactyl
        systemctl start pod-pterodactyl.service podman-pterodactyl-redis.service podman-pterodactyl-db.service podman-pterodactyl.service
        sleep 5
        $podman exec pterodactyl redis-cli -h 127.0.0.1 ping | grep -q PONG
        systemctl restart podman-pterodactyl.service
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
        "${config.sops.secrets."pterodactyl-env".path}:/var/www/pterodactyl/.env.initial:U"
      ];

      environment = panelUpdateEnvStock // {
        ENV_FILE = "${config.sops.secrets."pterodactyl-env".path}";
      };

      extraOptions = [
        "--pod=pterodactyl"
        "--env-file=${config.sops.secrets."pterodactyl-env".path}"
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

      image = "mariadb:latest";
    };
    # Redis is not required, but is a great cache system
    "pterodactyl-redis" = {
      autoStart = true;

      user = "pterodactyl:pterodactyl";

      volumes = [
        "/etc/passwd:/etc/passwd:ro"
        "/etc/group:/etc/group:ro"
        "/pterodactyl/redis:/data"
      ];

      cmd = [ "redis-server" "--save" "59" "1" "--loglevel" "warning" ];

      extraOptions = [ "--pod=pterodactyl" ];

      image = "redis:latest";
    };
  };
}
