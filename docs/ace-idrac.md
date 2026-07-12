# Ace iDRAC (out-of-band)

Dell **iDRAC** on the PowerEdge R730xd (`ace`). Used when the OS is hung (SSH accepts TCP but never sends a banner) and needs a remote power reset.

## Addressing

| Field | Value |
|-------|-------|
| Hostname | `ace-idrac` |
| IPv4 | **`192.168.5.10/24`** static |
| Gateway | `192.168.5.1` (Astracap) |
| MAC | `18:66:DA:82:52:D6` |
| Chassis SKU / service tag (Redfish) | `3F3FHB2` |
| Switch port | Astraquasar **`Gi2/0/47`** (access VLAN 1, portfast, no port-security) |
| Web / Redfish | `https://192.168.5.10` |
| Credentials | Vaultwarden item **`iDRAC`** (username `root`) — see [Network & SSH / Bitwarden](network-ssh-ace.md) |

DHCP on Astracap excludes **`192.168.5.1`–`.20`**; the dynamic pool starts at **`.21`**. `.10` is in the static infrastructure range and is reserved for this iDRAC.

Previously the iDRAC used static **`192.168.8.120`** (GL.iNet-era subnet) while the cable was already on VLAN 1 — that made it unreachable without a temporary `192.168.8.50/24` alias on a LAN host (e.g. crux). That IP is obsolete.

## Reset ace when hung (Redfish)

Prefer graceful if the firmware exposes it; this iDRAC’s allowable reset types include **`ForceRestart`** (no `GracefulRestart`). When userspace is wedged, use ForceRestart:

```bash
# From any host on 192.168.5.0/24 — password from Vaultwarden item "iDRAC"
curl -sk -u "root:${IDRAC_PASS}" \
  -X POST 'https://192.168.5.10/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset' \
  -H 'Content-Type: application/json' \
  -d '{"ResetType":"ForceRestart"}'
# Expect HTTP 204
```

Wait for SSH on `192.168.5.5` (typically a few minutes after power cycle). Do not start heavy `nixos-rebuild` jobs until the host is confirmed responsive.

Power state / identity check:

```bash
curl -sk -u "root:${IDRAC_PASS}" \
  'https://192.168.5.10/redfish/v1/Systems/System.Embedded.1' \
  | grep -E 'PowerState|Model|SerialNumber|SKU'
```

NIC path (for IP changes):

`/redfish/v1/Managers/iDRAC.Embedded.1/EthernetInterfaces/iDRAC.Embedded.1%23NIC.1`

## Related docs

- [Astraquasar switch](network-astraquasar-switch.md) — port 47
- [Astracap router](network-astracap-router.md) — DHCP exclusions / pool floor
- [Network topology](network-topology.md) — addressing summary
