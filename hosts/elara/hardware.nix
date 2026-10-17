{ config, lib, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "ehci_pci" "ahci" "usbhid" "usb_storage" "sd_mod" ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # Filesystems from the live bootstrap disk. disko.nix is kept for
  # nixos-anywhere only; do not format on nixos-rebuild switch.
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/74b1b449-cdc3-4c88-ba9a-5ac6dd635c5e";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/0AA0-7725";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
