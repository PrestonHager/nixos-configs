# Homelab IDS — Test Cases

**Status:** Active (tracks implementation in `nixos/security/` and `nixos/monitoring/`)  
**Plan:** [`security-ids-plan.md`](security-ids-plan.md)  
**Branch:** `dell-poweredge-r730xd`

Naming: **TC-1.N** = Phase 1 item N, **TC-2.N** = Phase 2, **TC-3.N** = Phase 3.

---

## Phase 1 — Audit, logging, baselines

### TC-1.1 — auditd and fail2ban auth logging

**Setup**

- Deploy `homelab.security.enable = true` on ace, crux, nova (`nixos/security/audit.nix`, `fail2ban.nix`).
- Confirm SSH reachable on each host.

**Execution**

```bash
# On each host
systemctl is-active auditd fail2ban sshd
auditctl -l | grep -E 'nixos-config|root-exec'
# Trigger a failed SSH login (wrong key/user from a test client)
ssh -o BatchMode=yes baduser@192.168.5.5 exit || true
journalctl -u sshd -u fail2ban --since "5 min ago" --no-pager | tail -20
```

**Troubleshooting**

| Symptom | Fix |
|---------|-----|
| `auditd` inactive | `journalctl -u auditd`; check `security.audit.enable` in rebuild |
| No failed-login lines | Verify test used password/disallowed user; keys-only may not log "Failed password" |
| fail2ban not banning WAN IP | LAN `192.168.5.0/24` is in `ignoreIP` by design — test from outside LAN or temporarily remove ignore for drill |

**Deliverables**

- journal entries with `sshd` / `fail2ban` units
- `auditctl -l` lists `nixos-config`, `root-exec`, `identity` rules
- Promtail ships `{job="systemd-journal", host="<hostname>"}` to Loki (after TC-1.5)

**Interpretation**

- **Pass:** Failed auth attempt visible in journal within 1 minute; audit rules loaded.
- **Fail:** No auth events or auditd failed to start.

---

### TC-1.2 — Cisco syslog to ace

**Setup**

