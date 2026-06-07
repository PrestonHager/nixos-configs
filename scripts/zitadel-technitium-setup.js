#!/usr/bin/env node
/**
 * Create Technitium OIDC app, technitium_admin role, and grant to prestonh.
 * Run on ace as root (login-client key + zitadel-env secrets).
 *
 * Prints client credentials for sops (technitium.yaml):
 *   technitium-oidc-client-id
 *   technitium-oidc-client-secret
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
const APP_NAME = 'Technitium';
const ROLE_KEY = 'technitium_admin';
const REDIRECT_URI = 'https://dns.prestonhager.com/sso/callback';

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

async function ensureRole() {
  try {
    await api('POST', `/management/v1/projects/${PROJECT_ID}/roles`, {
      roleKey: ROLE_KEY,
      displayName: 'Technitium Admin',
    });
    console.log(`Created project role ${ROLE_KEY}`);
  } catch (err) {
    if (String(err.message).includes('already exists') || String(err.message).includes('RoleKeyDuplicated')) {
      console.log(`Project role ${ROLE_KEY} already exists`);
    } else {
      throw err;
    }
  }
}

async function ensureGrant() {
  const grants = await api('POST', '/management/v1/users/grants/_search', {
    query: { offset: '0', limit: 100, asc: true },
    queries: [{ userIdQuery: { userId: PRESTON_USER_ID } }],
  });
  const existing = (grants.result || []).find(
    (g) => g.projectId === PROJECT_ID && (g.roleKeys || []).includes(ROLE_KEY),
  );
  if (existing) {
    console.log(`User prestonh already has ${ROLE_KEY}`);
    return;
  }
  const projectGrant = (grants.result || []).find((g) => g.projectId === PROJECT_ID);
  if (projectGrant) {
    await api('PUT', `/management/v1/users/${PRESTON_USER_ID}/grants/${projectGrant.id}`, {
      roleKeys: [...new Set([...(projectGrant.roleKeys || []), ROLE_KEY])],
    });
  } else {
    await api('POST', `/management/v1/users/${PRESTON_USER_ID}/grants`, {
      projectId: PROJECT_ID,
      roleKeys: [ROLE_KEY],
    });
  }
  console.log(`Granted ${ROLE_KEY} to prestonh (${PRESTON_USER_ID})`);
}

async function findApp() {
  const apps = await api('POST', `/management/v1/projects/${PROJECT_ID}/apps/_search`, {
    query: { offset: '0', limit: 100, asc: true },
  });
  return (apps.result || []).find((a) => a.name === APP_NAME);
}

async function createOrUpdateApp() {
  let app = await findApp();
  if (!app) {
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
    });
    console.log(`Created Technitium OIDC app ${resp.appId}`);
    return { clientId: resp.clientId, clientSecret: resp.clientSecret };
  }

  const detail = await api('GET', `/management/v1/projects/${PROJECT_ID}/apps/${app.id}`);
  const oidc = detail.app?.oidcConfig || detail.oidcConfig || {};
  await api('PUT', `/management/v1/projects/${PROJECT_ID}/apps/${app.id}`, {
    name: APP_NAME,
    oidcConfig: {
      ...oidc,
      redirectUris: [...new Set([...(oidc.redirectUris || []), REDIRECT_URI])],
      accessTokenRoleAssertion: true,
      idTokenRoleAssertion: true,
      roleAssertion: true,
    },
  });
  const refreshed = await api('GET', `/management/v1/projects/${PROJECT_ID}/apps/${app.id}`);
  const cfg = refreshed.app?.oidcConfig || refreshed.oidcConfig || {};
  return { clientId: cfg.clientId || app.clientId, clientSecret: cfg.clientSecret || null };
}

(async () => {
  await ensureRole();
  const creds = await createOrUpdateApp();
  await ensureGrant();
  console.log('\n=== Technitium OIDC credentials (add to sops technitium.yaml) ===');
  console.log(`technitium-oidc-client-id: ${creds.clientId}`);
  if (creds.clientSecret) {
    console.log(`technitium-oidc-client-secret: ${creds.clientSecret}`);
  } else {
    console.log('Client secret not returned (existing app). Regenerate in Zitadel console if needed.');
  }
  console.log(`\nRedirect URI: ${REDIRECT_URI}`);
  console.log(`Zitadel project role for Technitium admin: ${ROLE_KEY}`);
})().catch((err) => {
  console.error(err.message || err);
  process.exit(1);
});
