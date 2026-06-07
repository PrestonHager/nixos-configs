# Monitoring on ace (Grafana + Prometheus)

Implementation: `nixos/containers/grafana.nix`, `nixos/containers/prometheus.nix`, Caddy vhosts in `nixos/caddy/grafana.nix` and `nixos/caddy/prometheus.nix`, OAuth secrets in `nixos-secrets/secrets/containers/grafana-oauth.yaml`.

## Grafana

| Field | Value |
|-------|-------|
| URL | https://grafana.prestonhager.com |
| Auth | Zitadel OIDC (Generic OAuth); local login form remains enabled for break-glass |
| Secrets | `grafana-oauth-env` in sops (`grafana-oauth.yaml`) |

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
