# Monitoring on ace (Grafana + Prometheus)

Implementation: `nixos/containers/grafana.nix`, `nixos/containers/prometheus.nix`, Caddy vhosts in `nixos/caddy/grafana.nix` and `nixos/caddy/prometheus.nix`, OAuth secrets in `nixos-secrets/secrets/containers/grafana-oauth.yaml`.

## Grafana

| Field | Value |
|-------|-------|
| URL | https://grafana.prestonhager.com |
| Auth | Zitadel OIDC (Generic OAuth); local login form remains enabled for break-glass |
| Secrets | `grafana-oauth-env` in sops (`grafana-oauth.yaml`) |
| Image export | Remote `grafana-image-renderer` sidecar in `grafana-pod` (not the deprecated plugin) |

### Dashboard image export (PNG / PDF)

Grafana 13+ no longer supports the in-process image renderer plugin. ace runs the official remote renderer (`grafana/grafana-image-renderer` v5.12.7, pinned by digest in `grafana.nix`) in the same Podman pod as Grafana so both reach each other on loopback.

| Component | URL / port |
|-----------|------------|
| Renderer (Grafana → renderer) | `http://127.0.0.1:8081/render` |
| Callback (renderer → Grafana) | `http://127.0.0.1:3000/` |
| Public UI (Caddy) | `https://grafana.prestonhager.com` → host `8082` |

**Export in the UI:** open a dashboard → **Share** (top right) → **Export** tab → choose **Save as PNG** or **Save as PDF**.

**Verify after deploy:**

```bash
systemctl is-active podman-grafana podman-grafana-image-renderer
curl -sf http://127.0.0.1:8082/api/health
podman exec grafana-image-renderer wget -qO- http://127.0.0.1:8081/metrics | head -1
```

Renderer port 8081 is pod-internal only (host `8081` is Vaultwarden).

### Grafana Admin via Zitadel OAuth

OAuth users are **not** Grafana server admins unless `role_attribute_path` maps their OIDC claims to `GrafanaAdmin` and `GF_AUTH_GENERIC_OAUTH_ALLOW_ASSIGN_GRAFANA_ADMIN=true`.

Current mapping (in sops):

- Zitadel project role `grafana_admin` (in userinfo claim `urn:zitadel:iam:org:project:roles`) → `GrafanaAdmin`
- Everyone else → org `Viewer`

Required sops env vars (`secrets/containers/grafana-oauth.yaml`):

```bash
GF_AUTH_GENERIC_OAUTH_ALLOW_ASSIGN_GRAFANA_ADMIN=true
GF_AUTH_GENERIC_OAUTH_SKIP_ORG_ROLE_SYNC=false
GF_AUTH_GENERIC_OAUTH_EMAIL_ATTRIBUTE_PATH=email
GF_AUTH_GENERIC_OAUTH_SCOPES=openid profile email urn:zitadel:iam:org:project:roles urn:zitadel:iam:org:project:id:376196450586990901:aud
GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH=contains(keys("urn:zitadel:iam:org:project:roles"), 'grafana_admin') && 'GrafanaAdmin' || 'Viewer'
```

Zitadel emits project roles as an object keyed by role name, for example:

```json
"urn:zitadel:iam:org:project:roles": {
  "grafana_admin": { "376196450586990901": "prestonhager.com" }
}
```

Grafana evaluates JMESPath against userinfo; `contains(keys("urn:zitadel:iam:org:project:roles"), 'grafana_admin')` checks for the role key.

Zitadel setup (Home Lab project):

1. Create project role `grafana_admin` (Roles tab).
2. Assign the role to users under **Authorizations**.
3. In the Grafana OIDC application, enable **Assert Roles on Authentication** (access token + ID token role assertion).
4. After changing sops, run `nix flake update nix-secrets && nixos-rebuild switch --flake .#ace` on ace so the Grafana container restarts with the new env file.
5. Sign out of Grafana and sign in with Zitadel again so roles are re-evaluated.

