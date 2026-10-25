# Configuration review (2026-10-24)

A review of ace's alerts, update automation, IDS and overall configuration, done after clearing the Grafana alerts that were firing that day. Like the [October security audit](./security-audit.md), it leaves out exploit detail because this repository is public.

## Alerts at the start of the day

| Alert | Cause | Outcome |
|---|---|---|
| Ace service major version behind: **nextcloud** (34.0.3 → 35.0.2) | Major release waiting for approval | **Fixed.** Upgraded to 35.0.2, with the whiteboard server 2.1.2 and ClamAV 1.5.4. See [Nextcloud](../ace/nextcloud.md). |
| Ace service major version behind: **jellyfin** (10.11.11 → 12.3) | Major release waiting for approval | **Held on 10.** The SSO plugin used for Zitadel login has no Jellyfin 12 build, and the 12.0 migration is one-way. The hold is in the update registry (`holdMajor`), so the alert and the approval mails stop. See [Jellyfin](../ace/jellyfin.md). |
| NixOS git config drift (ace) | The auto-updater had applied the pterodactyl-panel 1.15.2 pin and rebuilt but never committed it. There was also an uncommitted doc, and two local commits were unpushed | **Fixed.** Committed and pushed. The bump script now commits a pin that is already at the target. |
| Ace external probe cannot reach the WAN path (crux) | crux is behind the same NAT as ace and the router does not hairpin, so the external probe has never reached the WAN address (none in 30 days) | **Open.** Needs an off-site probe host, or NAT hairpinning on Astracap. |
| Suricata scan or exploit alert (repeating) | The local SYN-count rule counted 20 SYNs from one source to any port, so a busy internet client on 443 looked like a scan | **Fixed.** The rule now ignores 80/443, and paging is limited to severity 1–2. |

## IDS

- Suricata loaded **one** hand-written rule. The plan called for ET Open, which is now loaded: 52,888 rules enabled, 0 failed, refreshed daily by `suricata-update.timer` with a `suricata -T` check before reload. Memory use is about 0.7 GB.
- `eve.json` was never rotated and had reached **81 GB**. It now rotates daily, with 7 copies kept, compressed.
- AIDE re-baselined after the rebuild (activation script), git drift is 0, and the last AIDE check passed.
- Suricata sees only ace's own NIC (`bond0`), so traffic between other hosts is not inspected until a SPAN port feeds it. `HOME_NET` covers `192.168.5.0/24` only.

See [IDS test cases](security-ids-test-cases.md), TC-2.2.

## Health snapshot

| Check | Result |
|---|---|
| Failed systemd units | None |
| Prometheus targets | 45 of 45 up |
| TLS certificates (blackbox) | None expire within 21 days |
| Disk | `/` 45% (1.9 TB free), `/stor` 2% |
| Memory | 31 GiB, about 23 GiB available |
| Backups | restic snapshot taken before the upgrades. The nightly timer is healthy |
| Uptime | 19 days on kernel 7.2.9 |

## Findings

### Worth doing soon

1. **No off-site backup.** restic writes to `/stor` in the same chassis. This is already in the audit's *Planned* list, and it remains the biggest single risk.
2. **The external probe is blind.** The WAN-path alert reports that correctly, but nothing has checked public reachability from outside for at least 30 days. A small off-site VPS, or another network on the tailnet running `ace-external-probe-push`, would fix it without touching the router.
3. **Digest-pinned services report version "unknown".** Synapse (pinned v1.163.0, latest 1.163.2), the Grafana image renderer (v5.12.7, latest 5.12.9) and Pushgateway are pinned by digest, and `ace-version-check` reads versions from tags. Their lag never shows in Grafana. Read the version from a label, or keep the version in a nix variable next to the digest.
4. **Sidecar majors behind (not alerted):** MariaDB 12.3 → 13.0 (Nextcloud, Pterodactyl), Valkey 8.1 → 9.1 (Pterodactyl, MediaWiki). Minor: nextcloud-redis 8.8 → 8.10, Coolify 4.4.6 → 4.5.0, MediaWiki 1.45 → 1.46. Patch: Caddy 2.11.4 → 2.11.7 (comes with nixpkgs).
5. **nixpkgs is three weeks old** (2026-10-03). A routine `nix flake update nixpkgs` brings the kernel, Caddy and host packages up to date. Do it as its own change, with a rebuild and a reboot.

### Housekeeping

- `/etc/nixos` holds 27 git stashes, some from June. The updater's `--autostash` rebases add to them. Review them and drop the stale ones.
- Nextcloud: `digitalsignage` is disabled until it supports Nextcloud 35. `occ` reports old schema differences (`memories_*` indexes from the disabled Memories app, `oc_files_antivirus.fileid`, `oc_share_external.id`). The known `nextcloud-db` password mismatch from [Backups](../ace/backups.md) is still open.
- Grafana's `alert_instance` table holds stale rows from July. Use the UI or the state-history annotations for current alert state, not that table.
- Suricata logs a missing `threshold.config` warning. It is harmless, but an empty file would silence it.

### Still open from the security audit

Nothing on the audit's *Needs owner action* list was closed by this review: the Astraquasar IOS-XE upgrade, Astracap WAN-facing services, iDRAC hardening, rotation of the old secrets in git history, and switch management. VLAN segmentation and the edge router replacement remain planned.

## Changes made (branch `dell-poweredge-r730xd`)

| Commit | Change |
|---|---|
| `ace: bump pterodactyl-panel to 1.15.2` | Committed the pin that was already deployed |
| `docs: Loftia Community Wiki launch checklist` | Committed the untracked doc |
| `ace: bump nextcloud to 35.0.2, whiteboard server to 2.1.2, clamav to 1.5.4` | Nextcloud major upgrade |
| `suricata: load the ET Open ruleset, rotate eve.json` | IDS rules, rule tuning, alert severity gate, log rotation |
| `ace updates: declarative major holds; commit already-applied bumps` | `holdMajor` for Jellyfin, plus the bump-script fix |
| `docs: …` | These pages |
