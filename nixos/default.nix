# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, inputs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./users.nix
      inputs.home-manager.nixosModules.default
    ];

  # short-users allows us to create users quickly
  short-users = [
    {
      username = "prestonh";
      name = "Preston Hager";
      home-manager.enable = true;
    }
  ];

  # Enable login via hardware keys
  security.pam = {
    services = {
      login.u2fAuth = true;
      sudo.u2fAuth = true;
    };
    u2f.enable = true;
    # Enable a prompt for a hardware key
    u2f.cue = true;
  };
  # Enable pcsclite for smart card support
  services.pcscd = {
    enable = true;
  };

  # Only allow user to login with a key by locking the desktop whenever a key is
  # unplugged. Note that you can still get into the system via normal
  # credentials. Only if a key is already connected and then disconnected with
  # the desktop lock the current session.
  services.udev.extraRules = ''
    ACTION=="remove",\
      SUBSYSTEM=="usb",\
      ENV{PRODUCT}=="1050/407/543",\
      RUN+="${pkgs.systemd}/bin/loginctl lock-sessions"
  '';

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
    neovim      # Editor
    tmux        # Terminal multiplexer
    tio         # Serial terminal
  ];

  # Configure default editor, these can be overridden by users too
  environment.variables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
    SUDO_EDITOR = "nvim";
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
        core.editor = "${pkgs.neovim}/bin/nvim";
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