See also `docs/zitadel-ace.md` for console steps.

External and LAN probe perspectives: `docs/monitoring-external-probes.md`.

Security detection and incident response: `docs/security-ids-plan.md` — Loki log aggregation, host IDS (Suricata), audit/fail2ban, and Grafana **Security** alert rules. Test procedures: `docs/security-ids-test-cases.md`.

## Email alerting (Grafana Unified Alerting)

Ace sends operational emails through Grafana’s built-in SMTP relay (same iCloud credentials as Nextcloud/Zitadel). Alert rules and notification routing are **file-provisioned** under `nixos/monitoring/grafana/provisioning/alerting/`; recipients come from sops.

### What triggers email

| Alert | Query / condition | `for` | Severity |
|-------|-------------------|-------|----------|
| **Service down** | `probe_success{probe_location=~"local\|lan",job=~"blackbox.*"} == 0` | 5m | critical |
| **Major update** | `ace_service_version_behind == 3`, unless the service is held (`ace_service_version_held == 1`) | immediate | critical |
| **Patch/minor update** | `ace_service_version_behind_in_series == 1 or == 2` (so held and major-behind services still alert on updates in their series) | 1h | warning |
| **Nightly nixpkgs update failed** | `ace_nixpkgs_update_success < 1` | immediate | warning |
| **nixpkgs input stale** | nixpkgs revision in `flake.lock` older than 4 days | 1h | warning |

Local and LAN blackbox probes are included; external probes are excluded (often flaky). Version metrics come from the `ace-version-check` timer (node_exporter textfile collector) and appear on the **Ace Service Versions** Grafana dashboard (`ace-versions`).

Every container on ace reports a version: 34 services, including sidecar databases and caches (`nextcloud-mariadb`, `matrix-postgres`, `mediawiki-redis`, `animal-search-node`, …). Digest-pinned images are read from the image itself: Synapse from its OCI version label, the image renderer by mapping the commit its `--version` prints to a release tag, Pushgateway from `--version`, and official Postgres/MariaDB/Valkey/Redis/Node images from `PG_VERSION`, `MARIADB_VERSION` and similar. OCI labels are not used generically (Coolify's label is its base image's).

Each service has two lags:

| Metric | Meaning |
|---|---|
| `ace_service_version_behind` | Against the newest release overall (0 current, 1 patch, 2 minor, 3 major, 4 unknown) |
| `ace_service_version_behind_in_series` | Against the newest release in the running **series**: the update that needs no major upgrade. A series is the major version, or major.minor for MariaDB (11.4 and 11.8 are different LTS series) and MediaWiki (1.45 → 1.46 needs matching extension branches) |

`ace_service_version_info` carries `current`, `latest` and `latest_in_series` labels. The **Ace Service Versions** dashboard shows both lags, a *Safe updates (in series)* count and a *Held on a major* count. Auto-update takes an in-series update before (and regardless of) a pending, held or denied major.

### SMTP

Non-secret SMTP settings are applied in `nixos/containers/grafana.nix`. The iCloud app-specific password is injected at runtime from `SMTP_PASSWORD` in `nextcloud-environment` (shared with Nextcloud and Zitadel).

| Setting | Value |
|---------|-------|
| Host | `smtp.mail.me.com:587` |
| User | `prestonhager@icloud.com` |
| From | `admin@prestonhager.com` (name: Grafana Ace Alerts) |
| TLS | Mandatory STARTTLS |

### Alert recipients

Set comma-separated addresses in sops `grafana-oauth-env` (`secrets/containers/grafana-oauth.yaml`):

```bash
GRAFANA_ALERT_EMAILS=preston@hagerfamily.com
# GRAFANA_ALERT_EMAILS=preston@hagerfamily.com,other@example.com
```

