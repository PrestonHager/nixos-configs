#!/usr/bin/env node
/** Grant matrix_admin (+ ensure grafana_admin) on Home Lab project for admin user. */
const fs = require('fs');
const crypto = require('crypto');
const http = require('http');

const KEY_FILE = '/zitadel/login-client/tls.key';
const PUBLIC_HOST = 'zitadel.prestonhager.com';
const AUDIENCE = `https://${PUBLIC_HOST}`;
const ORG_ID = '376181820519160098';
const PROJECT_ID = '376196450586990901';
const ADMIN_USER_ID = '376181820519684386';
const ROLES = ['grafana_admin', 'matrix_admin'];

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

(async () => {
  const grants = await api('POST', '/management/v1/users/grants/_search', {
    query: { offset: '0', limit: 100, asc: true },
    queries: [{ userIdQuery: { userId: ADMIN_USER_ID } }],
  });
  const projectGrant = (grants.result || []).find((g) => g.projectId === PROJECT_ID);
  const roleKeys = [...new Set([...(projectGrant?.roleKeys || []), ...ROLES])];
  if (projectGrant) {
    await api('PUT', `/management/v1/users/${ADMIN_USER_ID}/grants/${projectGrant.id}`, { roleKeys });
    console.log(`Updated grant ${projectGrant.id}: ${roleKeys.join(', ')}`);
  } else {
    await api('POST', `/management/v1/users/${ADMIN_USER_ID}/grants`, { projectId: PROJECT_ID, roleKeys });
    console.log(`Created grant with roles: ${roleKeys.join(', ')}`);
  }
})().catch((e) => {
  console.error(e.message || e);
  process.exit(1);
});
