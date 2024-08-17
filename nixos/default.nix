# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, inputs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./network.nix
      ./users.nix
      inputs.home-manager.nixosModules.default
    ];

  users.main = {
    enable = true;
    username = "prestonh";
    name = "Preston Hager";
#    home-manager = import ../home/home.nix;
  };

  home-manager = {
    extraSpecialArgs = { inherit inputs; };
    users = {
      "prestonh" = import ../home/home.nix;
    };
  };

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 15;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "nixos"; # Define your hostname.

  # Enable experimental features
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Enable garbage collector
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # Set your time zone.
  time.timeZone = "America/Denver";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

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

  # Configure zsh for the global user
  users.defaultUserShell=pkgs.zsh;

  # Enable fonts local and from the nerd fonts package
  fonts = {
    fontDir.enable = true;
    packages = with pkgs; [
      (nerdfonts.override {
        fonts = [ "Hack" ];
      })
    ];
  };

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    neovim      # Editor
    kitty       # Terminal
    dmenu       # Menu for i3 using $mod+d
    lm_sensors  # Sensor library for many platforms
                # Used in i3-status files
    pasystray   # Pulse Audio System Tray
  ];

  # Configure default terminal emulator and editor
  environment.variables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
    SUDO_EDITOR = "nvim";
    TERMINAL = "kitty";
  };

  programs = {
    git = {
      enable = true;
      package = pkgs.git;
      config = {
        credential.helper = "${
            pkgs.git.override { withLibsecret = true; }
          }/bin/git-credential-libsecret";
      };
    };
    # Enable zsh
    zsh = {
      enable = true;
      autosuggestions.enable = true;
      zsh-autoenv.enable = true;
      syntaxHighlighting.enable = true;
    };
#    nix-ld = {
#      enable = true;
#      libraries = with pkgs; [
#        # Insert libraries to add to the system
#      ];
#    };
 };

 # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable flatpak so we can install third-party apps
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    config.common.default = [ "*" ];
  };
#  services.flatpak.enable = true;

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;
  # Optional: use these settings for Public Key authentication only which is
  # more secure than password authentication.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      KbdInteractiveAuthentication = false;
      # Only enable this if needed
      # PermitRootLogin = true;
    };
  };

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.05"; # Did you read the comment?

}
