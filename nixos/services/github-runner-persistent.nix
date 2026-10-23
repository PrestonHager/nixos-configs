# A persistent (non-ephemeral) GitHub Actions runner.
#
# Why this exists instead of `homelab.github-runners`:
# that module de-registers the runner on container exit and re-registers on
# every start, which requires a long-lived fine-grained PAT in sops. The
# NMSU-CS-CS371 class repo has no way to mint a PAT for itself, so this runner
# is registered ONCE by hand and its registration (.runner / .credentials /
# .credentials_rsaparams) is kept in a 0700 host directory that survives
# restarts and rebuilds.
#
# Isolation model (jobs come from a repo other people can push to):
#   * The host state dir is mounted READ-ONLY at /runner-state. The start
#     script copies the registration files (0600) into the image's own
#     /actions-runner, which already holds the latest baked runner release.
#     Jobs therefore cannot rewrite the host's credentials or plant a modified
#     runner binary that survives a container restart. They can still read the
#     registration, because they run as the same uid as the listener; that is
#     inherent to self-hosted runners.
#   * Everything the runner writes (_work, _diag, self-update, migrated
#     registration) lives in the container's own filesystem and is discarded
#     on restart (oci-containers runs with --rm).
#   * The shared tools dir is an overlay (:O): jobs see a writable copy, the
#     host copy that the ephemeral runners use is never modified.
#   * No host Podman socket by default, and the container sits on the
#     egress-filtered runner network (github-runner/network.nix): internet
#     only, no host services, no LAN.
#
# Consequences worth knowing:
#   * No secret is stored in nix-secrets. Rotating it is a re-registration.
#   * Deleting the host directory orphans the runner in GitHub; delete it in
#     the repo's Settings > Actions > Runners UI too (or via the API).
#   * The runner is intentionally NOT ephemeral: it stays registered between
#     jobs. Jobs within one container lifetime share its filesystem; a restart
#     returns to a clean image.
#
# Registering (one-time, as root on the host): override the entrypoint so the
# image's EXIT trap cannot de-register the runner, run config.sh in the image's
# /actions-runner and copy the resulting files out to the state dir:
#   podman run --rm --entrypoint bash -e RUNNER_ALLOW_RUNASROOT=1 \
#     -v /var/lib/github-runner-nmsu:/runner-state <image> -c \
#     'cd /actions-runner && ./config.sh --unattended --url <url> --token <tok> \
#        --name <n> --labels <l> && \
#      cp .runner .credentials .credentials_rsaparams /runner-state/ && \
#      chmod 0600 /runner-state/.runner /runner-state/.credentials*'
{ config, lib, pkgs, ... }:

let
  cfg = config.homelab.github-runner-persistent;
  netCfg = config.homelab.github-runner-network;
  runnerDir = cfg.stateDir;
  toolsDir = "/var/lib/github-runner-tools";

  # Registration files copied from the read-only host state dir. The optional
  # ones are written by config.sh (.env/.path) or by a server-driven migration;
  # a migration that is lost on restart is simply replayed by GitHub.
  registrationFiles = [
    ".runner"
    ".credentials"
    ".credentials_rsaparams"
    ".runner_migrated"
    ".credentials_migrated"
    ".env"
    ".path"
  ];

  startScript = pkgs.writeShellScript "persistent-runner-start" ''
    set -euo pipefail
    umask 077
    for f in ${lib.escapeShellArgs registrationFiles}; do
      if [ -f "/runner-state/$f" ] && [ ! -L "/runner-state/$f" ]; then
        install -m 0600 "/runner-state/$f" "/actions-runner/$f"
      fi
    done
    if [ ! -f /actions-runner/.runner ] || [ ! -f /actions-runner/.credentials ]; then
      echo "persistent-runner: no registration in /runner-state; see github-runner-persistent.nix" >&2
      exit 1
    fi
    install -d -m 0700 /actions-runner/_work
    find /actions-runner/_work -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    umask 022
    cd /actions-runner
    exec ./run.sh
  '';
