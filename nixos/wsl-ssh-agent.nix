# Forward the Windows SSH agent (the openssh-ssh-agent pipe, served by
# Bitwarden Desktop) into WSL, so keys never have to live on the Linux side.
{ config, pkgs, lib, ... }:

{
  environment.systemPackages = [ pkgs.wsl2-ssh-agent ];

  # Starts the bridge daemon on first login (later shells reuse it) and points
  # SSH_AUTH_SOCK at ~/.ssh/wsl2-ssh-agent.sock. Skipped for SSH logins, which
  # bring their own agent.
  environment.extraInit = ''
    if [ -z "$SSH_CONNECTION" ] && [ -n "$HOME" ]; then
      mkdir -p "$HOME/.ssh"
      eval "$(${pkgs.wsl2-ssh-agent}/bin/wsl2-ssh-agent -format bash)"
    fi
  '';

  # Other agents would overwrite SSH_AUTH_SOCK
  programs.ssh.startAgent = false;
  services.yubikey-agent.enable = lib.mkForce false;

  programs.ssh.knownHosts."github.com".publicKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
}
