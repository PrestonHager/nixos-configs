#!/usr/bin/env node
/**
 * Create/update Nextcloud OIDC app in Zitadel, nextcloud_admin role, and admin grant.
 * Run on ace as root (needs login-client key).
 *
 * Prints CLIENT_ID and CLIENT_SECRET for nextcloud-oidc-env sops secret.
 */
const fs = require('fs');
const crypto = require('crypto');
const http = require('http');

const KEY_FILE = '/zitadel/login-client/tls.key';
const PUBLIC_HOST = 'zitadel.prestonhager.com';
const AUDIENCE = `https://${PUBLIC_HOST}`;
const ORG_ID = '376181820519160098';
const PROJECT_ID = '376196450586990901';
const ADMIN_USER_ID = '376181820519684386';
const APP_NAME = 'Nextcloud';
const ROLE_KEY = 'nextcloud_admin';
const REDIRECT_URI = 'https://cloud.prestonhager.com/apps/user_oidc/code';

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

async function findNextcloudApp() {
  const apps = await api('POST', `/management/v1/projects/${PROJECT_ID}/apps/_search`, {
    query: { offset: '0', limit: 100, asc: true },
  });
  return (apps.result || []).find((a) => a.name === APP_NAME);
}

async function createNextcloudApp() {
  const resp = await api('POST', `/management/v1/projects/${PROJECT_ID}/apps/oidc`, {
    name: APP_NAME,
    redirectUris: [REDIRECT_URI],
    responseTypes: ['OIDC_RESPONSE_TYPE_CODE'],
    grantTypes: ['OIDC_GRANT_TYPE_AUTHORIZATION_CODE', 'OIDC_GRANT_TYPE_REFRESH_TOKEN'],
    appType: 'OIDC_APP_TYPE_WEB',
    authMethodType: 'OIDC_AUTH_METHOD_TYPE_BASIC',
    accessTokenType: 'OIDC_TOKEN_TYPE_BEARER',
    idTokenRoleAssertion: true,
    accessTokenRoleAssertion: true,
    devMode: false,
  });
  console.log(`Created Nextcloud OIDC app id=${resp.appId}`);
  return { appId: resp.appId, clientId: resp.clientId, clientSecret: resp.clientSecret };
}

async function updateNextcloudApp(appId) {
  const app = await api('GET', `/management/v1/projects/${PROJECT_ID}/apps/${appId}`);
  const oidc = app.app?.oidcConfig || app.oidcConfig || {};
  const redirectUris = [...new Set([...(oidc.redirectUris || []), REDIRECT_URI])];
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
  console.log(`Updated Nextcloud OIDC app ${appId} (redirect + role assertions)`);
  const refreshed = await api('GET', `/management/v1/projects/${PROJECT_ID}/apps/${appId}`);
  const cfg = refreshed.app?.oidcConfig || refreshed.oidcConfig || {};
  return {
    appId,
    clientId: cfg.clientId || refreshed.clientId,
    clientSecret: cfg.clientSecret || refreshed.clientSecret || null,
  };
}

async function ensureProjectRole() {
  try {
    await api('POST', `/management/v1/projects/${PROJECT_ID}/roles`, {
      roleKey: ROLE_KEY,
      displayName: 'Nextcloud Admin',
    });
    console.log(`Created project role ${ROLE_KEY}`);
  } catch (err) {
    if (String(err.message).includes('already exists') || String(err.message).includes('RoleKeyDuplicated')) {
      console.log(`Project role ${ROLE_KEY} already exists`);
    } else if (String(err.message).includes('No matching permissions')) {
      console.warn(`WARN: cannot create role ${ROLE_KEY} via API (${err.message}); create it in Zitadel console if missing`);
    } else {
      throw err;
    }
  }
}

async function ensureUserGrant() {
  try {
    const grants = await api('POST', '/management/v1/users/grants/_search', {
      query: { offset: '0', limit: 100, asc: true },
      queries: [{ userIdQuery: { userId: ADMIN_USER_ID } }],
    });
    const existing = (grants.result || []).find(
      (g) => g.projectId === PROJECT_ID && (g.roleKeys || []).includes(ROLE_KEY),
    );
    if (existing) {
      console.log(`Admin user already has ${ROLE_KEY}`);
      return;
    }
    const projectGrant = (grants.result || []).find((g) => g.projectId === PROJECT_ID);
    if (projectGrant) {
      const roleKeys = [...new Set([...(projectGrant.roleKeys || []), ROLE_KEY])];
      await api('PUT', `/management/v1/users/${ADMIN_USER_ID}/grants/${projectGrant.id}`, { roleKeys });
      console.log(`Updated grant ${projectGrant.id} with ${ROLE_KEY}`);
      return;
    }
    await api('POST', `/management/v1/users/${ADMIN_USER_ID}/grants`, {
      projectId: PROJECT_ID,
      roleKeys: [ROLE_KEY],
    });
    console.log(`Granted ${ROLE_KEY} to admin user`);
  } catch (err) {
    if (String(err.message).includes('No matching permissions')) {
      console.warn(`WARN: cannot grant ${ROLE_KEY} via API; assign role in Zitadel console Authorizations`);
      return;
    }
    throw err;
  }
}

const GROUPS_ACTION = `function nextcloudGroups(ctx, api) {
  if (!ctx.v1.user || !ctx.v1.user.grants || !ctx.v1.user.grants.grants) {
    return;
  }
  const groups = [];
  for (const grant of ctx.v1.user.grants.grants) {
    const roleKeys = grant.roleKeys || [];
    if (roleKeys.includes('${ROLE_KEY}')) {
      groups.push('admin');
      break;
    }
  }
  api.v1.claims.setClaim('groups', groups);
}`;

(async () => {
  await ensureProjectRole();

  let app = await findNextcloudApp();
  let credentials;
  if (!app) {
    credentials = await createNextcloudApp();
  } else {
    console.log(`Found existing Nextcloud app id=${app.id} clientId=${app.clientId || app.oidcConfig?.clientId}`);
    credentials = await updateNextcloudApp(app.id);
  }

  await ensureUserGrant();

  console.log('\n=== Nextcloud OIDC credentials (store in nextcloud-oidc-env sops secret) ===');
  console.log(`NEXTCLOUD_OIDC_CLIENT_ID=${credentials.clientId}`);
  if (credentials.clientSecret) {
    console.log(`NEXTCLOUD_OIDC_CLIENT_SECRET=${credentials.clientSecret}`);
  } else {
    console.log('# CLIENT_SECRET not returned (existing app). Rotate secret in Zitadel console if needed.');
  }
  console.log(`ZITADEL_PROJECT_ID=${PROJECT_ID}`);
  console.log(`ADMIN_ROLE=${ROLE_KEY}`);
  console.log(`REDIRECT_URI=${REDIRECT_URI}`);
  console.log('\n=== MANUAL: Zitadel Complement Token action (required for admin group mapping) ===');
  console.log('Console → Actions → New → Complement Token → name: nextcloudGroups');
  console.log('Triggers: Pre Userinfo creation, Pre access token creation');
  console.log('Add this script, then attach the action to the Complement Token flow:\n');
  console.log(GROUPS_ACTION);
})().catch((e) => {
  console.error(e.message || e);
  process.exit(1);
});
