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

Re-sync private key from Bitwarden. The Windows helper `scripts/sync-git-signing-key.ps1` was removed in commit `572c200`; recover it into a checkout, run it, then delete it:

```powershell
bw unlock   # or set BW_SESSION
git restore --source=572c200^ -- scripts/sync-git-signing-key.ps1
.\scripts\sync-git-signing-key.ps1
Remove-Item scripts\sync-git-signing-key.ps1
```

Verify:

```powershell
git config --global --get-regexp "gpg|signing|gpgsign"
git commit --allow-empty -S -m "signing probe"
git verify-commit HEAD
git reset HEAD~1
```

## NixOS (ace / crux / elara / nova / ph-nixos)

home-manager module: `users/prestonh/programs/git-signing.nix` (imported from `home-programs.nix`).

After rebuild:

```bash
sudo nixos-rebuild switch --flake /etc/nixos#ace   # or #crux, #elara, #nova, #ph-nixos
source ~/.config/bitwarden/bw-ssh.sh               # unlock + SSH agent
sync-git-signing-key                               # writes ~/.ssh/git_signing_ed25519
git commit -S ...
```

Verification of others’ commits uses `~/.ssh/allowed_signers` (installed by home-manager from the in-repo public key).

`sync-git-signing-key` is a command installed by the home-manager module (`writeShellApplication` in `git-signing.nix`); it replaced the old `scripts/sync-git-signing-key.sh`, which was removed in commit `572c200`.

## Root on ace (automation identity)

Root on ace signs and pushes with **its own key**, so no SSH agent forwarding is needed for commits, pushes or flake input fetches in the config repos on ace.

| Field | Value |
|-------|-------|
| Key comment | `root@ace (nixos-configs automation)` (ed25519) |
| Module | `nixos/ace-git-identity.nix` (imported by `hosts/ace/default.nix`) |
| Private key | nix-secrets `secrets/hosts/ace/git.yaml` → sops secret `ace-root-ssh-key` (root, `0400`; age recipients: root admin + ace) |
| Repos | `/etc/nixos` and `/home/prestonh/nixos-secrets` (git `includeIf gitdir:`) |
| Commit identity | Preston Hager `<preston@hagerfamily.com>`, `gpg.format = ssh`, `user.signingkey` = the sops key |
| GitHub | Public key added to the account as both an **Authentication** key and a **Signing** key; revoke it there to cut ace off |

The module also adds an SSH `Match host github.com localuser root` block with `IdentityFile` pointing at the sops key, and an `allowedSignersFile` that trusts both this key and the personal signing key above, so `git verify-commit` works on ace for either.

Why: commits and pushes from ace used to rely on agent forwarding from a workstation, and Bitwarden's SSH agent **always prompts** for forwarded requests, by design. With root's own key, `git -C /etc/nixos commit -S` and `git push` work unattended. Do not use `ssh -A` to ace for this.

## Rotate

1. Generate a new ed25519 key: `ssh-keygen -t ed25519 -f git_signing_ed25519 -C "preston@hagerfamily.com git-signing"`.
2. Update Vaultwarden item **`git-signing-ed25519`** (replace public/private/fingerprint).
3. Replace `users/prestonh/ssh/git-signing-ed25519.pub` in this repo; commit/push.
4. Re-run `sync-git-signing-key` (NixOS) or the recovered `.ps1` (Windows) on each machine that signs.
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
- Module: `users/prestonh/programs/git-signing.nix` (provides `sync-git-signing-key`)
- Module: `nixos/ace-git-identity.nix` (root on ace)
- Removed in `572c200`: `scripts/sync-git-signing-key.sh`, `scripts/sync-git-signing-key.ps1` (recover with `git show 572c200^:scripts/<name>`)
