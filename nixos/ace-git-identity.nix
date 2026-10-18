# root@ace's own GitHub/signing identity for the config repos on this host.
#
# Commits and pushes in /etc/nixos and /home/prestonh/nixos-secrets used to
# rely on SSH agent forwarding from a workstation, and Bitwarden prompts on
# every forwarded request by design. This key lets root on ace fetch flake
# inputs, push and sign without a forwarded agent.
#
# Private key: nix-secrets secrets/hosts/ace/git.yaml (age: root admin + ace).
# GitHub: add the public key below to the account as both an Authentication
# key and a Signing key; revoke it there to cut ace off.
{ config, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  keyPath = config.sops.secrets."ace-root-ssh-key".path;
  email = "preston@hagerfamily.com";
  pubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDEMydexGEchoOPoh8jDiecyTkmgj/Tfxap7U+lQQfPW root@ace (nixos-configs automation)";
  allowedSigners = builtins.toFile "ace-allowed-signers" ''
    ${email} ${pubKey}
    ${email} ${builtins.readFile ../users/prestonh/ssh/git-signing-ed25519.pub}
  '';
  # Signing settings only for the repos root maintains on this host.
  repoGitConfig = builtins.toFile "ace-repo-gitconfig" ''
    [user]
      name = Preston Hager
      email = ${email}
      signingkey = ${keyPath}
    [gpg]
      format = ssh
    [gpg "ssh"]
      allowedSignersFile = ${allowedSigners}
  '';
in
{
  sops.secrets."ace-root-ssh-key" = {
    sopsFile = "${sops-path}/secrets/hosts/ace/git.yaml";
    owner = "root";
    mode = "0400";
  };

  programs.ssh.extraConfig = ''
    Match host github.com localuser root
      IdentityFile ${keyPath}
      IdentitiesOnly yes
  '';

  programs.git.config.includeIf = {
    "gitdir:/etc/nixos/".path = repoGitConfig;
    "gitdir:/home/prestonh/nixos-secrets/".path = repoGitConfig;
  };
}
