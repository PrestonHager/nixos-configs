#!/usr/bin/env node
/**
 * Create pterodactyl_test_admin project role and grant to prestonh.
 * Test panel only — production continues to use pterodactyl_admin.
 * Run on ace as root. Requires zitadel-env secrets + login-client key.
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
const PRESTON_USER_ID = '376197075085302069';
const ROLE_KEY = 'pterodactyl_test_admin';

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

async function ensureRole(token) {
  try {
    const resp = await mgmt(
      'POST',
      `/management/v1/projects/${PROJECT_ID}/roles`,
      { roleKey: ROLE_KEY, displayName: 'Pterodactyl Test Admin' },
      token,
    );
    console.log(`Created role ${ROLE_KEY} (id: ${resp.details?.sequence || resp.sequence || 'n/a'})`);
    return resp;
  } catch (e) {
    if (String(e.message).includes('already exists') || String(e.message).includes('RoleKeyDuplicated')) {
      console.log(`Role ${ROLE_KEY} already exists`);
      const roles = await mgmt(
        'POST',
        `/management/v1/projects/${PROJECT_ID}/roles/_search`,
        { query: { offset: '0', limit: 100, asc: true } },
        token,
      );
      const role = (roles.result || []).find((r) => r.key === ROLE_KEY);
      if (role) console.log(`Role id: ${role.id || role.roleId || JSON.stringify(role)}`);
      return role;
    }
    throw e;
  }
}

async function ensureGrant(token) {
  const grants = await mgmt(
    'POST',
    '/management/v1/users/grants/_search',
    {
      query: { offset: '0', limit: 100, asc: true },
      queries: [{ userIdQuery: { userId: PRESTON_USER_ID } }],
    },
    token,
  );
  const existing = (grants.result || []).find(
    (g) => g.projectId === PROJECT_ID && (g.roleKeys || []).includes(ROLE_KEY),
  );
  if (existing) {
    console.log(`prestonh already has ${ROLE_KEY}`);
    return;
  }
  const projectGrant = (grants.result || []).find((g) => g.projectId === PROJECT_ID);
  if (projectGrant) {
    await mgmt(
      'PUT',
      `/management/v1/users/${PRESTON_USER_ID}/grants/${projectGrant.id}`,
      { roleKeys: [...new Set([...(projectGrant.roleKeys || []), ROLE_KEY])] },
      token,
    );
  } else {
    await mgmt(
      'POST',
      `/management/v1/users/${PRESTON_USER_ID}/grants`,
      { projectId: PROJECT_ID, roleKeys: [ROLE_KEY] },
      token,
    );
  }
  console.log(`Granted ${ROLE_KEY} to prestonh (${PRESTON_USER_ID})`);
}

(async () => {
  const token = await adminSessionToken();
  console.log('Admin session established');
  console.log(`Project: Home Lab (${PROJECT_ID})`);
  await ensureRole(token);
  await ensureGrant(token);
  console.log('\n=== Next: deploy homelabGroups action ===');
  console.log('nix shell nixpkgs#nodejs_22 -c node scripts/zitadel-homelab-groups-action.js');
  console.log(`\nTEST_ADMIN_ROLE=${ROLE_KEY}`);
  console.log('Users must sign out and sign in again for token refresh');
})().catch((e) => {
  console.error(e.message || e);
  process.exit(1);
});
