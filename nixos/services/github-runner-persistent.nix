# A persistent (non-ephemeral) GitHub Actions runner.
#
# Why this exists instead of `homelab.github-runners`:
# that module de-registers the runner on container exit and re-registers on
# every start, which requires a long-lived fine-grained PAT in sops. The
# NMSU-CS-CS371 class repo has no way to mint a PAT for itself, so this runner
# is registered ONCE by hand and its credentials (.runner / .credentials) are
# kept in a 0700 host directory that survives restarts and rebuilds.
#
# Consequences worth knowing:
#   * No secret is stored on the host. Rotating it is a re-registration.
#   * Deleting the host directory orphans the runner in GitHub; delete it in
#     the repo's Settings > Actions > Runners UI too (or via the API).
#   * The runner is intentionally NOT ephemeral: it stays registered between
#     jobs, so a stale `_work` tree is cleared on each start instead.
#
# Registering: the myoung34 base image ENTRYPOINT installs an EXIT trap that
# de-registers the runner when the container stops, which wipes the config.
# Always register with --entrypoint overridden, e.g.
#   podman run --rm --entrypoint bash -e RUNNER_ALLOW_RUNASROOT=1 \
#     -v /var/lib/github-runner-nmsu:/actions-runner <image> \
#     -c 'cd /actions-runner && ./config.sh --unattended --url <url> --token <tok> --name <n> --labels <l>'
{ config, lib, pkgs, ... }:

let
  cfg = config.homelab.github-runner-persistent;
  runnerDir = cfg.stateDir;
  toolsDir = "/var/lib/github-runner-tools";

  startScript = pkgs.writeShellScript "persistent-runner-start" ''
    set -euo pipefail
    install -d -m 0700 /actions-runner/_work
    find /actions-runner/_work -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    cd /actions-runner
    exec ./run.sh
  '';
in
{
  options.homelab.github-runner-persistent = {
    enable = lib.mkEnableOption "A pre-registered, non-ephemeral GitHub Actions runner";

    image = lib.mkOption {
      type = lib.types.str;
      default = "localhost/homelab-github-runner:al2023";
      description = "Runner image. Must contain /actions-runner and run on AL2023 glibc 2.34.";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/github-runner-nmsu";
      description = "Host directory holding the persisted runner (binaries + .runner + .credentials).";
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

    extraVolumes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "/stor/adopter-central" ];
      description = ''
        Extra read-write host binds for the runner container, as `host:container`
        pairs. The runner already talks to the host Podman socket, so this only
        adds convenience for jobs that must move files in and out of host paths
        (for example staging a release tree). Prefer keeping this list short:
        anything mounted here is writable by every job that lands on this runner.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      # 0700: .credentials is bearer material for this repo's workflows.
      "d ${runnerDir} 0700 root root -"
    ];

    systemd.services."podman-github-runner-nmsu" = {
      after = [ "podman.socket" "network-online.target" ];
      wants = [ "podman.socket" ];
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

      # Wrap run.sh so `_work` is emptied on every start: this runner is not
      # ephemeral, so a stale checkout from a previous job would otherwise
      # linger. `_work` itself is kept because the runner expects it to exist.
      # (The oci-containers `entrypoint` option only takes a string, so the
      # script is bind-mounted in below, same as the github-runner module.)
      entrypoint = "/bootstrap/persistent-runner-start.sh";
      cmd = [ ];

      environment = {
        # config.sh/run.sh refuse to run as root without this; the container
        # runs as root because the state dir is 0700 root-owned.
        RUNNER_ALLOW_RUNASROOT = "1";
        RUN_AS_ROOT = "true";
        # Match the rest of the ace runner fleet.
        DISABLE_AUTO_UPDATE = "1";
      };

      volumes = [
        "${startScript}:/bootstrap/persistent-runner-start.sh:ro"
        "${runnerDir}:/actions-runner"
        "${toolsDir}:${toolsDir}"
        # pkgs.zig / pkgs.ffmpeg live in the shared tools volume as Nix store
        # paths, so the store must be visible inside the container.
        "/nix/store:/nix/store:ro"
        # Jobs that use `container:` / docker actions talk to host Podman.
        "/run/podman/podman.sock:/var/run/docker.sock"
      ] ++ cfg.extraVolumes;

      extraOptions = [
        "--memory=${cfg.memory}"
        "--cpus=${cfg.cpus}"
        "--security-opt=label=disable"
      ];
    };
  };
}