# Adopter Central (NMSU-CS-CS371 group project)
#
# Astro SSR app + MariaDB, deployed by .github/workflows/deploy.yml in
# NMSU-CS-CS371/software-development-semester-project-group-5.
#
# Layout:
#   /stor/adopter-central/app      - symlink to the active release
#   /stor/adopter-central/releases - one directory per deploy
#   /stor/adopter-central/mariadb  - database files
#
# A deploy is: write releases/<sha>, run migrations, repoint `current`, restart
# the app container. `current` is bind-mounted read-only, so rollback is a
# symlink swap plus a restart.
#
# No Caddy vhost yet (deliberately): the app port is published on
# 127.0.0.1:4321 only, reachable over Tailscale or a future reverse proxy.
{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.services.adopterCentral;
  sops-path = builtins.toString inputs.nix-secrets;
  appRoot = "/stor/adopter-central";
  appPort = 4321;
  dbUid = 999;
  appUid = 1002;

  # Placeholder served until the first real deploy lands, so `nixos-rebuild`
  # never fails activation on a fresh host and the reason is obvious in the logs.
  placeholder = pkgs.writeTextFile {
    name = "adopter-central-placeholder.mjs";
    text = ''
      const msg =
        'Adopter Central is running but no release has been deployed yet.\n' +
        'Run the "Deploy to ace" workflow to publish one.\n';
      const server = (await import('node:http')).createServer((_req, res) => {
        res.writeHead(503, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ status: 'placeholder', message: msg }));
      });
      server.listen(4321, '0.0.0.0', () =>
        console.log('adopter-central placeholder listening on 4321 (no release deployed yet)'),
      );
    '';
  };
in
{
  options.services.adopterCentral = {
    enable = lib.mkEnableOption "Adopter Central (Astro SSR + MariaDB)";
    port = lib.mkOption {
      type = lib.types.port;
      default = appPort;
      description = "Host port bound to 127.0.0.1 for the Astro SSR server.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets = {
      "adopter-central-db-env" = {
        sopsFile = "${sops-path}/secrets/containers/adopter-central.yaml";
        key = "adopter-central-db-env";
        mode = "0400";
      };
      "adopter-central-app-env" = {
        sopsFile = "${sops-path}/secrets/containers/adopter-central.yaml";
        key = "adopter-central-app-env";
        mode = "0400";
      };
    };

    # Host-side owners for the bind-mounted volumes. These are deliberately
    # NOT the image users (mariadb uses `mysql`, node uses `node`, both 999 /
    # 1000 in-image) because uid 1000 is already a real user on ace. Podman is
    # given numeric ids below so no in-image /etc/passwd lookup is required.
    users.users.adopter-central-db = {
      isSystemUser = true;
      uid = 999;
      group = "adopter-central-db";
      description = "MariaDB (Adopter Central container)";
    };
    users.groups.adopter-central-db.gid = 999;

    users.users.adopter-central-app = {
      isSystemUser = true;
      uid = 1002;
      group = "adopter-central-app";
      description = "Adopter Central Astro SSR";
    };
    users.groups.adopter-central-app.gid = appUid;

    systemd.tmpfiles.rules = [
      "d ${appRoot} 0755 root root -"
      "d ${appRoot}/releases 0755 adopter-central-app adopter-central-app -"
      "d ${appRoot}/mariadb 0770 adopter-central-db adopter-central-db -"
    ];

    # Install a placeholder release the first time only. Afterwards `current`
    # belongs to the deploy workflow and is never touched by Nix.
    systemd.services.adopter-central-bootstrap = {
      description = "Install the Adopter Central placeholder release if nothing is deployed";
      wantedBy = [ "multi-user.target" ];
      before = [ "adopter-central-release-check.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        if [ -e "${appRoot}/current/server/entry.mjs" ]; then
          echo "adopter-central-bootstrap: existing release found, leaving it alone"
          exit 0
        fi
        install -d -m 0755 -o adopter-central-app -g adopter-central-app \
          "${appRoot}/releases/bootstrap/server"
        install -m 0444 -o adopter-central-app -g adopter-central-app \
          ${lib.escapeShellArg placeholder} "${appRoot}/releases/bootstrap/server/entry.mjs"
        ln -sfn "${appRoot}/releases/bootstrap" "${appRoot}/current"
        echo "adopter-central-bootstrap: installed placeholder release"
      '';
    };

    systemd.services.pod-adopter-central = {
      description = "Podman pod for Adopter Central (Astro app + MariaDB)";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      requiredBy = [ "podman-adopter-central-db.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        if ! podman pod exists adopter-central-pod; then
          # Loopback-only: no Caddy vhost yet, so do not expose it on the LAN.
          podman pod create --name adopter-central-pod --memory 3G --cpus 2 \
            -p 127.0.0.1:${toString cfg.port}:${toString cfg.port}
        fi
      '';
      path = [ pkgs.podman ];
    };

    virtualisation.oci-containers.containers = {
      "adopter-central-db" = {
        autoStart = true;
        user = "${toString dbUid}:${toString dbUid}";
        image = "docker.io/library/mariadb:11.4";
        extraOptions = [ "--pod=adopter-central-pod" ];
        environmentFiles = [ config.sops.secrets."adopter-central-db-env".path ];
        volumes = [ "${appRoot}/mariadb:/var/lib/mysql" ];
        cmd = [
          "--character-set-server=utf8mb4"
          "--collation-server=utf8mb4_unicode_ci"
        ];
      };

      "adopter-central-app" = {
        autoStart = true;
        dependsOn = [ "adopter-central-db" ];
        user = "${toString appUid}:${toString appUid}";
        # NOT alpine: astro pulls in sharp as a production transitive dependency,
        # and its native binaries are glibc-only. The release is built on the
        # glibc AL2023 runner, so the runtime image has to match.
        image = "docker.io/library/node:22-slim";
        extraOptions = [ "--pod=adopter-central-pod" ];
        environmentFiles = [ config.sops.secrets."adopter-central-app-env".path ];
        environment = {
          HOST = "0.0.0.0";
          PORT = toString cfg.port;
          NODE_ENV = "production";
          # The app shares the pod network namespace with MariaDB, so the
          # database is reachable on localhost — not on a published port.
          DB_HOST = "localhost";
          DB_PORT = "3306";
        };
        volumes = [ "${appRoot}/current:/app:ro" ];
        # Published ports must be declared on the pod, not the container.
        # `current` is a symlink the deploy workflow repoints; resolving it at
        # container start means a restart picks up the new release.
        workdir = "/app/server";
        cmd = [ "/usr/local/bin/node" "./entry.mjs" ];
      };
    };

    systemd.services.podman-adopter-central-app = {
      after = [ "adopter-central-release-check.service" "sops-nix.service" ];
      requires = [ "adopter-central-release-check.service" ];
    };

    # Fails loudly if `current` has no server entrypoint. The bootstrap service
    # guarantees this holds from the very first activation.
    systemd.services.adopter-central-release-check = {
      description = "Verify an Adopter Central release is present";
      before = [ "podman-adopter-central-app.service" ];
      requiredBy = [ "podman-adopter-central-app.service" ];
      after = [ "adopter-central-bootstrap.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        target="${appRoot}/current/server/entry.mjs"
        if [ ! -f "$target" ]; then
          echo "adopter-central-release-check: no release at $target" >&2
          echo "adopter-central-release-check: run the deploy workflow" >&2
          exit 1
        fi
        echo "adopter-central-release-check: serving $target"
      '';
    };
  };
}