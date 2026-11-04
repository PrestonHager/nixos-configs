# Server logins with Keycloak

Servers that import `nixos/auth/sso-login.nix` and set `homelab.sso.enable = true` accept logins from the Keycloak `homelab` realm (`docs/keycloak-ace.md`). That is mars and the pterodactyl nodes today. ace (where Keycloak runs) and the laptop are not enrolled.

## How it works

| Piece | What it does |
|---|---|
| **SSSD** (`id_provider = idp`) | Looks users and groups up in Keycloak with the `sssd` client's service account. Every Keycloak user is a Linux user on every enrolled host. UIDs and GIDs are generated from 200000 up, and come out the same on every host. Home `/home/<user>` is created on first SSH login, shell bash. |
| **Host access** (`access_provider = simple`) | The PAM account step lets in members of `srv-all` or `srv-<hostname>` (`homelab.sso.allowGroups`). It is strict (`sssdStrictAccess`), so a denial is final. |
| **opkssh** | `opkssh login` on your machine signs you in to Keycloak in a browser and writes an SSH key and certificate that carry the ID token. sshd hands keys to `opkssh verify` (AuthorizedKeysCommand), which checks the token against Keycloak's keys. |
| **opkssh policy plugin** | `/etc/opk/policy.d/keycloak.yml` allows a key only for an account that (1) is not in `/etc/passwd`, (2) resolves through SSSD, (3) equals the token's `preferred_username`, and (4) whose token lists `srv-all` or `srv-<host>`. Root and local accounts never accept opkssh keys. |
| **sudo** | Rules name Keycloak groups. For SSSD users, sudo runs pam_sss first, which shows a Keycloak device-code prompt (URL + code) instead of a password. Local users fall through to pam_unix and their password. |
| **Folder access** | `homelab.sso.folderAccess` applies POSIX ACLs for Keycloak groups once SSSD is up (`sso-folder-acls.service`). |

Removing someone from a group in Keycloak takes effect within `homelab.sso.cacheTimeout` (300 s), because SSSD checks group membership on every login and every sudo. An `opkssh login` key stops working after `homelab.sso.keyLifetime` (12 h).

## Logging in

One-time client setup (any machine with opkssh; `nix shell nixpkgs#opkssh`), in `~/.opk/config.yml`:

```yaml
default_provider: keycloak
providers:
  - alias: keycloak
    issuer: https://keycloak.prestonhager.com/realms/homelab
    client_id: opkssh
    scopes: openid profile email
    access_type: offline
    prompt: consent
    redirect_uris:
      - http://localhost:3000/login-callback
      - http://localhost:10001/login-callback
      - http://localhost:11110/login-callback
```

Then each day:

```bash
opkssh login            # browser: Keycloak password + TOTP
ssh prestonh@192.168.5.15
sudo -i                 # prints a URL and code; approve it in the browser, press Enter
```

Keycloak is LAN, tailnet and VPN only, so be on one of those for `opkssh login` and for sudo.

## Break-glass account

On enrolled hosts the old local `prestonh` (uid 1000) is now **`phadmin`**:

- It keeps the old home: the first switch moves `/home/prestonh` to `/home/phadmin`. On crux that is about 1.6 GB.
- It keeps the old password (`users/prestonh/passwd` in `secrets/users.yaml`) for sudo, plus the bootstrap SSH key. It is in `wheel`.
- It never touches Keycloak. If ace or Keycloak is down: `ssh phadmin@<host>`, or `root@` with the deploy and bootstrap keys as before.

The Keycloak `prestonh` is a different uid with a fresh `/home/prestonh`. Copy anything you still want from `/home/phadmin`.

Home-manager no longer runs for prestonh on these hosts: home-manager needs a declared local user.

## Configuration

```nix
homelab.sso = {
  enable = true;
  breakGlass.keys = [ bootstrapPubkey ];

  # Optional:
  allowGroups = [ "srv-all" "srv-mars" ];   # default: srv-all + srv-<hostName>
  rebuildFlake = "/etc/nixos#ace";          # enables the sudo-rebuild rule
  sudoRules.wings = {
    groups = [ "wings-ops" ];
    commands = [
      "/run/current-system/sw/bin/systemctl restart wings.service"
      "/run/current-system/sw/bin/journalctl -u wings.service"
    ];
  };
  folderAccess = [
    { path = "/var/lib/pterodactyl/backups"; group = "game-backups"; access = "read"; }
  ];
};
```

### Sudo rules: what is safe

sudo matches commands by full path and, if given, exact arguments.

- **Rebuild is root.** The `sudo-rebuild` rule pins `nixos-rebuild <switch|boot|test|build> --flake <rebuildFlake>` with no other arguments. It is only limited while the group cannot write the flake checkout, and nothing else lets them point it at another flake.
- **Never grant** editors, pagers, shells, interpreters or file tools (`vim`, `less`, `find`, `tar`, `cp`, `rsync`, `tee`, `systemctl edit`, `journalctl` without `-u`, ...). Each of these can start a root shell. Grant `systemctl restart <unit>`-style commands with fixed arguments.
- **Reading or writing other people's folders is not a sudo job.** Use `folderAccess`: an ACL gives the group access to that tree without root. It is completely separate from rebuild rights, so you can grant either one without the other.

### Folder ACLs

Each `folderAccess` entry gives the group `--x` (traverse) on every parent directory, `rX` or `rwX` on the tree, and a matching default ACL so new files inherit it. Services that `chmod` their own files can narrow the ACL mask. For example, `pterodactyl-config-perms` sets `0750` and `0640` every 5 minutes, which caps an ACL at read-only there. Pick paths whose owners do not do that, or adjust the service.

### SELinux

Not on NixOS. nixpkgs has no SELinux policy or labelling support (`/nix/store` paths cannot be relabelled per host), so enabling it in the kernel gets you nothing to enforce. Group-based POSIX ACLs and narrow sudo rules cover the "this folder, not that command" split. If you later want to confine services rather than users, AppArmor (`security.apparmor`) is the MAC that NixOS supports.

## Adding a host

1. Import `../../nixos/auth/sso-login.nix`, set `homelab.sso.enable = true`, and drop the host's `users/prestonh` import, or set `breakGlass.migrateHomeFrom = null` if it never had one.
2. Add the host's age key to the `secrets/sssd-keycloak.yaml` rule in nixos-secrets `.sops.yaml` and run `sops updatekeys secrets/sssd-keycloak.yaml`.
3. Create the `srv-<host>` group in Keycloak if it is not one of the imported ones.

## Troubleshooting

```bash
getent passwd prestonh                 # SSSD lookup (uid 2xxxxx)
id prestonh                            # groups: srv-all, sudo-full, ...
sssctl user-checks prestonh -s sshd    # access decision
journalctl -u sssd -b
tail /var/log/opkssh.log               # opkssh verify and policy plugin results
sss_cache -E                           # drop SSSD's cache after a group change
```

| Symptom | Likely cause |
|---|---|
| `Permission denied (publickey)` | No current `opkssh login` key, the plugin denied it (see `opkssh.log`), or the user is not in an allowed `srv-*` group |
| `getent passwd` empty | SSSD cannot reach Keycloak or the `sssd` client secret is wrong (`journalctl -u sssd`) |
| sudo asks for a password, not a device code | The user resolved as a local user. Check `grep ^<user>: /etc/passwd` |
| Old prestonh files owned by `phadmin` | Expected: they moved with the account. `sudo cp -a` what you need into the new home and `chown` it |
