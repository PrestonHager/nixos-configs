# Homelab network topology

End-to-end view of the **192.168.5.0/24** LAN: ISP edge through Astracap, Astraquasar, ace services (including Technitium DNS), PowerEdge OOB, and Pterodactyl nodes.

**Verified live** (Aug 2026): Astracap + Astraquasar SSH; crux on `Gi2/0/25`; **mars iDRAC** on `Gi2/0/48` (`192.168.5.11`). Other new hosts reserved but not yet cabled.

## Hosts, IPs, and where they are reachable from

| Host / device | IP | Switch port | LAN reachability | Internet / WAN | Notes |
|---------------|-----|-------------|------------------|----------------|-------|
| Astracap (router) | `192.168.5.1` | Astraquasar `Gi2/0/1` (uplink) | LAN SSH `astracap` (`prestonh`) | WAN on `Gi0/0` (DHCP `10.0.0.x`); management VTY is **LAN-only** (ACL 1) | Default gateway + DHCP |
| *(legacy name-server)* | `192.168.5.2` | — | **Down** (Aug 2026) | — | Still listed on router `ip name-server`; unused |
| Astraquasar (switch) | `192.168.5.3` | SVI VLAN 1 | LAN SSH `astraquasar` (`admin`) | No WAN publish | L2 only |
| **Unknown** (wireless) | `192.168.5.4` | via Astraspring `Gi2/0/2` | Pingable on LAN | PAT outbound only | MAC `94:83:c4:42:34:03`; **occupies reserved static range** — identify or reclaim before assigning `.4` |
| **ace** | `192.168.5.5` | `Po1` (`Gi2/0/13`–`16`) | Full LAN; SSH `ace` (root) | **WAN TCP 80/443** static NAT → ace; public name `ip1.lc1.nm.us.prestonhager.com` (`73.26.67.25`) | DNS, Caddy, monitoring, apps |
| **crux** | `192.168.5.6` | **`Gi2/0/25`** (MAC `b8:85:84:a8:6d:b4`) | LAN SSH `crux` (root); no WAN NAT | Outbound PAT only | Pterodactyl Wings; ports: [crux-ports.md](crux-ports.md) |
| **nova** | `192.168.5.7` | *unassigned / offline* | **Down** (Aug 2026) | No WAN NAT | Planned Wings node; reserve IP until reattached |
| **elara** | `192.168.5.8` | *unassigned* | **Not connected** | No WAN NAT | Dell OptiPlex — planned Wings node; [elara.md](elara.md) |
| **zenith** | `192.168.5.9` | *unassigned* | **Not connected** | No WAN NAT | Dell OptiPlex — planned Wings node; [zenith.md](zenith.md) |
| **ace iDRAC** | `192.168.5.10` | `Gi2/0/47` | LAN HTTPS/Redfish only (`https://192.168.5.10`) | No WAN publish | OOB; [ace-idrac.md](ace-idrac.md) |
| **mars iDRAC** | `192.168.5.11` | **`Gi2/0/48`** (MAC `d4:ae:52:92:c5:a2`) | LAN HTTPS (iDRAC 6 UI) | No WAN publish | PowerEdge R410 OOB — **online**; [mars-idrac.md](mars-idrac.md) |
| **sally iDRAC** | `192.168.5.12` | *unassigned* | **Not connected** | No WAN publish | PowerEdge R320 OOB; [sally-idrac.md](sally-idrac.md) |
| **mars** | `192.168.5.15` | *unassigned* | **Not connected** | No WAN NAT | PowerEdge R410 host OS; [mars.md](mars.md) |
| **sally** | `192.168.5.16` | *unassigned* | **Not connected** | No WAN NAT | PowerEdge R320 host OS; [sally.md](sally.md) |
| Astraspring AP | (bridged) | `Gi2/0/2` | Wi-Fi clients join same L2 LAN | Client traffic via Astracap PAT | Not a routed hop |
| DHCP clients | `192.168.5.21`–`.254` | AP and spare access ports | LAN only (unless you add NAT) | Outbound PAT | Active leases vary; see Astracap `show ip dhcp binding` |
| **ph-nixos** / admin PCs | DHCP or static in pool | — | LAN SSH to infra hosts | Outbound PAT | SSH aliases in home-manager |

### Access cheat-sheet

