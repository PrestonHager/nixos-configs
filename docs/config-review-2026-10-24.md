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
3. ~~**Digest-pinned services report version "unknown".**~~ **Fixed in the follow-up:** every container reports a version. See below.
4. ~~**Services behind.**~~ **Fixed in the follow-up:** every update within the running release series is applied. The remaining majors are listed below with the reason each is not taken.
5. ~~**nixpkgs is three weeks old.**~~ **Fixed in the follow-up:** nixpkgs is at 2026-10-23 and now updates nightly.

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

## Follow-up: version tracking, updates and nightly nixpkgs (same day)

### Every service reports its version

`ace-version-check` now tracks all **34** containers on ace, none unknown. The sidecar databases and caches, zitadel-login and animal-search's Node are new. Digest-pinned images are read from the image: Synapse's OCI label, the renderer's commit mapped to its release tag, Pushgateway's `--version`, and the `PG_VERSION`/`MARIADB_VERSION`/`VALKEY_VERSION`/`REDIS_VERSION`/`NODE_VERSION` variables of official images. A stopped container reports unknown instead of a guessed version.

Each service has a second lag, `ace_service_version_behind_in_series`: the newest release in its running series (major, or major.minor for MariaDB and MediaWiki). That is what can be taken without a major upgrade. The patch/minor alert and auto-update use it, so held and major-behind services still get their safe updates. See [Monitoring](../ace/monitoring.md).

### Updates applied (release notes checked for each)

| Service | From → to | Notes |
|---|---|---|
| Matrix Synapse | 1.163.0 → 1.163.2 | Dependency security bumps |
| Coolify | 4.4.6 → 4.5.0 | Additive migrations; nothing coolify-edge queries changes; the API-token changes affect nothing configured here |
| Grafana image renderer | 5.12.7 → 5.12.9 | Go and Chromium |
| Postgres (Matrix, Zitadel) | 16.14 → 16.15 | Security fixes, no dump/restore. Only `plpgsql` is installed, so the pgcrypto/btree_gist/ltree notes do not apply |
| MariaDB (Nextcloud, Pterodactyl) | 12.3.2 → 12.3.3 | Maintenance |
| MariaDB (MediaWiki, animal-search, test panel) | 11.4.12 → 11.4.13 | Maintenance |
| Redis (Nextcloud) | 8.8.0 → 8.10.2 | New commands, security fixes |
| Node (animal-search) | 22.23.3 → 22.23.4 | Patch |
| MediaWiki | 1.45.3 → 1.45.6 | Nine CVEs fixed in 1.45.5. `/mw/html` was 1.45.3 core over a 1.44 tree (1.44-era bundled extensions and resources, a hand-edited 1.44 `Resources.php`). It is replaced with a clean, signed tarball plus the settings files, eight non-bundled extensions, the Citizen and Loftia skins and the logo assets. Smoke-tested against the live database first; `update.php` ran clean. The old tree is at `/mw/html.bak-1.45.3`, and a tarball of it and a DB dump are in `/stor/backup` |
| nixpkgs | 2026-10-03 → 2026-10-23 | Kernel 7.3, systemd 262, Caddy 2.11.7, OpenSSH 10.6p1, OpenSSL 3.5.9, Podman 5.8.9. The Caddy plugin vendor hash was re-pinned after two fetches agreed. `sambaFull` is built without CephFS because ceph 20.2.4 fails to build at this revision |

### Majors not taken, and why

| Service | Running → latest | Why not |
|---|---|---|
| Jellyfin | 10.11.11 → 12.3 | Held: no SSO plugin build for 12, and the migration is one-way |
| MariaDB (all six) | 11.4 / 12.3 → 13.0 | 11.4 and 12.3 are LTS series with fixes for years. Moving series is an in-place data upgrade that cannot be undone without a restore |
| Postgres (Matrix, Zitadel, Coolify) | 15 / 16 → 18 | Needs `pg_upgrade` or a dump and restore |
| Valkey (Pterodactyl, MediaWiki, test panel) | 8.1 → 9.1 | Writes a newer RDB format that 8.x cannot read back. Plan it with the apps |
| Redis (Coolify) | 7.4 → 8.10 | Coolify ships 7.4. Follow Coolify's own pin |
| Node (animal-search) | 22 → 26 | The app's runtime. Its CI should move first |
| MediaWiki | 1.45 → 1.46 | Needs REL1_46 branches of Wikibase and the other non-bundled extensions, and the wiki launches on 2026-11-03 |

### Nightly nixpkgs updates

`ace-nixpkgs-update.timer` updates the nixpkgs input every night at 04:30. It builds first, then switches, rolls back if units fail or ace loses its default route or internet, then commits and pushes `flake.lock`. Failures send email and fire **Ace nightly nixpkgs update failed**. A nixpkgs revision older than 4 days fires **Ace nixpkgs input stale**. See [Monitoring](../ace/monitoring.md).

### Outage during the nixpkgs switch (19:28 to about 20:08)

**What happened.** The switch to the new nixpkgs restarted `bond0-netdev`, which deletes and recreates the bond, plus the bond and NIC address units. It did not restart `network-setup`, which owns the default route. ace was left without a default route, so it was unreachable from other subnets and the internet. Units that needed the internet (Blueprint installs, Packagist) timed out, and the switch took 17 minutes. The host was hard-reset at about 20:07 and booted the new generation (kernel 7.3).

**Second problem, at boot.** ace-version-check ran before the Pterodactyl container was up, and `current_pterodactyl` fell back to a hard-coded "1.11.11". Auto-update then "bumped" the panel to the pin it already had, and the bump script's already-at-target path ran `nixos-rebuild switch` 40 seconds into boot. Units not yet started (Zitadel, Nextcloud, Grafana) were left inactive until started by hand.

**Fixes (deployed):**

- The bond, the address units and `network-setup` no longer restart on switch. Their changes apply at the next boot.
- The nightly updater rolls back if there is no default route or no internet after a switch.
- A stopped container reports an unknown version, not a guess. Already-at-target-and-committed bumps do nothing instead of rebuilding.
- The nightly timer is not `Persistent`, so a missed run never fires during boot or mid-switch. The first activation had fired it during the switch at 19:28:46. It waited on the rebuild lock and did nothing.
- Podman 5.8.9 moved pod host entries to `.InfraConfig.HostAdd`, so the Grafana and Zitadel pod scripts were recreating their pods on every start. Fixed.

After recovery: no failed units, all public endpoints 200, all 34 services current within their series.
