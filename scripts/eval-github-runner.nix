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

  enabled = mkSystem [
    {
      homelab.github-runners = {
        enable = true;
        runners.default = {
          url = "https://github.com/PrestonHager";
          tokenFile = "/dev/null";
          ephemeral = true;
          extraLabels = [ "nixos" ];
        };
      };
    }
  ];
in {
  disabled = disabled.config.homelab.github-runners.enable;
  enabled = enabled.config.homelab.github-runners.enable;
  runnerUrl = enabled.config.services.github-runners.default.url;
  ephemeral = enabled.config.services.github-runners.default.ephemeral;
  tokenFile = enabled.config.services.github-runners.default.tokenFile;
  labels = enabled.config.services.github-runners.default.extraLabels;
}
