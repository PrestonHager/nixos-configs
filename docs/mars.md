# Mars (PowerEdge R410)

Dell PowerEdge **R410** host. Paired with a dedicated iDRAC 6 OOB interface.

| Field | Value |
|-------|-------|
| Hostname | `mars` (planned) |
| Host OS IPv4 | **`192.168.5.15/24`** static (reserved; **not connected yet**) |
| iDRAC IPv4 | **`192.168.5.11/24`** — [mars iDRAC](mars-idrac.md) |
| Gateway | `192.168.5.1` |
| Hardware | Dell PowerEdge R410 |
| Role | TBD (OS / flake not deployed yet) |
| WAN | None — LAN / outbound PAT only unless Astracap NAT is added |

## Status (Aug 2026)

| Path | State |
|------|-------|
| iDRAC | Online — `https://192.168.5.11`, switch **`Gi2/0/48`** |
| Host NIC / OS | Not connected |

When cabling the host NIC, pick a free Astraquasar access port, set `description Mars`, and update [network-astraquasar-switch.md](network-astraquasar-switch.md) + [network-topology.md](network-topology.md).
