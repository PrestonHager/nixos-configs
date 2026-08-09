# Astraquasar (Cisco Catalyst 3650 switch)

Layer-2 access switch for the homelab LAN (`192.168.5.0/24`). Documented from live IOS-XE **16.12.7** on **WS-C3650-48PD** (`show running-config`, VLAN/interface/STP/CDP output via SSH, June 2026). Secrets omitted.

SSH: [Network & SSH / Bitwarden](network-ssh-ace.md). Router: [Astracap](network-astracap-router.md). Full map: [Network topology](network-topology.md).

## Role

| Function | Detail |
|----------|--------|
| LAN switching | Single VLAN (**VLAN 1** / default) — flat L2 domain |
| Management | SVI **`Vlan1` → `192.168.5.3/24`**, default gateway **`192.168.5.1`** (Astracap) |
| Uplink | **`Gi2/0/1`** to Astracap **`Gi0/2`** (CDP confirms) |
| Server attachment | **ace** — LACP **Port-channel1** (`Gi2/0/13`–`16`, access VLAN 1) |
| Wi‑Fi | **`Gi2/0/2`** — Astraspring access point |

## Logical diagram

```mermaid
flowchart TB
  R["Astracap Gi0/2<br/>192.168.5.1"]
  SW["Astraquasar<br/>192.168.5.3"]
  U["Gi2/0/1 Uplink_to_Astracap"]
  AP["Gi2/0/2 Astraspring_AP"]
  Po["Po1 Ace_Bond"]
  Ace["ace 192.168.5.5"]
  P25["Gi2/0/25 Crux"]
  Crux["crux 192.168.5.6"]
  P47["Gi2/0/47 Ace_iDRAC"]
  AceId["ace iDRAC 192.168.5.10"]
  P48["Gi2/0/48 Mars_iDRAC"]
  MarsId["mars iDRAC 192.168.5.11"]

  R --- U --> SW
  SW --> AP
  SW --> Po --> Ace
  SW --> P25 --> Crux
  SW --> P47 --> AceId
  SW --> P48 --> MarsId
```
## VLANs

| VLAN | Name | Ports | Notes |
|------|------|-------|-------|
| 1 | default | All access ports listed in `show vlan brief` | No additional user VLANs configured |

All documented access ports use **`switchport mode access`** (no 802.1Q trunks in use on active uplink).

## Port assignments (labeled / notable)

| Port | Description / config | Status (Aug 2026) | Notes |
|------|----------------------|-------------------|-------|
| `Gi2/0/1` | Uplink_to_Astracap | connected | Primary router uplink |
| `Gi2/0/2` | Astraspring_AP, portfast | connected | AP + wireless clients (multiple MACs) |
| `Gi2/0/3` | access | notconnect | Spare |
| `Gi2/0/4`–`12`, `18`–`24`, `26`, `28`–`46` | — | shutdown or disabled | Intentionally unused — candidates for elara / zenith / mars OS / sally when cabled |
| `Gi2/0/13`–`16` | Server_Ace → **Po1** LACP active, portfast | 14 connected; 13 suspended; 15–16 notconnect | ace bond members |
| `Gi2/0/17` | Server_Ace (label only) | up / protocol down | Labeled like bond members but **not** in Po1; treat as leftover label / investigate before reuse |
| `Po1` | Ace_Bond | connected (via active member) | Aggregates ace NICs |
| `Gi2/0/25` | **Crux** | connected | **crux** `192.168.5.6` — NIC MAC `b8:85:84:a8:6d:b4`; `description Crux` |
| `Gi2/0/27` | **Spare_Nova_candidate** | notconnect | Candidate when reattaching **nova** (`192.168.5.7`); `description Spare_Nova_candidate` |
| `Gi2/0/47` | **Ace_iDRAC** — access VLAN 1, portfast (**no** port-security) | connected | Dedicated Dell iDRAC OOB NIC — MAC `18:66:DA:82:52:D6`, static **`192.168.5.10`**. Sticky port-security cleared 2026-07-12. Runbook: [ace-idrac.md](ace-idrac.md). |
| `Gi2/0/48` | **Mars_iDRAC** | connected | **mars** iDRAC 6 — MAC `d4:ae:52:92:c5:a2`, static **`192.168.5.11`**. `description Mars_iDRAC` set Aug 2026. Runbook: [mars-idrac.md](mars-idrac.md). |
| `Te2/1/4` | Uplink_to_Astracap (routed, no IP) | shutdown | Alternate uplink not in use |
| `Gi2/1/1`, `Gi2/1/2`, `Te2/1/3` | default | — | Unused uplink capacity |

**Online infra (Aug 2026):** crux on **`Gi2/0/25`**, ace iDRAC on **`Gi2/0/47`**, mars iDRAC on **`Gi2/0/48`**. Reserved / not cabled: nova `.7`, elara `.8`, zenith `.9`, sally iDRAC `.12`, mars OS `.15`, sally OS `.16`. Prefer **`Gi2/0/27`** for nova; label new ports when attaching.


## Spanning tree

- Mode: **rapid-PVST**
- **`spanning-tree portfast`** on AP and ace bond member ports
- UplinkFast disabled (default)

## Routing

- **L3 routing not used** for production traffic (SVI + default gateway only).
- **`ip default-gateway 192.168.5.1`**

## CDP

| Local | Remote |
|-------|--------|
| `GigabitEthernet2/0/1` | Astracap `GigabitEthernet0/2` (`192.168.5.1`) |

## Management and authentication

| Item | Configuration |
|------|----------------|
| Hostname | `Astraquasar` |
| User | `admin` privilege 15, `login local` on VTY |
| Enable | [REDACTED] |
| VTY | `transport input ssh`; `login local` ([REDACTED] type-7 password on line — not documented) |
| SSH | Version 2; pubkey for `admin` via `ip ssh pubkey-chain` ([REDACTED]) |
| HTTP(S) | Enabled (`ip http server`, `ip http secure-server`) for Web UI — prefer SSH |

## Hardware

- **WS-C3650-48PD** — 48× PoE GE + 2× GE + 2× 10G
- **Smart Licensing:** eval expired / unregistered (operational; register if Cisco support needed)

## Operational notes

- ace should stay on **Po1** for throughput; only one member was forwarding at documentation time — check LACP on ace if performance issues.
- Fetch fresh data: `ssh astraquasar` → `show interfaces status`, `show etherchannel summary`.
