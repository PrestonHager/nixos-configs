#!/usr/bin/env node
/**
 * Unified Complement Token action: merge all Home Lab service roles into one groups claim.
 * Replaces per-service *Groups actions that overwrite each other (last writer wins).
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
const ACTION_NAME = 'homelabGroups';
const FLOW_TYPE = '2'; // Complement Token
const TRIGGER_PRE_USERINFO = '4';
const TRIGGER_PRE_ACCESS = '5';

// Single action sets groups once with all applicable values for every service.
const GROUPS_SCRIPT = `function ${ACTION_NAME}(ctx, api) {
  if (!ctx.v1.user || !ctx.v1.user.grants || ctx.v1.user.grants.count === 0) {
    return;
  }
  const roles = new Set();
  for (const grant of ctx.v1.user.grants.grants) {
    for (const role of grant.roles || grant.roleKeys || []) {
      roles.add(role);
    }
  }
  const groups = [];
  if (roles.has('nextcloud_admin')) groups.push('admin');
  if (roles.has('jellyfin_admin')) groups.push('jellyfin_admin');
  else if (roles.has('jellyfin_user')) groups.push('jellyfin_user');
  if (roles.has('pterodactyl_admin')) groups.push('pterodactyl_admin');
  if (roles.has('technitium_admin')) groups.push('technitium_admin');
  else if (roles.has('technitium_user')) groups.push('technitium_user');
  if (groups.length > 0) {
    api.v1.claims.setClaim('groups', groups);
  }
}`;

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

async function findAction(token, name) {
  const resp = await mgmt(
    'POST',
    '/management/v1/actions/_search',
    { query: { offset: '0', limit: 100, asc: true } },
    token,
  );
  return (resp.result || []).find((a) => a.name === name);
}

async function ensureAction(token) {
  let action = await findAction(token, ACTION_NAME);
  if (action) {
    await mgmt(
      'PUT',
      `/management/v1/actions/${action.id}`,
      { name: ACTION_NAME, script: GROUPS_SCRIPT, timeout: '10s', allowedToFail: false },
      token,
    );
    console.log(`Updated action ${ACTION_NAME} (${action.id})`);
    return action.id;
  }
  const resp = await mgmt(
    'POST',
    '/management/v1/actions',
    { name: ACTION_NAME, script: GROUPS_SCRIPT, timeout: '10s', allowedToFail: false },
    token,
  );
  console.log(`Created action ${ACTION_NAME} (${resp.id})`);
  return resp.id;
}

async function setTriggerActions(token, triggerType, actionIds, label) {
  try {
    await mgmt(
      'POST',
      `/management/v1/flows/${FLOW_TYPE}/trigger/${triggerType}`,
      { actionIds },
      token,
    );
    console.log(`${label}: ${actionIds.join(', ')}`);
  } catch (e) {
    if (String(e.message).includes('No changes') || String(e.message).includes('No Changes')) {
      console.log(`${label} already set: ${actionIds.join(', ')}`);
      return;
    }
    throw e;
  }
}

(async () => {
  const token = await adminSessionToken();
  console.log('Admin session established');

  const homelabId = await ensureAction(token);

  // Replace per-service *Groups actions with unified homelabGroups on both triggers.
  await setTriggerActions(token, TRIGGER_PRE_USERINFO, [homelabId], 'Pre Userinfo trigger');
  await setTriggerActions(token, TRIGGER_PRE_ACCESS, [homelabId], 'Pre access token trigger');

  console.log('\n=== homelabGroups complement action deployed ===');
  console.log('groups claim now includes admin, jellyfin_*, pterodactyl_admin, technitium_* as applicable');
  console.log('Users must sign out and sign in again for token refresh');
})().catch((e) => {
  console.error(e.message || e);
  process.exit(1);
});
