#!/usr/bin/env node
/**
 * Create nextcloudGroups Complement Token action and ensure prestonh has nextcloud_admin.
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
const ACTION_NAME = 'nextcloudGroups';
const ROLE_CLAIM = 'groups';
const ADMIN_ROLE = 'nextcloud_admin';
const NC_ADMIN_GROUP = 'admin';
const FLOW_TYPE = '2'; // Complement Token
const TRIGGER_PRE_USERINFO = '4';
const TRIGGER_PRE_ACCESS = '5';

const GROUPS_SCRIPT = `function ${ACTION_NAME}(ctx, api) {
  if (!ctx.v1.user || !ctx.v1.user.grants || ctx.v1.user.grants.count === 0) {
    return;
  }
  const groups = [];
  for (const grant of ctx.v1.user.grants.grants) {
    const roles = grant.roles || grant.roleKeys || [];
    if (roles.includes('${ADMIN_ROLE}')) {
      groups.push('${NC_ADMIN_GROUP}');
      break;
    }
  }
  if (groups.length > 0) {
    api.v1.claims.setClaim('${ROLE_CLAIM}', groups);
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
    const detail = await mgmt('GET', `/management/v1/actions/${action.id}`, null, token);
    const script = detail.action?.script || detail.script || '';
    if (!script.includes("setClaim('groups'") || !script.includes(ADMIN_ROLE)) {
      await mgmt(
        'PUT',
        `/management/v1/actions/${action.id}`,
        { name: ACTION_NAME, script: GROUPS_SCRIPT, timeout: '10s', allowedToFail: false },
        token,
      );
      console.log(`Updated action ${ACTION_NAME} script (${action.id})`);
    } else {
      console.log(`Action ${ACTION_NAME} already exists (${action.id})`);
    }
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

async function attachActionToTrigger(token, triggerType, actionId, label, allGroupActionIds) {
  const merged = [...new Set(allGroupActionIds)];
  try {
    await mgmt(
      'POST',
      `/management/v1/flows/${FLOW_TYPE}/trigger/${triggerType}`,
      { actionIds: merged },
      token,
    );
    console.log(`Attached complement actions to ${label} trigger: ${merged.join(', ')}`);
  } catch (e) {
    if (String(e.message).includes('No changes') || String(e.message).includes('No Changes')) {
      console.log(`${label} trigger already has complement actions: ${merged.join(', ')}`);
      return;
    }
    throw e;
  }
}

async function ensureUserGrant(token, userId, roleKeys, label) {
  const grants = await mgmt(
    'POST',
    '/management/v1/users/grants/_search',
    { query: { offset: '0', limit: 100, asc: true }, queries: [{ userIdQuery: { userId } }] },
    token,
  );
  const projectGrant = (grants.result || []).find((g) => g.projectId === PROJECT_ID);
  if (!projectGrant) {
    await mgmt('POST', `/management/v1/users/${userId}/grants`, { projectId: PROJECT_ID, roleKeys }, token);
    console.log(`Created grant for ${label}: ${roleKeys.join(', ')}`);
    return;
  }
  const current = projectGrant.roleKeys || [];
  if (current.includes(ADMIN_ROLE)) {
    console.log(`${label} already has ${ADMIN_ROLE}`);
    return;
  }
  await mgmt(
    'PUT',
    `/management/v1/users/${userId}/grants/${projectGrant.id}`,
    { roleKeys: [...new Set([...current, ...roleKeys])] },
    token,
  );
  console.log(`Granted ${ADMIN_ROLE} to ${label}`);
}

(async () => {
  const token = await adminSessionToken();
  console.log('Admin session established');

  await ensureUserGrant(token, PRESTON_USER_ID, [ADMIN_ROLE], 'prestonh');

  const actionId = await ensureAction(token);

  const allActions = await mgmt(
    'POST',
    '/management/v1/actions/_search',
    { query: { offset: '0', limit: 100, asc: true } },
    token,
  );
  const groupActionIds = (allActions.result || [])
    .filter((a) => a.name.endsWith('Groups') && a.state === 'ACTION_STATE_ACTIVE')
    .map((a) => a.id);
  console.log(`Active *Groups actions: ${groupActionIds.join(', ')}`);

  await attachActionToTrigger(token, TRIGGER_PRE_USERINFO, actionId, 'Pre Userinfo creation', groupActionIds);
  await attachActionToTrigger(token, TRIGGER_PRE_ACCESS, actionId, 'Pre access token creation', groupActionIds);

  console.log('\n=== nextcloudGroups complement action ready ===');
  console.log(`Action ID: ${actionId}`);
  console.log(`Maps Zitadel role ${ADMIN_ROLE} -> groups claim ["${NC_ADMIN_GROUP}"]`);
  console.log('User must sign out of Nextcloud and sign in again via Zitadel');
})().catch((e) => {
  console.error(e.message || e);
  process.exit(1);
});