On each Grafana start, `grafana-alerting-provision` reads that variable and writes `/run/grafana/provisioning/alerting/contact-points.yaml` for the `ace-email` receiver.

After editing sops:

```bash
cd /etc/nixos && nix flake update nix-secrets && nixos-rebuild switch --flake .#ace
```

### Verify alerting

```bash
# Runtime env includes SMTP + GRAFANA_ALERT_EMAILS
grep -E '^(GF_SMTP_|GRAFANA_ALERT_)' /run/grafana/container.env

# Provisioned contact point
cat /run/grafana/provisioning/alerting/contact-points.yaml

# Grafana health
curl -sf http://127.0.0.1:8082/api/health

# Send test notification (requires Grafana admin API key or break-glass login)
# Alerting → Contact points → ace-email → Test
```

Provisioned rules appear under **Alerting → Alert rules** in folder **Ace Alerts**. File-provisioned resources cannot be edited in the UI (changes must be made in git).

## Automated service updates

`ace-service-auto-update@.service` upgrades individual Ace services when `ace-version-check` reports they are behind upstream.

| Behavior | Detail |
|----------|--------|
| **Trigger** | After each `ace-version-check` run, `ace-service-update-dispatch` starts `ace-service-auto-update@SERVICE` for each enabled, out-of-date service |
| **Patch / minor** | Bumps pinned versions in `/etc/nixos` nix modules, commits, pushes to the deployment branch, then runs a **constrained** `nixos-rebuild switch --flake /etc/nixos#ace` (`-j 4`, `max-jobs 4`, `cores 12`, serialized with flock) |
| **Major** | Sends an approval email (same SMTP + recipients as Grafana alerts) with breaking-change notes and **Approve** / **Deny** links at https://update.prestonhager.com. Opening a link only shows a confirmation page; the upgrade is approved or denied when you press its button (a POST), so mail link scanners that prefetch URLs cannot trigger it |
| **Result email** | Success or failure notification after each attempted update |
| **Registry** | `/etc/ace-service-update/registry.json` — enable/disable services and bump rules |
| **Persistence** | All enabled services use `nix-bump` (or `occ-app` for Nextcloud apps). Image tags live in nix expressions; the next rebuild reproduces the same versions. **Do not** use floating `:latest` `podman-pull` updates — those diverge from nix and are wiped on rebuild. |

Enabled auto-update services (all `nix-bump` unless noted): Grafana, Technitium, Nextcloud, Zitadel, Vaultwarden, Matrix Synapse, Jellyfin, Prometheus, Pterodactyl panel, and notify_push (`occ-app`). Sidecar databases and Redis instances are version-tracked in Grafana dashboards but are **not** alerted and are updated with their parent stack.

### Persistence contract

1. Version check writes `ace_service_version_*` metrics.
2. Auto-update selects an enabled registry service that is behind.
3. `ace-service-update-bump` edits the pinned version in the service’s nix file under `/etc/nixos`, commits (`ace: bump SERVICE to VERSION`), and pushes `origin/<branch>`. If the file already has the target version but it is not committed (an earlier run rebuilt from a dirty tree), it commits and pushes that instead of only rebuilding.
4. Constrained `nixos-rebuild switch --flake /etc/nixos#ace` applies the new pin.
5. After rebuild, container tags match the nix pins — no ephemeral drift.

### Holding a service on a major release

When a major upgrade is known to break something, add `holdMajor` (the major to stay on, as a string) and `holdReason` to the service's row in `nixos/monitoring/scripts/ace-service-update-registry.json`. While the running version is on that major:

- `ace-version-check` exports `ace_service_version_held{service,major} 1`;
- **Ace service major version behind** skips the service (minor and patch updates within the held major still apply);
- `ace-service-auto-update` logs the hold and sends no approval mail.

Current holds: **Jellyfin on 10** (see [Jellyfin](./jellyfin.md)). Delete the two keys and rebuild to release a hold.

