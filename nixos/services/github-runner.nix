# Reusable GitHub Actions self-hosted runner(s).
# Import on any host:  imports = [ ../../nixos/services/github-runner.nix ];
# Enable with:         homelab.github-runners.enable = true; + runners.<name>
# Docs: docs/github-runner.md
{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.homelab.github-runners;
  netCfg = config.homelab.github-runner-network;
  sops-path = builtins.toString inputs.nix-secrets;

  # Tools GitHub-hosted Ubuntu runners commonly provide that CI scripts expect.
  # Used only for backend = "native". Container backend uses an Ubuntu image
  # plus a shared tools volume (rustup bootstrap + pkgs.zig/ffmpeg symlinks).
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
    ffmpeg
  ];

  defaultBaseImage = "docker.io/myoung34/github-runner:ubuntu-noble";
  defaultContainerImage = "localhost/homelab-github-runner:ubuntu-noble";
  defaultContainerfile = ./github-runner/Containerfile;
  imageStampPath = "/var/lib/github-runner-tools/image.stamp";
  runnerVersionPath = "/var/lib/github-runner-tools/runner.version";

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
      # pkgs.zig / pkgs.ffmpeg are symlinked into $TOOLS/bin on the host (needs /nix/store mounted).
      # Node: AL2023 image bakes Node 20 into /usr/local; Actions externals/node20 is a fallback
      # so shell jobs (build-lambdas.sh) find `node` even before a re-bake.
      export CARGO_HOME="$TOOLS_CARGO"
      export RUSTUP_HOME="$TOOLS/rustup"
      export PATH="$TOOLS/bin:$TOOLS_CARGO/bin:/usr/local/sbin:/usr/local/bin:/actions-runner/externals/node20/bin:/usr/sbin:/usr/bin:/sbin:/bin"

      # Prefer baked image packages (/etc/homelab-ci-baked); apt/dnf fallback for stock bases.
      if [ -f /etc/homelab-ci-baked ]; then
        echo "homelab-ci: toolchain present (baked image)"
      elif command -v apt-get >/dev/null 2>&1; then
        echo "homelab-ci: installing apt build/cross packages (image missing toolchain) ..."
        apt-get update -qq
        apt-get install -y --no-install-recommends \
          build-essential pkg-config libssl-dev libffi-dev zlib1g-dev \
          ca-certificates curl wget jq unzip zip rsync gnupg openssh-client \
          git cmake python3 \
          gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
          libc6-dev-arm64-cross binutils-aarch64-linux-gnu
      elif command -v dnf >/dev/null 2>&1; then
        echo "homelab-ci: installing dnf build packages (image missing toolchain) ..."
        dnf install -y --setopt=install_weak_deps=0 \
          gcc gcc-c++ make cmake pkgconf-pkg-config \
          openssl-devel libffi-devel zlib-devel \
          ca-certificates curl wget jq unzip zip rsync \
          gnupg2 openssh-clients git python3 libicu \
          tar gzip findutils which \
          || true
        # AL2023 does not ship these RPMs; baked image installs Zig wrappers instead.
        dnf install -y --setopt=install_weak_deps=0 \
          gcc-aarch64-linux-gnu gcc-c++-aarch64-linux-gnu \
          binutils-aarch64-linux-gnu \
          || echo "homelab-ci: aarch64 cross unavailable via dnf (use AL2023 Zig wrappers)"
      else
        echo "homelab-ci: WARNING no apt/dnf and no baked marker — toolchain may be incomplete"
      fi

      if [ ! -x "$TOOLS_CARGO/bin/rustup" ]; then
        echo "homelab-ci: installing rustup into $TOOLS ..."
        got_lock=0
        waited=0
        while ! mkdir "$TOOLS/.bootstrap.lock.d" 2>/dev/null; do
          if [ -x "$TOOLS_CARGO/bin/rustup" ]; then
            break
          fi
          # A holder that died without its trap (SIGKILL, OOM) leaves the lock behind.
          if [ "$waited" -ge 600 ]; then
            echo "homelab-ci: removing stale bootstrap lock"
            rmdir "$TOOLS/.bootstrap.lock.d" 2>/dev/null || true
            waited=0
            continue
          fi
          sleep 2
          waited=$((waited + 2))
        done
        if [ -d "$TOOLS/.bootstrap.lock.d" ] && [ ! -x "$TOOLS_CARGO/bin/rustup" ]; then
          got_lock=1
          # Release the lock even when the install fails under set -e.
          trap 'rmdir "$TOOLS/.bootstrap.lock.d" 2>/dev/null || true' EXIT
          curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --no-modify-path --default-toolchain stable \
              --profile minimal \
              --target x86_64-unknown-linux-gnu,aarch64-unknown-linux-gnu
          echo "homelab-ci: rustup install complete"
        fi
        if [ "$got_lock" = 1 ]; then
          rmdir "$TOOLS/.bootstrap.lock.d" 2>/dev/null || true
          trap - EXIT
        fi
      fi

      if [ -x "$TOOLS_CARGO/bin/rustup" ]; then
        "$TOOLS_CARGO/bin/rustup" default stable >/dev/null 2>&1 || \
          "$TOOLS_CARGO/bin/rustup" toolchain install stable --profile minimal
        "$TOOLS_CARGO/bin/rustup" target add \
          x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu >/dev/null 2>&1 || true
      fi

      # github-runner-tools-bootstrap runs this once with the tools dir writable;
      # runner containers only get an overlay of it.
      if [ "''${HOMELAB_CI_BOOTSTRAP_ONLY:-}" = 1 ]; then
        echo "homelab-ci: tools bootstrap done"
        exit 0
      fi

      # Cross-link defaults when aarch64 cross gcc exists (Ubuntu bake / optional AL2023).
      if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
        export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="''${CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER:-aarch64-linux-gnu-gcc}"
        export CC_aarch64_unknown_linux_gnu="''${CC_aarch64_unknown_linux_gnu:-aarch64-linux-gnu-gcc}"
        export CXX_aarch64_unknown_linux_gnu="''${CXX_aarch64_unknown_linux_gnu:-aarch64-linux-gnu-g++}"
      fi

      # Job caches must NOT live on the shared tools volume (cross-job/PR/repo leak).
      # Use GitHub actions/cache (Swatinem/rust-cache, actions/setup-node cache) instead.
      # Keep toolchain binaries on PATH; point CARGO_HOME at a per-container home path.
      export PATH="$TOOLS/bin:$TOOLS_CARGO/bin:/usr/local/sbin:/usr/local/bin:/actions-runner/externals/node20/bin:/usr/sbin:/usr/bin:/sbin:/bin"
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
      # myoung34 exports this only inside /entrypoint.sh; our EXIT trap runs
      # config.sh remove from this shell, which otherwise fails with
      # "Must not run with sudo" and leaves the runner registered.
      export RUNNER_ALLOW_RUNASROOT=1

      _HOMELAB_DEREGISTERED=false

      # The GitHub PAT never enters the container (jobs run as root here and could
      # read it). The host mints a short-lived registration token (RUNNER_TOKEN) and
      # remove token (HOMELAB_REMOVE_TOKEN) before each start, and deletes the runner
      # by name with the PAT after the container stops (ExecStopPost).
      homelab_deregister() {
        local reason="''${1:-EXIT}"
        if [ "''${_HOMELAB_DEREGISTERED}" = "true" ]; then
          return 0
        fi
        _HOMELAB_DEREGISTERED=true
        echo "homelab-ci: deregister ($reason)"
        if [ -f /actions-runner/.runner ] && [ -n "''${HOMELAB_REMOVE_TOKEN:-}" ]; then
          echo "homelab-ci: .runner present — config.sh remove while credentials exist"
          (
            cd /actions-runner
            ./config.sh remove --token "''${HOMELAB_REMOVE_TOKEN}" \
              || echo "homelab-ci: config.sh remove failed; host deletes by name on stop"
          )
        else
          echo "homelab-ci: no local registration or remove token; host deletes by name on stop"
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

  # The runner binary is baked into the image with DISABLE_AUTO_UPDATE, and
  # GitHub refuses messages from deprecated versions (the listener exits right
  # after "Listening for Jobs"). So resolve the latest actions/runner release at
  # bake time and fold it into the stamp; the daily refresh timer rebakes when
  # a new release lands. Falls back to the last resolved version (or the
  # Containerfile's GH_RUNNER_VERSION default) when the API is unreachable.
  imageBuildScript = pkgs.writeShellScript "github-runner-image-build" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.podman pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.curl pkgs.jq pkgs.util-linux ]}:$PATH
    install -d -m 0755 ${toolsDir}
    exec 9>${toolsDir}/.image-build.lock
    flock 9

    base=${lib.escapeShellArg cfg.containerBaseImage}
    tag=${lib.escapeShellArg cfg.containerImage}
    cf=${lib.escapeShellArg "${cfg.containerfile}"}
    stamp=${lib.escapeShellArg imageStampPath}
    verfile=${lib.escapeShellArg runnerVersionPath}

    echo "homelab-ci: ensuring base image $base"
    # A registry outage must not stop runners from starting on the image we already have.
    if ! podman pull "$base"; then
      podman image exists "$base" || { echo "homelab-ci: pull failed and no local $base" >&2; exit 1; }
      echo "homelab-ci: pull failed; using local $base"
    fi
    # AL2023 Containerfile also FROM myoung34 for entrypoint/token scripts.
    m34_id=""
    if grep -q 'myoung34/github-runner' "$cf" 2>/dev/null; then
      echo "homelab-ci: ensuring myoung34 image for runner scripts"
      podman pull docker.io/myoung34/github-runner:ubuntu-noble || true
      m34_id="$(podman image inspect docker.io/myoung34/github-runner:ubuntu-noble --format '{{.Id}}' 2>/dev/null || true)"
    fi

    ver="$(curl -fsS --max-time 30 https://api.github.com/repos/actions/runner/releases/latest \
      | jq -r '.tag_name // empty' | sed 's/^v//' || true)"
    if [ -z "$ver" ] && [ -f "$verfile" ]; then
      ver="$(cat "$verfile")"
      echo "homelab-ci: runner release lookup failed; reusing $ver"
    fi
    ver_args=()
    if [ -n "$ver" ]; then
      echo "homelab-ci: actions/runner version $ver"
      ver_args=(--build-arg "GH_RUNNER_VERSION=$ver")
    else
      echo "homelab-ci: runner release lookup failed; using Containerfile default"
    fi

    base_id="$(podman image inspect "$base" --format '{{.Id}}')"
    cf_hash="$(sha256sum "$cf" | cut -d' ' -f1)"
    want="''${cf_hash}-''${base_id}-''${m34_id}-''${ver:-default}"

    old_id=""
    if podman image exists "$tag"; then
      old_id="$(podman image inspect "$tag" --format '{{.Id}}')"
    fi

    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ] && [ -n "$old_id" ]; then
      echo "homelab-ci: runner image $tag up to date"
      exit 0
    fi

    echo "homelab-ci: building $tag from $cf (base=$base)"
    builddir="$(mktemp -d)"
    trap 'rm -rf "$builddir"' EXIT
    cp "$cf" "$builddir/Containerfile"
    podman build \
      --build-arg "BASE_IMAGE=$base" \
      "''${ver_args[@]}" \
      -t "$tag" \
      -f "$builddir/Containerfile" \
      "$builddir"
    printf '%s\n' "$want" > "$stamp"
    [ -n "$ver" ] && printf '%s\n' "$ver" > "$verfile"
    echo "homelab-ci: built $tag"
    # Drop the superseded image once no container uses it (best effort).
    new_id="$(podman image inspect "$tag" --format '{{.Id}}')"
    if [ -n "$old_id" ] && [ "$old_id" != "$new_id" ]; then
      podman rmi "$old_id" >/dev/null 2>&1 || true
    fi
  '';

  recoverGhostScript =pkgs.writeShellScriptBin "github-runner-recover-ghost" ''
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
          default = false;
          description = ''
            Mount host Podman socket at /var/run/docker.sock inside the runner
            so workflow `container:` / docker actions work (ace uses podman + dockerCompat).
            Off by default: the rootful socket gives every CI job root on the host.
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

  # Host-only: holds the PAT (ACCESS_TOKEN=…) for the token minting and ghost-watch units.
  envFilePath = name: "/run/github-runner/${name}.env";
  # Passed to the container: short-lived registration/remove tokens only.
  instanceEnvPath = cname: "/run/github-runner/${cname}.tokens.env";

  # The PAT goes to curl as a config file on stdin (bash here-string), never as
  # an argv element: argv is world-readable in /proc and `ps`.
  githubApi = ''
    gh_api() {
      curl -fsS --max-time 30 -K - \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" "$@" \
        <<< "header = \"Authorization: Bearer $pat\""
    }
  '';

  # Host-side wipe of a runner's bind-mounted workdir. Runs before each start
  # and after each stop, so checkout credentials (_temp/git-credentials-*) and
  # sources do not sit on the host between jobs.
  wipeWorkdir = name: i: pkgs.writeShellScript "github-runner-wipe-${name}-${toString i}" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.findutils ]}
    d=${lib.escapeShellArg (workDir name i)}
    install -d -m 0700 "$d"
    find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf --one-file-system -- {} +
  '';

  # ExecStartPre: mint a registration and a remove token (each valid ~1h) with the PAT.
  mintRunnerTokens = name: r: cname: pkgs.writeShellScript "github-runner-mint-${cname}" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.curl pkgs.jq pkgs.gnused ]}
    pat="$(sed -n 's/^ACCESS_TOKEN=//p' ${lib.escapeShellArg (envFilePath name)} | tr -d '\r\n')"
    ${githubApi}
    base="https://api.github.com/repos/${ownerRepoFromUrl r.url}/actions/runners"
    reg="$(gh_api -X POST "$base/registration-token" | jq -r '.token // empty')"
    rem="$(gh_api -X POST "$base/remove-token" | jq -r '.token // empty' || true)"
    if [ -z "$reg" ]; then
      echo "homelab-ci: could not mint a registration token for ${cname}" >&2
      exit 1
    fi
    umask 077
    out=${lib.escapeShellArg (instanceEnvPath cname)}
    printf 'RUNNER_TOKEN=%s\nHOMELAB_REMOVE_TOKEN=%s\n' "$reg" "$rem" > "$out.tmp"
    mv "$out.tmp" "$out"
  '';

  # ExecStopPost: delete a runner left registered (killed container, expired remove token).
  deleteRunnerByName = name: r: cname: runnerName: pkgs.writeShellScript "github-runner-delete-${cname}" ''
    set -uo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.curl pkgs.jq pkgs.gnused ]}
    rm -f ${lib.escapeShellArg (instanceEnvPath cname)}
    pat="$(sed -n 's/^ACCESS_TOKEN=//p' ${lib.escapeShellArg (envFilePath name)} | tr -d '\r\n')"
    [ -n "$pat" ] || exit 0
    ${githubApi}
    base="https://api.github.com/repos/${ownerRepoFromUrl r.url}/actions/runners"
    id="$(gh_api "$base?per_page=100" \
      | jq -r --arg n ${lib.escapeShellArg runnerName} '.runners[]? | select(.name == $n) | .id' | head -n1)"
    if [ -n "$id" ]; then
      gh_api -X DELETE "$base/$id" >/dev/null \
        && echo "homelab-ci: deleted leftover runner ${runnerName} (id $id)" \
        || echo "homelab-ci: delete of ${runnerName} failed (may be busy or gone)"
    fi
    exit 0
  '';

  ownerRepoFromUrl = u:
    lib.removeSuffix "/" (lib.removeSuffix ".git" (
      lib.removePrefix "https://github.com/" (
        lib.removePrefix "http://github.com/" u
      )
    ));
  toolsDir = "/var/lib/github-runner-tools";
  workDir = name: i: "/var/lib/github-runner/${name}-${toString i}/work";

  # Official musl release — runs on AL2023 (glibc 2.34). Do NOT cargo-install into
  # the shared tools volume from Ubuntu/NixOS hosts (those binaries need GLIBC 2.38+).
  cargoLambdaMusl = pkgs.stdenvNoCC.mkDerivation {
    pname = "cargo-lambda-musl";
    version = "1.6.3";
    src = pkgs.fetchurl {
      url = "https://github.com/cargo-lambda/cargo-lambda/releases/download/v1.6.3/cargo-lambda-v1.6.3.x86_64-unknown-linux-musl.tar.gz";
      hash = "sha256-Zwoc8cosAdMMjdBqt/quNhWK3QOw6bL78NG7+Ljt+Og=";
    };
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.gnutar pkgs.gzip ];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      tar -xzf $src -C $out/bin
      chmod +x $out/bin/cargo-lambda
      runHook postInstall
    '';
    dontPatchELF = true;
    dontStrip = true;
  };
