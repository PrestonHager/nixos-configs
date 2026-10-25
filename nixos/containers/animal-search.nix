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
  # Pinned by digest to what was running; was the floating tags mariadb:11.4 / node:22-slim.
  mariadbImage = "docker.io/library/mariadb@sha256:250e1609e93c0e6aecf64bfbab2d84d5e89d2481540fe77447ff6c855c3b1873"; # mariadb 11.4.13
  nodeImage = "docker.io/library/node@sha256:de170b39439eb0e5a3444ad7d60b015614a381e10fecae2e30ec9e735122f38d"; # node 22.23.4-slim

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
    # Runner-writable. Mounted into the deploy runner as ${root}/releases and
    # ${root}/deploy so the workflow's paths are unchanged.
    inbox = "${root}/inbox";
    # Root-only (0700): claimed request, logs, status.
    state = "${root}/deploy-state";
    pod = "animal-search-${name}-pod";
    dbContainer = "animal-search-${name}-db";
    appContainer = "animal-search-${name}-app";
    dbSecret = "animal-search-${name}-db-env";
    appSecret = "animal-search-${name}-app-env";
    placeholder = mkPlaceholder name envCfg.port;
  };

  envs = lib.mapAttrs forEnv cfg.environments;

  sha40 = "^[0-9a-f]{40}$";

  # --- Deploy pipeline -------------------------------------------------------
  #
  # The deploy runner (homelab.github-runner-persistent) executes workflows from
  # a repository other people can push to, as root in its container. It only
  # ever sees ${inbox}/{releases,deploy}. Everything below treats the inbox as
  # hostile: no path in it is opened by root except through operations that do
  # not follow symlinks (rename(2), GNU tar's O_NOFOLLOW traversal, rm -rf),
  # nothing read from it is echoed back, and results are published by renaming
  # root-written files from the root-only state dir into the inbox.
  #
  # One deploy is one run of animal-search-<env>-deploy.service:
  #   1. claim   (sandboxed) move inbox/deploy/request into the state dir,
  #              validate it, copy inbox/releases/<sha> into releases/.incoming
  #   2. activate (+, full privileges, touches only root-owned paths) migrate,
  #              repoint `current`, restart the app, health-check, roll back
  #   3. publish (ExecStopPost, sandboxed) rename last.log and result into the
  #              inbox for the workflow to read

  claimScript = e: pkgs.writeShellScript "animal-search-${e.name}-deploy-claim" ''
    set -euo pipefail
    umask 077
    state=${lib.escapeShellArg e.state}
    inbox=${lib.escapeShellArg e.inbox}
    releases=${lib.escapeShellArg "${e.root}/releases"}

    rm -rf -- "$state/request" "$state/pending" "$state/status"
    # rename(2) moves the directory entry itself: a symlink, FIFO or directory
    # planted as `request` is moved, never followed or opened.
    if ! mv -T --no-copy -- "$inbox/deploy/request" "$state/request" 2>/dev/null; then
      if [ -e "$inbox/deploy/request" ] || [ -L "$inbox/deploy/request" ]; then
        # Could not be claimed; drop it so the path unit does not spin.
        rm -rf -- "$inbox/deploy/request"
      fi
      exit 0
    fi

    : > "$state/last.log"
    exec >> "$state/last.log" 2>&1
    echo "animal-search[${e.name}] deploy request received $(date -Is)"

    label=invalid
    # Any unexpected failure still produces a result for the workflow.
    trap '[ -f "$state/status" ] || [ -f "$state/pending" ] \
      || printf "%s error\n" "$label" > "$state/status"' EXIT

    reject() {
      echo "rejected: $2"
      printf '%s rejected\n' "$1" > "$state/status"
      rm -rf -- "$state/request" "$releases/.incoming"
      exit 0
    }

    # The state dir is root-only, so these checks cannot race.
    if [ -L "$state/request" ] || [ ! -f "$state/request" ]; then
      reject invalid "request is not a regular file"
    fi
    sha="$(head -c 64 -- "$state/request" | tr -d '[:space:]')"
    rm -f -- "$state/request"
    if ! [[ "$sha" =~ ${sha40} ]]; then
      reject invalid "request is not a 40-character lowercase hex commit sha"
    fi
    label="$sha"
    if [ -L "$inbox/releases/$sha" ] || [ ! -d "$inbox/releases/$sha" ]; then
      reject "$sha" "no staged release directory for $sha"
    fi

    # Copy, do not move: the runner keeps its own copy for its prune step, and
    # nothing the runner can still reach (open fds included) ends up live.
    # GNU tar walks the source with openat(O_NOFOLLOW) and archives symlinks as
    # symlinks; extraction refuses absolute and ../ member names.
    rm -rf -- "$releases/.incoming"
    install -d -m 0700 "$releases/.incoming"
    if ! tar -C "$inbox/releases" --one-file-system -cf - "$sha" \
        | tar -C "$releases/.incoming" --no-same-owner -xf -; then
      reject "$sha" "copying the staged release failed"
    fi
    inc="$releases/.incoming/$sha"
    if [ -L "$inc" ] || [ ! -d "$inc" ]; then
      reject "$sha" "staged release is not a directory"
    fi
    # No setuid/setgid or group/world-writable entries in a release.
    chmod -R u-s,g-s,go-w -- "$inc"
    if [ -L "$inc/server" ] || [ -L "$inc/server/entry.mjs" ] || [ ! -f "$inc/server/entry.mjs" ]; then
      reject "$sha" "release has no server/entry.mjs"
    fi

    printf '%s\n' "$sha" > "$state/pending"
    echo "claimed release $sha"
  '';

  activateScript = e: pkgs.writeShellScript "animal-search-${e.name}-deploy-activate" ''
    set -euo pipefail
    umask 022
    root=${lib.escapeShellArg e.root}
    state=${lib.escapeShellArg e.state}
    releases="$root/releases"
    [ -f "$state/pending" ] || exit 0
    exec >> "$state/last.log" 2>&1

    sha="$(head -c 64 -- "$state/pending" | tr -d '[:space:]')"
    rm -f -- "$state/pending"
    [[ "$sha" =~ ${sha40} ]] || { echo "internal: bad pending sha"; exit 1; }
    finish() { printf '%s %s\n' "$sha" "$1" > "$state/status"; }
    trap '[ -f "$state/status" ] || finish error' EXIT

    prev="$(readlink -f -- "$root/current" || true)"

    # Never overwrite the release that is live (redeploy of the same sha):
    # rollback must still have it.
    name="$sha"
    if [ -e "$releases/$name" ] || [ -L "$releases/$name" ]; then
      if [ -n "$prev" ] && [ "$(readlink -f -- "$releases/$name")" = "$prev" ]; then
        name="$sha-$(date +%s)"
      else
        rm -rf --one-file-system -- "$releases/$name"
      fi
    fi
    release="$releases/$name"
    mv -T -- "$releases/.incoming/$sha" "$release"
    rmdir -- "$releases/.incoming" 2>/dev/null || true
    touch -- "$release"
    echo "installed $release"

    rollback() {
      if [ -n "$prev" ] && [ -d "$prev" ]; then
        echo "rolling back to $prev"
        ln -sfn -- "$prev" "$root/current.new"; mv -Tf -- "$root/current.new" "$root/current"
        systemctl restart podman-animal-search-${e.name}-app.service || true
      fi
    }

    if [ -f "$release/scripts/migrate.mjs" ] && [ -f "$release/db/schema.sql" ]; then
      echo "running migrations"
      if ! podman run --rm --pod=${e.pod} --security-opt label=disable \
          --user ${toString appId}:${toString appId} \
          --cap-drop=all --security-opt=no-new-privileges \
          --env-file ${config.sops.secrets.${e.appSecret}.path} \
          -e DB_HOST=localhost -e DB_PORT=3306 \
          -v "$release:/app:ro" --entrypoint node \
          ${nodeImage} /app/scripts/migrate.mjs; then
        finish migrate-failed; exit 1
      fi
    fi

    ln -sfn -- "$release" "$root/current.new"; mv -Tf -- "$root/current.new" "$root/current"
    systemctl restart podman-animal-search-${e.name}-app.service

    ok=0
    for _ in $(seq 1 30); do
      if curl -fsS -o /dev/null http://127.0.0.1:${toString e.port}; then ok=1; break; fi
      sleep 3
    done
    if [ "$ok" != 1 ]; then
      rollback; finish health-failed; exit 1
    fi
    echo "release $name is live"
    finish ok

    # Keep the live and previous releases plus the five newest.
    live="$(readlink -f -- "$root/current" || true)"
    find "$releases" -mindepth 1 -maxdepth 1 -type d \
        -regextype posix-extended -regex '.*/[0-9a-f]{40}(-[0-9]+)?' \
        -printf '%T@ %p\n' \
      | sort -rn | tail -n +6 | cut -d' ' -f2- \
      | while IFS= read -r old; do
          [ "$old" = "$live" ] || [ "$old" = "$prev" ] && continue
          echo "pruning $old"
          rm -rf --one-file-system -- "$old"
        done
  '';

  publishScript = e: pkgs.writeShellScript "animal-search-${e.name}-deploy-publish" ''
    set -euo pipefail
    umask 022
    state=${lib.escapeShellArg e.state}
    inbox=${lib.escapeShellArg e.inbox}
    [ -f "$state/status" ] || exit 0
    # Write into the root-only state dir, then rename into the inbox. rename(2)
    # replaces whatever directory entry is there (symlink included) without
    # following it, and --no-copy refuses to fall back to copying.
    publish() {
      local tmp="$state/.publish-$2"
      rm -f -- "$tmp"
      cp -- "$1" "$tmp"
      chmod 0644 -- "$tmp"
      mv -fT --no-copy -- "$tmp" "$inbox/deploy/$2" || rm -f -- "$tmp"
    }
    [ -f "$state/last.log" ] && publish "$state/last.log" last.log
    publish "$state/status" result
    rm -f -- "$state/status"
  '';
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

    runnerVolumes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = lib.concatLists (lib.mapAttrsToList (_: e: [
        "${e.inbox}/releases:${e.root}/releases"
        "${e.inbox}/deploy:${e.root}/deploy"
      ]) envs);
      defaultText = lib.literalExpression ''
        [ "/stor/animal-search/<env>/inbox/releases:/stor/animal-search/<env>/releases"
          "/stor/animal-search/<env>/inbox/deploy:/stor/animal-search/<env>/deploy" ... ]
      '';
      description = ''
        The only binds the deploy runner gets: per environment, the inbox
        directories mounted at the paths deploy.yml already uses. Pass to
        homelab.github-runner-persistent.extraVolumes. Never mount the
        environment root itself (it holds MariaDB data and the live releases).
      '';
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
        # Live releases: root-owned, never mounted into the runner. The app
        # only reads `current` through a read-only bind.
        "d ${e.root}/releases 0755 root root -"
        "d ${e.root}/mariadb 0770 animal-search-db animal-search-db -"
        "d ${e.state} 0700 root root -"
        # The runner's whole view of this host (see runnerVolumes).
        "d ${e.inbox} 0755 root root -"
        "d ${e.inbox}/releases 0755 root root -"
        "d ${e.inbox}/deploy 0755 root root -"
      ]) envs
    );

    # PathExists, not PathChanged: the claim step moves `request` away, and
    # systemd re-checks after each run, so a request that lands mid-deploy is
    # picked up instead of lost.
    systemd.paths = lib.mapAttrs' (name: e:
      lib.nameValuePair "animal-search-${name}-deploy" {
        wantedBy = [ "multi-user.target" ];
        pathConfig.PathExists = "${e.inbox}/deploy/request";
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
              path = [
                pkgs.bash pkgs.coreutils pkgs.findutils pkgs.gnutar
                pkgs.podman pkgs.curl pkgs.systemd
              ];
              serviceConfig = {
                Type = "oneshot";
                TimeoutStartSec = "15min";
                # Sandboxed: handles the runner-writable inbox.
                ExecStart = [
                  "${claimScript e}"
                  # `+`: runs outside the sandbox below (podman, systemctl,
                  # loopback curl), and only touches root-owned paths.
                  "+${activateScript e}"
                ];
                ExecStopPost = "${publishScript e}";

                # Applies to claim and publish (not to the `+` activate step).
                UMask = "0077";
                ProtectSystem = "strict";
                ReadWritePaths = [ e.root ];
                InaccessiblePaths = [ "-${e.root}/mariadb" ];
                ProtectHome = true;
                PrivateTmp = true;
                PrivateDevices = true;
                NoNewPrivileges = true;
                CapabilityBoundingSet = [
                  "CAP_CHOWN" "CAP_FOWNER" "CAP_DAC_OVERRIDE" "CAP_DAC_READ_SEARCH"
                ];
                RestrictAddressFamilies = [ "AF_UNIX" ];
                RestrictNamespaces = true;
                RestrictRealtime = true;
                LockPersonality = true;
                MemoryDenyWriteExecute = true;
                ProtectKernelTunables = true;
                ProtectKernelModules = true;
                ProtectKernelLogs = true;
                ProtectControlGroups = true;
                ProtectClock = true;
                ProtectHostname = true;
                ProtectProc = "invisible";
                SystemCallArchitectures = "native";
                SystemCallFilter = [ "@system-service" ];
              };
            };
          }
          {
            name = "pod-animal-search-${name}";
            value = {
              description = "Podman pod for Animal Search [${name}] (Astro app + MariaDB)";
              wants = [ "network-online.target" ];
              after = [ "network-online.target" ];
              # before= orders the pod ahead of both containers; requiredBy alone does not.
              before = [
                "podman-animal-search-${name}-db.service"
                "podman-animal-search-${name}-app.service"
              ];
              requiredBy = [
                "podman-animal-search-${name}-db.service"
                "podman-animal-search-${name}-app.service"
              ];
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
              image = mariadbImage;
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
              image = nodeImage;
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
