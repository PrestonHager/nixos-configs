{ config, pkgs, lib ? pkgs.lib, inputs, ... }:

{
  home.packages = with pkgs; [
    # Nvidia settings
    gnomeExtensions.gpu-profile-selector
    inputs.envycontrol.packages.x86_64-linux.default
  ];

  dconf.settings = with inputs.home-manager.lib.hm.gvariant; {
    # Gnome Extention - GPU Profile Selector
    "org/gnome/shell/extensions/GPU_profile_selector" = {
      rtd3 = true;
      force-composition-pipeline = true;
      coolbits = true;
      force-topbar-view = false;
    };
  };
}

