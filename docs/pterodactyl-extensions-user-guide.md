# Pterodactyl Blueprint Extensions — User Guide

How to use the **DNS Records** and **Port Forward** Blueprint extensions on the Preston Hager game server panel.

| Panel | URL | Extensions |
|-------|-----|------------|
| **Production** | https://panel.prestonhager.com | DNS Records + Port Forward + Social Login |
| **Test** | https://test.panel.prestonhager.com | DNS Records + Social Login (no Port Forward) |

---

## Prerequisites

### Root administrator access

All extension settings and per-server tabs require a **root administrator** account (`root_admin=1` in the panel database).

- **Production:** Sign in with Zitadel SSO. Your Zitadel user must have the `pterodactyl_admin` role, which maps to root admin in the panel.
- **Test:** Sign in with Zitadel SSO (same Home Lab OIDC app and `pterodactyl_admin` role), or use the local admin account from `/var/lib/pterodactyl-test/admin-credentials` on ace.

If you are logged in but do not see **Admin** in the sidebar, or **Extensions** under Admin, you are not a root admin.

### Where to find settings (not the Blueprint menu)

Blueprint custom extensions do **not** add a top-level “Blueprint” sidebar item. Use:

| What | Navigation |
|------|------------|
| Extension global settings | **Admin → Extensions → DNS Records** or **Port Forward** |
| Per-server DNS | **Admin → Servers → View server → DNS** tab |
| Per-server NAT | **Admin → Servers → View server → Network / NAT** tab |

Direct URLs (production):

- https://panel.prestonhager.com/admin/extensions/dnsrecords
- https://panel.prestonhager.com/admin/extensions/portforward

---

## How the extensions work

### DNS Records (`dnsrecords`)

Automates DNS for game servers:

1. **On server install** — creates SRV records (e.g. Minecraft `_minecraft._tcp`) for enabled SRV profiles.
2. **On allocation change** — updates SRV target port/host when the primary allocation changes.
3. **On server delete** — removes DNS records.

**Providers:**

| Mode | Backend | Use case |
|------|---------|----------|
| `cloudflare` | Cloudflare API | Public DNS (WAN players) |
| `technitium` | Technitium on ace (`host.containers.internal:5380`) | LAN resolution via ace |
| `both` | Cloudflare + Technitium | Public and LAN |

Credentials are stored encrypted in extension settings (Cloudflare token) or via sops-mounted env files (Technitium token on production).

### Port Forward (`portforward`)

Automates Cisco IOS NAT on the Astracap router (192.168.5.1):

1. Builds `ip nat inside source static tcp …` commands for a server's node IP and port.
2. Applies them over SSH as user **`pterofwd`** (dedicated automation account).
3. Logs all commands and router output to the audit log.

**Safety defaults:**

- Extension starts **disabled** until enabled in admin UI or by Nix configure service.
- **Dry-run ON** until the router SSH key is deployed via sops — commands are logged but not applied.
- Blocked ports: 22, 80, 443, 3380.

**Node IP mapping** (defaults):

| Node | LAN IP |
|------|--------|
| crux | 192.168.5.6 |
| nova | 192.168.5.7 |

---

## Step-by-step: new game server

### 1. Configure extension settings (one-time)

**DNS Records** — Admin → Extensions → DNS Records:

1. Set **Provider mode** (`technitium` for LAN-only testing, `both` for production).
2. Enter **Cloudflare API token** and **zone ID** (if using Cloudflare).
3. Set **Technitium API URL** (`http://host.containers.internal:5380` on production).
4. Add **SRV profiles** for your egg (e.g. Minecraft Java with `_minecraft._tcp`).
5. Enable **Auto-provision on server install** if desired.
6. Save.

**Port Forward** — Admin → Extensions → Port Forward:

1. Check **Enable extension**.
2. Leave **Dry-run** ON until router SSH is verified (see [pterodactyl-plugin-port-forward.md](./pterodactyl-plugin-port-forward.md)).
3. Confirm router host `192.168.5.1`, SSH user `pterofwd`, WAN interface `GigabitEthernet0/0`.
4. Save.

