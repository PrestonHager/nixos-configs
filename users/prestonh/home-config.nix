{ config, pkgs, osConfig, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  uid = osConfig.users.users.${config.home.username}.uid;
in
{
  sops = {
    defaultSopsFile = "${sops-path}/secrets/secrets.yaml";
    defaultSymlinkPath = "/run/user/${builtins.toString uid}/secrets";
    defaultSecretsMountPoint = "/run/user/${builtins.toString uid}/secrets.d";
    age = {
      keyFile = "/home/prestonh/.config/sops/age/keys.txt";
      generateKey = true;
    };
    secrets = {
      "yubikey/u2f_keys" = {
        sopsFile = "${sops-path}/secrets/home-manager/prestonh/secrets.yaml";
      };
      # 2048-bit RSA key for Cisco IOS pubkey-chain (astracap / astraquasar).
      # Add to nix-secrets: sops secrets/home-manager/prestonh/secrets.yaml
      #   ssh/id_rsa_astracap: <PEM private key>
      "ssh/id_rsa_astracap" = {
        sopsFile = "${sops-path}/secrets/home-manager/prestonh/secrets.yaml";
        path = "${config.home.homeDirectory}/.ssh/id_rsa_astracap";
        mode = "0600";
      };
    };
  };

  # Home Manager is pretty good at managing dotfiles. The primary way to manage
  # plain files is through 'home.file'.
  home.file = {
    # Recursively add all files from the config directory
    ".config/" = {
      source = ./config;
      recursive = true;
    };
    ".config/Yubico/u2f_keys" = {
      source = config.lib.file.mkOutOfStoreSymlink config.sops.secrets."yubikey/u2f_keys".path;
    };
  };

  # Home Manager can also manage your environment variables through
  # 'home.sessionVariables'. If you don't want to manage your shell through Home
  # Manager then you have to manually source 'hm-session-vars.sh' located at
  # either
  #
  #  ~/.nix-profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  ~/.local/state/nix/profiles/profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  /etc/profiles/per-user/prestonh/etc/profile.d/hm-session-vars.sh
  #
  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
    SUDO_EDITOR = "nvim";
  };
}