in {
  imports = [ ./github-runner/network.nix ];

  options.homelab.github-runners = {
    enable = lib.mkEnableOption ''
      Self-hosted GitHub Actions runners.
      See docs/github-runner.md for token + sops setup.
    '';

    backend = lib.mkOption {
      type = lib.types.enum [ "native" "container" ];
      default = "container";
      description = ''
        `container` (default): OCI runners via Podman (Ubuntu Noble or AL2023
        baked images + shared tools volume). `native`: NixOS
        services.github-runners with parityPackages on PATH.
      '';
    };

    containerImage = lib.mkOption {
      type = lib.types.str;
      default = defaultContainerImage;
      description = ''
        OCI image for container-backend runners. Default is the locally built
        Ubuntu Noble image. Ace uses `localhost/homelab-github-runner:al2023`
        (glibc 2.34) for Lambda-compatible native builds. Built by
        `github-runner-image.service` from `containerfile`.
      '';
    };

    containerBaseImage = lib.mkOption {
      type = lib.types.str;
      default = defaultBaseImage;
      description = ''
        Upstream image used as FROM when building `containerImage`.
        Ubuntu: myoung34/github-runner:ubuntu-noble.
        AL2023 (Lambda glibc 2.34): amazonlinux:2023 (see Containerfile.al2023).
      '';
    };

    containerfile = lib.mkOption {
      type = lib.types.path;
      default = defaultContainerfile;
      defaultText = "nixos/services/github-runner/Containerfile";
      description = ''
        Containerfile for `github-runner-image.service`.
        Use `./github-runner/Containerfile` (Ubuntu Noble) or
        `./github-runner/Containerfile.al2023` (Amazon Linux 2023 / Lambda).
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
    homelab.github-runner-network.enable = lib.mkIf (cfg.backend == "container") true;

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
        # 0700 all the way down: jobs leave checkout credentials and sources in
        # the workdirs, which are none of any other host user's business.
        "d /var/lib/github-runner 0700 root root -"
      ]
      ++ lib.concatMap ({ name, r, i, ... }: [
        "d /var/lib/github-runner/${name}-${toString i} 0700 root root -"
        "d ${workDir name i} 0700 root root -"
      ]) containerInstances
      ++ [ "d /run/github-runner 0750 root root -" ]
    );

    # Render ACCESS_TOKEN=… env files from sops/tokenFile for myoung34 image.
    # Also provision pkgs.zig / pkgs.ffmpeg (and future Nix toolchains) into the shared tools volume.
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
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            TimeoutStartSec = "45min";
            ExecStart = imageBuildScript;
          };
        };
        # Separate unit for the timer: restarting github-runner-image itself
        # would propagate (Requires=) and kill every runner mid-job. Containers
        # pick up the re-tagged image on their next ephemeral restart.
        github-runner-image-refresh = {
          description = "Rebuild homelab GitHub runner image if a newer runner release exists";
          after = [ "network-online.target" "podman.socket" "github-runner-image.service" ];
          wants = [ "network-online.target" "podman.socket" ];
          serviceConfig = {
            Type = "oneshot";
            TimeoutStartSec = "45min";
            ExecStart = imageBuildScript;
          };
        };
      }])
      # Runners mount the tools dir as an overlay, so first-time rustup install must
      # happen here, with the real directory writable.
      ++ (lib.optionals (cfg.backend == "container") [{
        github-runner-tools-bootstrap = {
          description = "Install rustup into the shared GitHub runner tools dir";
          wantedBy = [ "multi-user.target" ];
          after = [ "github-runner-image.service" "network-online.target" ];
          wants = [ "github-runner-image.service" "network-online.target" ];
          before = map ({ cname, ... }: "${containerUnitName cname}.service")
            containerInstances;
          unitConfig.ConditionPathExists = "!${toolsDir}/cargo/bin/rustup";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            TimeoutStartSec = "30min";
            ExecStart = lib.escapeShellArgs [
              "${pkgs.podman}/bin/podman" "run" "--rm"
              "--security-opt=label=disable"
              "--entrypoint" "/bootstrap/homelab-entrypoint.sh"
              "-e" "HOMELAB_CI_BOOTSTRAP_ONLY=1"
              "-e" "HOMELAB_CI_TOOLS=${toolsDir}"
              "-v" "${containerEntrypoint}:/bootstrap/homelab-entrypoint.sh:ro"
              "-v" "${toolsDir}:${toolsDir}"
              "-v" "/nix/store:/nix/store:ro"
              cfg.containerImage
            ];
          };
        };
      }])
      # Symlink nixpkgs toolchains into the shared volume (survives ephemeral restarts).
      ++ (lib.optionals (cfg.backend == "container") [{
        github-runner-tools-bin = {
          description = "Provision shared GitHub runner toolchain bins (zig, ffmpeg, cargo-lambda)";
          wantedBy = [ "multi-user.target" ];
          before = map ({ cname, ... }: "${containerUnitName cname}.service")
            containerInstances;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          # Keep zig/ffmpeg/cargo-lambda nix store paths alive across GC.
          path = [ pkgs.coreutils ];
          script = ''
            set -euo pipefail
            install -d -m 0755 ${toolsDir}/bin ${toolsDir}/cargo/bin
            ln -sfn ${lib.escapeShellArg "${pkgs.zig}/bin/zig"} ${toolsDir}/bin/zig
            ln -sfn ${lib.escapeShellArg "${pkgs.ffmpeg}/bin/ffmpeg"} ${toolsDir}/bin/ffmpeg
            ln -sfn ${lib.escapeShellArg "${pkgs.ffmpeg}/bin/ffprobe"} ${toolsDir}/bin/ffprobe
            # Musl static binary (glibc-independent). Replaces any cargo-install
            # artifact that required GLIBC 2.38+ and broke AL2023 runners.
            ln -sfn ${lib.escapeShellArg "${cargoLambdaMusl}/bin/cargo-lambda"} \
              ${toolsDir}/cargo/bin/cargo-lambda
          '';
        };
      }])
      # Ghost offline+busy auto-recovery (uses PAT from env file; no secrets logged).
      # Multi-repo: one row per instance — owner/repo, GitHub name, systemd unit, env file.
      ++ (lib.optionals (cfg.backend == "container" && enabledRunners != { }) (
        let
          ghostRows = lib.concatLists (
            lib.mapAttrsToList (name: r:
              map (i:
                let
                  githubName = instanceName (if r.name != null then r.name else name) r i;
                  unitSuffix = instanceName name r i;
                in "${ownerRepoFromUrl r.url}|${githubName}|podman-github-runner-${unitSuffix}|${envFilePath name}"
              ) (instanceRange r)
            ) enabledRunners
          );
          ghostRowsText = lib.concatStringsSep "\n" ghostRows;
          envAfter = map (n: "github-runner-env-${n}.service") (lib.attrNames enabledRunners);
        in [{
          github-runner-ghost-watch = {
            description = "Recover GitHub runners stuck offline+busy";
            after = [ "network-online.target" ] ++ envAfter;
            wants = [ "network-online.target" ];
            path = [ pkgs.curl pkgs.jq pkgs.systemd pkgs.coreutils pkgs.gnugrep ];
            serviceConfig = {
              Type = "oneshot";
            };
            script = ''
              set -euo pipefail
              rows=${lib.escapeShellArg ghostRowsText}
              declare -A TOKENS=()
              declare -A RUNNER_JSON=()
              token_for() {
                local envf="$1" t
                if [ -n "''${TOKENS[$envf]+x}" ]; then
                  printf '%s' "''${TOKENS[$envf]}"
                  return 0
                fi
                t=""
                if [ -f "$envf" ]; then
                  t="$(sed -n 's/^ACCESS_TOKEN=//p' "$envf" | tr -d '\r\n')"
                fi
                TOKENS[$envf]="$t"
                printf '%s' "$t"
              }
              # PAT via curl config on stdin, never argv (visible in ps).
              gh_get() {
                local token="$1"; shift
                curl -fsS --max-time 30 -K - \
                  -H "Accept: application/vnd.github+json" \
                  -H "X-GitHub-Api-Version: 2022-11-28" "$@" \
                  <<< "header = \"Authorization: Bearer ''${token}\""
              }
              runners_json_for() {
                local repo="$1" token="$2" cache_key="$3" json
                if [ -n "''${RUNNER_JSON[$cache_key]+x}" ]; then
                  printf '%s' "''${RUNNER_JSON[$cache_key]}"
                  return 0
                fi
                json="$(gh_get "$token" \
                  "https://api.github.com/repos/''${repo}/actions/runners" || true)"
                RUNNER_JSON[$cache_key]="$json"
                printf '%s' "$json"
              }
              # Prefer here-string so associative caches stay in this shell (not a pipe subshell).
              while IFS='|' read -r repo gname unit envf; do
                [ -z "''${repo:-}" ] && continue
                token="$(token_for "$envf")"
                if [ -z "$token" ]; then
                  echo "homelab-ci: ghost-watch skip $gname (no token)"
                  continue
                fi
                json="$(runners_json_for "$repo" "$token" "''${repo}|''${envf}")"
                if [ -z "$json" ]; then
                  echo "homelab-ci: ghost-watch: runners API unavailable for $repo"
                  continue
                fi
                ghost="$(printf '%s' "$json" | jq -r --arg n "$gname" '
                  .runners[]?
                  | select(.name==$n and .status=="offline" and .busy==true)
                  | .name
                ' | head -n1 || true)"
                [ -z "$ghost" ] && continue
                echo "homelab-ci: ghost-watch recovering $gname ($unit) repo=$repo"
                runs="$(gh_get "$token" \
                  "https://api.github.com/repos/''${repo}/actions/runs?status=in_progress&per_page=20" \
                  | jq -r '.workflow_runs[]?.id' || true)"
                for run_id in $runs; do
                  [ -z "$run_id" ] && continue
                  hit="$(gh_get "$token" \
                    "https://api.github.com/repos/''${repo}/actions/runs/''${run_id}/jobs" \
                    | jq -r --arg n "$gname" \
                      '[.jobs[]? | select(.runner_name==$n and .status=="in_progress")] | length' || echo 0)"
                  if [ "''${hit:-0}" != "0" ]; then
                    echo "homelab-ci: cancelling run $run_id for $gname"
                    gh_get "$token" -X POST \
                      "https://api.github.com/repos/''${repo}/actions/runs/''${run_id}/cancel" >/dev/null || true
                  fi
                done
                systemctl restart "''${unit}.service" || true
              done <<< "$rows"
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
        map ({ name, r, i, cname, runnerName, ... }: {
          "${containerUnitName cname}" = {
            after = [
              netCfg.unit
              "github-runner-env-${name}.service"
              "github-runner-tools-bin.service"
              "github-runner-image.service"
              "podman.socket"
            ];
            # The PAT file is needed to mint tokens. Image and tools are only wanted:
            # a failed rebake must not keep runners down on the image we already have.
            requires = [ netCfg.unit "github-runner-env-${name}.service" ];
            wants = [
              "podman.socket"
              "github-runner-tools-bin.service"
              "github-runner-tools-bootstrap.service"
              "github-runner-image.service"
            ];
            serviceConfig = {
              Restart = lib.mkForce "always";
              RestartSec = "5";
              ExecStartPre = lib.mkAfter [
                "${wipeWorkdir name i}"
                "${mintRunnerTokens name r cname}"
              ];
              ExecStopPost = lib.mkAfter [
                "${deleteRunnerByName name r cname runnerName}"
                "${wipeWorkdir name i}"
              ];
            };
          };
        }) containerInstances
      ))
    );

    systemd.timers = lib.mkIf (cfg.backend == "container" && enabledRunners != { }) {
      github-runner-image-refresh = {
        description = "Daily check for a newer GitHub runner release";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1h";
          OnUnitActiveSec = "1d";
          RandomizedDelaySec = "1h";
          Persistent = true;
        };
      };
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
            environmentFiles = [ (instanceEnvPath cname) ];
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
                # Overlay (:O): jobs see a writable copy (rustup can still add a toolchain
                # for one job) but writes are dropped when the container exits, so one
                # job cannot plant binaries for the next repo or PR.
                "${toolsDir}:${toolsDir}:O"
                # pkgs.zig / pkgs.ffmpeg (and any other Nix-linked tools under
                # ${toolsDir}/bin) need store paths resolvable inside the Ubuntu container.
                "/nix/store:/nix/store:ro"
                "${workDir name i}:${workDir name i}"
              ]
              ++ lib.optional r.container.mountDockerSocket
                "/run/podman/podman.sock:/var/run/docker.sock";
            extraOptions = [
              "--memory=${if r.container.memory != null then r.container.memory else cfg.containerMemory}"
              "--cpus=${if r.container.cpus != null then r.container.cpus else cfg.containerCpus}"
              # No SELinux on NixOS; kept so an opted-in docker socket mount works.
              "--security-opt=label=disable"
              # Jobs already run as container root; setuid binaries add nothing.
              "--security-opt=no-new-privileges"
            ]
            # Dedicated bridge with internet-only egress (see github-runner/network.nix).
            ++ netCfg.podmanOptions;
          };
        }) containerInstances
      )
    );
  };
}