```text
Internet ──► ISP modem (10.0.0.1)
               │
               ▼
         Astracap Gi0/0 (WAN / NAT outside)
               │  static NAT :80/:443 ──► ace only
               │  PAT (all LAN outbound)
               ▼
         Astracap Gi0/2 192.168.5.1
               │
               ▼
         Astraquasar 192.168.5.3 (VLAN 1 flat L2)
           ├─ Po1        → ace            192.168.5.5    [LAN + WAN :80/:443]
           ├─ Gi2/0/47   → ace iDRAC      192.168.5.10   [LAN OOB only]
           ├─ Gi2/0/48   → mars iDRAC     192.168.5.11   [LAN OOB · online]
           ├─ Gi2/0/25   → crux           192.168.5.6    [LAN only]
           ├─ (none)     → nova           192.168.5.7    [offline]
           ├─ (none)     → elara          192.168.5.8    [reserved]
           ├─ (none)     → zenith         192.168.5.9    [reserved]
           ├─ (none)     → sally iDRAC    192.168.5.12   [reserved]
           ├─ (none)     → mars OS        192.168.5.15   [reserved]
           ├─ (none)     → sally OS       192.168.5.16   [reserved]
           ├─ Gi2/0/2    → Astraspring + Wi-Fi clients
           └─ DHCP .21+  → workstations / phones / etc.
```

**Rule of thumb when adding a device**

1. Pick a free IP in **`192.168.5.1`–`.20`** for infrastructure (static), or let DHCP assign **`.21`–`.254`**.
2. Document it in this table + [Astraquasar port table](network-astraquasar-switch.md) (and label the switch port).
3. WAN publish is **opt-in**: only ace has static NAT today. Anything else stays LAN-only unless you add NAT on Astracap.
4. Free / reclaim **`.2`** and **`.4`** (or confirm ownership) before reusing those addresses. Assigned reserved IPs: `.8` elara, `.9` zenith, `.11`/`.15` mars, `.12`/`.16` sally.

## Full topology

```mermaid
flowchart TB
  subgraph WAN["Internet"]
    Pub["ip1.lc1.nm.us.prestonhager.com<br/>73.26.67.25"]
  end

  subgraph Edge["Edge — Astracap 192.168.5.1"]
    Gi0["Gi0/0 DHCP WAN<br/>NAT outside"]
    Gi2["Gi0/2 LAN<br/>NAT inside + DHCP"]
  end

  subgraph LAN["LAN 192.168.5.0/24 — Astraquasar 192.168.5.3"]
    Ace["ace 192.168.5.5<br/>Po1 · DNS/Caddy/services<br/>LAN + WAN :80/:443"]
    AceId["ace iDRAC 192.168.5.10<br/>Gi2/0/47 · LAN OOB"]
    MarsId["mars iDRAC 192.168.5.11<br/>Gi2/0/48 · LAN OOB · online"]
    Mars["mars 192.168.5.15<br/>R410 · reserved"]
    SallyId["sally iDRAC 192.168.5.12<br/>R320 OOB · reserved"]
    Sally["sally 192.168.5.16<br/>R320 · reserved"]
    Crux["crux 192.168.5.6<br/>Gi2/0/25 · Wings"]
    Nova["nova 192.168.5.7<br/>offline · reserved"]
    Elara["elara 192.168.5.8<br/>OptiPlex Wings · reserved"]
    Zenith["zenith 192.168.5.9<br/>OptiPlex Wings · reserved"]
    AP["Astraspring AP<br/>Gi2/0/2"]
    Unk["unknown 192.168.5.4<br/>via AP · reclaim?"]
    WS["DHCP clients .21–.254"]
  end

  Modem["ISP modem 10.0.0.1"]

  Pub -.-> Modem
  Modem --> Gi0
  Gi0 --> Gi2
  Gi2 --> Ace
  Gi2 --> AceId
  Gi2 --> MarsId
  Gi2 --> Mars
  Gi2 --> SallyId
  Gi2 --> Sally
  Gi2 --> Crux
  Gi2 --> Nova
  Gi2 --> Elara
  Gi2 --> Zenith
  Gi2 --> AP
  AP --> Unk
  AP --> WS
  Gi0 -->|"static NAT TCP 80/443"| Ace
```

## Accessibility zones

