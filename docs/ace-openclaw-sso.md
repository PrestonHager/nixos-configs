# OpenClaw SSO on ace

Browser SSO for the OpenClaw AI portal at https://ai.prestonhager.com via Zitadel + oauth2-proxy + Caddy forward auth. OpenClaw uses `trusted-proxy` auth mode (no gateway token in the browser).

## Architecture

```
Browser (LAN)
  → Caddy ai.prestonhager.com (@lan only)
    → oauth2-proxy (127.0.0.1:4181, Zitadel OIDC, reverse proxy upstream)
      → passes X-Forwarded-Email on HTTP + WebSocket upgrades
    → OpenClaw gateway (127.0.0.1:18789, trusted-proxy auth)
```

| Component | Config |
|-----------|--------|
| Caddy | `nixos/caddy/ai.nix` — reverse_proxy to oauth2-proxy (WebSocket-safe); `/ollama` uses forward_auth |
| oauth2-proxy | `nixos/containers/openclaw-oauth.nix` — port 4181, upstream OpenClaw |
| OpenClaw | `/stor/openclaw/.openclaw/openclaw.json` — `gateway.auth.mode: trusted-proxy` (enforced by `openclaw-trusted-proxy-config` on boot) |
| Zitadel app | Home Lab project, redirect `https://ai.prestonhager.com/oauth2/callback` |
| Secrets | `nixos-secrets/secrets/containers/openclaw-oauth.yaml` (sops) |

## One-time setup

### 1. Create Zitadel OIDC app

On ace:

```bash
cd /etc/nixos
git pull
nix shell nixpkgs#nodejs_22 -c node scripts/zitadel-openclaw-console-setup.js
```

Save the printed `OPENCLAW_OIDC_CLIENT_ID` and `OPENCLAW_OIDC_CLIENT_SECRET`.

**Manual console alternative** (if the script fails):

1. https://zitadel.prestonhager.com/ui/console → **Home Lab** project → **Applications** → **New**
2. Type: **Web**, name: **OpenClaw**
3. Auth method: **Basic**
4. Redirect URI: `https://ai.prestonhager.com/oauth2/callback`
5. Grant types: Authorization Code + Refresh Token
6. Copy Client ID and Client Secret

### 2. Add sops secret

On ace (nixos-secrets checkout at `/home/prestonh/nixos-secrets`):

```bash
cp /etc/nixos/scripts/openclaw-oauth.yaml.template \
  /home/prestonh/nixos-secrets/secrets/containers/openclaw-oauth.yaml
# Edit with real values, then encrypt:
sops -e -i /home/prestonh/nixos-secrets/secrets/containers/openclaw-oauth.yaml
cd /etc/nixos && nix flake update nix-secrets
```

Generate cookie secret:

```bash
openssl rand -base64 32 | tr -d '\n' | head -c 32; echo
```

Required keys in `openclaw-oauth-env`:

- `OPENCLAW_OIDC_CLIENT_ID`
- `OPENCLAW_OIDC_CLIENT_SECRET`
- `OAUTH2_PROXY_COOKIE_SECRET` (32 chars)
- `ZITADEL_PROJECT_ID=376196450586990901`

### 3. Deploy

```bash
cd /etc/nixos
nixos-rebuild switch --flake .#ace
bash scripts/ace-openclaw-config.sh gemma2:2b
systemctl restart openclaw-gateway openclaw-oauth2-proxy
systemctl reload caddy
```

## OpenClaw trusted-proxy config

Applied by `scripts/ace-openclaw-config.sh`:

```json
{
  "gateway": {
    "mode": "local",
    "trustedProxies": ["127.0.0.1"],
    "auth": {
      "mode": "trusted-proxy",
      "trustedProxy": {
        "userHeader": "x-forwarded-email",
        "allowLoopback": true,
        "requiredHeaders": ["x-forwarded-proto", "x-forwarded-host"]
      }
    },
    "controlUi": {
      "allowedOrigins": ["https://ai.prestonhager.com"]
    }
  }
}
```

**Do not** set `gateway.auth.token` or `OPENCLAW_GATEWAY_TOKEN` when using trusted-proxy (OpenClaw rejects mixed configs).

Optional hardening: set `gateway.auth.trustedProxy.allowUsers` to restrict to specific Zitadel email addresses.

## Browser flow

1. From a LAN client, open https://ai.prestonhager.com
2. oauth2-proxy redirects unauthenticated users to `/oauth2/start` → Zitadel login
3. Zitadel login (same IdP as Grafana, Nextcloud, etc.)
4. oauth2-proxy sets session cookie and proxies to OpenClaw with `X-Forwarded-Email`
5. OpenClaw Control UI loads; WebSocket connects without manual gateway token

If the UI loads but WebSocket fails with `token_missing` in gateway logs, OpenClaw is still in token auth mode — redeploy or run `bash scripts/ace-openclaw-config.sh`, then hard-refresh the browser.

Non-LAN clients receive HTTP 403 (Caddy `@lan` matcher unchanged).

## Verify

```bash
# Services
systemctl status openclaw-oauth2-proxy openclaw-gateway caddy

# Unauthenticated → redirect to Zitadel (302 to /oauth2/start)
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  --resolve ai.prestonhager.com:443:192.168.5.5 \
  https://ai.prestonhager.com/

# Loopback gateway health (no SSO, direct)
curl -sS http://127.0.0.1:18789/health

# OpenClaw security audit (expect trusted-proxy findings — intentional)
sudo -u openclaw HOME=/stor/openclaw openclaw security audit
```

After browser login, confirm Control UI loads and chat/WebSocket work.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `openclaw-oauth2-proxy` fails to start | Check `/run/secrets/openclaw-oauth-env`; placeholder client id |
| Redirect loop on `/oauth2/*` | Redirect URI mismatch in Zitadel app |
| `trusted_proxy_untrusted_source` | Ensure `trustedProxies: ["127.0.0.1"]` and `allowLoopback: true` |
| `trusted_proxy_user_missing` | oauth2-proxy not passing email; check `--pass-user-headers=true` |
| WebSocket 1008 unauthorized / `token_missing` | OpenClaw still in token mode — run `bash scripts/ace-openclaw-config.sh` or redeploy (systemd `openclaw-trusted-proxy-config`); ensure oauth2-proxy reverse-proxies with `--pass-user-headers` |
| WS connects then fails / no WS in gateway logs | Hard-refresh browser (Ctrl+Shift+R); clear site data for ai.prestonhager.com; verify DNS resolves to 192.168.5.5 on LAN (`dig @192.168.5.5 ai.prestonhager.com`) |
| `forward_auth` + WebSocket | Caddy forward_auth does not pass identity headers on WS upgrades; oauth2-proxy must proxy OpenClaw directly |
| `mixed_trusted_proxy_token` on startup | Remove `gateway.auth.token` / `OPENCLAW_GATEWAY_TOKEN` |
| External access works when it should not | Verify Caddy `@lan` matcher on ai.prestonhager.com |

## Related

- [ace-k80-gpu.md](./ace-k80-gpu.md) — GPU stack, Ollama, OpenClaw ports
- [zitadel-ace.md](./zitadel-ace.md) — Zitadel admin, other OIDC apps
- [OpenClaw trusted-proxy docs](https://docs.openclaw.ai/gateway/trusted-proxy-auth)
