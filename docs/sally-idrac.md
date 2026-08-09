# Sally iDRAC (out-of-band)

Dell **iDRAC** on the PowerEdge **R320** (`sally`). Planned LAN-only OOB management.

## Addressing

| Field | Value |
|-------|-------|
| Hostname | `sally-idrac` (planned) |
| IPv4 | **`192.168.5.12/24`** static (reserved) |
| Gateway | `192.168.5.1` (Astracap) |
| Chassis | Dell PowerEdge **R320** |
| Switch port | *unassigned* — label when cabled |
| Web UI | `https://192.168.5.12` (planned; LAN only) |
| Credentials | Store in Vaultwarden when finalized |

Host OS IP (not connected yet): **`192.168.5.16`** — see [sally](sally.md).

## Status (Aug 2026)

| Interface | State |
|-----------|-------|
| iDRAC `192.168.5.12` | **Not connected** |
| Host OS `192.168.5.16` | **Not connected** |

## Related docs

- [sally](sally.md)
- [Network topology](network-topology.md)
- [Astraquasar switch](network-astraquasar-switch.md)
