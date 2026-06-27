# Astraquasar port shutdown playbook (Phase 3 — manual)

Use when an internal host (crux/nova) is confirmed compromised and must be isolated at L2.

## Prerequisites

- SSH to switch: `ssh astraquasar` (see `docs/network-ssh-ace.md`)
- Vaultwarden **Astracap Router Info** for enable password if needed
- Identify target port from `docs/network-astraquasar-switch.md` port table

## Steps

1. **Confirm** alert via Grafana Security folder + Loki (`{job="suricata"}` or host logs).
2. **Identify** switch port (e.g. server uplink for crux/nova).
3. **Notify** — stop Wings on affected node: `systemctl stop wings` (from node or SSH).
4. **Shutdown port** (IOS-XE):

   ```
   configure terminal
   interface GigabitEthernetX/Y/Z
    shutdown
   end
   write memory
   ```

5. **Verify** — port `show interfaces status` shows `disabled`; node unreachable from LAN except console/iDRAC.
6. **Recovery** — malware scan, `nixos-rebuild switch`, then `no shutdown` on interface.

## Rollback

```
configure terminal
interface GigabitEthernetX/Y/Z
 no shutdown
end
```

Document port name and time in private incident log.

Test case: **TC-3.4** in `docs/security-ids-test-cases.md`.
