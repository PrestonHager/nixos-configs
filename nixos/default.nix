# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, lib ? pkgs.lib, inputs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./users.nix
      ./nginx # nginx module, further customization available in nginx folder
      # Containers submodule
      ./containers
      # Disable the yubikey module if it's not needed
      ./yubikey.nix
      inputs.home-manager.nixosModules.default
      # OpenLDAP
      ./ldap.nix
    ];

  # short-users allows us to create users quickly
  short-users = [
    {
      username = "prestonh";
      name = "Preston Hager";
      home-manager.enable = true;
    }
  ];

  # Configure specific unfree packages that are used across the system
  # Note that in order to use an unfree package in home manager it must also be
  # listed here.
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
    "copilot.vim"
    "obsidian"
  ];

  # Configure zsh for the users by default
  users.defaultUserShell = pkgs.zsh;

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 15;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "ph-nixos"; # Define your hostname.

  # Enable network manager
  networking.networkmanager.enable = true;

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

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    vim      # Editor
    tmux        # Terminal multiplexer
    tio         # Serial terminal
  ];

  # Configure default editor, these can be overridden by users too
  environment.variables = {
    EDITOR = "vim";
    VISUAL = "vim";
    SUDO_EDITOR = "vim";
  };

  programs = {
    git = {
      enable = true;
      package = pkgs.git;
      config = {
        credential.helper = "${
            pkgs.git.override { withLibsecret = true; }
          }/bin/git-credential-libsecret";
        commit.gpgsign = true;
        core.editor = "${pkgs.vim}/bin/vim";
      };
    };
    # Enable zsh
    zsh = {
      enable = true;
      autosuggestions.enable = true;
      zsh-autoenv.enable = true;
      syntaxHighlighting.enable = true;
      interactiveShellInit = ''
        fpath+=("${pkgs.pure-prompt}/share/zsh/site-functions")
      '';
      promptInit = ''
        if [ "$TERM" != dumb ]; then
          autoload -U promptinit && promptinit && prompt pure
        fi
      '';
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

  # Enable Pipewire audio server
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # Enable support for JACK audio applications or not
#    jack.enable = true;
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