- ace: `rsyslog` receives UDP 514 (`nixos/security/cisco-syslog.nix`).
- On **Astracap** and **Astraquasar** (one-time IOS config — see [Cisco integration](#cisco-integration-phase-12)):

  ```
  logging host 192.168.5.5
  logging trap informational
  login on-failure log
  ```

- Save config (`write memory` / `copy run start`).

**Execution**

```bash
# From operator workstation — generate login failure or config log
ssh astracap "show logging last 5"
# On ace
sudo tail -20 /var/log/cisco-syslog/cisco.log
# In Grafana → Explore → Loki
# Query: {job="cisco-syslog"}
```

**Troubleshooting**

| Symptom | Fix |
|---------|-----|
| Empty `/var/log/cisco-syslog/cisco.log` | Verify UDP 514 open on ace; `sudo ss -ulnp \| grep 514`; check router `show logging` for 192.168.5.5 |
| Logs on router but not ace | ACL blocking UDP/514; confirm source IP 192.168.5.1 or .3 |
| rsyslog not writing | `journalctl -u rsyslog`; validate `$fromhost-ip` in `cisco-syslog.nix` |

**Deliverables**

- Lines in `/var/log/cisco-syslog/cisco.log` with router/switch timestamps
- Loki query `{job="cisco-syslog"}` returns events

**Interpretation**

- **Pass:** Cisco login or system messages appear on ace within 60 seconds of generating activity.
- **Fail:** No file growth after confirmed `logging host` on both devices.

---

### TC-1.3 — Cisco running-config backup and diff

**Setup**

- Add sops secrets in `nixos-secrets` (`secrets/cisco.yaml`):

  ```yaml
  cisco-ssh-key: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    ...
    -----END OPENSSH PRIVATE KEY-----
  cisco-enable-password: "<enable secret>"
  ```

- Rebuild ace with `homelab.security.cisco.enable = true`.
- SSH public key must be authorized on Astracap (`prestonh`) and Astraquasar (`admin`).

**Execution**

```bash
# On ace
systemctl start cisco-config-backup.service
ls -la /var/lib/cisco-config-backup/astracap/
ls -la /var/lib/cisco-config-backup/astraquasar/
cat /var/lib/node-exporter-textfile/homelab_cisco_config_drift.prom
# Optional: make a trivial IOS change, re-run timer, confirm drift metric = 1
```

**Troubleshooting**

| Symptom | Fix |
|---------|-----|
| SSH permission denied | Deploy `id_rsa_astracap` public key to devices; see `docs/network-ssh-ace.md` |
| Enable failed | Verify sops `cisco-enable-password` matches Vaultwarden **Astracap Router Info** |
| Timer not running | `systemctl list-timers \| grep cisco-config` |

**Deliverables**

- `running-config-latest.txt` per device under `/var/lib/cisco-config-backup/`
- Prometheus metric `homelab_cisco_config_drift` (0 = unchanged, 1 = diff detected)

**Interpretation**

- **Pass:** Both devices backed up successfully; drift 0 on steady state.
- **Fail:** Missing files or non-zero exit from `cisco-config-backup.service`.

---

### TC-1.4 — Git drift check on `/etc/nixos`

**Setup**

- Timer `homelab-git-drift` on all hosts (`nixos/security/git-drift.nix`).
- `/etc/nixos` is a git checkout tracking `origin/dell-poweredge-r730xd`.

**Execution**

```bash
systemctl start homelab-git-drift.service
cat /var/lib/node-exporter-textfile/homelab_git_drift.prom
# Controlled drift test (revert after):
sudo touch /etc/nixos/.drift-test && systemctl start homelab-git-drift.service
cat /var/lib/node-exporter-textfile/homelab_git_drift.prom
sudo rm /etc/nixos/.drift-test
```

**Troubleshooting**

| Symptom | Fix |
|---------|-----|
| `homelab_git_drift{reason="no_git"}` | Initialize git remote on host or clone flake to `/etc/nixos` |
| Fetch fails | Ensure ace can reach GitHub; HTTPS remote configured |
| Metric missing on crux/nova | Confirm `node_exporter` textfile collector (TC-1.4 node metrics module) |

**Deliverables**

- Textfile metrics: `homelab_git_drift`, `homelab_git_dirty`, `homelab_git_ahead`, `homelab_git_behind`
- Journal: `logger -t homelab-git-drift` on drift

**Interpretation**

- **Pass:** `homelab_git_drift 0` when tree clean; `1` after test touch file.
- **Fail:** Timer errors or metric absent after 1 hour.

---

### TC-1.5 — Loki + Promtail central logging

**Setup**

- ace: Loki on `:3100`, Grafana Alloy log shipper enabled (`nixos/monitoring/loki.nix`, `promtail.nix` — Alloy replaces deprecated Promtail).
- crux/nova: Alloy → `http://192.168.5.5:3100`.
- Grafana Loki datasource provisioned (`nixos/monitoring/grafana-security-alerting.nix`).

**Execution**

```bash
# ace
systemctl is-active loki alloy
curl -sf http://127.0.0.1:3100/ready
# crux or nova
systemctl is-active alloy
curl -sf http://192.168.5.5:3100/ready
# Grafana → Explore → Loki
# {host="crux"} |= "systemd"
# {host="ace", job="systemd-journal"} |= "sshd"
```

**Troubleshooting**

| Symptom | Fix |
|---------|-----|
| Promtail cannot push | Alloy cannot push — ace firewall allows 3100 from .6/.7; `journalctl -u alloy` |
| Grafana no Loki DS | Phase 2 must be enabled on ace for datasource provisioning |

**Deliverables**

- Loki `/ready` returns 200
- Multi-host labels in Grafana Explore

**Interpretation**

- **Pass:** Logs from ace + at least one node searchable within 2 minutes of generation.
- **Fail:** Single-host only or Promtail restart loop.

---

## Phase 2 — Detection rules

### TC-2.1 — AIDE file integrity

**Setup**

- `homelab.security.phase2.enable = true` on all hosts.
- Run `nixos-rebuild switch` to init AIDE DB (`services.aide`).

**Execution**

```bash
systemctl is-active aidecheck.timer
systemctl start aidecheck.service
journalctl -u aidecheck --since "10 min ago"
# Controlled change (revert after):
sudo touch /etc/aide-test && systemctl start aidecheck.service
```

**Troubleshooting**

| Symptom | Fix |
|---------|-----|
| AIDE init failed | `journalctl -u aideinit`; ensure `/var/lib/aide` writable |
| Too many false positives | Exclude volatile paths in `nixos/security/aide.nix` rules |

**Deliverables**

- `aidecheck.service` exit code non-zero on tamper
- Journal entries from `aidecheck`

**Interpretation**

- **Pass:** Baseline check succeeds; test file triggers mismatch.
- **Fail:** Timer inactive or DB never initialized post-rebuild.

---

### TC-2.2 — Suricata network IDS (ace)

**Setup**

- ace: `homelab.security.suricata.enable = true` (`nixos/monitoring/suricata.nix`).
- IDS listens on `bond0` (SPAN optional later — see plan §4.3).

**Execution**

```bash
systemctl is-active suricata
sudo tail -5 /var/log/suricata/eve.json
# From LAN client (controlled scan):
nmap -sS -T4 192.168.5.5
# Loki: {job="suricata"} | json | event_type="alert"
```

**Troubleshooting**

| Symptom | Fix |
|---------|-----|
| suricata won't start | `journalctl -u suricata`; verify `CAP_NET_RAW`; interface name |
| No alerts on nmap | Tune local.rules threshold; confirm EVE `alert` type enabled |
| High CPU | Reduce `detect-engine profile`; defer SPAN until hardware validated |

**Deliverables**

- EVE JSON lines with `"event_type":"alert"`
- Loki Suricata stream

**Interpretation**

- **Pass:** SYN scan from LAN produces alert within 5 minutes (Phase 2 exit criteria).
- **Fail:** No alerts after repeated scan and suricata running.

---

### TC-2.3 — Grafana Security alert rules

**Setup**

- ace Phase 2 enabled; Loki + Prometheus datasources provisioned.
- Alert rules in `nixos/monitoring/grafana/provisioning/alerting/security-alert-rules.yaml`.

**Execution**

```bash
# Provoke SSH failure burst (TC-1.1) or git drift (TC-1.4)
# Grafana → Alerting → Alert rules → folder **Security**
# Confirm rules: SSH auth failure burst, Git drift, Cisco config drift, Suricata alert
```

**Troubleshooting**

| Symptom | Fix |
|---------|-----|
| Rules missing | Rebuild ace; check `/etc/grafana/provisioning/alerting/security-alert-rules.yaml` in container mount |
| `loki` datasource error | `curl http://127.0.0.1:3100/ready`; datasource UID must be `loki` |
| No email | Same SMTP path as `docs/monitoring-ace.md`; test `ace-email` contact point |

**Deliverables**

- Alert state **Firing** in Security folder
- Email to `GRAFANA_ALERT_EMAILS` for warning/critical rules

**Interpretation**

- **Pass:** Controlled test fires alert within 5 minutes, email received.
- **Fail:** Rule error or permanent `No Data` with healthy backends.

---

### TC-2.4 — Technitium DNS query review

**Setup**

- Technitium logs under `/stor/technitium/logs/` (Promtail job `technitium-dns` on ace).
- Query logging enabled in Technitium admin (Settings → Logs).

**Execution**

```bash
# Generate DNS query
dig @192.168.5.5 test.internal.prestonhager.com
# Loki
# {job="technitium-dns"} |= "test.internal"
# Review blocked/suspicious domains in Technitium admin → Logs
```

**Troubleshooting**

| Symptom | Fix |
|---------|-----|
| No technitium logs in Loki | Confirm log path glob; promtail read permissions on `/stor/technitium/logs` |
| Log volume too high | Filter in Grafana; adjust Technitium log level |

**Deliverables**

- Loki lines for test `dig` query
- Admin UI query log entry

**Interpretation**

- **Pass:** Query visible in Loki and Technitium UI within 2 minutes.
- **Fail:** DNS works but no log ship.

---

### TC-2.5 — Cisco config drift alert (Grafana)

**Setup**

- TC-1.3 backups running; Grafana rule `sec_cisco_config_drift`.

**Execution**

```bash
# After intentional trivial IOS change (revert after):
systemctl start cisco-config-backup.service
curl -s http://127.0.0.1:9100/metrics | grep homelab_cisco_config_drift
# Grafana → Security → Cisco running-config changed
```

**Troubleshooting**

| Symptom | Fix |
|---------|-----|
| Metric stuck at 0 | Backup diff runs only when previous `latest` exists; run twice |
| Alert flapping | Document expected changes; reset by copying latest to previous after authorized change |

**Deliverables**

- `homelab_cisco_config_drift 1`
- Grafana alert notification

**Interpretation**

- **Pass:** Unauthorized config change triggers alert.
- **Fail:** Diff detected in files but metric/alert unchanged.

---

## Phase 3 — Response stubs (manual / tabletop)

### TC-3.1 — fail2ban persistent ban (stub)

**Setup**

- Review `ignoreIP` whitelist in `fail2ban.nix`.
- Phase 3 full auto-ban **not** enabled — document max bantime.

**Execution**

Tabletop: simulate repeated WAN SSH failures; verify fail2ban ban; confirm operator LAN IP still reachable.

**Troubleshooting**

- Operator locked out: serial/iDRAC; `fail2ban-client unban <ip>`.

**Deliverables**

- `fail2ban-client status sshd` shows ban
- Playbook notes in `docs/security-ids-plan.md` §6

**Interpretation**

- **Pass:** WAN attacker banned; LAN operator unaffected.
- **Fail:** Whitelist misconfigured blocking legitimate response.

---

### TC-3.2 — Technitium blocklist API (stub)

**Setup**

- Script: `/etc/homelab-security/response/block-ip-technitium.sh`
- `TECHNITIUM_API_TOKEN` from sops (not in git) — set at runtime only.

**Execution**

```bash
sudo TECHNITIUM_API_TOKEN="<from sops>" \
  /etc/homelab-security/response/block-ip-technitium.sh 203.0.113.99 "tabletop test"
```

**Troubleshooting**

| Symptom | Fix |
|---------|-----|
| API 401 | Regenerate Technitium API token in admin |
| LAN IP blocked | Script should refuse RFC1918 — use WAN test IP only |

**Deliverables**

- Blocklist entry in Technitium admin
- `logger -t homelab-response` entry

**Interpretation**

- **Pass:** WAN test IP blocked in DNS; revert entry after test.
- **Fail:** API error or LAN block attempted.

---

### TC-3.3 — nftables drop stub (ace)

**Setup**

- Script: `/etc/homelab-security/response/block-ip-nftables.sh`

**Execution**

```bash
sudo /etc/homelab-security/response/block-ip-nftables.sh 203.0.113.99
sudo nft list table inet homelab_block
# Cleanup: sudo nft delete table inet homelab_block
```

**Troubleshooting**

- Refuses LAN IPs by design — use documentation test IP.

**Deliverables**

- nftables rule with counter increment under test traffic

**Interpretation**

- **Pass:** Rule created; LAN IP rejected by script.
- **Fail:** Table creation error.

---

### TC-3.4 — Switch port shutdown playbook

**Setup**

- Read `/etc/homelab-security/response/port-shutdown-playbook.md`

**Execution**

Tabletop walkthrough: identify port, `shutdown`, verify isolation, rollback `no shutdown` — **do not run on production without maintenance window**.

**Deliverables**

- Completed checklist in private incident log

**Interpretation**

- **Pass:** Operator can articulate steps and rollback without prompt.
- **Fail:** Missing port map — update `docs/network-astraquasar-switch.md`.

---

### TC-3.5 — Wings node isolation (stub)

**Setup**

- Pterodactyl panel access; `wings.service` on crux/nova.

**Execution**

Tabletop: stop wings → panel suspend → optional TC-3.4 port shutdown.

**Deliverables**

- Panel shows node offline; ace panel API unreachable from node

**Interpretation**

- **Pass:** Multi-step isolation understood and ordered correctly.
- **Fail:** ace still accepts Wings traffic after supposed isolation.

---

## Cisco integration (Phase 1–2)

One-time configuration on network devices (not NixOS-managed). Reference: `docs/network-astracap-router.md`, `docs/network-astraquasar-switch.md`, `docs/network-ssh-ace.md`.

### Astracap (192.168.5.1)

```
configure terminal
logging host 192.168.5.5
logging trap informational
login on-failure log
archive
 log config
  logging enable
  notify syslog contenttype plaintext
  hidekeys
end
write memory
```

### Astraquasar (192.168.5.3)

```
configure terminal
logging host 192.168.5.5
logging trap informational
login on-failure log
end
write memory
```

### SPAN (Phase 2 optional)

When ace has a dedicated IDS NIC, add monitor session on Astraquasar sourcing server ports + uplink — see plan §4.3. Validate switch CPU before permanent enable.

---

## Maintenance cadence

| Test | Frequency |
|------|-----------|
| TC-1.1, TC-1.5 | Monthly |
| TC-2.2, TC-2.3 | Quarterly (tabletop + nmap) |
| TC-1.3, TC-2.5 | After any Cisco change |
| TC-3.x | Annual tabletop |

Cross-check service availability with `docs/ace-health-report.md`.
