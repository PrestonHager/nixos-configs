{ config, pkgs, lib, ... }:

let
  vaultServer = "https://vault.prestonhager.com";
in
{
  home.packages = [
    pkgs.bitwarden-cli
  ];

  services.ssh-agent.enable = true;

  # Idempotent: point bw at self-hosted Vaultwarden (no login required).
  home.activation.bitwardenServer = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ -x "${pkgs.bitwarden-cli}/bin/bw" ]; then
      current="$(${pkgs.bitwarden-cli}/bin/bw config server 2>/dev/null || true)"
      if [ "$current" != "${vaultServer}" ]; then
        $DRY_RUN_CMD ${pkgs.bitwarden-cli}/bin/bw config server ${vaultServer}
      fi
    fi
  '';

  home.file.".config/bitwarden/bw-ssh.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Unlock Vaultwarden and start the Bitwarden SSH agent for this shell.
      # Usage: source ~/.config/bitwarden/bw-ssh.sh
      set -euo pipefail
      export BW_SESSION="$(${pkgs.bitwarden-cli}/bin/bw unlock --raw)"
      eval "$(${pkgs.bitwarden-cli}/bin/bw ssh-agent)"
    '';
  };
}
