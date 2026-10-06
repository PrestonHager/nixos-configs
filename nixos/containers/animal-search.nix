# Animal Search (NMSU-CS-CS371 group project)
#
# Astro SSR app + MariaDB, deployed by .github/workflows/deploy.yml in
# NMSU-CS-CS371/software-development-semester-project-group-5.
#
# Two fully independent environments run side by side, each with its own pod,
# MariaDB instance, database, credentials and release tree:
#
#   /stor/animal-search/production/releases  - one directory per deploy
#   /stor/animal-search/production/current   - symlink to the active release
#   /stor/animal-search/production/mariadb   - database files
#   /stor/animal-search/staging/...          - same layout, separate data
#
# A deploy is: write releases/<sha>, run migrations, repoint `current`, restart
# the app container. `current` is bind-mounted read-only, so rollback is a
# symlink swap plus a restart.
#
# Environment ports are published on 127.0.0.1 only. The public hostnames are
# reverse-proxied by nixos/caddy/animal-search.nix:
#   production -> animal-search.prestonhager.com
#   staging    -> staging.animal-search.prestonhager.com
#
# Renamed from `adopter-central` / services.adopterCentral on 2026-10-04. The
# old placeholder tree at /stor/adopter-central was removed (it never held a
# real release) and adopter-central-{db,app}-env in nix-secrets are retired.
{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.services.animalSearch;
  sops-path = builtins.toString inputs.nix-secrets;
  # Ids are pinned high on purpose. They were originally uid=gid=999, which
  # collided with the ids NixOS hands out on ace: gid 999 is `nscd`, and uid 999
  # is shared with `nm-iodine`. The MariaDB data directories are 0770, so a
  # colliding group hands an unrelated system daemon write access to both
  # production and staging databases.
  #
  # ace's dynamically-assigned ids occupy roughly the 300-1002 band (nixbld is
  # pinned at 30001+), so 10000+ is unused and stays clear of the allocator as
  # more services are added. Do not move these back down into the low band.
  dbId = 10000;
  appId = 10001;

  envType = lib.types.submodule {
    options = {
      port = lib.mkOption {
        type = lib.types.port;
        description = "Host port bound to 127.0.0.1 for this environment's Astro server.";
      };
      memory = lib.mkOption {
        type = lib.types.str;
        default = cfg.podMemory;
        description = "Podman memory limit for this environment's pod.";
      };
      cpus = lib.mkOption {
        type = lib.types.str;
        default = cfg.podCpus;
        description = "Podman CPU limit for this environment's pod.";
      };
    };
  };

  # Placeholder served until the first real deploy lands, so `nixos-rebuild`
  # never fails activation on a fresh host and the reason is obvious in the logs.
  mkPlaceholder = name: port: pkgs.writeTextFile {
    name = "animal-search-placeholder-${name}.mjs";
    text = ''
      const env = "${name}";
      const msg =
        `Animal Search [${"$"}{env}] is running but no release has been deployed yet.\n` +
        'Run the "Deploy to ace" workflow to publish one.\n';
      const server = (await import('node:http')).createServer((_req, res) => {
        res.writeHead(503, { 'content-type': 'application/json' });
        res.end(
          JSON.stringify({ status: 'placeholder', environment: env, message: msg }),
        );
      });
      server.listen(${toString port}, '0.0.0.0', () =>
        console.log(
          `animal-search [${"$"}{env}] placeholder listening on ${toString port} (no release deployed yet)`,
        ),
      );
    '';
  };

  forEnv = name: envCfg: rec {
    inherit name;
    port = envCfg.port;
    memory = envCfg.memory;
    cpus = envCfg.cpus;
    root = "/stor/animal-search/${name}";
    pod = "animal-search-${name}-pod";
    dbContainer = "animal-search-${name}-db";
    appContainer = "animal-search-${name}-app";
    dbSecret = "animal-search-${name}-db-env";
    appSecret = "animal-search-${name}-app-env";
    placeholder = mkPlaceholder name envCfg.port;
  };

  envs = lib.mapAttrs forEnv cfg.environments;
in
{
  options.services.animalSearch = {
    enable = lib.mkEnableOption "Animal Search (Astro SSR + MariaDB, staging + production)";

    environments = lib.mkOption {
      type = lib.types.attrsOf envType;
      default = {
        production = { port = 4322; };
        staging = { port = 4323; };
      };
      description = ''
        Per-environment settings, keyed by environment name. The attribute name
        becomes part of the pod name, container names, systemd unit names, the
        /stor/animal-search/<name> tree and the sops secret names, so renaming an
        environment is a rename, not a migration.
      '';
    };

    podMemory = lib.mkOption {
      type = lib.types.str;
      default = "3G";
      description = "Default Podman memory limit per environment pod.";
    };

    podCpus = lib.mkOption {
      type = lib.types.str;
      default = "2";
      description = "Default Podman CPU limit per environment pod.";
    };
  };

  config = lib.mkIf cfg.enable {
    # One sops secret per environment per role, all from a single secrets file.
    sops.secrets = lib.listToAttrs (
      lib.concatLists (
        lib.mapAttrsToList (name: e: [
          {
            name = e.dbSecret;
            value = {
              sopsFile = "${sops-path}/secrets/containers/animal-search.yaml";
              key = e.dbSecret;
              mode = "0400";
            };
          }
          {
            name = e.appSecret;
            value = {
              sopsFile = "${sops-path}/secrets/containers/animal-search.yaml";
              key = e.appSecret;
              mode = "0400";
            };
          }
        ]) envs
      )
    );

    # Host-side owners for the bind-mounted volumes. These are deliberately
    # NOT the image users (mariadb uses `mysql`, node uses `node`, both 999 /
    # 1000 in-image) because uid 1000 is already a real user on ace. Podman is
    # given numeric ids below so no in-image /etc/passwd lookup is required.
    # Both environments share these ids: they are separate containers, and the
    # host only needs one owner per data directory.
    #
    # uid/gid are pinned to the 10000+ band (see dbId/appId) so they cannot
    # collide with allocator-assigned ids such as nscd or nm-iodine.
    users.users.animal-search-db = {
      isSystemUser = true;
      uid = dbId;
      group = "animal-search-db";
      description = "MariaDB (Animal Search containers)";
    };
    users.groups.animal-search-db.gid = dbId;

    users.users.animal-search-app = {
      isSystemUser = true;
      uid = appId;
      group = "animal-search-app";
      description = "Animal Search Astro SSR";
    };
    users.groups.animal-search-app.gid = appId;

    systemd.tmpfiles.rules = lib.concatLists (
      lib.mapAttrsToList (name: e: [
        "d ${e.root} 0755 root root -"
        "d ${e.root}/deploy 0755 root root -"
        "d ${e.root}/releases 0755 animal-search-app animal-search-app -"
        "d ${e.root}/mariadb 0770 animal-search-db animal-search-db -"
      ]) envs
    );

    systemd.paths = lib.mapAttrs' (name: e:
      lib.nameValuePair "animal-search-${name}-deploy" {
        wantedBy = [ "multi-user.target" ];
        pathConfig.PathChanged = "${e.root}/deploy/request";
      }) envs;

    systemd.services = lib.listToAttrs (
      lib.concatLists (
        lib.mapAttrsToList (name: e: [
          {
            name = "animal-search-${name}-bootstrap";
            value = {
              description = "Install the Animal Search [${name}] placeholder release if nothing is deployed";
              wantedBy = [ "multi-user.target" ];
              before = [ "animal-search-${name}-release-check.service" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              script = ''
                set -euo pipefail
                if [ -e "${e.root}/current/server/entry.mjs" ]; then
                  echo "animal-search[${name}]-bootstrap: existing release found, leaving it alone"
                  exit 0
                fi
                install -d -m 0755 -o animal-search-app -g animal-search-app \
                  "${e.root}/releases/bootstrap/server"
                install -m 0444 -o animal-search-app -g animal-search-app \
                  ${lib.escapeShellArg e.placeholder} "${e.root}/releases/bootstrap/server/entry.mjs"
                ln -sfn "${e.root}/releases/bootstrap" "${e.root}/current"
                echo "animal-search[${name}]-bootstrap: installed placeholder release"
              '';
            };
          }
          {
            name = "animal-search-${name}-release-check";
            value = {
              description = "Verify an Animal Search [${name}] release is present";
              before = [ "podman-animal-search-${name}-app.service" ];
              requiredBy = [ "podman-animal-search-${name}-app.service" ];
              after = [ "animal-search-${name}-bootstrap.service" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              script = ''
                set -euo pipefail
                target="${e.root}/current/server/entry.mjs"
                if [ ! -f "$target" ]; then
                  echo "animal-search[${name}]-release-check: no release at $target" >&2
                  echo "animal-search[${name}]-release-check: run the deploy workflow" >&2
                  exit 1
                fi
                echo "animal-search[${name}]-release-check: serving $target"
              '';
            };
          }
          {
            name = "animal-search-${name}-deploy";
            value = {
              description = "Activate a staged Animal Search [${name}] release";
              path = [ pkgs.podman pkgs.coreutils pkgs.curl pkgs.systemd ];
              serviceConfig.Type = "oneshot";
              script = ''
                set -euo pipefail
                root=${e.root}
                exec > "$root/deploy/last.log" 2>&1
                sha="$(tr -d '[:space:]' < "$root/deploy/request")"
                finish() { printf '%s %s\n' "$sha" "$1" > "$root/deploy/result.tmp"
                           mv -f "$root/deploy/result.tmp" "$root/deploy/result"; }

                release="$root/releases/$sha"
                if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || [ -L "$release" ] || [ ! -d "$release" ]; then
                  echo "rejected request: $sha"; finish rejected; exit 1
                fi

                prev="$(readlink -f "$root/current")"
                rollback() {
                  ln -sfn "$prev" "$root/current.new"; mv -Tf "$root/current.new" "$root/current"
                  systemctl restart podman-animal-search-${name}-app.service || true
                }

                if [ -f "$release/scripts/migrate.mjs" ] && [ -f "$release/db/schema.sql" ]; then
                  podman run --rm --pod=${e.pod} --security-opt label=disable \
                    --env-file ${config.sops.secrets.${e.appSecret}.path} \
                    -e DB_HOST=localhost -e DB_PORT=3306 \
                    -v "$release:/app:ro" --entrypoint node \
                    docker.io/library/node:22-slim /app/scripts/migrate.mjs \
                    || { finish migrate-failed; exit 1; }
                fi

                ln -sfn "$release" "$root/current.new"; mv -Tf "$root/current.new" "$root/current"
                systemctl restart podman-animal-search-${name}-app.service

                for _ in $(seq 1 30); do
                  if curl -fsS -o /dev/null http://127.0.0.1:${toString e.port}/api/health; then
                    finish ok; exit 0
                  fi
                  sleep 3
                done
                rollback; finish health-failed; exit 1
              '';
            };
          }
          {
            name = "pod-animal-search-${name}";
            value = {
              description = "Podman pod for Animal Search [${name}] (Astro app + MariaDB)";
              wants = [ "network-online.target" ];
              after = [ "network-online.target" ];
              requiredBy = [ "podman-animal-search-${name}-db.service" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              script = ''
                set -euo pipefail
                if ! podman pod exists ${e.pod}; then
                  # Loopback-only. Ports MUST be declared at pod creation; podman
                  # rejects container-level networking for containers in a pod.
                  podman pod create --name ${e.pod} --memory ${e.memory} --cpus ${e.cpus} \
                    -p 127.0.0.1:${toString e.port}:${toString e.port}
                fi
              '';
              path = [ pkgs.podman ];
            };
          }
          {
            name = "podman-animal-search-${name}-app";
            value = {
              after = [
                "animal-search-${name}-release-check.service"
                "sops-nix.service"
              ];
              # No hard requirement on sops-nix.service: it does not exist on this
              # host (secrets land in /run/secrets.d/<generation>/) and requiring
              # a missing unit stops the container from ever starting.
              requires = [ "animal-search-${name}-release-check.service" ];
            };
          }
        ]) envs
      )
    );

    virtualisation.oci-containers.containers = lib.listToAttrs (
      lib.concatLists (
        lib.mapAttrsToList (name: e: [
          {
            name = e.dbContainer;
            value = {
              autoStart = true;
              user = "${toString dbId}:${toString dbId}";
              image = "docker.io/library/mariadb:11.4";
              extraOptions = [ "--pod=${e.pod}" ];
              environmentFiles = [ config.sops.secrets.${e.dbSecret}.path ];
              volumes = [ "${e.root}/mariadb:/var/lib/mysql" ];
              cmd = [
                "--character-set-server=utf8mb4"
                "--collation-server=utf8mb4_unicode_ci"
              ];
            };
          }
          {
            name = e.appContainer;
            value = {
              autoStart = true;
              dependsOn = [ e.dbContainer ];
              user = "${toString appId}:${toString appId}";
              # NOT alpine: astro pulls in sharp as a production transitive
              # dependency, and its native binaries are glibc-only. The release
              # is built on the glibc AL2023 runner, so the runtime image has to
              # match.
              image = "docker.io/library/node:22-slim";
              extraOptions = [ "--pod=${e.pod}" ];
              environmentFiles = [ config.sops.secrets.${e.appSecret}.path ];
              environment = {
                HOST = "0.0.0.0";
                PORT = toString e.port;
                NODE_ENV = "production";
                DEPLOY_ENVIRONMENT = name;
                # The app shares the pod network namespace with MariaDB, so the
                # database is reachable on localhost, not on a published port.
                DB_HOST = "localhost";
                DB_PORT = "3306";
              };
              volumes = [ "${e.root}/current:/app:ro" ];
              # `current` is a symlink the deploy workflow repoints; resolving it
              # at container start means a restart picks up the new release.
              workdir = "/app/server";
              cmd = [ "/usr/local/bin/node" "./entry.mjs" ];
            };
          }
        ]) envs
      )
    );
  };
}