### 2. Create the server

Admin → Servers → Create New:

- Assign to **crux** or **nova**.
- Set primary allocation port (e.g. 25565).

### 3. Provision DNS (if not auto)

Admin → Servers → View server → **DNS** tab:

1. Review generated hostname / subdomain.
2. Click **Provision selected** (or per-profile buttons) to create SRV records.
3. Verify with `dig` (LAN: `@192.168.5.5`, public: `@1.1.1.1`).

### 4. Configure port forward

Admin → Servers → View server → **Network / NAT** tab:

1. Click **Forward primary allocation** (or add a custom TCP/UDP mapping).
2. Check audit log for IOS commands and status (`dry_run`, `active`, or `failed`).

**Dry-run:** audit shows commands; router config unchanged.

**Live:** verify on ace:

```bash
ssh astracap "show running-config | include ip nat inside source static"
```

---

## Test panel vs production

| Feature | Production | Test |
|---------|------------|------|
| DNS Records extension | Yes | Yes |
| Port Forward extension | Yes | No |
| Social Login / Zitadel | Yes | No (local admin) |
| Technitium via `host.containers.internal` | Yes | Uses public URL in `.blueprintrc` |
| Router SSH / live NAT | Yes (when key deployed) | N/A |

Use the **test panel** to validate DNS extension changes before deploying to production.

---

## Troubleshooting

### Cannot find extension settings

| Symptom | Cause | Fix |
|---------|-------|-----|
| No **Admin** menu | Not root admin | Use SSO account with `pterodactyl_admin` role, or local admin on test panel |
| Admin exists but no **Extensions** | Wrong panel / cache | Hard refresh; confirm URL is production panel |
| Looking for “Blueprint” top menu | Misconception | Go to **Admin → Extensions** instead |
| DNS / NAT tabs missing on server view | Extension not installed or wrapper not loaded | Run `pterodactyl-blueprint-install.service` on ace; check routes |

### HTTP 500 on test.panel

Usually **Redis unreachable** inside the test pod (panel and redis in separate network namespaces). On ace:

```bash
sudo systemctl restart pterodactyl-test-pod-network-check.service
curl -sk -o /dev/null -w '%{http_code}\n' https://test.panel.prestonhager.com/
```

Expected: `200` or `302` (redirect to login).

### Extension settings empty / port forward disabled

The Nix configure service seeds defaults on boot. If it failed (psysh HOME error), restart it:

```bash
sudo systemctl restart pterodactyl-blueprint-extensions-configure.service
```

Then verify settings exist:

```bash
sudo podman exec -e HOME=/var/www/pterodactyl pterodactyl \
  php /var/www/pterodactyl/artisan tinker --execute='print_r(DB::table("portforward_settings")->count());'
```

### Port forward SSH permission denied

1. Verify key mounted: `/run/secrets/pterodactyl-router-ssh-key` on ace host.
2. Test from panel container:

```bash
sudo podman exec pterodactyl ssh -F /pterodactyl/secrets/portforward-ssh-config astracap "show ip interface brief"
```

3. Ensure `pterofwd` pubkey is on Astracap (see [pterodactyl-plugin-port-forward.md](./pterodactyl-plugin-port-forward.md)).

### DNS provision fails / NXDOMAIN

- Check provider mode and tokens in extension settings.
- LAN: `dig @192.168.5.5 _minecraft._tcp.<hostname>.prestonhager.com SRV +short`
- Review audit: `dnsrecords_audit_log` table.
- Technitium: panel pod must reach `host.containers.internal:5380`.

---

## Related docs

- [pterodactyl-plugin-dns-records.md](./pterodactyl-plugin-dns-records.md) — implementation and test cases
- [pterodactyl-plugin-port-forward.md](./pterodactyl-plugin-port-forward.md) — NAT deploy and router SSH
- [pterodactyl-ace.md](./pterodactyl-ace.md) — ace panel overview
- [pterodactyl-test-blueprint.md](./pterodactyl-test-blueprint.md) — test panel architecture
