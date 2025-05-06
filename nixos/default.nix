# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, lib ? pkgs.lib, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
in
{
  sops = {
    defaultSopsFile = "${sops-path}/secrets/secrets.yaml";
    age = {
      sshKeyPaths = [
        "/etc/ssh/ssh_host_ed25519_key"
      ];
      keyFile = "/var/lib/sops/age/keys.txt";
    };
  };

  # Configure specific unfree packages that are used across the system
  # Note that in order to use an unfree package in home manager it must also be
  # listed here.
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
    "copilot.vim"
    "obsidian"
    # Nvidia drivers, also accept the license with config.nvidia.acceptLicense
    "nvidia-x11"
    "nvidia-settings"
    # Steam packages for the Steampowered Client
    "steam"
    "steam-original"
    "steam-run"
    "steam-unwrapped"
    # Allow spotify to be installed
    "spotify"
    # Allow virtual box extension
    "Oracle_VirtualBox_Extension_Pack"
  ];
  # Accept the nvidia license if applicable
  nixpkgs.config.nvidia.acceptLicense = true;

  # Configure kernel parameters
  boot.kernelParams = [
    "vm.overcommit_memory=1"
    "vm.overcommit_ratio=150"
  ];

  # Configure zsh for the users by default
  users.defaultUserShell = pkgs.zsh;

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 15;
  boot.loader.efi.canTouchEfiVariables = true;

  # Enable network manager
  networking.networkmanager.enable = true;

  # Enable the OOM killer
  systemd.oomd.enable = true;

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
    vim         # Editor
    tmux        # Terminal multiplexer
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
 };

  # Enable realtime kit so that audio server works
  security.rtkit.enable = true;
  # Enable Pipewire audio server
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.11"; # Did you read the comment?
}

