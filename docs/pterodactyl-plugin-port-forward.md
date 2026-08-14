# Pterodactyl Blueprint — Port Forward / NAT (Implementation)

**Status:** Implemented (v1.0.0, live NAT when router key deployed)  
**Branch:** `dell-poweredge-r730xd`  
**Panel:** https://panel.prestonhager.com  
**Plan:** [pterodactyl-plugin-port-forward-plan.md](./pterodactyl-plugin-port-forward-plan.md)

---

## What was built

| Component | Path | Notes |
|-----------|------|-------|
| Blueprint extension | `plugins/pterodactyl-portforward-blueprint/` | Identifier `portforward` |
| IOS NAT builder | `.../Cisco/NatRule.php` | Static NAT line generation |
| SSH client | `.../Ssh/SshClient.php` | OpenSSH in panel container; legacy KEX for IOS 15.7 |
| Router service | `.../RouterNatService.php` | Validate, apply, audit |
| Queue jobs | `ApplyNatJob`, `RemoveNatJob` | Async NAT apply/remove |
| Audit log | `portforward_audit_log` table | IOS commands + stdout (truncated) |
| Nix install | `nixos/containers/pterodactyl-blueprint.nix` | Installs alongside dnsrecords |
| SSH config | `nixos/containers/pterodactyl-extensions.nix` | Drop-in config for Astracap |

### Default safety

- **Extension disabled** in schema until `pterodactyl-blueprint-extensions-configure.service` enables it (or admin enables manually)
- **Dry-run ON** until sops key `pterodactyl-router-ssh-key` is mounted — then configure service sets **dry-run OFF**
- Blocked ports: 22, 80, 443, 3380
- Allowed range: 1024–65535

### Finding extensions in the panel

Blueprint does **not** add a top-level “Blueprint” sidebar item for custom extensions. After install, open:

| Location | What you see |
|----------|----------------|
| **Admin → Extensions** | Blueprint framework settings |
| **Admin → Extensions → DNS Records** | Technitium/Cloudflare DNS extension |
| **Admin → Extensions → Port Forward** | NAT automation settings |
| **Admin → Servers → View server** | **DNS** and **Network / NAT** tabs (when extensions enabled) |

Requires **root admin** (`root_admin=1`). SSO users need Zitadel role `pterodactyl_admin`.

See **[Usage guide](./pterodactyl-extensions-user-guide.md)** for step-by-step instructions (prerequisites, dry-run vs live NAT, server workflow, troubleshooting).

### Event hooks

- `Server\Installed` → `ApplyNatJob` (when `auto_forward_on_install` enabled)
- `Server\Deleting` → `RemoveNatJob` (when `auto_remove_on_delete` enabled)

### Node → IP mapping

| Node | Default LAN IP |
|------|----------------|
| crux | 192.168.5.6 |
| nova | 192.168.5.7 |

Override via **Node IP map** JSON in extension settings (`{"1": "192.168.5.6", ...}`).

---

## Deploy

```bash
cd /etc/nixos
git fetch origin dell-poweredge-r730xd
git reset --hard origin/dell-poweredge-r730xd
sudo nixos-rebuild switch --flake .#ace
sudo systemctl restart pterodactyl-blueprint-install.service
sudo systemctl restart pterodactyl-blueprint-extensions-configure.service
sudo podman exec pterodactyl php /var/www/pterodactyl/artisan migrate --force
```

### Router SSH key (one-time on ace)

Generate a **2048-bit RSA** key, encrypt in nix-secrets, rebuild:

```bash
# Copy private key to ace (from secure workstation), then:
sudo bash /etc/nixos/scripts/ace-pterodactyl-router-ssh-deploy.sh /path/to/pterodactyl-router-ssh-key
```

Authorize the printed public key on Astracap for user **`pterofwd`** (serial console recommended):

```powershell
$env:CISCO_ENABLE_PASSWORD = (& scripts/get-cisco-enable.ps1)
$env:PTEROFWD_PUBKEY = "C:\path\to\pterofwd_astracap.pub"
$env:ASTRACAP_SERIAL_PORT = "COM6"   # USB console adapter
python scripts/astracap-setup-pterofwd.py
Remove-Item Env:CISCO_ENABLE_PASSWORD
```

SSH-based alternative (when console unavailable, may require manual IOS `key-string` paste):

