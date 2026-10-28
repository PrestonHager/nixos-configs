{ config, lib, inputs, ... }:

{
  networking.hostName = "ph-nixos-wsl";

  imports = [
    inputs.nixos-wsl.nixosModules.default
    ../../nixos
    # WSL "hardware" configuration on the MSI Summit E16 Flip
    ../../hardware/msi-summit-e16flip-wsl/hardware-configuration.nix
    # yubico keys
    ../../nixos/yubikey.nix
    # SSH keys come from the Windows agent (Bitwarden)
    ../../nixos/wsl-ssh-agent.nix
    # RISCV-CPU / LibreLane development
    ../../nixos/librelane.nix
    # include any users
    ../../users/prestonh
  ];

  # The WSL install created prestonh before the uid was pinned to 1000
  users.users.prestonh.uid = lib.mkForce 1001;

  # WSL manages networking; wpa_supplicant fails inside it
  networking.networkmanager.enable = lib.mkForce false;

  # The home-manager ssh-agent would replace the Windows agent socket
  home-manager.users.prestonh.services.ssh-agent.enable = lib.mkForce false;

  wsl.enable = true;
  wsl.defaultUser = "prestonh";

  # WSL boots through the Windows host, not an EFI bootloader
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
}
