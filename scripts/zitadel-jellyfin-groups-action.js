#!/usr/bin/env node
/**
 * Create jellyfinGroups Complement Token action and fix prestonh grant (admin only).
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
const DYLAN_USER_ID = '376328957357726005';
const ACTION_NAME = 'jellyfinGroups';
const ROLE_CLAIM = 'groups';
const ADMIN_ROLE = 'jellyfin_admin';
const USER_ROLE = 'jellyfin_user';
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
    for (const role of roles) {
      if (role === '${ADMIN_ROLE}') {
        groups.push('${ADMIN_ROLE}');
        break;
      }
      if (role === '${USER_ROLE}') {
        groups.push('${USER_ROLE}');
      }
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
    if (!script.includes("setClaim('groups'")) {
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

async function getTriggerActionIds(token, triggerType) {
  return [];
}

async function attachActionToTrigger(token, triggerType, actionId, label, allGroupActionIds) {
  const existing = await getTriggerActionIds(token, triggerType);
  const merged = [...new Set([...existing, ...allGroupActionIds])];
  if (existing.includes(actionId) && merged.length === existing.length) {
    console.log(`Action already on ${label} trigger`);
    return;
  }
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

async function setUserGrantRoles(token, userId, roleKeys, label) {
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
  const otherRoles = (projectGrant.roleKeys || []).filter(
    (r) => r !== ADMIN_ROLE && r !== USER_ROLE,
  );
  const nextRoles = [...new Set([...otherRoles, ...roleKeys])];
  const currentJellyfin = (projectGrant.roleKeys || []).filter((r) => r === ADMIN_ROLE || r === USER_ROLE);
  if (JSON.stringify(currentJellyfin.sort()) === JSON.stringify(roleKeys.sort())) {
    console.log(`${label} Jellyfin roles already correct: ${roleKeys.join(', ')}`);
    return;
  }
  await mgmt(
    'PUT',
    `/management/v1/users/${userId}/grants/${projectGrant.id}`,
    { roleKeys: nextRoles },
    token,
  );
  console.log(`Updated ${label} Jellyfin roles: ${currentJellyfin.join(', ') || '(none)'} -> ${roleKeys.join(', ')}`);
}

(async () => {
  const token = await adminSessionToken();
  console.log('Admin session established');

  await setUserGrantRoles(token, PRESTON_USER_ID, [ADMIN_ROLE], 'prestonh');
  await setUserGrantRoles(token, DYLAN_USER_ID, [USER_ROLE], 'dylanh');

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

  console.log('\n=== jellyfinGroups complement action ready ===');
  console.log(`Action ID: ${actionId}`);
  console.log('Preston: jellyfin_admin only (no jellyfin_user)');
  console.log('Dylan: jellyfin_user only');
})().catch((e) => {
  console.error(e.message || e);
  process.exit(1);
});