```powershell
$env:CISCO_ENABLE_PASSWORD = (& scripts/get-cisco-enable.ps1)
$env:PTEROFWD_PUBKEY = "C:\path\to\pterofwd_astracap.pub"
python scripts/astracap-setup-pterofwd-ssh.py
Remove-Item Env:CISCO_ENABLE_PASSWORD
```

Verify from ace panel container:

```bash
podman exec pterodactyl ssh -F /pterodactyl/secrets/portforward-ssh-config astracap "show ip interface brief"
```

Mount router SSH key via sops (see Secrets). Extension appears under **Admin → Extensions → Port Forward**.

---

## Secrets (not in git)

| Secret | sops key in `pterodactyl.yaml` | Host path | Container path |
|--------|----------------------------------|-----------|----------------|
| Router SSH private key | `pterodactyl-router-ssh-key` | `/run/secrets/pterodactyl-router-ssh-key` | `/pterodactyl/secrets/pterodactyl-router-ssh-key` |
| SSH config | Nix-generated | `/pterodactyl/secrets/portforward-ssh-config` | same (bind mount) |
| Technitium API token (optional) | `pterodactyl-technitium-api-token` | `/run/secrets/...` | `/pterodactyl/secrets/pterodactyl-technitium-api-token` |

Env vars written to `/pterodactyl/secrets/blueprint-extensions.env`:

| Env var | When set |
|---------|----------|
| `PORTFORWARD_SSH_KEY_FILE` | Router key present |
| `PORTFORWARD_SSH_CONFIG_FILE` | Always |
| `TECHNITIUM_API_TOKEN_FILE` | Technitium token present |

Add to nix-secrets (`secrets/containers/pterodactyl.yaml`, **do not commit plaintext keys to nixos-configs**):

```yaml
pterodactyl-router-ssh-key: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  ...
  -----END OPENSSH PRIVATE KEY-----
```

Or run `scripts/ace-pterodactyl-router-ssh-deploy.sh` on ace (encrypts via sops automatically).

Router SSH user: **`pterofwd`** (dedicated automation account; pubkey in `ip ssh pubkey-chain`).

---

## IOS command format

```text
ip nat inside source static tcp 192.168.5.6 25565 interface GigabitEthernet0/0 25565
```

Removal: prefix with `no `. Running-config only (no `write memory` in v1).

---

## Test case TC-PF-1 — Dry-run command builder

### Setup

1. Port Forward extension installed
2. Dry-run **enabled**, extension **enabled**
3. SSH key **not required** for this test

### Execution

1. Admin → Extensions → Port Forward → enable extension, keep dry-run on → Save
2. Admin → Servers → View test server → **Network / NAT** tab → **Forward primary allocation**
3. Check audit log: `GET /extensions/portforward/admin/audit` (or DB table)

### Expected deliverables

- Mapping row with status `dry_run`
- Audit entry with action `dry_run` and IOS commands containing `ip nat inside source static`
- No change on router (`show running-config | include ip nat inside source static` unchanged)

### Interpretation

| Result | Meaning |
|--------|---------|
| Audit shows IOS lines | Command builder working |
| Status `active` with dry-run on | Bug — dry-run should not mark active |
| 422 error | Port policy blocked (e.g. port 80) or extension disabled |

---

## Test case TC-PF-2 — Live NAT apply (manual)

### Setup

1. Dry-run **disabled**
2. Router SSH key mounted; test connection succeeds
3. Test port e.g. 25570 on crux server (not in blocked list)

### Execution

1. Create mapping TCP 25570 → 25570 from server Network tab
2. On ace: `ssh astracap "show running-config | include 25570"`
3. External: `nc -vz 73.26.67.25 25570` (if ISP path allows)

### Troubleshooting

```bash
# SSH from panel pod
sudo podman exec -it pterodactyl sh -c 'ssh -F /pterodactyl/secrets/portforward-ssh-config astracap "show ip interface brief"'

# Audit
sudo podman exec pterodactyl php artisan tinker --execute="DB::table('portforward_audit_log')->orderByDesc('id')->limit(5)->get();"
```

---

## Known limitations (v1)

- No `write memory` — NAT rules lost on router reboot
- UDP + TCP same port requires two explicit mappings
- No WAN ACL permit-line management
- SSH apply not verified in CI; test on ace before disabling dry-run in production

---

## References

- [network-astracap-router.md](../shared/network-astracap.md)
- [network-ssh-ace.md](../shared/network-ssh.md)
- [pterodactyl-plugin-dns-records.md](./pterodactyl-plugin-dns-records.md)