Manual run for one service:

```bash
systemctl start ace-service-auto-update@grafana.service
```

Requirements on ace:

- `/etc/nixos` is a git checkout with push access (for `nix-bump` services)
- Public DNS for `update.prestonhager.com` → ace (Caddy terminates TLS and proxies to the local approval handler)
- `GRAFANA_ALERT_EMAILS` and `SMTP_PASSWORD` already configured (shared with Grafana alerting)

Verify:

```bash
systemctl status ace-service-update-http
curl -sf http://127.0.0.1:8765/health
cat /var/lib/node-exporter-textfile/ace_versions.prom | grep ace_service_version_behind
```

### One-time grant for an existing OAuth user

If a user logged in before admin mapping was configured, update the Grafana SQLite DB on ace:

```bash
nix shell nixpkgs#sqlite -c sqlite3 /grafana/data/grafana.db \
  "UPDATE user SET is_admin=1 WHERE email='admin@prestonhager.com';"
nix shell nixpkgs#sqlite -c sqlite3 /grafana/data/grafana.db \
  "UPDATE org_user SET role='Admin' WHERE user_id=(SELECT id FROM user WHERE email='admin@prestonhager.com');"
```

The user should log out and back in via Zitadel; future logins pick up roles from `role_attribute_path` automatically.

Verify admin:

```bash
curl -s http://127.0.0.1:8082/api/user -H "Cookie: ..."   # or check Profile → Server Admin in UI
nix shell nixpkgs#sqlite -c sqlite3 /grafana/data/grafana.db \
  "SELECT email, is_admin FROM user WHERE email='admin@prestonhager.com';"
```

## Nightly nixpkgs updates

`ace-nixpkgs-update.timer` runs `nixos/monitoring/scripts/ace-nixpkgs-update.sh` every night at 04:30 (±20 min, after the 03:30 backup):

