# Jellyfin on ace

Implementation: `nixos/containers/jellyfin.nix`, Caddy `nixos/caddy/jellyfin.nix`, secrets `nixos-secrets/secrets/containers/jellyfin.yaml` (`jellyfin-oauth-env`).

## Service

| Field | Value |
|-------|-------|
| URL | https://jellyfin.prestonhager.com |
| Version | Jellyfin **12.4** (official container image, pinned as `jellyfinVersion`; tested digest `sha256:fea863d0cd9ec445985d9c75fc6ed64e38a1d2766cf0c250a33d553f4fc1b771`) |
| Auth | Keycloak OIDC (realm `homelab`, client `jellyfin`) via the **SSO-Auth** plugin, [`MaxRink/jellyfin-plugin-sso`](https://github.com/MaxRink/jellyfin-plugin-sso) fork **6.1.0.0** (ABI 12.0, hash-pinned, installed to `plugins/SSO-Auth_6.1.0.0`). The original `9p4/jellyfin-plugin-sso` is archived at 4.0.0.4 (ABI 10.11). The fork keeps the plugin GUID and the `SSO-Auth.xml` schema |
| Other plugins | Installed from the Jellyfin catalog, not by nix: AniDB 13, AniList 15, Open Subtitles 25, Playback Reporting 19, Reports 20 (ABI 12 builds). A major upgrade leaves the old builds `NotSupported`; reinstall them from the dashboard catalog |
| Upgrades | No major hold since 12.4 (tested 2026-11-04 on a copy of production). The 10.11 → 12 database migration is one-way: back up `/jf/config` before any major bump |
| SSO login URL | https://jellyfin.prestonhager.com/sso/OID/start/keycloak |
| Break-glass local admin | `prestonh` keeps its local Jellyfin password (default auth provider) |

## Keycloak OIDC client

Keycloak realm `homelab` ([keycloak-ace.md](./keycloak-ace.md)), client **`jellyfin`**, declared in `nixos/containers/jellyfin.nix` as `homelab.keycloak.clients.jellyfin`. `keycloak-realm-sync` creates and updates it on every switch:

| Setting | Value |
|---------|--------|
| Client ID | `jellyfin` (confidential, standard flow only) |
| Redirect URIs | `https://jellyfin.prestonhager.com/sso/OID/redirect/keycloak`, `https://jellyfin.prestonhager.com/sso/OID/r/keycloak` |
| Secret | `KEYCLOAK_CLIENT_SECRET` in `jellyfin-oauth-env` (the value the Zitadel app used, reused) |
| Scopes | `openid email profile`; the client's default `groups` scope adds a flat `groups` claim |

Keycloak is LAN/tailnet/VPN only, so **SSO login works only from home or over the VPN**. Existing sessions, Quick Connect and local-password logins (LAN TV/app clients) do not depend on Keycloak.

`jellyfin-sso-setup.service` installs the plugin and writes `plugins/configurations/SSO-Auth.xml` (provider **`keycloak`**) and the login button in `branding.xml`. Jellyfin keeps both in memory, and the plugin writes its in-memory copy back over the file. So the unit fingerprints what it controls (everything except the canonical links, stored in `/jf/config/.sso-setup-hash`) and restarts Jellyfin when the fingerprint changes. The container reaches Keycloak's back-channel (discovery, token, certs, userinfo) through the carve-out in `nixos/caddy/keycloak.nix`.

## Jellyfin roles from Keycloak groups

The plugin reads the flat `groups` claim (`RoleClaim`):

| Keycloak group | Jellyfin effect |
|----------------|-----------------|
| `jellyfin_admin` | Administrator, set on every login and removed on the next login after leaving the group (`PreserveAdminPermissions=false`) |
| `jellyfin_user` | Login with library access (`EnableAllFolders`) |
| neither | Login refused ("Error. Check permissions.") |

Membership in both groups works with plugin 6.x. The old "both roles break login" problem came from the Zitadel complement action and the old plugin. `tests/sso/jellyfin.test.sh` logs in with both groups.

Membership is managed in the Keycloak admin console ([keycloak-users.md](./keycloak-users.md)): Preston `jellyfin_admin` (+ `jellyfin_user`), Dylan `jellyfin_user`.

## Accounts and linking

The plugin links a Keycloak identity to a Jellyfin user by **canonical link** (`CanonicalLinks` in `SSO-Auth.xml`, Keycloak `sub` -> Jellyfin user id). Existing accounts are pre-linked by username:

- `jellyfin-sso-setup` seeds a username-keyed link for each of `linkedUsers` (`prestonh`, `dylanh`) to the Jellyfin user of the same name. On that user's first Keycloak login the plugin rekeys the link to the Keycloak `sub`. Links the plugin has recorded are kept when the file is rewritten.
- `DisableUsernameAccountAdoption=true` means no Keycloak user ever takes over another existing local account by name, such as `admin@prestonhager.com` (still present, administrator). That login is refused. A Keycloak user with no Jellyfin account gets a new one (random password, SSO only).
- To link another existing account, add its username to `linkedUsers`.

Recorded before the move (2026-11-04):

| Jellyfin user | Id | Admin | Watch-data rows |
|---------------|----|-------|-----------------|
| `prestonh` | `31D58C8E-4CA2-4177-959C-D83144A25177` | yes | 35 |
| `dylanh` | `AAA9A29D-D8DD-43E2-BCCB-864D429C16FA` | yes (set locally; never logged in via SSO) | 6 |
| `admin@prestonhager.com` | `25D5D8B7-5B16-4FF3-9607-C4E64BCD4CFC` | yes, not linked | 0 |

With `jellyfin_user` only, Dylan's first SSO login turns his administrator flag off. If he should stay an admin, add him to `jellyfin_admin` first.

## Login (SSO)

1. Open https://jellyfin.prestonhager.com (from home or the VPN)
2. Click **Sign in with Keycloak** (login disclaimer button)
3. Or go directly to https://jellyfin.prestonhager.com/sso/OID/start/keycloak

## Sops secrets

`secrets/containers/jellyfin.yaml`:

```yaml
jellyfin-oauth-env: |
  KEYCLOAK_CLIENT_SECRET=<client secret; keycloak-realm-sync sets the Keycloak client to it>
```

After sops changes: commit and push nixos-secrets, run `nix flake update nix-secrets` in `/etc/nixos`, then `bash scripts/ace-rebuild.sh` (it restarts `jellyfin-sso-setup` and `keycloak-realm-sync`).

## Regression test

```bash
bash /etc/nixos/tests/sso/run.sh jellyfin
```

It logs in as `sso-regression` four times: non-admin, admin, demoted, and refused without a group. It checks the API with the SSO token, that `prestonh` and `dylanh` are linked to their existing user ids, and that real accounts and watch data are unchanged. It deletes the test account at the end.

## Container networking

Jellyfin runs with `--add-host=keycloak.prestonhager.com:host-gateway`, so server-side OIDC discovery and token exchange reach Caddy on the host. Caddy lets the podman bridge reach only Keycloak's back-channel endpoints (`nixos/caddy/keycloak.nix`).

Port 8096 is published on `127.0.0.1` (Caddy, version check) and `192.168.5.5` (LAN TV/app clients that connect to `http://192.168.5.5:8096` directly and log in with Jellyfin credentials). It is not published on other host addresses (tailnet, Podman bridges); remote clients use https://jellyfin.prestonhager.com.

## Verification on ace

```bash
# SSO plugin loaded (302 to Keycloak)
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  'http://127.0.0.1:8096/sso/OID/start/keycloak'

# Canonical links and admin flags
nix shell nixpkgs#xmlstarlet -c xmlstarlet sel -t -m '//OidConfigs/item[key/string="keycloak"]//CanonicalLinks/item' \
  -v key/string -o ' ' -v value/guid -n /jf/config/plugins/configurations/SSO-Auth.xml
nix shell nixpkgs#sqlite -c sqlite3 -readonly /jf/config/data/jellyfin.db \
  "SELECT u.Username, u.Id, p.Value AS admin FROM Users u JOIN Permissions p ON p.UserId = u.Id AND p.Kind = 0;"
```

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| `redirect_uri` mismatch | `homelab.keycloak.clients.jellyfin.redirectUris`; check that `journalctl -u keycloak-realm-sync` shows it applied |
| "Check permissions" on login | The Keycloak user is in neither `jellyfin_user` nor `jellyfin_admin` |
| 409 "username taken" on login | A local account of that name exists and is not linked. Add it to `linkedUsers` in `jellyfin.nix`, but only if it really belongs to that Keycloak user |
| OIDC discovery fails / 403 | The container must reach `keycloak.prestonhager.com` from the podman bridge: `--add-host` on the container and the back-channel carve-out in `nixos/caddy/keycloak.nix` |
| `/sso/OID/start/keycloak` returns 400 "No matching provider" | Jellyfin was not restarted after the provider changed: `rm /jf/config/.sso-setup-hash; systemctl restart jellyfin-sso-setup` |
| Start URL works publicly but fails on `127.0.0.1:8096` | Expected: the plugin builds the redirect URI from the request host, and only the public URL is registered in Keycloak |
| API calls with a token get 401 | Jellyfin 12 ignores `X-Emby-Token`; send `Authorization: MediaBrowser Token="..."` |
| Plugin not loaded | Run `systemctl restart jellyfin-sso-setup.service`; check `/jf/config/plugins/SSO-Auth_6.1.0.0/` (Jellyfin loads `plugins/<Name>_<version>/`) and its `meta.json` `status` (`NotSupported` means the build targets another ABI) |
| SSO button missing on login page | `branding.xml` LoginDisclaimer HTML must be XML entity-escaped (raw `<form>` tags break parsing); check `podman logs jellyfin` for `Error loading configuration file: branding.xml` |

Useful logs:

```bash
journalctl -u jellyfin-sso-setup.service -n 50
podman logs jellyfin --tail 100 | grep -i sso
```
