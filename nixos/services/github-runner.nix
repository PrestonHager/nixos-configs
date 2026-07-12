# Reusable GitHub Actions self-hosted runner(s).
# Import on any host:  imports = [ ../../nixos/services/github-runner.nix ];
# Enable with:         homelab.github-runners.enable = true; + runners.<name>
# Docs: docs/github-runner.md
{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.homelab.github-runners;
  sops-path = builtins.toString inputs.nix-secrets;

  # Tools GitHub-hosted Ubuntu runners commonly provide that CI scripts expect.
  # Upstream services.github-runners already puts bash, coreutils, git, gnutar,
  # gzip, nix, findutils, gnugrep, and gnused on PATH; these fill the gaps.
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
  ];

  runnerModule = { name, ... }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to enable this runner instance.";
      };

      name = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = name;
        description = ''
          Runner name shown in GitHub. Defaults to the attrset key.
          Changing this triggers re-registration.
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
        default = [ "nixos" ];
        description = ''
          Extra labels (GitHub already adds self-hosted / OS / arch by default).
          Example overrides: [ "nixos" "linux" "x64" "ace" ]
        '';
      };

      extraPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        example = lib.literalExpression "with pkgs; [ cachix ]";
        description = ''
          Extra packages on PATH for this runner, in addition to
          `homelab.github-runners.parityPackages`.
        '';
      };

      extraEnvironment = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = "Extra environment variables for the runner service.";
      };

      serviceOverrides = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = "Extra systemd serviceConfig merges (sandboxing, binds, etc.).";
      };

      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Fixed user for the runner; null uses a systemd dynamic user.";
      };

      group = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Fixed group for the runner; required with docker.enable.";
      };

      docker = {
        enable = lib.mkEnableOption ''
          Give the runner access to the host Docker socket (jobs that use
          `container:` / docker actions). Enables virtualisation.docker when needed.
        '';
      };
    };
  };

  enabledRunners = lib.filterAttrs (_: r: r.enable) cfg.runners;

  resolvedTokenFile = name: r:
    if r.tokenFile != null then r.tokenFile
    else config.sops.secrets.${r.tokenSecret}.path;

  needsDocker = lib.any (r: r.docker.enable) (lib.attrValues enabledRunners);
  needsNode20 = lib.elem "node20" cfg.nodeRuntimes;
in {
  options.homelab.github-runners = {
    enable = lib.mkEnableOption ''
      Self-hosted GitHub Actions runners via services.github-runners.
      See docs/github-runner.md for token + sops setup.
    '';

    nodeRuntimes = lib.mkOption {
      type = lib.types.nonEmptyListOf (lib.types.enum [ "node20" "node24" ]);
      default = [ "node20" "node24" ];
      description = ''
        Node.js runtimes shipped under the runner package `lib/externals/`.
        Actions expression helpers such as `hashFiles(...)` still expect
        `externals/node20` even when workflows request a newer Node.
        Nixpkgs defaults the package to node24-only (node20 is EOL/insecure);
        we re-enable node20 and permit that package when it is listed here.
      '';
    };

    parityPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = defaultParityPackages;
      defaultText = lib.literalExpression "curl wget jq unzip zip rsync … (see module)";
      description = ''
        Packages added to every runner PATH for closer parity with
        GitHub-hosted Ubuntu runners. Per-runner `extraPackages` are appended.
      '';
    };

    runners = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule runnerModule);
      default = { };
      example = {
        default = {
          url = "https://github.com/PrestonHager";
          extraLabels = [ "nixos" "ace" ];
        };
      };
      description = ''
        Attrset of runners. Each key is the default runner name and the
        services.github-runners.<name> instance id.
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
    ++ lib.mapAttrsToList (name: r: {
      assertion = !r.docker.enable || (r.user != null && r.group != null);
      message = ''
        homelab.github-runners.runners.${name}: docker.enable requires
        user and group to be set (DynamicUser cannot join the docker group).
      '';
    }) enabledRunners;

    # nodejs_20 is marked insecure (EOL) but Actions still require externals/node20.
    nixpkgs.config.permittedInsecurePackages = lib.mkIf needsNode20 [
      "nodejs-${pkgs.nodejs_20.version}"
    ];

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

    virtualisation.docker.enable = lib.mkIf needsDocker true;

    users = lib.mkMerge (
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
    );

    services.github-runners = lib.mapAttrs (name: r: {
      enable = true;
      inherit (r) name url ephemeral replace extraLabels extraEnvironment;
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
          # Docker socket for container jobs
          BindPaths = [ "/var/run/docker.sock" ];
        })
        r.serviceOverrides
      ];
    }) enabledRunners;

    # Ensure runners start after secrets are decrypted when using sops.
    systemd.services = lib.mkMerge (
      lib.mapAttrsToList (name: r:
        lib.optionalAttrs (r.tokenFile == null) {
          "github-runner-${name}" = {
            after = [ "sops-nix.service" ];
            wants = [ "sops-nix.service" ];
          };
        }
      ) enabledRunners
    );
  };
}
