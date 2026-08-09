# Sally (PowerEdge R320)

Dell PowerEdge **R320** host. Paired with a dedicated iDRAC OOB interface.

| Field | Value |
|-------|-------|
| Hostname | `sally` (planned) |
| Host OS IPv4 | **`192.168.5.16/24`** static (reserved; **not connected yet**) |
| iDRAC IPv4 | **`192.168.5.12/24`** — [sally iDRAC](sally-idrac.md) |
| Gateway | `192.168.5.1` |
| Hardware | Dell PowerEdge R320 |
| Role | TBD (OS / flake not deployed yet) |
| WAN | None — LAN / outbound PAT only unless Astracap NAT is added |

## Status (Aug 2026)

| Path | State |
|------|-------|
| iDRAC | Not connected |
| Host NIC / OS | Not connected |

When cabling, label Astraquasar ports (e.g. `Sally_iDRAC` / `Sally`) and update [network-astraquasar-switch.md](network-astraquasar-switch.md) + [network-topology.md](network-topology.md).
