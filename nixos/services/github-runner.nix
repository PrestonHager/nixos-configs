# Reusable GitHub Actions self-hosted runner(s).
# Import on any host:  imports = [ ../../nixos/services/github-runner.nix ];
# Enable with:         homelab.github-runners.enable = true; + runners.<name>
# Docs: docs/github-runner.md
{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.homelab.github-runners;
  sops-path = builtins.toString inputs.nix-secrets;

  # Tools GitHub-hosted Ubuntu runners commonly provide that CI scripts expect.
  # Used only for backend = "native". Container backend uses an Ubuntu image
  # plus a shared tools volume (rustup bootstrap + pkgs.zig symlink).
  defaultParityPackages = with pkgs; [
    curl
    wget
    jq
    unzip
    zip
    rsync
    gnupg
    openssh
    which
    file
    cacert
    bashInteractive
    nodejs_20
    python3
    gcc
    gnumake
    cmake
    pkg-config
    openssl
    zig
  ];

  defaultBaseImage = "docker.io/myoung34/github-runner:ubuntu-noble";
  defaultContainerImage = "localhost/homelab-github-runner:ubuntu-noble";
  containerfileSrc = ./github-runner/Containerfile;
  imageStampPath = "/var/lib/github-runner-tools/image.stamp";

  # Bootstrap once into a shared volume: rustup (+ apt fallback if image lacks
  # cross gcc). Must use /bin/bash shebang — Nix store interpreters are invisible
  # in Ubuntu. Wraps myoung34 entrypoint so deregister runs while config exists
  # (or falls back to GitHub API delete-by-name when files were already wiped).
  containerEntrypoint = pkgs.writeTextFile {
    name = "github-runner-container-entrypoint";
    executable = true;
    text = ''
      #!/bin/bash
      set -euo pipefail

      TOOLS="''${HOMELAB_CI_TOOLS:-/opt/homelab-ci}"
      TOOLS_CARGO="$TOOLS/cargo"
      mkdir -p "$TOOLS" "$TOOLS/bin"
      export DEBIAN_FRONTEND=noninteractive
      # Bootstrap only: rustup installs toolchain binaries under the shared tools volume.
      # pkgs.zig is symlinked into $TOOLS/bin on the host (needs /nix/store mounted).
      export CARGO_HOME="$TOOLS_CARGO"
      export RUSTUP_HOME="$TOOLS/rustup"
      export PATH="$TOOLS/bin:$TOOLS_CARGO/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

      # Prefer baked image packages; keep apt as fallback for stock base images.
      if ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
        echo "homelab-ci: installing apt build/cross packages (image missing toolchain) ..."
        apt-get update -qq
        apt-get install -y --no-install-recommends \
          build-essential pkg-config libssl-dev libffi-dev zlib1g-dev \
          ca-certificates curl wget jq unzip zip rsync gnupg openssh-client \
          git cmake python3 \
          gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
          libc6-dev-arm64-cross binutils-aarch64-linux-gnu
      else
        echo "homelab-ci: apt/cross toolchain present (baked image)"
      fi

      if [ ! -x "$TOOLS_CARGO/bin/rustup" ]; then
        echo "homelab-ci: installing rustup into $TOOLS ..."
        got_lock=0
        while ! mkdir "$TOOLS/.bootstrap.lock.d" 2>/dev/null; do
          if [ -x "$TOOLS_CARGO/bin/rustup" ]; then
            break
          fi
          sleep 2
        done
        if [ -d "$TOOLS/.bootstrap.lock.d" ] && [ ! -x "$TOOLS_CARGO/bin/rustup" ]; then
          got_lock=1
          curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --no-modify-path --default-toolchain stable \
              --profile minimal \
              --target x86_64-unknown-linux-gnu,aarch64-unknown-linux-gnu
          echo "homelab-ci: rustup install complete"
        fi
        if [ "$got_lock" = 1 ]; then
          rmdir "$TOOLS/.bootstrap.lock.d" 2>/dev/null || true
        fi
      fi

      if [ -x "$TOOLS_CARGO/bin/rustup" ]; then
        "$TOOLS_CARGO/bin/rustup" default stable >/dev/null 2>&1 || \
          "$TOOLS_CARGO/bin/rustup" toolchain install stable --profile minimal
        "$TOOLS_CARGO/bin/rustup" target add \
          x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu >/dev/null 2>&1 || true
      fi

      # Cross-link defaults for cargo/rustc (matches GitHub ubuntu runners + apt cross gcc).
      export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="''${CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER:-aarch64-linux-gnu-gcc}"
      export CC_aarch64_unknown_linux_gnu="''${CC_aarch64_unknown_linux_gnu:-aarch64-linux-gnu-gcc}"
      export CXX_aarch64_unknown_linux_gnu="''${CXX_aarch64_unknown_linux_gnu:-aarch64-linux-gnu-g++}"

      # Job caches must NOT live on the shared tools volume (cross-job/PR/repo leak).
      # Use GitHub actions/cache (Swatinem/rust-cache, actions/setup-node cache) instead.
      # Keep toolchain binaries on PATH; point CARGO_HOME at a per-container home path.
      export PATH="$TOOLS/bin:$TOOLS_CARGO/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      export CARGO_HOME="''${HOMELAB_JOB_CARGO_HOME:-/root/.cargo}"
      mkdir -p "$CARGO_HOME"
      # Ephemeral runners restart after each job — wipe local dependency caches so the
      # next job cannot read another workflow's cargo/npm artifacts from disk.
      rm -rf "$CARGO_HOME/registry" "$CARGO_HOME/git" /root/.npm /root/.cache/npm

      # Clear bind-mounted workdir between ephemeral restarts (stale checkout / _actions).
      if [ -n "''${RUNNER_WORKDIR:-}" ] && [ -d "''${RUNNER_WORKDIR}" ]; then
        echo "homelab-ci: clearing workdir ''${RUNNER_WORKDIR}"
        find "''${RUNNER_WORKDIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
      fi

      # Disable myoung34 EXIT trap: it calls config.sh remove AFTER Runner.Listener
      # already deleted .runner/.credentials ("config files are missing"), which
      # skips server-side remove and leaves offline+busy ghosts. We deregister
      # while files exist, with API delete-by-name fallback.
      export DISABLE_AUTOMATIC_DEREGISTRATION=true
      export RANDOM_RUNNER_SUFFIX=false

      _HOMELAB_DEREGISTERED=false

      homelab_owner_repo() {
        local u="''${REPO_URL:-}"
        u="''${u#https://github.com/}"
        u="''${u#http://github.com/}"
        u="''${u%.git}"
        u="''${u%/}"
        printf '%s' "$u"
      }

      homelab_api_delete_runner_by_name() {
        local name="''${RUNNER_NAME:-}"
        local token="''${ACCESS_TOKEN:-}"
        local or id
        if [ -z "$name" ] || [ -z "$token" ]; then
          echo "homelab-ci: API delete skipped (missing RUNNER_NAME or ACCESS_TOKEN)"
          return 0
        fi
        or="$(homelab_owner_repo)"
        if [ -z "$or" ]; then
          return 0
        fi
        echo "homelab-ci: API delete-by-name name=$name repo=$or"
        id="$(curl -fsS \
          -H "Authorization: Bearer ''${token}" \
          -H "Accept: application/vnd.github+json" \
          -H "X-GitHub-Api-Version: 2022-11-28" \
          "https://api.github.com/repos/''${or}/actions/runners" \
          | jq -r --arg n "$name" '.runners[]? | select(.name == $n) | .id' \
          | head -n1 || true)"
        if [ -n "''${id:-}" ] && [ "$id" != "null" ]; then
          curl -fsS -X DELETE \
            -H "Authorization: Bearer ''${token}" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "https://api.github.com/repos/''${or}/actions/runners/''${id}" \
            && echo "homelab-ci: deleted runner id=$id" \
            || echo "homelab-ci: API delete failed for id=$id (may already be gone)"
        else
          echo "homelab-ci: no server-side runner named $name"
        fi
      }

      homelab_deregister() {
        local reason="''${1:-EXIT}"
        if [ "''${_HOMELAB_DEREGISTERED}" = "true" ]; then
          return 0
        fi
        _HOMELAB_DEREGISTERED=true
        echo "homelab-ci: deregister ($reason)"
        if [ -f /actions-runner/.runner ]; then
          echo "homelab-ci: .runner present — config.sh remove while credentials exist"
          if [ -n "''${ACCESS_TOKEN:-}" ]; then
            (
              cd /actions-runner
              _TOKEN="$(ACCESS_TOKEN="''${ACCESS_TOKEN}" bash /token.sh)" || true
              RUNNER_TOKEN="$(printf '%s' "''${_TOKEN:-}" | jq -r .token)"
              if [ -n "''${RUNNER_TOKEN:-}" ] && [ "''${RUNNER_TOKEN}" != "null" ]; then
                ./config.sh remove --token "''${RUNNER_TOKEN}" || true
              else
                echo "homelab-ci: could not obtain remove token; API fallback"
                homelab_api_delete_runner_by_name || true
              fi
            )
          else
            homelab_api_delete_runner_by_name || true
          fi
        else
          echo "homelab-ci: .runner already gone — API fallback by name"
          homelab_api_delete_runner_by_name || true
        fi
      }

      trap 'homelab_deregister EXIT' EXIT
      trap 'homelab_deregister SIGTERM; exit 143' TERM
      trap 'homelab_deregister SIGINT; exit 130' INT

      # Do not exec: keep traps. myoung34 runs Runner.Listener in the foreground.
      set +e
      /entrypoint.sh "$@"
      rc=$?
      set -e
      exit "$rc"
    '';
  };

  recoverGhostScript = pkgs.writeShellScriptBin "github-runner-recover-ghost" ''
    export PATH=${lib.makeBinPath [
      pkgs.bash
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
      pkgs.openssh
      pkgs.systemd
      pkgs.gnugrep
      pkgs.gnused
    ]}:$PATH
    exec ${pkgs.bash}/bin/bash ${../../scripts/github-runner-recover-ghost.sh} "$@"
  '';

  runnerModule = { name, ... }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to enable this runner definition.";
      };

      name = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = name;
        description = ''
          Base runner name shown in GitHub. With instances > 1, suffixes
          `-1` … `-N` are appended (e.g. ace-1). Changing names re-registers.
        '';
      };

      url = lib.mkOption {
        type = lib.types.str;
        example = "https://github.com/PrestonHager";
        description = ''
          Org or repo URL to register against.
          Org-wide PAT/token → `https://github.com/ORG`
          Single repo → `https://github.com/ORG/REPO`
        '';
      };

      instances = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1;
        description = ''
          Number of parallel runner processes/containers for this definition.
          Each GitHub runner accepts one job at a time; raise this for concurrency.
        '';
      };

      # Prefer a fine-grained PAT in sops (required for ephemeral restarts).
      tokenSecret = lib.mkOption {
        type = lib.types.str;
        default = "github-runner-token";
        description = "sops.secrets attr name that holds the registration/PAT token.";
      };

      sopsFile = lib.mkOption {
        type = lib.types.path;
        default = "${sops-path}/secrets/github-runner.yaml";
        defaultText = "\${inputs.nix-secrets}/secrets/github-runner.yaml";
        description = "Encrypted secrets file in nix-secrets for this runner token.";
      };

      sopsKey = lib.mkOption {
        type = lib.types.str;
        default = "token";
        description = "Key inside the sops YAML file (single-line token, no trailing newline preferred).";
      };

      tokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          If set, use this path instead of declaring/using a sops secret.
          Useful for local smoke tests; prefer sops in production.
        '';
      };

      ephemeral = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Prefer true: runner de-registers after each job and re-registers on restart.
          Requires a PAT (not a one-hour registration token) in tokenFile/sops.
        '';
      };

      replace = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Replace an existing runner with the same name on (re)registration.";
      };

      extraLabels = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "ace-ubuntu-x64-4" ];
        description = ''
          Custom labels only. GitHub always also attaches read-only
          `self-hosted`, OS (`Linux`), and arch (`X64`) — those cannot be removed.
          Prefer one descriptive label (e.g. `ace-ubuntu-x64-4`) so workflows use
          `runs-on: ace-ubuntu-x64-4`.
        '';
      };

      extraPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        example = lib.literalExpression "with pkgs; [ cachix ]";
        description = ''
          Extra packages on PATH for native runners, in addition to
          `homelab.github-runners.parityPackages`. Ignored for container backend.
        '';
      };

      extraEnvironment = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = "Extra environment variables for the runner service/container.";
      };

      serviceOverrides = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = "Extra systemd serviceConfig merges (native backend only).";
      };

      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Fixed user for native runner; null uses a systemd dynamic user.";
      };

      group = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Fixed group for native runner; required with docker.enable.";
      };

      docker = {
        enable = lib.mkEnableOption ''
          Native backend: give the runner access to the host Docker socket
          (jobs that use `container:` / docker actions). Enables virtualisation.docker
          when needed. Container backend mounts the Podman socket by default instead.
        '';
      };

      container = {
        image = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            OCI image for this runner. Null inherits
            `homelab.github-runners.containerImage` (baked local image by default).
          '';
        };

        memory = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Podman/Docker memory limit per runner (e.g. 4096m).
            Null inherits `homelab.github-runners.containerMemory`.
          '';
        };

        cpus = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Podman/Docker CPU limit per runner (e.g. 4).
            Null inherits `homelab.github-runners.containerCpus`.
          '';
        };

        mountDockerSocket = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Mount host Podman socket at /var/run/docker.sock inside the runner
            so workflow `container:` / docker actions work (ace uses podman + dockerCompat).
          '';
        };
      };
    };
  };

  enabledRunners = lib.filterAttrs (_: r: r.enable) cfg.runners;

  resolvedTokenFile = _name: r:
    if r.tokenFile != null then r.tokenFile
    else config.sops.secrets.${r.tokenSecret}.path;

  instanceRange = r: lib.range 1 r.instances;

  instanceName = base: n: i:
    if n.instances == 1 then base
    else "${base}-${toString i}";

  containerUnitName = cname: "podman-${cname}";

  needsNativeDocker =
    cfg.backend == "native"
    && lib.any (r: r.docker.enable) (lib.attrValues enabledRunners);

  # Flatten runners × instances for container backend.
  containerInstances = lib.concatLists (
    lib.mapAttrsToList (name: r:
      map (i: {
        inherit name r i;
        cname = "github-runner-${instanceName name r i}";
        runnerName = instanceName (if r.name != null then r.name else name) r i;
      }) (instanceRange r)
    ) enabledRunners
  );

  labelsCsv = r: lib.concatStringsSep "," r.extraLabels;

  envFilePath = name: "/run/github-runner/${name}.env";
  toolsDir = "/var/lib/github-runner-tools";
  workDir = name: i: "/var/lib/github-runner/${name}-${toString i}/work";
