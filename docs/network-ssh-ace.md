# LAN SSH and Vaultwarden MCP

Non-secret patterns for accessing Astracap (Cisco router), Astraquasar (Cisco switch), and Vaultwarden from Cursor or NixOS hosts.

## SSH client summary (`ssh astracap`)

Windows (`~/.ssh/config`) and NixOS (home-manager `programs.ssh`) use the same shape:

```
Host astracap
  HostName 192.168.5.1
  User prestonh
  IdentityFile ~/.ssh/id_rsa_astracap
  IdentitiesOnly yes
  IdentityAgent none
  KexAlgorithms +diffie-hellman-group14-sha1
  HostKeyAlgorithms +ssh-rsa
  PubkeyAcceptedAlgorithms +ssh-rsa
```

| Field | Value |
|-------|-------|
| Device | Cisco router (IOS 15.7, Astracap) |
| LAN IP | `192.168.5.1` |
| SSH user | **`prestonh`** (publickey-only; `admin` exists but router SSH is keyed for `prestonh`) |
| Key | **`id_rsa_astracap`** — 2048-bit RSA (IOS rejects 4096-bit keys in `ip ssh pubkey-chain`) |
| Legacy KEX | `+diffie-hellman-group14-sha1`, `+ssh-rsa` on Kex / HostKey / PubkeyAccepted |

Verify:

```powershell
ssh astracap "show ip interface brief"
```

## SSH client summary (`ssh astraquasar`)

```
Host astraquasar
  HostName 192.168.5.3
  User admin
  IdentityFile ~/.ssh/id_rsa_astracap
  IdentitiesOnly yes
  IdentityAgent none
  KexAlgorithms +diffie-hellman-group14-sha1
  HostKeyAlgorithms +ssh-rsa
  PubkeyAcceptedAlgorithms +ssh-rsa
```

| Field | Value |
|-------|-------|
| Device | Cisco Catalyst WS-C3650 (IOS-XE 16.12, Astraquasar) |
| LAN IP | `192.168.5.3` |
| SSH user | **`admin`** (publickey via `login local` + `ip ssh pubkey-chain`) |
| Key | Same **`id_rsa_astracap`** as Astracap |
| Telnet | Port 23 (legacy; prefer SSH) |

Verify:

```powershell
ssh astraquasar "show version"
```

## NixOS deployment (ace, crux, ph-nixos)

Home-manager for **`prestonh`** on all three hosts:

| File | Purpose |
|------|---------|
| `users/prestonh/programs/ssh.nix` | `Host astracap` / `Host astraquasar` match blocks |
| `users/prestonh/home-config.nix` | sops secret `ssh/id_rsa_astracap` → `~/.ssh/id_rsa_astracap` |

**One-time:** add the private key to **nix-secrets** (never commit the key here):

```bash
# In nix-secrets repo, edit secrets/home-manager/prestonh/secrets.yaml
sops secrets/home-manager/prestonh/secrets.yaml
# Add: ssh/id_rsa_astracap: <PEM contents>
```

Generate a new 2048-bit key if needed (on any host):

```bash
ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa_astracap -C 'preston@astracap-lan'
```

Then rebuild: `sudo nixos-rebuild switch --flake /etc/nixos#ace` (or `#crux`, `#ph-nixos`).

## Vaultwarden MCP (Cursor)

Config: `~/.cursor/mcp.json`

| Server | Package | Use |
|--------|---------|-----|
| `vaultwarden` | `@icoretech/warden-mcp` | Credentials in `~/.cursor/warden-mcp.env` |
| `bitwarden` | `@bitwarden/mcp-server` | Requires `bw` on PATH in MCP env |

Bitwarden CLI: `bw config server https://vault.prestonhager.com`

Cisco enable password helper (Windows, never prints secret):

```powershell
$env:CISCO_ENABLE_PASSWORD = (& scripts/get-cisco-enable.ps1)
```

Vault item **Astracap Router Info** holds enable secret/password (shared with switch console).

## Authorize SSH pubkey (serial console)

Scripts (Windows, COM6):

| Script | Target |
|--------|--------|
| `scripts/cisco-authorize-ssh.py` | Generic IOS pubkey install |
| `scripts/astracap-authorize-ssh.py` | Router → user `prestonh` |
| `scripts/astraquasar-authorize-ssh.py` | Switch → user `admin` |
| `scripts/cisco-enable-ssh-login.py` | Switch: `username … privilege 15`, `line vty … login local` |

**IOS 15.x quirk:** run `key-string` alone (enters `(conf-ssh-pubkey-data)#`), paste base64 in 64-character lines, blank line to finish. IOS stores `key-hash ssh-rsa …`.

Example (switch):

```powershell
$env:CISCO_ENABLE_PASSWORD = (& scripts/get-cisco-enable.ps1)
python scripts/cisco-authorize-ssh.py --username admin
python scripts/cisco-enable-ssh-login.py --username admin
Remove-Item Env:CISCO_ENABLE_PASSWORD
```

## Status (2026-06)

| Host | SSH | Notes |
|------|-----|-------|
| astracap | ✅ `ssh astracap` | Pubkey for `prestonh` |
| astraquasar | ✅ `ssh astraquasar` | Pubkey for `admin`; vty `login local` required |

## Related LAN hosts

| SSH alias | IP | User |
|-----------|-----|------|
| ace | 192.168.5.5 | root |
| crux | 192.168.5.6 | root |
| nova | 192.168.5.7 | root |