```mermaid
flowchart LR
  subgraph PubZ["From Internet"]
    W80["TCP 80/443 → ace only"]
  end

  subgraph LanZ["From LAN 192.168.5.0/24"]
    L1["SSH: astracap / astraquasar / ace / crux"]
    L2["HTTPS apps via Caddy on ace"]
    L3["iDRAC: ace .10 · mars .11 · sally .12"]
    L4["Technitium DNS 192.168.5.5:53"]
  end

  subgraph OutZ["Outbound to Internet"]
    PAT["All LAN hosts via Astracap PAT"]
  end

  PubZ --> AceNode["ace 192.168.5.5"]
  LanZ --> AceNode
  LanZ --> CruxNode["crux 192.168.5.6"]
  LanZ --> IdNodes["iDRAC OOB hosts"]
  LanZ --> EdgeNode["Astracap / Astraquasar"]
  AceNode --> OutZ
  CruxNode --> OutZ
```

## DNS flow

Technitium on **ace** is primary LAN DNS (LanCache deprecated).

```mermaid
sequenceDiagram
  participant C as LAN client
  participant D as Astracap DHCP
  participant T as Technitium 192.168.5.5
  participant CF as Cloudflare 1.1.1.1

  C->>D: DHCP discover
  D->>C: Offer 192.168.5.x, router 192.168.5.1, DNS 192.168.5.5 + 1.1.1.1
  C->>T: Query internal / public names
  T->>CF: Recurse when not authoritative
  CF->>T: Response
  T->>C: Answer
```

Details: [DNS on ace](dns-ace.md).

## Addressing summary

| Address | Device / service |
|---------|------------------|
| `192.168.5.1` | Astracap — default gateway, DHCP server |
| `192.168.5.2` | Router `ip name-server` leftover — **host down** (Aug 2026) |
| `192.168.5.3` | Astraquasar — switch management |
| `192.168.5.4` | **Unidentified** wireless client (via AP) — reserved-range collision risk |
| `192.168.5.5` | ace — static; primary DNS, reverse proxy, monitoring |
| `192.168.5.6` | crux — static; Astraquasar **`Gi2/0/25`** |
| `192.168.5.7` | nova — static reserved; **offline** (Aug 2026) |
| `192.168.5.8` | elara — OptiPlex Wings; reserved / **not connected** |
| `192.168.5.9` | zenith — OptiPlex Wings; reserved / **not connected** |
| `192.168.5.10` | ace iDRAC — static OOB (`18:66:DA:82:52:D6`, Gi2/0/47); see [ace-idrac.md](ace-idrac.md) |
| `192.168.5.11` | mars iDRAC — R410 iDRAC 6 (`d4:ae:52:92:c5:a2`, Gi2/0/48); **online**; [mars-idrac.md](mars-idrac.md) |
| `192.168.5.12` | sally iDRAC — R320 OOB; reserved / **not connected**; [sally-idrac.md](sally-idrac.md) |
| `192.168.5.15` | mars — R410 host OS; reserved / **not connected**; [mars.md](mars.md) |
| `192.168.5.16` | sally — R320 host OS; reserved / **not connected**; [sally.md](sally.md) |
| `192.168.5.1`–`.20` | Static / infrastructure (DHCP excluded); pool floor **`.21`** |
| `192.168.5.21`–`.254` | DHCP pool (Astracap `LAN-Pool`) |
| `10.0.0.x` | WAN side DHCP on Astracap Gi0/0 |

## NAT / published services

| WAN (on Gi0/0) | Inside target | Purpose |
|----------------|---------------|---------|
| TCP 80 | `192.168.5.5:80` | HTTP to ace (Caddy / services) |
| TCP 443 | `192.168.5.5:443` | HTTPS to ace |
| Other outbound | PAT via Gi0/0 | All LAN hosts |

No static WAN NAT to Wings nodes or PowerEdge hosts as of Aug 2026. Crux listening ports and probe coverage: [crux-ports.md](crux-ports.md). Grafana: [Network Topology & Ports](https://grafana.prestonhager.com/d/network-topology).

## SSH and documentation index

| Topic | Document |
|-------|----------|
| SSH keys, Bitwarden, legacy KEX | [network-ssh-ace.md](network-ssh-ace.md) |
| Router config | [network-astracap-router.md](network-astracap-router.md) |
| Switch config | [network-astraquasar-switch.md](network-astraquasar-switch.md) |
| DNS | [dns-ace.md](dns-ace.md) |
| mars / sally OOB | [mars-idrac.md](mars-idrac.md), [sally-idrac.md](sally-idrac.md) |

## Workstation access

**ph-nixos** and other admin systems on LAN use the same gateway and DNS path; SSH aliases for infrastructure are defined in home-manager (`users/prestonh/programs/ssh.nix`).