in {
  options.homelab.github-runners = {
    enable = lib.mkEnableOption ''
      Self-hosted GitHub Actions runners.
      See docs/github-runner.md for token + sops setup.
    '';

    backend = lib.mkOption {
      type = lib.types.enum [ "native" "container" ];
      default = "container";
      description = ''
        `container` (default): Ubuntu OCI runners via Podman (GitHub-hosted FHS
        parity, rustup aarch64 target, apt libs). `native`: NixOS
        services.github-runners with parityPackages on PATH.
      '';
    };

    containerImage = lib.mkOption {
      type = lib.types.str;
      default = defaultContainerImage;
      description = ''
        OCI image for container-backend runners. Default is the locally built
        `localhost/homelab-github-runner:ubuntu-noble` (base + apt/cross toolchain).
        Built by `github-runner-image.service` from nixos/services/github-runner/Containerfile.
      '';
    };

    containerBaseImage = lib.mkOption {
      type = lib.types.str;
      default = defaultBaseImage;
      description = ''
        Upstream image used as FROM when building `containerImage`.
        Default: myoung34/github-runner:ubuntu-noble.
      '';
    };

    containerMemory = lib.mkOption {
      type = lib.types.str;
      default = "4096m";
      description = ''
        Default memory hard-cap per runner container when
        `runners.<name>.container.memory` is null. Sized so N concurrent
        runners leave headroom for ace web services (see docs/github-runner.md).
      '';
    };

    containerCpus = lib.mkOption {
      type = lib.types.str;
      default = "4";
      description = ''
        Default CPU limit per runner container when
        `runners.<name>.container.cpus` is null.
      '';
    };

    nodeRuntimes = lib.mkOption {
      type = lib.types.nonEmptyListOf (lib.types.enum [ "node20" "node24" ]);
      default = [ "node20" "node24" ];
      description = ''
        Native backend only: Node.js runtimes under runner `lib/externals/`.
        Actions `hashFiles(...)` still expect `externals/node20`.
      '';
    };

    parityPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = defaultParityPackages;
      defaultText = lib.literalExpression "curl wget jq unzip zip rsync … (see module)";
      description = ''
        Native backend: packages on every runner PATH. Container backend uses
        Ubuntu apt packages + rustup bootstrap instead.
      '';
    };

    runners = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule runnerModule);
      default = { };
      example = {
        default = {
          url = "https://github.com/PrestonHager/soundbytes-app";
          instances = 4;
          extraLabels = [ "ace-ubuntu-x64-4" ];
        };
      };
      description = ''
        Attrset of runner definitions. Each key is the base name; with
        `instances > 1` GitHub sees `name-1` … `name-N`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = enabledRunners != { };
        message = "homelab.github-runners.enable requires at least one entry in homelab.github-runners.runners";
      }
    ] ++ lib.mapAttrsToList (name: r: {
      assertion = r.url != "";
      message = "homelab.github-runners.runners.${name}.url must be set";
    }) enabledRunners
    ++ lib.optionals (cfg.backend == "native") (
      lib.mapAttrsToList (name: r: {
        assertion = !r.docker.enable || (r.user != null && r.group != null);
        message = ''
          homelab.github-runners.runners.${name}: docker.enable requires
          user and group to be set (DynamicUser cannot join the docker group).
        '';
      }) enabledRunners
    );

    # Declare sops secrets only when not overridden by tokenFile.
    sops.secrets = lib.mkMerge (
      lib.mapAttrsToList (_name: r:
        lib.optionalAttrs (r.tokenFile == null) {
          ${r.tokenSecret} = {
            sopsFile = r.sopsFile;
            key = r.sopsKey;
            mode = "0400";
          };
        }
      ) enabledRunners
    );

    ########################################################################
    # Native backend (NixOS services.github-runners)
    ########################################################################
    virtualisation.docker.enable = lib.mkIf needsNativeDocker true;

    users = lib.mkIf (cfg.backend == "native") (lib.mkMerge (
      lib.mapAttrsToList (_name: r:
        lib.optionalAttrs (r.docker.enable && r.user != null) {
          users.${r.user} = {
            isSystemUser = true;
            group = r.group;
            extraGroups = [ "docker" ];
            description = "GitHub Actions runner";
          };
          groups.${r.group} = { };
        }
      ) enabledRunners
    ));

    services.github-runners = lib.mkIf (cfg.backend == "native") (
      lib.listToAttrs (
        lib.concatLists (
          lib.mapAttrsToList (name: r:
            map (i:
              let
                iname = instanceName name r i;
                rname = instanceName (if r.name != null then r.name else name) r i;
              in {
                name = iname;
                value = {
                  enable = true;
                  name = rname;
                  inherit (r) url ephemeral replace extraLabels;
                  extraEnvironment = r.extraEnvironment;
                  inherit (cfg) nodeRuntimes;
                  tokenFile = resolvedTokenFile name r;
                  user = r.user;
                  group = r.group;
                  extraPackages = cfg.parityPackages ++ r.extraPackages;
                  serviceOverrides = lib.mkMerge [
                    (lib.optionalAttrs r.docker.enable {
                      SupplementaryGroups = [ "docker" ];
                      PrivateUsers = false;
                      RestrictNamespaces = false;
                      BindPaths = [ "/var/run/docker.sock" ];
                    })
                    r.serviceOverrides
                  ];
                };
              }
            ) (instanceRange r)
          ) enabledRunners
        )
      )
    );

    ########################################################################
    # Container backend (Ubuntu OCI via Podman)
    ########################################################################
    systemd.tmpfiles.rules = lib.mkIf (cfg.backend == "container") (
      [
        "d ${toolsDir} 0755 root root -"
        "d ${toolsDir}/bin 0755 root root -"
      ]
      ++ lib.concatMap ({ name, r, i, ... }: [
        "d /var/lib/github-runner/${name}-${toString i} 0755 root root -"
        "d ${workDir name i} 0755 root root -"
      ]) containerInstances
      ++ [ "d /run/github-runner 0750 root root -" ]
    );

    # Render ACCESS_TOKEN=… env files from sops/tokenFile for myoung34 image.
    # Also provision pkgs.zig (and future Nix toolchains) into the shared tools volume.
    # Build baked runner image; optional ghost-watch timer.
    environment.systemPackages = lib.mkIf (cfg.backend == "container") [
      recoverGhostScript
    ];

    systemd.services = lib.mkMerge (
      # Env renderers (container)
      (lib.optionals (cfg.backend == "container") (
        lib.mapAttrsToList (name: r: {
          "github-runner-env-${name}" = {
            description = "Render GitHub runner ACCESS_TOKEN env for ${name}";
            wantedBy = [ "multi-user.target" ];
            after = lib.optional (r.tokenFile == null) "sops-nix.service";
            wants = lib.optional (r.tokenFile == null) "sops-nix.service";
            before = map (i: "${containerUnitName "github-runner-${instanceName name r i}"}.service")
              (instanceRange r);
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              set -euo pipefail
              install -d -m 0750 /run/github-runner
              token="$(tr -d '\n' < ${lib.escapeShellArg (resolvedTokenFile name r)})"
              umask 077
              printf 'ACCESS_TOKEN=%s\n' "$token" > ${lib.escapeShellArg (envFilePath name)}
            '';
          };
        }) enabledRunners
      ))
      # Bake apt/cross into local OCI image (skip per-start apt on ephemeral restarts).
      ++ (lib.optionals (cfg.backend == "container") [{
        github-runner-image = {
          description = "Build homelab GitHub runner OCI image (apt/cross baked in)";
          wantedBy = [ "multi-user.target" ];
          before = map ({ cname, ... }: "${containerUnitName cname}.service")
            containerInstances;
          after = [ "network-online.target" "podman.socket" ];
          wants = [ "network-online.target" "podman.socket" ];
          path = [ pkgs.podman pkgs.coreutils pkgs.gnugrep ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            TimeoutStartSec = "45min";
          };
          script = ''
            set -euo pipefail
            install -d -m 0755 ${toolsDir}
            base=${lib.escapeShellArg cfg.containerBaseImage}
            tag=${lib.escapeShellArg cfg.containerImage}
            cf=${lib.escapeShellArg "${containerfileSrc}"}
            stamp=${lib.escapeShellArg imageStampPath}

            echo "homelab-ci: ensuring base image $base"
            podman pull "$base"

            base_id="$(podman image inspect "$base" --format '{{.Id}}')"
            cf_hash="$(sha256sum "$cf" | cut -d' ' -f1)"
            want="''${cf_hash}-''${base_id}"

            have_tag=0
            if podman image exists "$tag"; then
              have_tag=1
            fi

            if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ] && [ "$have_tag" = 1 ]; then
              echo "homelab-ci: runner image $tag up to date"
              exit 0
            fi

            echo "homelab-ci: building $tag from $cf (base=$base)"
            builddir="$(mktemp -d)"
            trap 'rm -rf "$builddir"' EXIT
            cp "$cf" "$builddir/Containerfile"
            podman build \
              --build-arg "BASE_IMAGE=$base" \
              -t "$tag" \
              -f "$builddir/Containerfile" \
              "$builddir"
            printf '%s\n' "$want" > "$stamp"
            echo "homelab-ci: built $tag"
          '';
        };
      }])
      # Symlink nixpkgs toolchains into the shared volume (survives ephemeral restarts).
      ++ (lib.optionals (cfg.backend == "container") [{
        github-runner-tools-bin = {
          description = "Provision shared GitHub runner toolchain bins (zig)";
          wantedBy = [ "multi-user.target" ];
          before = map ({ cname, ... }: "${containerUnitName cname}.service")
            containerInstances;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          # Keep zig's nix store path alive across GC.
          path = [ pkgs.coreutils ];
          script = ''
            set -euo pipefail
            install -d -m 0755 ${toolsDir}/bin
            ln -sfn ${lib.escapeShellArg "${pkgs.zig}/bin/zig"} ${toolsDir}/bin/zig
          '';
        };
      }])
      # Ghost offline+busy auto-recovery (uses PAT from env file; no secrets logged).
      ++ (lib.optionals (cfg.backend == "container" && enabledRunners != { }) (
        let
          # Prefer first enabled runner definition for token + repo URL.
          primaryName = builtins.head (lib.attrNames enabledRunners);
          primary = enabledRunners.${primaryName};
          ownerRepo =
            let
              u = primary.url;
              stripped = lib.removeSuffix "/" (lib.removeSuffix ".git" (
                lib.removePrefix "https://github.com/" (
                  lib.removePrefix "http://github.com/" u
                )
              ));
            in stripped;
          runnerNames = lib.concatStringsSep " " (
            lib.concatLists (
              lib.mapAttrsToList (name: r:
                map (i: instanceName (if r.name != null then r.name else name) r i)
                  (instanceRange r)
              ) enabledRunners
            )
          );
        in [{
          github-runner-ghost-watch = {
            description = "Recover GitHub runners stuck offline+busy";
            after = [
              "network-online.target"
              "github-runner-env-${primaryName}.service"
            ];
            wants = [ "network-online.target" ];
            path = [ pkgs.curl pkgs.jq pkgs.systemd pkgs.coreutils pkgs.gnugrep ];
            serviceConfig = {
              Type = "oneshot";
            };
            script = ''
              set -euo pipefail
              envf=${lib.escapeShellArg (envFilePath primaryName)}
              if [ ! -f "$envf" ]; then
                echo "homelab-ci: ghost-watch skip (no env file)"
                exit 0
              fi
              # shellcheck disable=SC1090
              set -a
              # Only ACCESS_TOKEN=... ; do not echo
              token="$(sed -n 's/^ACCESS_TOKEN=//p' "$envf" | tr -d '\r\n')"
              set +a
              if [ -z "$token" ]; then
                echo "homelab-ci: ghost-watch skip (empty token)"
                exit 0
              fi
              repo=${lib.escapeShellArg ownerRepo}
              known=${lib.escapeShellArg runnerNames}
              api() {
                curl -fsS -H "Authorization: Bearer ''${token}" \
                  -H "Accept: application/vnd.github+json" \
                  -H "X-GitHub-Api-Version: 2022-11-28" \
                  "$@"
              }
              json="$(api "https://api.github.com/repos/''${repo}/actions/runners" || true)"
              if [ -z "$json" ]; then
                echo "homelab-ci: ghost-watch: runners API unavailable"
                exit 0
              fi
              echo "$json" | jq -r --arg known "$known" '
                ($known | split(" ")) as $k
                | .runners[]?
                | select(.status=="offline" and .busy==true)
                | select(.name as $n | $k | index($n) != null)
                | .name
              ' | while read -r name; do
                [ -z "$name" ] && continue
                echo "homelab-ci: ghost-watch recovering $name"
                # Cancel in-progress runs that have jobs on this runner
                runs="$(api "https://api.github.com/repos/''${repo}/actions/runs?status=in_progress&per_page=20" \
                  | jq -r '.workflow_runs[]?.id' || true)"
                for run_id in $runs; do
                  [ -z "$run_id" ] && continue
                  hit="$(api "https://api.github.com/repos/''${repo}/actions/runs/''${run_id}/jobs" \
                    | jq -r --arg n "$name" \
                      '[.jobs[]? | select(.runner_name==$n and .status=="in_progress")] | length' || echo 0)"
                  if [ "''${hit:-0}" != "0" ]; then
                    echo "homelab-ci: cancelling run $run_id for $name"
                    curl -fsS -X POST \
                      -H "Authorization: Bearer ''${token}" \
                      -H "Accept: application/vnd.github+json" \
                      -H "X-GitHub-Api-Version: 2022-11-28" \
                      "https://api.github.com/repos/''${repo}/actions/runs/''${run_id}/cancel" >/dev/null || true
                  fi
                done
                systemctl restart "podman-github-runner-''${name}.service" || true
              done
            '';
          };
        }]
      ))
      # Native: wait for sops
      ++ (lib.optionals (cfg.backend == "native") (
        lib.concatLists (
          lib.mapAttrsToList (name: r:
            if r.tokenFile != null then [ ] else
            map (i: {
              "github-runner-${instanceName name r i}" = {
                after = [ "sops-nix.service" ];
                wants = [ "sops-nix.service" ];
              };
            }) (instanceRange r)
          ) enabledRunners
        )
      ))
      # Container units: depend on env + tools + image; always restart (ephemeral
      # runners exit 0 after each job and must come back online).
      ++ (lib.optionals (cfg.backend == "container") (
        map ({ name, cname, ... }: {
          "${containerUnitName cname}" = {
            after = [
              "github-runner-env-${name}.service"
              "github-runner-tools-bin.service"
              "github-runner-image.service"
              "podman.socket"
            ];
            requires = [
              "github-runner-env-${name}.service"
              "github-runner-tools-bin.service"
              "github-runner-image.service"
            ];
            wants = [ "podman.socket" ];
            serviceConfig = {
              Restart = lib.mkForce "always";
              RestartSec = "5";
            };
          };
        }) containerInstances
      ))
    );

    systemd.timers = lib.mkIf (cfg.backend == "container" && enabledRunners != { }) {
      github-runner-ghost-watch = {
        description = "Periodically recover ghost offline+busy GitHub runners";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "3min";
          OnUnitActiveSec = "5min";
          Persistent = true;
        };
      };
    };

    virtualisation.oci-containers.containers = lib.mkIf (cfg.backend == "container") (
      lib.listToAttrs (
        map ({ name, r, i, cname, runnerName }: {
          name = cname;
          value = {
            autoStart = true;
            image =
              if r.container.image != null then r.container.image else cfg.containerImage;
            entrypoint = "/bootstrap/homelab-entrypoint.sh";
            # Image CMD is dropped when entrypoint is overridden; restore it so
            # myoung34's entrypoint actually starts Runner.Listener.
            cmd = [ "./bin/Runner.Listener" "run" "--startuptype" "service" ];
            environmentFiles = [ (envFilePath name) ];
            environment = {
              REPO_URL = r.url;
              RUNNER_NAME = runnerName;
              RUNNER_SCOPE = "repo";
              LABELS = labelsCsv r;
              RUNNER_WORKDIR = workDir name i;
              EPHEMERAL = if r.ephemeral then "true" else "";
              DISABLE_AUTO_UPDATE = "1";
              # Homelab entrypoint owns deregister (see containerEntrypoint).
              DISABLE_AUTOMATIC_DEREGISTRATION = "true";
              RANDOM_RUNNER_SUFFIX = "false";
              RUN_AS_ROOT = "true";
              HOMELAB_CI_TOOLS = toolsDir;
              # Toolchains on shared volume; job Cargo registry/git use /root/.cargo
              # (wiped each start). Do NOT set CARGO_HOME to toolsDir — that shared
              # writable cache across repos/PRs. Prefer actions/cache in workflows.
              RUSTUP_HOME = "${toolsDir}/rustup";
              CARGO_HOME = "/root/.cargo";
              CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER = "aarch64-linux-gnu-gcc";
              CC_aarch64_unknown_linux_gnu = "aarch64-linux-gnu-gcc";
              CXX_aarch64_unknown_linux_gnu = "aarch64-linux-gnu-g++";
            } // r.extraEnvironment;
            volumes =
              [
                "${containerEntrypoint}:/bootstrap/homelab-entrypoint.sh:ro"
                "${toolsDir}:${toolsDir}"
                # pkgs.zig (and any other Nix-linked tools under ${toolsDir}/bin)
                # need store paths resolvable inside the Ubuntu container.
                "/nix/store:/nix/store:ro"
                "${workDir name i}:${workDir name i}"
              ]
              ++ lib.optional r.container.mountDockerSocket
                "/run/podman/podman.sock:/var/run/docker.sock";
            extraOptions = [
              "--memory=${if r.container.memory != null then r.container.memory else cfg.containerMemory}"
              "--cpus=${if r.container.cpus != null then r.container.cpus else cfg.containerCpus}"
              # Nested docker/podman via host socket
              "--security-opt=label=disable"
            ];
          };
        }) containerInstances
      )
    );
  };
}
