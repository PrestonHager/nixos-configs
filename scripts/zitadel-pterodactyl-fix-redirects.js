#!/usr/bin/env node
/** Update Pterodactyl OIDC redirect URIs via dedicated oidc_config endpoint. Run on ace as root. */
const fs = require('fs');
const crypto = require('crypto');
const http = require('http');

const KEY_FILE = '/zitadel/login-client/tls.key';
const SECRETS = '/run/secrets/zitadel-env';
const PUBLIC_HOST = 'zitadel.prestonhager.com';
const ORG_ID = '376181820519160098';
const PROJECT_ID = '376196450586990901';
const APP_ID = '376324661987776821';
const REDIRECT_URIS = [
  'https://panel.prestonhager.com/extensions/sociallogin/callback',
  'https://panel.prestonhager.com/oauth2/callback',
  'https://test.panel.prestonhager.com/extensions/sociallogin/callback',
];

function loadEnv(prefix) {
  const env = fs.readFileSync(SECRETS, 'utf8');
  const line = env.split('\n').find((l) => l.startsWith(prefix));
  if (!line) throw new Error(`${prefix} not found`);
  return line.split('=').slice(1).join('=').trim();
}

function makeLoginClientToken() {
  const key = fs.readFileSync(KEY_FILE, 'utf8');
  const b64 = (o) => Buffer.from(o).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
  const now = Math.floor(Date.now() / 1000);
  const data = `${b64(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))}.${b64(JSON.stringify({ iss: 'login-client', sub: 'login-client', aud: `https://${PUBLIC_HOST}`, iat: now, exp: now + 3600 }))}`;
  const sig = crypto.createSign('RSA-SHA256').update(data).sign(key).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
  return `${data}.${sig}`;
}

function api(method, path, body, sessionToken) {
  return new Promise((resolve, reject) => {
    const payload = body ? JSON.stringify(body) : null;
    const req = http.request(
      {
        hostname: '127.0.0.1',
        port: 9080,
        path,
        method,
        headers: {
          Host: PUBLIC_HOST,
          'X-Forwarded-Proto': 'https',
          'X-Forwarded-Host': PUBLIC_HOST,
          'X-Zitadel-Public-Host': PUBLIC_HOST,
          'X-Zitadel-Orgid': ORG_ID,
          Authorization: `Bearer ${sessionToken}`,
          Accept: 'application/json',
          'Content-Type': 'application/json',
          ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}),
        },
      },
      (res) => {
        let raw = '';
        res.on('data', (c) => (raw += c));
        res.on('end', () => {
          if (res.statusCode >= 400) reject(new Error(`${res.statusCode} ${method} ${path}: ${raw}`));
          else resolve(raw ? JSON.parse(raw) : {});
        });
      },
    );
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

async function adminSessionToken() {
  const loginJwt = makeLoginClientToken();
  const loginName = loadEnv('ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME=');
  const password = loadEnv('ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD=');
  const session = await api('POST', '/v2/sessions', { checks: { user: { loginName } } }, loginJwt);
  const patched = await api(
    'PATCH',
    `/v2/sessions/${session.sessionId}`,
    { checks: { password: { password } } },
    loginJwt,
  );
  return patched.sessionToken || session.sessionToken;
}

(async () => {
  const token = await adminSessionToken();
  const detail = await api('GET', `/management/v1/projects/${PROJECT_ID}/apps/${APP_ID}`, null, token);
  const oidc = detail.app?.oidcConfig || detail.oidcConfig || {};
  const redirectUris = [...new Set([...(oidc.redirectUris || []), ...REDIRECT_URIS])];
  const body = {
    redirectUris,
    responseTypes: oidc.responseTypes,
    grantTypes: oidc.grantTypes,
    appType: 'OIDC_APP_TYPE_WEB',
    authMethodType: 'OIDC_AUTH_METHOD_TYPE_BASIC',
    accessTokenType: 'OIDC_TOKEN_TYPE_BEARER',
    accessTokenRoleAssertion: true,
    idTokenRoleAssertion: true,
    clockSkew: oidc.clockSkew || '0s',
    additionalOrigins: oidc.allowedOrigins || ['https://panel.prestonhager.com'],
  };
  await api('PUT', `/management/v1/projects/${PROJECT_ID}/apps/${APP_ID}/oidc_config`, body, token);
  const refreshed = await api('GET', `/management/v1/projects/${PROJECT_ID}/apps/${APP_ID}`, null, token);
  const updated = refreshed.app?.oidcConfig || refreshed.oidcConfig || {};
  console.log('Updated redirect URIs:', JSON.stringify(updated.redirectUris || [], null, 2));
})().catch((e) => {
  console.error(e.message || e);
  process.exit(1);
});
