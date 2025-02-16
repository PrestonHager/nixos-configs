{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # Create a swap file
  swapDevices = [
    {
      device = "/dev/disk/by-uuid/66ba4a80-a99f-4f56-b4b3-6fb5bde695d4";
      encrypted = {
        enable = true;
        keyFile = "/mnt-root/root/swap.key";
        label = "luks-swap";
        blkDev = "/dev/disk/by-uuid/66ba4a80-a99f-4f56-b4b3-6fb5bde695d4";
      };
    }
  ];

  hardware.graphics.enable =  true;
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    modesetting.enable = true;
    powerManagement.enable = true;
    # Fine-grained power management. Turns off GPU when not in use.
    # Experimental and only works on modern Nvidia GPUs (Turing or newer).
    powerManagement.finegrained = true;
    open = true;
    nvidiaSettings = true;
    # Enable nvidia graphics cards PRIME
    # Be sure to replace with your actual bus ids if applicable
    prime = {
      intelBusId = "PCI:0:2:0";
      nvidiaBusId = "PCI:91:0:0";
      #amdgpuBusId = "PCI:0:0:0";
      offload = {
        enable = true;
        enableOffloadCmd = true;
      };
      #sync.enable = true;
    };

    # Update package based on what type of video card you have
    # Legacy cards are not supported by unified video driver most other cards
    # should work with the stable package.
    # https://www.nvidia.com/en-us/drivers/unix/legacy-gpu/
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  boot.initrd.availableKernelModules = [ "xhci_pci" "thunderbolt" "nvme" "rtsx_pci_sdmmc" ];
  # Add nvidia kernel modules to the initrd
  boot.initrd.kernelModules = [ "nvidia" "i915" "nvidia_modeset" "nvidia_drm" ];
  # and enable them with kernel parameters
  boot.kernelParams = [ "nvidia-drm.fbdev=1" ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" =
    { device = "/dev/disk/by-uuid/2c1fbbd4-c9f4-4d82-950a-9586bf5ad650";
      fsType = "ext4";
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/ECDB-7BA7";
      fsType = "vfat";
      options = [ "fmask=0077" "dmask=0077" ];
    };

  # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
  # (the default) this is the recommended approach. When using systemd-networkd it's
  # still possible to use this option, but it's recommended to use it in conjunction
  # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
  networking.useDHCP = lib.mkDefault true;
  # networking.interfaces.wlp89s0.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
