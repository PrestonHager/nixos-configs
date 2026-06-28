# OpenClaw SSO on ace

Browser SSO for the OpenClaw AI portal at https://ai.prestonhager.com via Zitadel + oauth2-proxy + Caddy forward auth. OpenClaw uses `trusted-proxy` auth mode (no gateway token in the browser).

## Architecture

```
Browser (LAN)
  â†’ Caddy ai.prestonhager.com (@lan only)
    â†’ oauth2-proxy (127.0.0.1:4181, Zitadel OIDC, reverse proxy upstream)
      â†’ passes X-Forwarded-Email on HTTP + WebSocket upgrades
    â†’ OpenClaw gateway (127.0.0.1:18789, trusted-proxy auth)
```

| Component | Config |
|-----------|--------|
| Caddy | `nixos/caddy/ai.nix` â€” reverse_proxy to oauth2-proxy (WebSocket-safe); `/ollama` uses forward_auth |
| oauth2-proxy | `nixos/containers/openclaw-oauth.nix` â€” port 4181, upstream OpenClaw |
| OpenClaw | `/stor/openclaw/.openclaw/openclaw.json` â€” `gateway.auth.mode: trusted-proxy` (enforced by `openclaw-trusted-proxy-config` on boot) |
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

1. https://zitadel.prestonhager.com/ui/console â†’ **Home Lab** project â†’ **Applications** â†’ **New**
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
bash scripts/ace-openclaw-config.sh llama3.2:3b
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
2. oauth2-proxy redirects unauthenticated users to `/oauth2/start` â†’ Zitadel login
3. Zitadel login (same IdP as Grafana, Nextcloud, etc.)
4. oauth2-proxy sets session cookie and proxies to OpenClaw with `X-Forwarded-Email`
5. OpenClaw Control UI loads; WebSocket connects without manual gateway token

If the UI loads but WebSocket fails with `token_missing` in gateway logs, OpenClaw is still in token auth mode â€” redeploy or run `bash scripts/ace-openclaw-config.sh`, then hard-refresh the browser.

Non-LAN clients receive HTTP 403 (Caddy `@lan` matcher unchanged).

## Verify

```bash
# Services
systemctl status openclaw-oauth2-proxy openclaw-gateway caddy

# Unauthenticated â†’ redirect to Zitadel (302 to /oauth2/start)
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  --resolve ai.prestonhager.com:443:192.168.5.5 \
  https://ai.prestonhager.com/

# Loopback gateway health (no SSO, direct)
curl -sS http://127.0.0.1:18789/health

# OpenClaw security audit (expect trusted-proxy findings â€” intentional)
sudo -u openclaw HOME=/stor/openclaw openclaw security audit
```

After browser login, confirm Control UI loads and chat/WebSocket work.


## Control UI device pairing

SSO (trusted-proxy) satisfies gateway **user** identity; the Control UI still performs a one-time **device** pairing step (browser keypair stored in `paired.json`). After approval, the same browser profile reconnects without repeating pairing unless site data is cleared.

Pending requests expire after **5 minutes** (`pending.json` under `/stor/openclaw/.openclaw/devices/`). If approval fails with no pending entry, refresh the Control UI to generate a new request ID.

### Approve from ace

The `openclaw` CLI is not on a global PATH; use the same binary as the gateway unit:

```bash
OC="$(systemctl cat openclaw-gateway | sed -n 's#^ExecStart=\([^ ]*/bin/openclaw\).*#\1#p' | head -1)"
sudo -u openclaw HOME=/stor/openclaw OPENCLAW_CONFIG_PATH=/stor/openclaw/.openclaw/openclaw.json \
  "$OC" devices list
sudo -u openclaw HOME=/stor/openclaw OPENCLAW_CONFIG_PATH=/stor/openclaw/.openclaw/openclaw.json \
  "$OC" devices approve '<request-id-from-ui>'
```

With `gateway.auth.mode: trusted-proxy` and **no** `gateway.auth.token`, loopback `devices list` / `approve` often fail with gateway `unauthorized` (CLI cannot authenticate like the browser). Options:

1. Approve while the pending request is fresh (within 5 minutes) and rely on local pairing-state fallback when the CLI error indicates device pairing (not always triggered for plain `unauthorized`).
2. Inspect pending: `sudo -u openclaw cat /stor/openclaw/.openclaw/devices/pending.json`
3. If the request ID is present but expired, bump `ts` to `date +%s%3N` in that JSON entry, then run `devices approve` againâ€”or use OpenClaw's on-disk pairing API via the nix-store `openclaw` package (same state dir as the gateway).

No gateway restart is required after approval; state lives in `/stor/openclaw/.openclaw/devices/paired.json`.

### Auto-approve settings

There is **no** supported setting to auto-approve Control UI **operator** pairing for trusted-proxy SSO users:

| Setting | Scope |
|---------|--------|
| `gateway.nodes.pairing.autoApproveCidrs` | **Node** role only, no requested scopesâ€”not Control UI |
| `gateway.controlUi.dangerouslyDisableDeviceAuth` | Debug only; disables device identity checks |

Do not enable `dangerouslyDisableDeviceAuth` on a LAN-facing deployment.


## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `openclaw-oauth2-proxy` fails to start | Check `/run/secrets/openclaw-oauth-env`; placeholder client id |
| Redirect loop on `/oauth2/*` | Redirect URI mismatch in Zitadel app |
| `trusted_proxy_untrusted_source` | Ensure `trustedProxies: ["127.0.0.1"]` and `allowLoopback: true` |
| `trusted_proxy_user_missing` | oauth2-proxy not passing email; check `--pass-user-headers=true` |
| WebSocket 1008 unauthorized / `token_missing` | OpenClaw still in token mode â€” run `bash scripts/ace-openclaw-config.sh` or redeploy (systemd `openclaw-trusted-proxy-config`); ensure oauth2-proxy reverse-proxies with `--pass-user-headers` |
| WS connects then fails / no WS in gateway logs | Hard-refresh browser (Ctrl+Shift+R); clear site data for ai.prestonhager.com; verify DNS resolves to 192.168.5.5 on LAN (`dig @192.168.5.5 ai.prestonhager.com`) |
| `forward_auth` + WebSocket | Caddy forward_auth does not pass identity headers on WS upgrades; oauth2-proxy must proxy OpenClaw directly |
| `mixed_trusted_proxy_token` on startup | Remove `gateway.auth.token` / `OPENCLAW_GATEWAY_TOKEN` |
| External access works when it should not | Verify Caddy `@lan` matcher on ai.prestonhager.com |
| Control UI shows "device pairing required" | Approve with `devices approve <id>` on ace (see above); hard-refresh browser after approve; pending TTL is 5 minutes |

## Related

- [ace-k80-gpu.md](./ace-k80-gpu.md) â€” GPU stack, Ollama, OpenClaw ports
- [zitadel-ace.md](./zitadel-ace.md) â€” Zitadel admin, other OIDC apps
- [OpenClaw trusted-proxy docs](https://docs.openclaw.ai/gateway/trusted-proxy-auth)
