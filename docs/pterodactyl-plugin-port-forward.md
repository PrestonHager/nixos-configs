# Pterodactyl Blueprint — Port Forward / NAT (Implementation)

**Status:** Implemented (v1.0.0, dry-run default)  
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

- **Extension disabled** until admin enables it
- **Dry-run ON** by default — logs IOS commands without SSH apply
- Blocked ports: 22, 80, 443, 3380
- Allowed range: 1024–65535

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
sudo nixos-rebuild switch --flake /etc/nixos#ace
sudo systemctl restart pterodactyl-blueprint-install.service
sudo podman exec pterodactyl php /var/www/pterodactyl/artisan migrate --force
```

Mount router SSH key via sops (see Secrets). Extension appears under **Admin → Extensions → Port Forward**.

---

## Secrets (not in git)

| Secret | Recommended source | Env var |
|--------|-------------------|---------|
| Router SSH private key | sops → `/run/secrets/pterodactyl-router-ssh-key` | `PORTFORWARD_SSH_KEY_FILE` |
| SSH config | Nix-generated `/pterodactyl/secrets/portforward-ssh-config` | `PORTFORWARD_SSH_CONFIG_FILE` |

Add to nix-secrets (example structure, **do not commit keys**):

```yaml
# secrets/containers/pterodactyl-router-ssh.yaml
router-ssh-private-key: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  ...
  -----END OPENSSH PRIVATE KEY-----
```

Wire into ace `sops.secrets` when the file exists (see implementation notes in `pterodactyl-extensions.nix`).

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

- [network-astracap-router.md](./network-astracap-router.md)
- [network-ssh-ace.md](./network-ssh-ace.md)
- [pterodactyl-plugin-dns-records.md](./pterodactyl-plugin-dns-records.md)
