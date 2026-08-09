# Mars iDRAC (out-of-band)

Dell **iDRAC 6** on the PowerEdge **R410** (`mars`). LAN-only OOB management for power / console when the host OS is down or not yet installed.

## Addressing

| Field | Value |
|-------|-------|
| Hostname | `mars-idrac` (planned) |
| IPv4 | **`192.168.5.11/24`** static |
| Gateway | `192.168.5.1` (Astracap) |
| MAC | `d4:ae:52:92:c5:a2` |
| Chassis | Dell PowerEdge **R410** |
| Firmware family | **iDRAC 6** (legacy web UI / racadm; **no** modern Redfish like ace iDRAC 9) |
| Switch port | Astraquasar **`Gi2/0/48`** (`description Mars_iDRAC`) |
| Web UI | `https://192.168.5.11` (LAN only) |
| Credentials | Store in Vaultwarden when finalized (do not commit secrets) |

Host OS IP (not connected yet): **`192.168.5.15`** — see [mars](mars.md).

DHCP on Astracap excludes **`192.168.5.1`–`.20`**; `.11` is in the static infrastructure range.

## Status (Aug 2026)

| Interface | State |
|-----------|-------|
| iDRAC `192.168.5.11` | **Up** on LAN (`Gi2/0/48`) |
| Host OS `192.168.5.15` | Not connected / not online |

## Access notes (iDRAC 6)

- Prefer the browser UI at `https://192.168.5.11` from a LAN client (TLS certs on iDRAC 6 are often self-signed).
- Virtual console may require a Java / ActiveX-era client depending on firmware — expect older tooling than ace’s HTML5 iDRAC.
- Power actions: use the iDRAC **Power** / **Server** menus (or `racadm` if installed), not Redfish `ForceRestart` as documented for [ace iDRAC](ace-idrac.md).

## Related docs

- [mars](mars.md) — host OS IP and role
- [Network topology](network-topology.md)
- [Astraquasar switch](network-astraquasar-switch.md) — port 48
