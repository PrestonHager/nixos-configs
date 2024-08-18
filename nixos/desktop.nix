{ config, pkgs, inputs, ... }:

{
  # Configure keymap in X11
  services = {
    xserver = {
      enable = true;
      autorun = true;
      xkb.layout = "us";
      desktopManager = {
        xterm.enable = false;
        xfce.enable = false;
      };
      windowManager.i3 = {
        enable = true;
        extraPackages = with pkgs; [
          i3status-rust
          pasystray
        ];
      };
    };
    displayManager = {
      defaultSession = "none+i3";
    };
    pipewire = {
      enable = true;
      alsa = {
        enable = true;
        support32Bit = true;
      };
      pulse.enable = true;
    };
  };

  # This is needed for the audio to work in some apps
  nixpkgs.config.pulseaudio = true;

  # Enable fonts local and from the nerd fonts package
  fonts = {
    fontDir.enable = true;
    packages = with pkgs; [
      (nerdfonts.override {
        fonts = [ "Hack" ];
      })
    ];
  };

  environment.systemPackages = with pkgs; [
    kitty       # Terminal
    dmenu       # Menu for i3 using $mod+d
    lm_sensors  # Sensor library for many platforms
                # Used in i3-status files
    pasystray   # Pulse Audio System Tray
  ];

  # Enable flatpak so we can install third-party apps
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    config.common.default = [ "*" ];
  };
}

