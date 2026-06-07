#!/usr/bin/env node
/**
 * Create Jellyfin OIDC app + jellyfin_admin/jellyfin_user roles using admin session (v2 API).
 * Run on ace as root. Requires zitadel-env secrets.
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
const APP_NAME = 'Jellyfin';
const ADMIN_ROLE = 'jellyfin_admin';
const USER_ROLE = 'jellyfin_user';
const REDIRECT_URIS = [
  'https://jellyfin.prestonhager.com/sso/OID/redirect/zitadel',
  'https://jellyfin.prestonhager.com/sso/OID/r/zitadel',
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

async function findJellyfinApp(token) {
  const apps = await mgmt(
    'POST',
    `/management/v1/projects/${PROJECT_ID}/apps/_search`,
    { query: { offset: '0', limit: 100, asc: true } },
    token,
  );
  return (apps.result || []).find((a) => a.name === APP_NAME);
}

async function ensureRole(token, roleKey, displayName) {
  try {
    await mgmt(
      'POST',
      `/management/v1/projects/${PROJECT_ID}/roles`,
      { roleKey, displayName },
      token,
    );
    console.log(`Created role ${roleKey}`);
  } catch (e) {
    if (String(e.message).includes('already exists') || String(e.message).includes('RoleKeyDuplicated')) {
      console.log(`Role ${roleKey} exists`);
    } else throw e;
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
  const existingRoles = projectGrant?.roleKeys || [];
  const missing = roleKeys.filter((r) => !existingRoles.includes(r));
  if (missing.length === 0) {
    console.log(`${label} already has Jellyfin role(s): ${roleKeys.join(', ')}`);
    return;
  }
  const nextRoles = [...new Set([...existingRoles, ...roleKeys])];
  if (projectGrant) {
    await mgmt(
      'PUT',
      `/management/v1/users/${userId}/grants/${projectGrant.id}`,
      { roleKeys: nextRoles },
      token,
    );
  } else {
    await mgmt(
      'POST',
      `/management/v1/users/${userId}/grants`,
      { projectId: PROJECT_ID, roleKeys },
      token,
    );
  }
  console.log(`Granted ${missing.join(', ')} to ${label}`);
}

async function createOrUpdateApp(token) {
  let app = await findJellyfinApp(token);
  if (!app) {
    const resp = await mgmt(
      'POST',
      `/management/v1/projects/${PROJECT_ID}/apps/oidc`,
      {
        name: APP_NAME,
        redirectUris: REDIRECT_URIS,
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
    console.log(`Created Jellyfin app ${resp.appId}`);
    return { clientId: resp.clientId, clientSecret: resp.clientSecret };
  }

  const detail = await mgmt('GET', `/management/v1/projects/${PROJECT_ID}/apps/${app.id}`, null, token);
  const oidc = detail.app?.oidcConfig || detail.oidcConfig || {};
  await mgmt(
    'PUT',
    `/management/v1/projects/${PROJECT_ID}/apps/${app.id}`,
    {
      name: APP_NAME,
      oidcConfig: {
        ...oidc,
        redirectUris: [...new Set([...(oidc.redirectUris || []), ...REDIRECT_URIS])],
        accessTokenRoleAssertion: true,
        idTokenRoleAssertion: true,
        roleAssertion: true,
      },
    },
    token,
  );
  const refreshed = await mgmt('GET', `/management/v1/projects/${PROJECT_ID}/apps/${app.id}`, null, token);
  const cfg = refreshed.app?.oidcConfig || refreshed.oidcConfig || {};
  return { clientId: cfg.clientId || app.clientId, clientSecret: cfg.clientSecret || null };
}

const GROUPS_ACTION = `function jellyfinGroups(ctx, api) {
  if (!ctx.v1.user || !ctx.v1.user.grants || !ctx.v1.user.grants.grants) {
    return;
  }
  const groups = [];
  for (const grant of ctx.v1.user.grants.grants) {
    const roleKeys = grant.roleKeys || [];
    if (roleKeys.includes('${ADMIN_ROLE}')) {
      groups.push('${ADMIN_ROLE}');
    }
    if (roleKeys.includes('${USER_ROLE}')) {
      groups.push('${USER_ROLE}');
    }
  }
  if (groups.length > 0) {
    api.v1.claims.setClaim('groups', groups);
  }
}`;

(async () => {
  const token = await adminSessionToken();
  console.log('Admin session established');
  await ensureRole(token, ADMIN_ROLE, 'Jellyfin Admin');
  await ensureRole(token, USER_ROLE, 'Jellyfin User');
  const creds = await createOrUpdateApp(token);
  await ensureUserGrant(token, PRESTON_USER_ID, [ADMIN_ROLE], 'prestonh');
  await ensureUserGrant(token, DYLAN_USER_ID, [USER_ROLE], 'dylanh');
  console.log('\n=== Jellyfin OIDC credentials ===');
  console.log(`JELLYFIN_OIDC_CLIENT_ID=${creds.clientId}`);
  if (creds.clientSecret) console.log(`JELLYFIN_OIDC_CLIENT_SECRET=${creds.clientSecret}`);
  console.log(`ZITADEL_PROJECT_ID=${PROJECT_ID}`);
  console.log(`ADMIN_ROLE=${ADMIN_ROLE}`);
  console.log(`USER_ROLE=${USER_ROLE}`);
  console.log(`REDIRECT_URIS=${REDIRECT_URIS.join(' ')}`);
  console.log('\n=== MANUAL: Zitadel Complement Token action (required for role → groups mapping) ===');
  console.log('See docs/jellyfin-ace.md — create action jellyfinGroups on Complement Token flow:\n');
  console.log(GROUPS_ACTION);
})().catch((e) => {
  console.error(e.message || e);
  process.exit(1);
});
