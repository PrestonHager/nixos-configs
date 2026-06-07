#!/usr/bin/env node
/**
 * Create/update Jellyfin OIDC app in Zitadel, jellyfin_admin/jellyfin_user roles,
 * and grants for prestonh (admin) and dylanh (user).
 * Run on ace as root (needs login-client key).
 *
 * Prints CLIENT_ID and CLIENT_SECRET for jellyfin-oauth sops secret.
 */
const fs = require('fs');
const crypto = require('crypto');
const http = require('http');

const KEY_FILE = '/zitadel/login-client/tls.key';
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

function makeToken() {
  const key = fs.readFileSync(KEY_FILE, 'utf8');
  const b64 = (o) => Buffer.from(o).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
  const now = Math.floor(Date.now() / 1000);
  const data = `${b64(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))}.${b64(JSON.stringify({ iss: 'login-client', sub: 'login-client', aud: AUDIENCE, iat: now, exp: now + 3600 }))}`;
  const sig = crypto.createSign('RSA-SHA256').update(data).sign(key).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
  return `${data}.${sig}`;
}

function api(method, path, body) {
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
          Authorization: `Bearer ${makeToken()}`,
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

async function findJellyfinApp() {
  const apps = await api('POST', `/management/v1/projects/${PROJECT_ID}/apps/_search`, {
    query: { offset: '0', limit: 100, asc: true },
  });
  return (apps.result || []).find((a) => a.name === APP_NAME);
}

async function createJellyfinApp() {
  const resp = await api('POST', `/management/v1/projects/${PROJECT_ID}/apps/oidc`, {
    name: APP_NAME,
    redirectUris: REDIRECT_URIS,
    responseTypes: ['OIDC_RESPONSE_TYPE_CODE'],
    grantTypes: ['OIDC_GRANT_TYPE_AUTHORIZATION_CODE', 'OIDC_GRANT_TYPE_REFRESH_TOKEN'],
    appType: 'OIDC_APP_TYPE_WEB',
    authMethodType: 'OIDC_AUTH_METHOD_TYPE_BASIC',
    accessTokenType: 'OIDC_TOKEN_TYPE_BEARER',
    idTokenRoleAssertion: true,
    accessTokenRoleAssertion: true,
    devMode: false,
  });
  console.log(`Created Jellyfin OIDC app id=${resp.appId}`);
  return { appId: resp.appId, clientId: resp.clientId, clientSecret: resp.clientSecret };
}

async function updateJellyfinApp(appId) {
  const app = await api('GET', `/management/v1/projects/${PROJECT_ID}/apps/${appId}`);
  const oidc = app.app?.oidcConfig || app.oidcConfig || {};
  const redirectUris = [...new Set([...(oidc.redirectUris || []), ...REDIRECT_URIS])];
  await api('PUT', `/management/v1/projects/${PROJECT_ID}/apps/${appId}`, {
    name: APP_NAME,
    oidcConfig: {
      ...oidc,
      redirectUris,
      responseTypes: oidc.responseTypes || ['OIDC_RESPONSE_TYPE_CODE'],
      grantTypes: oidc.grantTypes || ['OIDC_GRANT_TYPE_AUTHORIZATION_CODE', 'OIDC_GRANT_TYPE_REFRESH_TOKEN'],
      appType: oidc.appType || 'OIDC_APP_TYPE_WEB',
      authMethodType: oidc.authMethodType || 'OIDC_AUTH_METHOD_TYPE_BASIC',
      accessTokenType: oidc.accessTokenType || 'OIDC_TOKEN_TYPE_BEARER',
      accessTokenRoleAssertion: true,
      idTokenRoleAssertion: true,
      roleAssertion: true,
    },
  });
  console.log(`Updated Jellyfin OIDC app ${appId} (redirect + role assertions)`);
  const refreshed = await api('GET', `/management/v1/projects/${PROJECT_ID}/apps/${appId}`);
  const cfg = refreshed.app?.oidcConfig || refreshed.oidcConfig || {};
  return {
    appId,
    clientId: cfg.clientId || refreshed.clientId,
    clientSecret: cfg.clientSecret || refreshed.clientSecret || null,
  };
}

async function ensureProjectRole(roleKey, displayName) {
  try {
    await api('POST', `/management/v1/projects/${PROJECT_ID}/roles`, {
      roleKey,
      displayName,
    });
    console.log(`Created project role ${roleKey}`);
  } catch (err) {
    if (String(err.message).includes('already exists') || String(err.message).includes('RoleKeyDuplicated')) {
      console.log(`Project role ${roleKey} already exists`);
    } else if (String(err.message).includes('No matching permissions')) {
      console.warn(`WARN: cannot create role ${roleKey} via API (${err.message}); create it in Zitadel console if missing`);
    } else {
      throw err;
    }
  }
}

async function ensureUserGrant(userId, roleKeys, label) {
  try {
    const grants = await api('POST', '/management/v1/users/grants/_search', {
      query: { offset: '0', limit: 100, asc: true },
      queries: [{ userIdQuery: { userId } }],
    });
    const projectGrant = (grants.result || []).find((g) => g.projectId === PROJECT_ID);
    const existingRoles = projectGrant?.roleKeys || [];
    const missing = roleKeys.filter((r) => !existingRoles.includes(r));
    if (missing.length === 0) {
      console.log(`${label} already has required Jellyfin role(s): ${roleKeys.join(', ')}`);
      return;
    }
    const nextRoles = [...new Set([...existingRoles, ...roleKeys])];
    if (projectGrant) {
      await api('PUT', `/management/v1/users/${userId}/grants/${projectGrant.id}`, { roleKeys: nextRoles });
      console.log(`Updated ${label} grant with ${missing.join(', ')}`);
      return;
    }
    await api('POST', `/management/v1/users/${userId}/grants`, {
      projectId: PROJECT_ID,
      roleKeys,
    });
    console.log(`Granted ${roleKeys.join(', ')} to ${label}`);
  } catch (err) {
    if (String(err.message).includes('No matching permissions')) {
      console.warn(`WARN: cannot grant Jellyfin roles to ${label} via API; assign in Zitadel console Authorizations`);
      return;
    }
    throw err;
  }
}

const GROUPS_ACTION = `function jellyfinGroups(ctx, api) {
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
    api.v1.claims.setClaim('groups', groups);
  }
}`;

(async () => {
  await ensureProjectRole(ADMIN_ROLE, 'Jellyfin Admin');
  await ensureProjectRole(USER_ROLE, 'Jellyfin User');

  let app = await findJellyfinApp();
  let credentials;
  if (!app) {
    credentials = await createJellyfinApp();
  } else {
    console.log(`Found existing Jellyfin app id=${app.id} clientId=${app.clientId || app.oidcConfig?.clientId}`);
    credentials = await updateJellyfinApp(app.id);
  }

  // Preston: admin only (do not also grant jellyfin_user — Jellyfin SSO rejects multiple role claims)
  await ensureUserGrant(PRESTON_USER_ID, [ADMIN_ROLE], 'prestonh');
  await ensureUserGrant(DYLAN_USER_ID, [USER_ROLE], 'dylanh');

  console.log('\n=== Jellyfin OIDC credentials (store in jellyfin-oauth sops secret) ===');
  console.log(`JELLYFIN_OIDC_CLIENT_ID=${credentials.clientId}`);
  if (credentials.clientSecret) {
    console.log(`JELLYFIN_OIDC_CLIENT_SECRET=${credentials.clientSecret}`);
  } else {
    console.log('# CLIENT_SECRET not returned (existing app). Rotate secret in Zitadel console if needed.');
  }
  console.log(`ZITADEL_PROJECT_ID=${PROJECT_ID}`);
  console.log(`ADMIN_ROLE=${ADMIN_ROLE}`);
  console.log(`USER_ROLE=${USER_ROLE}`);
  console.log(`REDIRECT_URIS=${REDIRECT_URIS.join(' ')}`);
  console.log('\n=== MANUAL: Zitadel Complement Token action (required for role → groups mapping) ===');
  console.log('Console → Actions → New → Complement Token → name: jellyfinGroups');
  console.log('Triggers: Pre Userinfo creation, Pre access token creation');
  console.log('Add this script, then attach the action to the Complement Token flow:\n');
  console.log(GROUPS_ACTION);
})().catch((e) => {
  console.error(e.message || e);
  process.exit(1);
});
