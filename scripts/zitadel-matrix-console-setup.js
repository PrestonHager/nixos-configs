#!/usr/bin/env node
/**
 * Create Matrix OIDC app + matrix_admin role using admin user session (v2 API).
 * Run on ace as root. Requires zitadel-env secrets.
 */
const fs = require('fs');
const http = require('http');

const SECRETS = '/run/secrets/zitadel-env';
const PUBLIC_HOST = 'zitadel.prestonhager.com';
const ORG_ID = '376181820519160098';
const PROJECT_ID = '376196450586990901';
const ADMIN_USER_ID = '376181820519684386';
const APP_NAME = 'Matrix';
const ROLE_KEY = 'matrix_admin';
const REDIRECT_URI = 'https://matrix.prestonhager.com/_synapse/client/oidc/callback';

function loadEnv(prefix) {
  const env = fs.readFileSync(SECRETS, 'utf8');
  const line = env.split('\n').find((l) => l.startsWith(prefix));
  if (!line) throw new Error(`${prefix} not found`);
  return line.split('=').slice(1).join('=').trim();
}

function api(method, path, body, token) {
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
          Authorization: `Bearer ${token}`,
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
  const session = await api('POST', '/v2/sessions', { checks: { user: { loginName } } }, '');
  const patched = await api(
    'PATCH',
    `/v2/sessions/${session.sessionId}`,
    { checks: { password: { password } } },
    session.sessionToken,
  );
  const tokenResp = await api(
    'POST',
    `/v2/sessions/${session.sessionId}/token`,
    {},
    patched.sessionToken || session.sessionToken,
  );
  return tokenResp.token || tokenResp.sessionToken || patched.sessionToken;
}

async function findMatrixApp(token) {
  const apps = await api(
    'POST',
    `/management/v1/projects/${PROJECT_ID}/apps/_search`,
    { query: { offset: '0', limit: 100, asc: true } },
    token,
  );
  return (apps.result || []).find((a) => a.name === APP_NAME);
}

async function ensureRole(token) {
  try {
    await api(
      'POST',
      `/management/v1/projects/${PROJECT_ID}/roles`,
      { roleKey: ROLE_KEY, displayName: 'Matrix Admin' },
      token,
    );
    console.log(`Created role ${ROLE_KEY}`);
  } catch (e) {
    if (String(e.message).includes('already exists') || String(e.message).includes('RoleKeyDuplicated')) {
      console.log(`Role ${ROLE_KEY} exists`);
    } else throw e;
  }
}

async function ensureGrant(token) {
  const grants = await api(
    'POST',
    '/management/v1/users/grants/_search',
    { query: { offset: '0', limit: 100, asc: true }, queries: [{ userIdQuery: { userId: ADMIN_USER_ID } }] },
    token,
  );
  const existing = (grants.result || []).find(
    (g) => g.projectId === PROJECT_ID && (g.roleKeys || []).includes(ROLE_KEY),
  );
  if (existing) {
    console.log('Admin already has matrix_admin');
    return;
  }
  const pg = (grants.result || []).find((g) => g.projectId === PROJECT_ID);
  if (pg) {
    await api(
      'PUT',
      `/management/v1/users/${ADMIN_USER_ID}/grants/${pg.id}`,
      { roleKeys: [...new Set([...(pg.roleKeys || []), ROLE_KEY])] },
      token,
    );
  } else {
    await api(
      'POST',
      `/management/v1/users/${ADMIN_USER_ID}/grants`,
      { projectId: PROJECT_ID, roleKeys: [ROLE_KEY] },
      token,
    );
  }
  console.log('Granted matrix_admin to admin user');
}

async function createOrUpdateApp(token) {
  let app = await findMatrixApp(token);
  if (!app) {
    const resp = await api(
      'POST',
      `/management/v1/projects/${PROJECT_ID}/apps/oidc`,
      {
        name: APP_NAME,
        redirectUris: [REDIRECT_URI],
        responseTypes: ['OIDC_RESPONSE_TYPE_CODE'],
        grantTypes: ['OIDC_GRANT_TYPE_AUTHORIZATION_CODE', 'OIDC_GRANT_TYPE_REFRESH_TOKEN'],
        appType: 'OIDC_APP_TYPE_WEB',
        authMethodType: 'OIDC_AUTH_METHOD_TYPE_BASIC',
        accessTokenType: 'OIDC_TOKEN_TYPE_BEARER',
        idTokenRoleAssertion: true,
        accessTokenRoleAssertion: true,
      },
      token,
    );
    console.log(`Created Matrix app ${resp.appId}`);
    return { clientId: resp.clientId, clientSecret: resp.clientSecret };
  }

  const detail = await api('GET', `/management/v1/projects/${PROJECT_ID}/apps/${app.id}`, null, token);
  const oidc = detail.app?.oidcConfig || detail.oidcConfig || {};
  await api(
    'PUT',
    `/management/v1/projects/${PROJECT_ID}/apps/${app.id}`,
    {
      name: APP_NAME,
      oidcConfig: {
        ...oidc,
        redirectUris: [...new Set([...(oidc.redirectUris || []), REDIRECT_URI])],
        accessTokenRoleAssertion: true,
        idTokenRoleAssertion: true,
        roleAssertion: true,
      },
    },
    token,
  );
  const refreshed = await api('GET', `/management/v1/projects/${PROJECT_ID}/apps/${app.id}`, null, token);
  const cfg = refreshed.app?.oidcConfig || refreshed.oidcConfig || {};
  return { clientId: cfg.clientId || app.clientId, clientSecret: cfg.clientSecret || null };
}

(async () => {
  const token = await adminSessionToken();
  console.log('Admin session established');
  await ensureRole(token);
  const creds = await createOrUpdateApp(token);
  await ensureGrant(token);
  console.log('\n=== Matrix OIDC credentials ===');
  console.log(`SYNAPSE_OIDC_CLIENT_ID=${creds.clientId}`);
  if (creds.clientSecret) console.log(`SYNAPSE_OIDC_CLIENT_SECRET=${creds.clientSecret}`);
  console.log(`ZITADEL_PROJECT_ID=${PROJECT_ID}`);
})().catch((e) => {
  console.error(e.message || e);
  process.exit(1);
});