1. Skips if `/etc/nixos` has uncommitted changes, then fast-forwards to `origin/<branch>`.
2. `nix flake update nixpkgs` (other inputs, including the K80's `nixpkgs-cuda114`, are not touched). Nothing to do if the revision is unchanged.
3. Builds ace's system with the same limits as service bumps (`-j 4`, 12 cores). A failed build never touches the running system.
   - If the only failure is the fixed-output hash of Caddy's plugin source (it changes whenever nixpkgs moves Caddy), the new hash is accepted only after a second independent fetch agrees and the vendored `caddy-dns/cloudflare` is the version pinned in `nixos/caddy/acme-dns.nix`.
4. `nixos-rebuild switch`. If units fail on the new generation, it switches back to the previous one.
5. Commits `flake.lock` (and the Caddy hash, if changed) as `flake: nightly nixpkgs update` and pushes.

On any failure `flake.lock` is restored, an email goes to the alert recipients with the log tail, and **Ace nightly nixpkgs update failed** fires. The whole run holds `/run/ace-service-update-rebuild.lock`, so service bumps wait, and `homelab-git-drift` skips its check instead of reporting the in-progress `flake.lock` as drift.

Metrics (`/var/lib/node-exporter-textfile/ace_nixpkgs.prom`): `ace_nixpkgs_update_success`, `ace_nixpkgs_update_last_run_timestamp_seconds`, `ace_nixpkgs_input_timestamp_seconds{rev}`, and `ace_reboot_required` (1 when the running generation's kernel or initrd has not been booted; the updater never reboots).

Only ace switches automatically. The other hosts (crux, elara, mars, …) pick up the new `flake.lock` the next time they are deployed.

```bash
systemctl list-timers ace-nixpkgs-update
systemctl start ace-nixpkgs-update     # run now
journalctl -u ace-nixpkgs-update -e
cat /var/lib/node-exporter-textfile/ace_nixpkgs.prom
```

## Prometheus

| Field | Value |
|-------|-------|
| URL | https://prometheus.prestonhager.com |
| Direct (on ace) | http://127.0.0.1:9090 |
| Auth | **Network restriction only** — no OAuth or basic auth |
| UI | Enabled (default Prometheus web UI) |
| Version source | Podman image tag from nix pin (`prometheusVersion` in `nixos/containers/prometheus.nix`); falls back to `GET /api/v1/status/buildinfo` when needed |
| Version metrics | `ace_service_version_*{service="prometheus"}` from `ace-version-check` |
| Auto-update | Enabled via `ace-service-auto-update@prometheus.service` (`nix-bump` → commit + constrained rebuild) |

### Access requirements

The Caddy vhost (`nixos/caddy/prometheus.nix`) reverse-proxies to `localhost:9090` **only** for clients on:

- `192.168.8.0/24` (LAN)
- `10.88.0.0/16` (Podman bridge / container network)

All other source IPs receive **HTTP 403 Forbidden**. This is expected for blackbox probes and external scanners; it is not application-level authentication.

To use the UI:

1. Be on the LAN (or VPN that routes into `192.168.8.0/24`).
2. Open https://prometheus.prestonhager.com in a browser.
3. No login prompt — the UI loads directly.

On ace itself, `curl http://127.0.0.1:9090/` returns 302 to `/graph`; `/-/healthy` returns `Prometheus Server is Healthy.`

Grafana reads Prometheus at `http://host.containers.internal:9090` (internal; not exposed via Caddy).

### Host listeners and the podman0 firewall

`podman0` (the default rootful Podman bridge, `10.88.0.0/16`) is **not** a trusted interface: it carries every default-network container and, through the wg-portal container, the WireGuard VPN clients. Only these host ports are opened on it (`networking.firewall.interfaces.podman0` in `nixos/monitoring/exporters.nix`), on top of the global allow list:

| Port | Used by |
|------|---------|
| 53 tcp/udp | DNS from containers and VPN clients |
| 80, 443 tcp; 443 udp | Caddy vhosts reached from containers via `host-gateway` (Zitadel OIDC, Nextcloud) and from VPN clients |
| 2020 tcp | Caddy metrics (Prometheus) |
| 3100 tcp | Loki API (Grafana datasource) |
| 9100, 9115 tcp | node_exporter, blackbox_exporter (Prometheus) |

Ports that containers publish on `10.88.0.1` (Prometheus 9090, Grafana 8082, wg-portal metrics 8787, Technitium API 5380, Pushgateway 9091) are DNATed by netavark and do not pass through `nixos-fw`. Other Podman networks (Coolify's `podman1`, runner networks) get nothing beyond the global allow list.

Listener bindings:

| Service | Listens on | Reached by |
|---------|-----------|------------|
| node_exporter | `10.88.0.1:9100` | Prometheus |
| blackbox_exporter | `10.88.0.1:9115` | Prometheus |
| Loki HTTP / gRPC | `192.168.5.5:3100` / `127.0.0.1:9096` | Alloy on ace, crux, nova, mars (per-source `nixos-fw` rules); Grafana via `192.168.5.5:3100` |
| Pushgateway | `192.168.5.5:9091`, `10.88.0.1:9091` | crux probe timer (raw-table rule drops other LAN sources); Prometheus |

node_exporter and blackbox_exporter start after `podman-prometheus.service` and retry every 5s until `10.88.0.1` exists.

A weekly `podman-image-prune.timer` removes dangling (untagged) images only; tagged images, containers and volumes are kept.

### Troubleshooting

| Symptom | Cause |
|---------|--------|
| 403 from https://prometheus.prestonhager.com | Client IP not in allowed Caddy subnets |
| Blackbox probe `probe_success=0` for prometheus URL | Probe runs from container network; 403 from outside allowed range is normal unless probe source is allowed |
| UI works on ace but not from laptop | DNS OK but client not on `192.168.8.0/24`; check VPN/subnet |
