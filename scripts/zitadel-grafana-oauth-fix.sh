#!/usr/bin/env bash
# Enable Grafana OIDC role assertions and grant grafana_admin to admin@prestonhager.com
set -euo pipefail

ORG_ID='376181820519160098'
PROJECT_ID='376196450586990901'
GRAFANA_CLIENT_ID='376196647316625717'
ADMIN_USER_ID='376181820519684386'
ROLE_KEY='grafana_admin'

echo '=== Before: OIDC role assertion flags ==='
podman exec zitadel-db psql -U zitadel -d zitadel -c \
  "SELECT client_id, access_token_role_assertion, id_token_role_assertion FROM projections.apps7_oidc_configs WHERE client_id='${GRAFANA_CLIENT_ID}';"

echo '=== Enabling role assertions on Grafana OIDC app ==='
podman exec zitadel-db psql -U zitadel -d zitadel -c \
  "UPDATE projections.apps7_oidc_configs SET access_token_role_assertion=true, id_token_role_assertion=true WHERE client_id='${GRAFANA_CLIENT_ID}';"

echo '=== Before: admin user grants ==='
podman exec zitadel-db psql -U zitadel -d zitadel -c \
  "SELECT id, user_id, project_id, roles FROM projections.user_grants5 WHERE user_id='${ADMIN_USER_ID}';"

echo '=== Grant grafana_admin to admin user (via management API) ==='
cat >/tmp/zitadel-grant.js <<'JS'
const fs = require('fs');
const crypto = require('crypto');
const http = require('http');
const KEY_FILE = '/zitadel/login-client/tls.key';
const PUBLIC_HOST = 'zitadel.prestonhager.com';
const AUDIENCE = `https://${PUBLIC_HOST}`;
const ORG_ID = process.env.ORG_ID;
const PROJECT_ID = process.env.PROJECT_ID;
const ADMIN_USER_ID = process.env.ADMIN_USER_ID;
const ROLE_KEY = process.env.ROLE_KEY;

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
    const req = http.request({
      hostname: '127.0.0.1', port: 9080, path, method,
      headers: {
        Host: PUBLIC_HOST, 'X-Forwarded-Proto': 'https', 'X-Zitadel-Orgid': ORG_ID,
        Authorization: `Bearer ${makeToken()}`, Accept: 'application/json', 'Content-Type': 'application/json',
        ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}),
      },
    }, (res) => {
      let raw = '';
      res.on('data', (c) => (raw += c));
      res.on('end', () => {
        if (res.statusCode >= 400) reject(new Error(`${res.statusCode} ${method} ${path}: ${raw}`));
        else resolve(raw ? JSON.parse(raw) : {});
      });
    });
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
  const existing = (grants.result || []).find((g) => g.projectId === PROJECT_ID);
  if (existing) {
    const roleKeys = [...new Set([...(existing.roleKeys || []), ROLE_KEY])];
    await api('PUT', `/management/v1/users/${ADMIN_USER_ID}/grants/${existing.id}`, { roleKeys });
    console.log('Updated grant', existing.id, roleKeys);
  } else {
    const created = await api('POST', `/management/v1/users/${ADMIN_USER_ID}/grants`, {
      projectId: PROJECT_ID,
      roleKeys: [ROLE_KEY],
    });
    console.log('Created grant', JSON.stringify(created));
  }
})().catch((e) => { console.error(e.message); process.exit(1); });
JS

ORG_ID="$ORG_ID" PROJECT_ID="$PROJECT_ID" ADMIN_USER_ID="$ADMIN_USER_ID" ROLE_KEY="$ROLE_KEY" \
  nix shell nixpkgs#nodejs_22 -c node /tmp/zitadel-grant.js

echo '=== After ==='
podman exec zitadel-db psql -U zitadel -d zitadel -c \
  "SELECT client_id, access_token_role_assertion, id_token_role_assertion FROM projections.apps7_oidc_configs WHERE client_id='${GRAFANA_CLIENT_ID}';"
podman exec zitadel-db psql -U zitadel -d zitadel -c \
  "SELECT id, user_id, project_id, roles FROM projections.user_grants5 WHERE user_id='${ADMIN_USER_ID}';"
