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

Grafana 13+ no longer supports the in-process image renderer plugin. ace runs the official remote renderer (`grafana/grafana-image-renderer:v5.8.8`) in the same Podman pod as Grafana so both reach each other on loopback.

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
| **Major update** | `ace_service_version_behind == 3` | immediate | critical |
| **Patch/minor update** | `ace_service_version_behind == 1 or == 2` | 1h | warning |

Local and LAN blackbox probes are included; external probes are excluded (often flaky). Version metrics come from the `ace-version-check` timer (node_exporter textfile collector) and appear on the **Ace Service Versions** Grafana dashboard (`ace-versions`).

Tracked services (metric label `service=…`): Grafana, **Prometheus**, Nextcloud, Zitadel, Matrix Synapse, Technitium, Jellyfin, Vaultwarden, Caddy, Pterodactyl panel, notify_push, and prefixed sidecars (`nextcloud-mariadb`, `nextcloud-redis`, `nextcloud-clamav`, `pterodactyl-mariadb`, `pterodactyl-redis`). Standalone stack services use their short name (for example `prometheus`, not a sidecar prefix).

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
| **Patch / minor** | Bumps pinned versions in `/etc/nixos`, commits, pushes, runs `nixos-rebuild switch --flake /etc/nixos#ace`, or pulls `:latest` images where configured |
| **Major** | Sends an approval email (same SMTP + recipients as Grafana alerts) with breaking-change notes and **Approve** / **Deny** links at https://update.prestonhager.com |
| **Result email** | Success or failure notification after each attempted update |
| **Registry** | `/etc/ace-service-update/registry.json` — enable/disable services and bump rules |

Enabled auto-update services include Grafana, Technitium, Nextcloud, Zitadel, Vaultwarden, Matrix Synapse, Jellyfin, **Prometheus** (`podman-pull` on `docker.io/prom/prometheus:latest`), Pterodactyl panel, and notify_push. Sidecar databases and Redis instances are version-tracked in Grafana but updated with their parent stack.

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

## Prometheus

| Field | Value |
|-------|-------|
| URL | https://prometheus.prestonhager.com |
| Direct (on ace) | http://127.0.0.1:9090 |
| Auth | **Network restriction only** — no OAuth or basic auth |
| UI | Enabled (default Prometheus web UI) |
| Version source | Podman image tag (`docker.io/prom/prometheus:latest`); falls back to `GET /api/v1/status/buildinfo` when tag is `latest` |
| Version metrics | `ace_service_version_*{service="prometheus"}` from `ace-version-check` |
| Auto-update | Enabled via `ace-service-auto-update@prometheus.service` (`podman-pull`) |

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

### Troubleshooting

| Symptom | Cause |
|---------|--------|
| 403 from https://prometheus.prestonhager.com | Client IP not in allowed Caddy subnets |
| Blackbox probe `probe_success=0` for prometheus URL | Probe runs from container network; 403 from outside allowed range is normal unless probe source is allowed |
| UI works on ace but not from laptop | DNS OK but client not on `192.168.8.0/24`; check VPN/subnet |
