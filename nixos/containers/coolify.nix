# Coolify control plane (https://coolify.io) on ace.
#
# Only the dashboard runs here: app, Postgres and Redis share the `coolify`
# pod, published on loopback for Caddy (nixos/caddy/coolify.nix). Coolify
# deploys applications over SSH to the Docker hosts registered in its UI
# (crux today; see docs/coolify.md). Upstream's installer expects Docker and
# /data/coolify; this module is the Podman/NixOS equivalent of its
# docker-compose.prod.yml.
#
# Secrets live in nix-secrets secrets/containers/coolify.yaml:
#   coolify-env       -> the app's .env (APP_KEY encrypts Coolify's DB values;
#                        losing it makes stored server keys unreadable)
#   coolify-db-env    -> POSTGRES_* for coolify-db
#   coolify-redis-env -> REDIS_PASSWORD for coolify-redis
{ config, pkgs, lib, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  sopsFile = "${sops-path}/secrets/containers/coolify.yaml";
  root = "/stor/coolify";

  # Pinned by digest (podman rejects tag+digest references). Versions:
  # coolify 4.4.6, postgres 15-alpine, redis 7-alpine as of 2026-10-18.
  coolifyImage = "ghcr.io/coollabsio/coolify@sha256:5e13a1b4c2abcce69a3ed840c67f3e24244f9a75e72d5ce88a9f2636ba67b2cc";
  postgresImage = "docker.io/library/postgres@sha256:25d430274d8a31184f9435cc5b2f56aff254952065bbbcac0c51acedb5a1d1e7";
  redisImage = "docker.io/library/redis@sha256:ca0acbb137c1dc3339c8b147a58fd6f42775d4599327b50e7b116c23de501af2";

  # The coolify image runs as www-data, which is uid/gid 9999 inside it.
  appUid = 9999;
  # The redis image's built-in user is 999, which is nm-iodine on ace.
  redisUid = 10010;

  containers = [ "coolify" "coolify-db" "coolify-redis" ];
in
{
  sops.secrets = {
    "coolify-env" = {
      inherit sopsFile;
      # Bind-mounted as the app's .env, so the container user must read it.
      uid = appUid;
      mode = "0400";
      restartUnits = [ "podman-coolify.service" ];
    };
    "coolify-db-env" = {
      inherit sopsFile;
      mode = "0400";
      restartUnits = [ "podman-coolify-db.service" ];
    };
    "coolify-redis-env" = {
      inherit sopsFile;
      mode = "0400";
      restartUnits = [ "podman-coolify-redis.service" ];
    };
  };

  users.users.coolify-redis = {
    isSystemUser = true;
    group = "coolify-redis";
    uid = redisUid;
  };
  users.groups.coolify-redis.gid = redisUid;

  systemd.tmpfiles.rules = [
    "d ${root} 0750 root root -"
    "d ${root}/app 0700 ${toString appUid} ${toString appUid} -"
    "d ${root}/app/ssh 0700 ${toString appUid} ${toString appUid} -"
    "d ${root}/app/applications 0700 ${toString appUid} ${toString appUid} -"
    "d ${root}/app/databases 0700 ${toString appUid} ${toString appUid} -"
    "d ${root}/app/services 0700 ${toString appUid} ${toString appUid} -"
    "d ${root}/app/backups 0700 ${toString appUid} ${toString appUid} -"
    "d ${root}/app/images 0700 ${toString appUid} ${toString appUid} -"
    # Alpine postgres drops to uid 70 (the host's `postgres` user).
    "d ${root}/postgres 0700 70 70 -"
    "d ${root}/redis 0700 ${toString redisUid} ${toString redisUid} -"
  ];

  systemd.services.pod-coolify = {
    description = "Start podman's 'coolify' pod";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    before = map (c: "podman-${c}.service") containers;
    requiredBy = map (c: "podman-${c}.service") containers;
    unitConfig.RequiresMountsFor = [ "/run/containers" root ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "pod-coolify" ''
        # Loopback only: Caddy is the sole client, and netavark DNATs published
        # ports ahead of nixos-fw. 8000 = dashboard, 6001 = realtime (websocket),
        # 6002 = web terminal.
        ${pkgs.podman}/bin/podman pod exists coolify || \
        ${pkgs.podman}/bin/podman pod create \
          -p 127.0.0.1:8000:8080 -p 127.0.0.1:6001:6001 -p 127.0.0.1:6002:6002 \
          --add-host=host.docker.internal:host-gateway \
          --memory 4G --cpus 0 coolify
      '';
    };
  };

  virtualisation.oci-containers.containers = {
    "coolify-db" = {
      autoStart = true;
      image = postgresImage;
      volumes = [ "${root}/postgres:/var/lib/postgresql/data" ];
      environmentFiles = [ config.sops.secrets."coolify-db-env".path ];
      extraOptions = [
        "--pod=coolify"
        "--health-cmd=pg_isready -U coolify -d coolify"
        "--health-interval=10s"
      ];
    };

    "coolify-redis" = {
      autoStart = true;
      image = redisImage;
      user = "${toString redisUid}:${toString redisUid}";
      volumes = [ "${root}/redis:/data" ];
      environmentFiles = [ config.sops.secrets."coolify-redis-env".path ];
      # requirepass comes from the env file, so expand it in a shell.
      entrypoint = "/bin/sh";
      cmd = [ "-c" ''exec redis-server --save 20 1 --loglevel warning --requirepass "$REDIS_PASSWORD"'' ];
      extraOptions = [ "--pod=coolify" ];
    };

    "coolify" = {
      autoStart = true;
      image = coolifyImage;
      dependsOn = [ "coolify-db" "coolify-redis" ];
      volumes = [
        "${config.sops.secrets."coolify-env".path}:/var/www/html/.env:ro"
        "${root}/app/ssh:/var/www/html/storage/app/ssh"
        "${root}/app/applications:/var/www/html/storage/app/applications"
        "${root}/app/databases:/var/www/html/storage/app/databases"
        "${root}/app/services:/var/www/html/storage/app/services"
        "${root}/app/backups:/var/www/html/storage/app/backups"
        "${root}/app/images:/var/www/html/storage/app/images"
      ];
      environmentFiles = [ config.sops.secrets."coolify-env".path ];
      environment = {
        APP_ENV = "production";
        PHP_MEMORY_LIMIT = "256M";
        PHP_FPM_PM_CONTROL = "dynamic";
        PHP_FPM_PM_START_SERVERS = "1";
        PHP_FPM_PM_MIN_SPARE_SERVERS = "1";
        PHP_FPM_PM_MAX_SPARE_SERVERS = "10";
        PUSHER_BACKEND_PORT = "6001";
      };
      extraOptions = [
        "--pod=coolify"
        "--health-cmd=curl -fsS http://127.0.0.1:8080/api/health && curl -fsS http://127.0.0.1:6001/up"
        "--health-interval=30s"
        "--health-start-period=2m"
      ];
    };
  };
}
