{ config, lib, pkgs, ... }:

let
  pubKey = lib.fileContents ../ssh/git-signing-ed25519.pub;
  email = "preston@hagerfamily.com";
  signingKeyPath = "${config.home.homeDirectory}/.ssh/git_signing_ed25519";
  allowedSignersPath = "${config.home.homeDirectory}/.ssh/allowed_signers";
in
{
  # Public key + allowed_signers are non-secret (verification / identity).
  # Private key: Vaultwarden SSH item `git-signing-ed25519`, synced to
  # ~/.ssh/git_signing_ed25519 via `sync-git-signing-key` (see docs/git-commit-signing.md).
  home.file.".ssh/git_signing_ed25519.pub".text = "${pubKey}\n";
  home.file.".ssh/allowed_signers".text = "${email} ${pubKey}\n";

  programs.git = {
    enable = true;
    settings = {
      gpg = {
        format = "ssh";
        ssh.allowedSignersFile = allowedSignersPath;
      };
      user.signingkey = signingKeyPath;
      commit.gpgsign = true;
      tag.gpgsign = true;
    };
    signing = {
      signByDefault = true;
      key = signingKeyPath;
      format = "ssh";
    };
  };

  home.packages = [
    (pkgs.writeShellApplication {
      name = "sync-git-signing-key";
      runtimeInputs = [ pkgs.bitwarden-cli pkgs.openssh pkgs.coreutils pkgs.python3 ];
      text = ''
        set -euo pipefail
        ITEM_NAME="''${GIT_SIGNING_BW_ITEM:-git-signing-ed25519}"
        DEST="''${GIT_SIGNING_KEY_PATH:-$HOME/.ssh/git_signing_ed25519}"
        SERVER="''${BW_SERVER:-https://vault.prestonhager.com}"

        current="$(bw config server 2>/dev/null || true)"
        if [[ "$current" != "$SERVER" ]]; then
          bw config server "$SERVER" >/dev/null
        fi

        status="$(bw status | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
        if [[ "$status" == "unauthenticated" ]]; then
          echo "error: not logged in; run: bw login" >&2
          exit 1
        fi
        if [[ "$status" == "locked" && -z "''${BW_SESSION:-}" ]]; then
          BW_SESSION="$(bw unlock --raw)"
          export BW_SESSION
        fi

        bw sync >/dev/null

        export ITEM_NAME
        item_id="$(
          bw list items --search "$ITEM_NAME" | python3 -c '
        import json,sys,os
        name=os.environ["ITEM_NAME"]
        for it in json.load(sys.stdin):
            if it.get("name")==name:
                print(it["id"]); break
        '
        )"
        if [[ -z "$item_id" ]]; then
          echo "error: vault item '$ITEM_NAME' not found" >&2
          exit 1
        fi

        umask 077
        mkdir -p "$(dirname "$DEST")"
        bw get item "$item_id" | python3 -c '
        import json,sys
        item=json.load(sys.stdin)
        sk=item.get("sshKey") or {}
        priv=sk.get("privateKey") or ""
        if not priv:
            raise SystemExit("missing privateKey on SSH key item")
        dest=sys.argv[1]
        with open(dest,"w",encoding="utf-8") as f:
            f.write(priv if priv.endswith("\n") else priv+"\n")
        pub=sk.get("publicKey") or ""
        if pub:
            with open(dest+".pub","w",encoding="utf-8") as f:
                f.write(pub if pub.endswith("\n") else pub+"\n")
        ' "$DEST"
        chmod 600 "$DEST"
        [[ -f "$DEST.pub" ]] && chmod 644 "$DEST.pub"

        fp="$(ssh-keygen -lf "$DEST.pub" 2>/dev/null | awk "{print \$2}" || true)"
        echo "Synced Git signing key to $DEST"
        if [[ -n "$fp" ]]; then
          echo "Fingerprint: $fp"
        fi
      '';
    })
  ];
}
