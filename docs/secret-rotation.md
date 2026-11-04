# Rotating secrets

Secrets on ace live in one of three places. Where a secret lives decides how it is rotated.

| Where | Examples | Rotated by |
|---|---|---|
| **Generated on ace**, never leaves the host | Valkey passwords, Technitium admin/PFX passwords, update-link HMAC key, wg-portal session/CSRF secrets | `ace-secret-rotate`, automatically, monthly ([below](#automatic-rotation-ace-secret-rotate)) |
| **sops** in [nix-secrets](https://github.com/PrestonHager/nixos-secrets) (`/home/prestonh/nixos-secrets` on ace) | Database passwords, OIDC client secrets, app keys, restic password | By hand: [sops workflow](#rotating-a-sops-secret) plus the [per-secret notes](#per-secret-notes) |
| **Outside services** | Cloudflare token, iCloud SMTP app password, AbuseIPDB key, GitHub keys, Tailscale auth key | By hand in that service, then the sops workflow ([external credentials](#external-credentials)) |

Ground rules:

- **Never put a secret on a command line.** ace has no `hidepid`, and auditd logs every `EXECVE`, so anything in argv ends up in the journal. Pass values through files (`curl --data-urlencode name@file`, `-H @file`, `podman exec --env-file`) or shell builtins (`printf`).
- **Never print a decrypted secret** to a terminal or a chat/agent session. When checking a file, print variable names only: `sed 's/=.*//' /run/secrets/NAME`.
- Generate values with `od -An -tx1 -N32 /dev/urandom | tr -d ' \n'` (64 hex characters, 256 bits). Hex needs no quoting or URL encoding.
- Avoid the 04:30 window: the nightly nixpkgs update holds the rebuild lock (`/run/ace-service-update-rebuild.lock`).

## Automatic rotation (`ace-secret-rotate`)

Module: `nixos/security/secret-rotation.nix`. Script: `nixos/security/scripts/ace-secret-rotate.sh`.

**Schedule:** the timer `ace-secret-rotate.timer` runs `ace-secret-rotate all` on the first Sunday of each month at 03:10 (up to 10 minutes later at random). It holds the rebuild lock, so it never overlaps a rebuild or a service auto-update. Every run mails a report (subject `Ace secret rotation ok: …` or `… FAILED: …`) through the same SMTP path as the update mails.

| Name | Secret | What the rotator does | Impact |
|---|---|---|---|
| `valkey-pterodactyl` | `/var/lib/redis-auth/pterodactyl/password` | New password, re-runs `pterodactyl-redis-auth` (rewrites `valkey.conf`, `app.env` and the panel `.env`), restarts Valkey and the panel | Panel restarts (≈30 s) |
| `valkey-nextcloud` | `/var/lib/redis-auth/nextcloud/password` | Same for `nextcloud-redis`, `nextcloud` and `nextcloud-notify-push` | Nextcloud restarts (≈1 min) |
| `valkey-mediawiki` | `/var/lib/redis-auth/mediawiki/password` | Same for `mediawiki-redis` and `mediawiki` | Wiki returns 502 while php-redis reinstalls (≈1–2 min) |
| `technitium-admin` | `/stor/technitium/secrets/admin-password` | Logs in with the old password, calls `/api/user/changePassword`, writes the new one, checks the login, re-runs `technitium-sync-zones` | None |
| `technitium-pfx` | `/stor/technitium/secrets/pfx-password` | Regenerates it, re-exports the PKCS#12 certificate, re-applies the DoT settings, checks DoT on `192.168.5.5:853` | DoT reloads its certificate |
| `update-signing-key` | `/var/lib/ace-service-update/signing-key` | Regenerates the HMAC key for the upgrade approve/deny links. **Skipped** while an approval mail is pending, because its links would stop working | None |
| `wg-portal-web` | `/var/lib/wg-portal-secrets/{session,csrf}` | Regenerates both and restarts wg-portal (`nixos/containers/wg-portal.nix` injects them into the rendered config) | Everyone signed in to wg.prestonhager.com is signed out. The VPN tunnels are not affected |

**Safety:** each rotator keeps the previous value as `<file>.prev` until its check passes. Checks include an AUTH and PING from inside the app container, the container running, and the site answering. If a check fails, the rotator puts the old value back, re-applies it, and marks the secret failed. The exception is `technitium-admin`: once Technitium has accepted the new password there is nothing to roll back to. If the follow-up login fails, the old value stays in `admin-password.prev` for manual recovery.

**Run it by hand:**

```bash
ace-secret-rotate --dry-run all              # show what would happen, change nothing
ace-secret-rotate valkey-mediawiki           # rotate one secret now (mails a report)
ace-secret-rotate --no-mail technitium-pfx   # no report mail
systemctl start ace-secret-rotate.service    # the same as the monthly run
journalctl -u ace-secret-rotate -n 100       # last run
```

**Monitoring:** `/var/lib/node-exporter-textfile/ace_secret_rotation.prom` exports the following metrics:

- `ace_secret_rotation_success{secret=…}`: 1 when the last attempt succeeded, 0 when it failed.
- `ace_secret_rotation_last_success_timestamp_seconds{secret=…}`: when the secret was last rotated successfully.

A query for anything not rotated in 45 days: `time() - ace_secret_rotation_last_success_timestamp_seconds > 45*86400`.

**Adding a rotator:** only for secrets that ace both generates and consumes. Write a `rotate_<name>` function that keeps `.prev`, applies the new value, checks the service end to end, and restores on failure. Add it to `ALL` and `run_one`, then add a row to the table above.

## Rotating a sops secret

Run all of this as root on ace. ace's age key (`/var/lib/sops/age/keys.txt`) is a recipient of every file, so ace can decrypt and re-encrypt. The other recipients come from nix-secrets `.sops.yaml`.

1. **Make the new value** in the service it belongs to: change the database user's password, regenerate the OIDC secret in Zitadel, or roll the API key. Do this first only when the old and new values can't both work at once; otherwise update sops first. The [per-secret notes](#per-secret-notes) say which.
2. **Edit the sops file:**

   ```bash
   export SOPS_AGE_KEY_FILE=/var/lib/sops/age/keys.txt
   cd /home/prestonh/nixos-secrets
   nix shell nixpkgs#sops -c sops secrets/containers/<file>.yaml   # opens $EDITOR on the decrypted file
   ```

   Change only the value you are rotating, save and quit. sops re-encrypts on save. Don't paste the value anywhere else.
3. **Commit and push nix-secrets:** `git commit -am "rotate <name>" && git push`.
4. **Point ace at it and deploy:**

   ```bash
   cd /etc/nixos
   nix flake update nix-secrets
   nixos-rebuild switch --flake .#ace
   git commit -m "flake: update nix-secrets (rotate <name>)" flake.lock && git push
   ```

   sops-nix rewrites `/run/secrets/<name>`. The secret's `restartUnits` restart the containers and setup units that read it.
5. **Check the service** (see its doc page), and check that `systemctl --failed` is empty.
6. **Other hosts:** if the file is shared (for example `secrets/pterodactyl.yaml`), redeploy each host that uses it: `nixos-rebuild switch --flake .#<host> --target-host root@<ip>`.

To rotate everything because a key leaked, repeat this per secret. If an **age key** leaked, also rotate the recipient. Generate a new key, replace it in `.sops.yaml`, run `sops updatekeys` on every file, then rotate the secret values too, because the old key could still decrypt old commits.

## Per-secret notes

Files are under `secrets/` in nix-secrets. Run "workflow" means [the sops workflow](#rotating-a-sops-secret).

### Databases (ace only)

These passwords are used in two places: inside the database, and in the app's env or config. Change the database first, then update every copy and deploy straight away, because the app can't open new connections until it has the new value. Take `systemctl start restic-backups-local` first.

| Secret (file → key) | Change in the database | Other copies to update |
|---|---|---|
| Zitadel DB: `containers/zitadel-config.yaml` → `zitadel-db-env` `POSTGRES_PASSWORD` and `zitadel-env` `ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD` / `ZITADEL_DATABASE_POSTGRES_USER_PASSWORD` | `podman exec -it zitadel-db psql -U postgres -c '\password <user>'` (prompts, so nothing goes in argv) | Both env blobs. The `POSTGRES_*` values only matter when the database is first created |
| Matrix DB: `containers/matrix.yaml` → `matrix-db-env` `POSTGRES_PASSWORD` | `podman exec -it matrix-db psql -U synapse -c '\password synapse'` | `matrix-synapse-init` renders the homeserver config from this value; its `restartUnits` re-run it |
| Coolify DB: `containers/coolify.yaml` → `coolify-db-env` `POSTGRES_PASSWORD` and `coolify-env` `DB_PASSWORD` | `podman exec -it coolify-db psql -U coolify -c '\password coolify'` | Both keys |
| Coolify Redis: `containers/coolify.yaml` → `coolify-redis-env` `REDIS_PASSWORD` and `coolify-env` `REDIS_PASSWORD` | None: Redis reads it from the env at start | Both keys; deploy restarts both containers |
| Nextcloud DB: `containers/nextcloud.yaml` → `nextcloud-environment` / `nextcloud-db-environment` `MARIADB_PASSWORD` | `podman exec -it nextcloud-db mariadb -u root -p` then `ALTER USER …` | **`config.php` `dbpassword` is the value Nextcloud really uses.** Edit `'dbpassword'` in `/var/www/html/config/config.php` (inside the container) with an editor. Don't use `occ config:system:set --value=…`, which puts the password in argv. The env copies are only used on first install |
| MediaWiki DB: `containers/mediawiki.yaml` → `mediawiki-environment` `MARIADB_PASSWORD` | `ALTER USER` in `mediawiki-db` | `$wgDBpassword` in `/mw/html/LocalSettings.php`, which is site state, not Nix |
| Panel DB: `containers/pterodactyl.yaml` → `pterodactyl-env` `DB_PASSWORD` | `ALTER USER` in `pterodactyl-db` | The panel container reads `pterodactyl-env` through `--env-file`, which overrides `/pterodactyl/html/.env`. Also update the `.env` copy so a stray `artisan` run without that env doesn't use the old value. The test panel has its own database and password |
| MariaDB root passwords (`MARIADB_ROOT_PASSWORD`) | `ALTER USER 'root'@'%' …` and `'root'@'localhost'` | Only the env copies. Backups use the app account through `MYSQL_PWD` |

### Application keys

| Secret | Notes |
|---|---|
| `zitadel-env` `ZITADEL_MASTERKEY` | **Do not rotate in place.** It encrypts Zitadel's stored keys and secrets. Changing it needs Zitadel's re-encryption procedure and a tested restore. |
| `coolify-env` `APP_KEY`, `pterodactyl-env` `APP_KEY` | **Do not rotate casually.** Laravel encrypts stored values with it (Coolify server keys and env vars, panel 2FA and API data), and those become unreadable. Only rotate after a leak, with a plan for re-entering those values. |
| `matrix-secrets` `SYNAPSE_MACAROON_SECRET_KEY`, `SYNAPSE_FORM_SECRET` | Safe to rotate. Every Matrix client is signed out and must sign in again. `SYNAPSE_REGISTRATION_SHARED_SECRET` is only used for admin registration and is safe to rotate any time. |
| `pterodactyl-oauth-env` `OAUTH2_PROXY_COOKIE_SECRET` | Safe; signs panel SSO users out. 32 random bytes, base64 (`openssl rand -base64 32 \| tr -d '\n'`). |
| `wg-portal-config` (`containers/wg-portal-config.yaml`) | `core.admin_password` only seeds the local admin on first start; change it in the portal UI, then in sops. `database.encryption_passphrase` encrypts peer keys in `sqlite.db`, so **don't change it** without wg-portal's migration. The web session/CSRF secrets are now generated on ace (`wg-portal-web` above), and their sops copies are no longer used. |
| `restic-password` (`hosts/ace/backup.yaml`) | Add a second key before removing the old one: `restic key add` (it prompts for the new password), check `restic snapshots` with the new password, then the sops workflow, then `restic key remove <old-id>` (`restic key list` shows the ids). |

### OIDC client secrets (Zitadel)

| App | sops key |
|---|---|
| Grafana | `grafana-oauth-env` `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET` |
| Matrix | `matrix-oauth-env` `SYNAPSE_OIDC_CLIENT_SECRET` |
| Nextcloud | `nextcloud-oidc-env` `NEXTCLOUD_OIDC_CLIENT_SECRET` |
| Jellyfin | `jellyfin-oauth-env` `JELLYFIN_OIDC_CLIENT_SECRET` |
| Pterodactyl (both panels) | `pterodactyl-oauth-env` `PTERODACTYL_OIDC_CLIENT_SECRET` |
| Technitium | `technitium-oidc-env` `TECHNITIUM_OIDC_CLIENT_SECRET` |
| Coolify | `coolify-zitadel-env` `ZITADEL_CLIENT_SECRET` |
| wg-portal | `client_secret` inside `wg-portal-config` |

Zitadel invalidates the old secret the moment a new one is generated, so logins to that app fail until the deploy finishes. Keep the window short: have the sops file open first, then in the Zitadel console go to **Projects → Home Lab → \<app\> → Regenerate client secret**. Paste the new value straight into the file, save, and continue the workflow. Each secret's `restartUnits` re-run the app's SSO setup unit (for example `jellyfin-sso-setup`, `pterodactyl-sso-configure`, `coolify-zitadel-oauth`), which writes the new value into the app.

## External credentials

| Credential | Where to roll it | Then |
|---|---|---|
| Cloudflare `dns-api-token` / `acme-env` (`cloudflare.yaml`) | dash.cloudflare.com → My Profile → API Tokens → *Roll*. Keep it **DNS-only** (Zone:DNS:Edit) | Workflow. Caddy and the Coolify edge DNS pick it up |
| iCloud SMTP (`nextcloud-environment` `SMTP_PASSWORD`, `wg-portal-config` `mail.password`) | appleid.apple.com → Sign-In and Security → App-Specific Passwords: revoke the old one, create a new one | Workflow for both files (Grafana, Coolify and the update mails reuse `SMTP_PASSWORD`) |
| AbuseIPDB (`hosts/ace/abuseipdb.yaml`) | abuseipdb.com → Account → API → create a key, delete the old one | Workflow |
| Yubico OTP (`vaultwarden-environment`) | upgrade.yubico.com/getapikey | Workflow |
| Tailscale auth key (`ace.yaml` `tailscale-auth-key`) | Tailscale admin → Settings → Keys | Workflow. Only used to join, so an existing node keeps working |
| GitHub runner token (`github-runner.yaml`) | GitHub → org/repo → Settings → Actions → Runners | Workflow; see [GitHub Actions runners](./github-runner.md) |
| ace root git key (`hosts/ace/git.yaml` `ace-root-ssh-key`) | New key: `ssh-keygen -t ed25519 -C "root@ace (nixos-configs automation)"`. Add the public key at <https://github.com/settings/ssh/new> twice, as an Authentication key and as a Signing key | Workflow. Update `pubKey` in `nixos/ace-git-identity.nix`, rebuild, check `ssh -T git@github.com`, then delete the old key on GitHub |
| Router keys (`pterodactyl-router-ssh-key`, `cisco.yaml`) | Add the new key on Astracap (`ip ssh pubkey-chain`) before removing the old one | Workflow; see [Astracap router](./network-astracap.md) |
| User passwords (`users.yaml`) | `mkpasswd -m yescrypt` | Workflow; redeploy every host |
| age keys (`.sops.yaml`) | Host keys come from `/etc/ssh/ssh_host_ed25519_key` (`ssh-to-age`); the root and prestonh keys are in Vaultwarden | `sops updatekeys` on every file, then rotate the values (see above) |

## Open items

- **wg-portal (2026-11-04):** the decrypted `wg-portal-config` was printed into an agent session. Session and CSRF are already replaced by ace-generated values. Still to rotate:
  - the portal admin password
  - the iCloud SMTP app password (shared with `nextcloud-environment`)
  - the database encryption passphrase, which needs wg-portal's migration first