in
{
  imports = [ ./github-runner/network.nix ];

  options.homelab.github-runner-persistent = {
    enable = lib.mkEnableOption "A pre-registered, non-ephemeral GitHub Actions runner";

    image = lib.mkOption {
      type = lib.types.str;
      default = "localhost/homelab-github-runner:al2023";
      description = ''
        Runner image. Must contain the actions runner in /actions-runner and run
        on AL2023 glibc 2.34. The runner binaries come from the image, not from
        the state dir.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/github-runner-nmsu";
      description = ''
        Host directory holding the runner registration (.runner, .credentials,
        .credentials_rsaparams). Mounted read-only into the container.
      '';
    };

    memory = lib.mkOption {
      type = lib.types.str;
      default = "4096m";
      description = "Podman memory limit for the runner container.";
    };

    cpus = lib.mkOption {
      type = lib.types.str;
      default = "4";
      description = "Podman CPU limit for the runner container.";
    };

    mountPodmanSocket = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Mount the host's rootful Podman socket at /var/run/docker.sock. This
        gives every job root on the host; leave it off.
      '';
    };

    extraVolumes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = lib.literalExpression "config.services.animalSearch.runnerVolumes";
      description = ''
        Extra host binds for the runner container, as `host:container[:opts]`.
        Anything mounted read-write here is writable by every job that lands on
        this runner, so only mount narrow inbox directories whose contents a
        root-side consumer treats as untrusted. Never mount data directories,
        sockets, or trees that a root process later follows symlinks in.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    homelab.github-runner-network.enable = true;

    systemd.tmpfiles.rules = [
      # 0700: the registration is bearer material for this repo's workflows.
      "d ${runnerDir} 0700 root root -"
    ] ++ map (f: "z ${runnerDir}/${f} 0600 root root -") registrationFiles;

    systemd.services."podman-github-runner-nmsu" = {
      after = [ "podman.socket" "network-online.target" netCfg.unit "github-runner-image.service" ];
      wants = [ "podman.socket" ];
      requires = [ netCfg.unit ];
      serviceConfig = {
        # oci-containers defaults to on-failure; a runner that exits must come
        # back, so force this like the main github-runner module does.
        Restart = lib.mkForce "always";
        RestartSec = "5";
      };
    };

    virtualisation.oci-containers.containers."github-runner-nmsu" = {
      autoStart = true;
      image = cfg.image;

      # Copy the registration in, empty `_work`, then exec run.sh. (The
      # oci-containers `entrypoint` option only takes a string, so the script
      # is bind-mounted in below, same as the github-runner module.)
      entrypoint = "/bootstrap/persistent-runner-start.sh";
      cmd = [ ];

      environment = {
        # config.sh/run.sh refuse to run as root without this.
        RUNNER_ALLOW_RUNASROOT = "1";
        RUN_AS_ROOT = "true";
        # Match the rest of the ace runner fleet.
        DISABLE_AUTO_UPDATE = "1";
      };

      volumes = [
        "${startScript}:/bootstrap/persistent-runner-start.sh:ro"
        "${runnerDir}:/runner-state:ro"
        # Overlay: job writes are dropped on exit and never reach the copy the
        # ephemeral runners use.
        "${toolsDir}:${toolsDir}:O"
        # pkgs.zig / pkgs.ffmpeg live in the shared tools volume as Nix store
        # paths, so the store must be visible inside the container.
        "/nix/store:/nix/store:ro"
      ] ++ lib.optional cfg.mountPodmanSocket "/run/podman/podman.sock:/var/run/docker.sock"
        ++ cfg.extraVolumes;

      extraOptions = [
        "--memory=${cfg.memory}"
        "--cpus=${cfg.cpus}"
        "--security-opt=label=disable"
        "--security-opt=no-new-privileges"
      ] ++ netCfg.podmanOptions;
    };
  };
}
