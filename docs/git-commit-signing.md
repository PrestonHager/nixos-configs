# Git commit signing (SSH)

SSH signing key for **Preston Hager** (`preston@hagerfamily.com`), using Git `gpg.format = ssh` (not OpenPGP).

## Identity

| Field | Value |
|-------|-------|
| Name | Preston Hager |
| Email | `preston@hagerfamily.com` |
| Algorithm | ed25519 |
| Fingerprint | `SHA256:555Xyg5MNgr0Y0eIvIde9qgUchwNPtUnBfk+9uQ7S0w` |
| Vaultwarden item | **`git-signing-ed25519`** (SSH key) |
| Public key in repo | `users/prestonh/ssh/git-signing-ed25519.pub` |
| Private key on disk | `~/.ssh/git_signing_ed25519` (synced from Bitwarden; never committed) |

## Design

- **Private key** lives in Vaultwarden (same pattern as Cisco SSH keys in [network-ssh-ace.md](./network-ssh.md)).
- **Public key** is in nixos-configs for `allowed_signers` and home-manager git config.
- Hosts do **not** get the private key via sops by default. Sync from Bitwarden after unlock (below). Optional sops deploy is documented under [Optional: sops](#optional-sops-private-key-on-hosts).

## Windows (this PC)

Already configured globally:

```text
gpg.format=ssh
user.signingkey=%USERPROFILE%\.ssh\git_signing_ed25519
commit.gpgsign=true
gpg.ssh.allowedSignersFile=%USERPROFILE%\.ssh\allowed_signers
```

Re-sync private key from Bitwarden:

```powershell
bw unlock   # or set BW_SESSION
.\scripts\sync-git-signing-key.ps1
```

Verify:

```powershell
git config --global --get-regexp "gpg|signing|gpgsign"
git commit --allow-empty -S -m "signing probe"
git verify-commit HEAD
git reset HEAD~1
```

## NixOS (ace / crux / nova / ph-nixos)

home-manager module: `users/prestonh/programs/git-signing.nix` (imported from `home-programs.nix`).

After rebuild:

```bash
sudo nixos-rebuild switch --flake /etc/nixos#ace   # or #crux, #nova, #ph-nixos
source ~/.config/bitwarden/bw-ssh.sh               # unlock + SSH agent
sync-git-signing-key                               # writes ~/.ssh/git_signing_ed25519
git commit -S ...
```

Verification of others’ commits uses `~/.ssh/allowed_signers` (installed by home-manager from the in-repo public key).

## Rotate

1. Generate a new ed25519 key: `ssh-keygen -t ed25519 -f git_signing_ed25519 -C "preston@hagerfamily.com git-signing"`.
2. Update Vaultwarden item **`git-signing-ed25519`** (replace public/private/fingerprint).
3. Replace `users/prestonh/ssh/git-signing-ed25519.pub` in this repo; commit/push.
4. Re-run `sync-git-signing-key` / `.ps1` on each machine that signs.
5. Rebuild NixOS so `allowed_signers` picks up the new public key.
6. Optionally add the new pubkey to GitHub → Settings → SSH and GPG keys → **Signing keys**.

## Optional: sops private key on hosts

Prefer Bitwarden sync. If a host must sign without Bitwarden CLI:

1. Add secret `git-signing-ed25519` under `secrets/home-manager/prestonh/secrets.yaml` in [nixos-secrets](https://github.com/PrestonHager/nixos-secrets) (age-encrypted private key PEM/OpenSSH format).
2. In `users/prestonh/home-config.nix`, declare `sops.secrets."git-signing-ed25519"` and symlink to `~/.ssh/git_signing_ed25519` (mode `0600`).
3. Keep the public key and `allowed_signers` in nixos-configs as today.

Do not put the private key in nixos-configs.

## Related

- [Network & SSH / Bitwarden](./network-ssh.md) — `bw` server, unlock, SSH agent
- Module: `users/prestonh/programs/git-signing.nix`
- Scripts: `scripts/sync-git-signing-key.sh`, `scripts/sync-git-signing-key.ps1`
