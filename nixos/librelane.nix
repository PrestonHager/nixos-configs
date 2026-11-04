# Development host for the RISCV-CPU VHDL project (GHDL simulation and the
# LibreLane ASIC flow). Mirrors nix/dev-host.nix from that repo; see its
# docs/nix.md for the workflow.
{ config, pkgs, ... }:

{
  nix.settings = {
    # FOSSi Foundation cache: prebuilt LibreLane / nix-eda tools (OpenROAD,
    # Yosys + GHDL plugin, Magic, KLayout, Netgen). Set system-wide so the
    # flake's nixConfig does not have to be trusted per user, otherwise
    # `nix develop .#librelane` builds OpenROAD from source.
    extra-substituters = [ "https://nix-cache.fossi-foundation.org" ];
    extra-trusted-public-keys = [
      "nix-cache.fossi-foundation.org:3+K59iFwXqKsL7BNu6Guy0v+uTlwsxYQxjspXzqLYQs="
    ];
  };

  # `cd` into the repo loads the dev shell automatically (.envrc: use flake).
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  environment.systemPackages = with pkgs; [
    gnumake
  ];
}
