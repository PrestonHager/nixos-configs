#!/usr/bin/env node
/**
 * Create OpenClaw OIDC app in Zitadel Home Lab project for oauth2-proxy SSO.
 * Run on ace as root (login-client key + zitadel-env secrets).
 *
 *   cd /etc/nixos
 *   nix shell nixpkgs#nodejs_22 -c node scripts/zitadel-openclaw-console-setup.js
 */
const fs = require('fs');
const crypto = require('crypto');
const http = require('http');

const KEY_FILE = '/zitadel/login-client/tls.key';
const SECRETS = '/run/secrets/zitadel-env';
const PUBLIC_HOST = 'zitadel.prestonhager.com';
const AUDIENCE = `https://${PUBLIC_HOST}`;
const ORG_ID = '376181820519160098';
const PROJECT_ID = '376196450586990901';
const APP_NAME = 'OpenClaw';
const REDIRECT_URI = 'https://ai.prestonhager.com/oauth2/callback';

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
  const data = `${b64(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))}.${b64(JSON.stringify({ iss: 'login-client', sub: 'login-client', aud: AUDIENCE, iat: now, exp: now + 3600 }))}`;
  const sig = crypto.createSign('RSA-SHA256').update(data).sign(key).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
  return `${data}.${sig}`;
}

function sessionApi(method, path, body, bearer) {
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
          Authorization: `Bearer ${bearer}`,
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

function mgmt(method, path, body, sessionToken) {
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
  const loginName = loadEnv('ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME=');
  const password = loadEnv('ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD=');
  const loginJwt = makeLoginClientToken();
  const session = await sessionApi('POST', '/v2/sessions', { checks: { user: { loginName } } }, loginJwt);
  const patched = await sessionApi(
    'PATCH',
    `/v2/sessions/${session.sessionId}`,
    { checks: { password: { password } } },
    loginJwt,
  );
  return patched.sessionToken || session.sessionToken;
}

async function findApp(token) {
  const apps = await mgmt('POST', `/management/v1/projects/${PROJECT_ID}/apps/_search`, {
    query: { offset: '0', limit: 100, asc: true },
  }, token);
  return (apps.result || []).find((a) => a.name === APP_NAME);
}

async function updateOidcConfig(token, appId, oidc) {
  const redirectUris = [...new Set([...(oidc.redirectUris || []), REDIRECT_URI])];
  await mgmt('PUT', `/management/v1/projects/${PROJECT_ID}/apps/${appId}/oidc_config`, {
    redirectUris,
    responseTypes: oidc.responseTypes || ['OIDC_RESPONSE_TYPE_CODE'],
    grantTypes: oidc.grantTypes || ['OIDC_GRANT_TYPE_AUTHORIZATION_CODE', 'OIDC_GRANT_TYPE_REFRESH_TOKEN'],
    appType: 'OIDC_APP_TYPE_WEB',
    authMethodType: 'OIDC_AUTH_METHOD_TYPE_BASIC',
    accessTokenType: 'OIDC_TOKEN_TYPE_BEARER',
    clockSkew: oidc.clockSkew || '0s',
    additionalOrigins: [...new Set([...(oidc.additionalOrigins || []), 'https://ai.prestonhager.com'])],
  }, token);
}

async function createOrUpdateApp(token) {
  let app = await findApp(token);
  if (!app) {
    const resp = await mgmt('POST', `/management/v1/projects/${PROJECT_ID}/apps/oidc`, {
      name: APP_NAME,
      redirectUris: [REDIRECT_URI],
      responseTypes: ['OIDC_RESPONSE_TYPE_CODE'],
      grantTypes: ['OIDC_GRANT_TYPE_AUTHORIZATION_CODE', 'OIDC_GRANT_TYPE_REFRESH_TOKEN'],
      appType: 'OIDC_APP_TYPE_WEB',
      authMethodType: 'OIDC_AUTH_METHOD_TYPE_BASIC',
      accessTokenType: 'OIDC_TOKEN_TYPE_BEARER',
    }, token);
    console.log(`Created OpenClaw app ${resp.appId}`);
    return { clientId: resp.clientId, clientSecret: resp.clientSecret };
  }

  const detail = await mgmt('GET', `/management/v1/projects/${PROJECT_ID}/apps/${app.id}`, null, token);
  const oidc = detail.app?.oidcConfig || detail.oidcConfig || {};
  await updateOidcConfig(token, app.id, oidc);
  console.log(`Updated OpenClaw OIDC redirect URI: ${REDIRECT_URI}`);
  const refreshed = await mgmt('GET', `/management/v1/projects/${PROJECT_ID}/apps/${app.id}`, null, token);
  const cfg = refreshed.app?.oidcConfig || refreshed.oidcConfig || {};
  return { clientId: cfg.clientId || app.clientId, clientSecret: cfg.clientSecret || null };
}

(async () => {
  const token = await adminSessionToken();
  console.log('Admin session established');
  const creds = await createOrUpdateApp(token);
  console.log('\n=== OpenClaw OIDC credentials (add to openclaw-oauth.yaml) ===');
  console.log(`OPENCLAW_OIDC_CLIENT_ID=${creds.clientId}`);
  if (creds.clientSecret) console.log(`OPENCLAW_OIDC_CLIENT_SECRET=${creds.clientSecret}`);
  console.log(`ZITADEL_PROJECT_ID=${PROJECT_ID}`);
  console.log(`REDIRECT_URI=${REDIRECT_URI}`);
  console.log('\nGenerate cookie secret: openssl rand -base64 32 | tr -d "\\n" | head -c 32');
})().catch((e) => {
  console.error(e.message || e);
  process.exit(1);
});
