# Eval helper — not imported by hosts. Smoke-tests github-runner module.
# Usage: nix eval --impure --file scripts/eval-github-runner.nix
let
  flake = builtins.getFlake (toString ./..);
  pkgs = flake.inputs.nixpkgs.legacyPackages.x86_64-linux;
  lib = flake.inputs.nixpkgs.lib;
  root = toString ./..;

  mkSystem = extraModules: lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = { inherit (flake) inputs; };
    modules = [
      ({ modulesPath, ... }: {
        imports = [ (modulesPath + "/profiles/minimal.nix") ];
        boot.loader.grub.device = "nodev";
        fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
        system.stateVersion = "24.11";
        networking.hostName = "github-runner-eval";
      })
      flake.inputs.sops-nix.nixosModules.sops
      (root + "/nixos/services/github-runner.nix")
    ] ++ extraModules;
  };

  disabled = mkSystem [
    { homelab.github-runners.enable = false; }
  ];

  enabledNative = mkSystem [
    {
      homelab.github-runners = {
        enable = true;
        backend = "native";
        runners.default = {
          url = "https://github.com/PrestonHager";
          tokenFile = "/dev/null";
          ephemeral = true;
          instances = 2;
          extraLabels = [ "nixos" ];
        };
      };
    }
  ];

  enabledContainer = mkSystem [
    {
      # Minimal podman stub so oci-containers evaluates
      virtualisation.oci-containers.backend = "podman";
      virtualisation.podman.enable = true;
      homelab.github-runners = {
        enable = true;
        backend = "container";
        runners.default = {
          url = "https://github.com/PrestonHager/example";
          tokenFile = "/dev/null";
          ephemeral = true;
          instances = 2;
          extraLabels = [ "nixos" "ubuntu-noble" ];
        };
      };
    }
  ];
in {
  disabled = disabled.config.homelab.github-runners.enable;
  backendDefault = disabled.config.homelab.github-runners.backend;
  native = {
    enabled = enabledNative.config.homelab.github-runners.enable;
    backend = enabledNative.config.homelab.github-runners.backend;
    instances = enabledNative.config.homelab.github-runners.runners.default.instances;
    hasRunner1 = enabledNative.config.services.github-runners ? "default-1";
    hasRunner2 = enabledNative.config.services.github-runners ? "default-2";
    nodeRuntimes = enabledNative.config.services.github-runners."default-1".nodeRuntimes;
    hasCurl = lib.any (p: p.pname or p.name or "" == "curl")
      enabledNative.config.services.github-runners."default-1".extraPackages;
  };
  container = {
    enabled = enabledContainer.config.homelab.github-runners.enable;
    backend = enabledContainer.config.homelab.github-runners.backend;
    hasC1 = enabledContainer.config.virtualisation.oci-containers.containers ? "github-runner-default-1";
    hasC2 = enabledContainer.config.virtualisation.oci-containers.containers ? "github-runner-default-2";
    image = enabledContainer.config.virtualisation.oci-containers.containers."github-runner-default-1".image;
    labels = enabledContainer.config.virtualisation.oci-containers.containers."github-runner-default-1".environment.LABELS;
  };
}
