{ config, pkgs, ... }:

{
  # Install required packages
  environment.systemPackages = with pkgs; [
    # Yubikey Tools
    yubikey-personalization
    yubikey-personalization-gui
    yubikey-manager
    yubikey-manager-qt
  ];

  # Add Yubikey udev rules
  services.udev.packages = with pkgs; [
    yubikey-personalization
    yubikey-personalization-gui
    yubikey-manager
    yubikey-manager-qt
  ];


  # Yubikey SSH Agent
  services.yubikey-agent.enable = true;
  # And be sure to disable the normal SSH agent for this
  programs.ssh.startAgent = false;

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
  # Enable PC/SC daemon for smart card support
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
}

