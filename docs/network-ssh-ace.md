# LAN SSH and Vaultwarden MCP

Non-secret patterns for accessing Astracap (Cisco router), Astraquasar (Cisco switch), and Vaultwarden from Cursor or NixOS hosts.

## SSH client summary (`ssh astracap`)

Windows (`~/.ssh/config`) and NixOS (home-manager `programs.ssh`) use the same shape:

```
Host astracap
  HostName 192.168.5.1
  User prestonh
  IdentitiesOnly yes
  IdentityFile ~/.ssh/id_rsa_astracap
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
  IdentitiesOnly yes
  IdentityFile ~/.ssh/id_rsa_astracap
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

## NixOS deployment (ace, crux, nova, ph-nixos)

Home-manager for **`prestonh`** on all NixOS hosts that import `users/prestonh`:

| Host | Flake target |
|------|----------------|
| ace | `#ace` |
| crux | `#crux` |
| nova | `#nova` |
| ph-nixos | `#ph-nixos` |

| File | Purpose |
|------|---------|
| `users/prestonh/programs/ssh.nix` | `Host astracap` / `Host astraquasar` match blocks (legacy KEX; keys via SSH agent) |
| `users/prestonh/programs/bitwarden.nix` | `bitwarden-cli`, Vaultwarden server URL, `bw-ssh.sh` helper |
| `users/prestonh/config/nushell/bitwarden.nu` | `bw-unlock-ssh` for Nushell sessions |

Rebuild after pulling:

```bash
sudo nixos-rebuild switch --flake /etc/nixos#ace    # or #crux, #nova, #ph-nixos
```

## Bitwarden CLI + SSH agent

SSH private keys for Cisco LAN devices live in **Vaultwarden** (not nix-secrets or the repo). Home-manager installs **`bitwarden-cli`** (`bw`) and sets the default server to **`https://vault.prestonhager.com`**.

### Vault items

| Item | Type | Use |
|------|------|-----|
| **`id_rsa_astracap`** | SSH key | Private key for `ssh astracap` and `ssh astraquasar` (2048-bit RSA) |
| **`git-signing-ed25519`** | SSH key | Git commit signing (`gpg.format=ssh`); see [git-commit-signing.md](./git-commit-signing.md) |
| **Astracap Router Info** | Login | Cisco enable password (console / scripts; not SSH key) |

Store the astracap key as a Bitwarden **SSH key** item named **`id_rsa_astracap`**. The public half must still be on the router/switch (`ip ssh pubkey-chain`); see [Authorize SSH pubkey](#authorize-ssh-pubkey-serial-console).

### First-time setup (once per host)

```bash
bw config server https://vault.prestonhager.com   # also set by home-manager activation
bw login                                          # email + master password; optional 2FA
bw unlock                                         # verify access
```

Never commit `BW_PASSWORD`, API keys, session tokens, or private keys.

### Per-session SSH (NixOS)

Unlock the vault and start the Bitwarden SSH agent, then use normal `ssh` aliases:

**Bash / sh:**

```bash
source ~/.config/bitwarden/bw-ssh.sh
ssh astracap "show ip interface brief"
```

Equivalent manual steps:

```bash
export BW_SESSION="$(bw unlock --raw)"
eval "$(bw ssh-agent)"
ssh astracap
```

**Nushell** (after rebuild; `bitwarden.nu` is sourced from `env.nu`):

```nu
bw-unlock-ssh
ssh astracap
```

`programs.ssh.enableAgent = true` is enabled in home-manager. Cisco hosts rely on **`SSH_AUTH_SOCK`** from `bw ssh-agent`; home-manager match blocks keep legacy KEX / host-key algorithms only (no on-disk `IdentityFile`).

### Windows / Cursor

Keep a local `~/.ssh/id_rsa_astracap` or use Bitwarden CLI on Windows with the same unlock + `bw ssh-agent` flow. MCP config: see [Vaultwarden MCP](#vaultwarden-mcp-cursor) below.

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


## Network configuration docs

| Document | Content |
|----------|---------|
| [Network topology](network-topology.md) | Full homelab diagram, DNS flow, addressing |
| [Astracap router](network-astracap-router.md) | WAN/LAN, NAT, DHCP, ACLs |
| [Astraquasar switch](network-astraquasar-switch.md) | VLANs, ports, uplinks |

## Related LAN hosts

| SSH alias | IP | User |
|-----------|-----|------|
| ace | 192.168.5.5 | root |
| ace iDRAC | 192.168.5.10 | `root` (Vaultwarden item **`iDRAC`**; HTTPS/Redfish, not SSH key) |
| crux | 192.168.5.6 | root |
| nova | 192.168.5.7 | root |

## Security monitoring (planned)

Cisco syslog, config backup/diff, and incident response playbooks for Astracap and Astraquasar are outlined in `docs/security-ids-plan.md` (detection tiers, SPAN/IDS placement, rollback steps).
