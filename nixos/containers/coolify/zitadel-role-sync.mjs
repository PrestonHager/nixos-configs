// Reads Coolify role grants from Zitadel and prints {email: "admin"|"member"}.
// Run by coolify-zitadel-role-sync.service (nixos/containers/coolify.nix) as
// root on ace; uses the same login-client + admin session as Zitadel's console.
import fs from 'node:fs';
import crypto from 'node:crypto';
import http from 'node:http';

const KEY_FILE = '/zitadel/login-client/tls.key';
const SECRETS = '/run/secrets/zitadel-env';
const PUBLIC_HOST = 'zitadel.prestonhager.com';
const ORG_ID = '376181820519160098';
const PROJECT_ID = process.env.COOLIFY_ZITADEL_PROJECT_ID;

function loadEnv(prefix) {
  const line = fs.readFileSync(SECRETS, 'utf8').split('\n').find((l) => l.startsWith(prefix));
  if (!line) throw new Error(`${prefix} not found in ${SECRETS}`);
  return line.slice(prefix.length).trim();
}

function loginClientToken() {
  const b64 = (s) => Buffer.from(s).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const claims = { iss: 'login-client', sub: 'login-client', aud: `https://${PUBLIC_HOST}`, iat: now, exp: now + 300 };
  const data = `${b64(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))}.${b64(JSON.stringify(claims))}`;
  const sig = crypto.createSign('RSA-SHA256').update(data).sign(fs.readFileSync(KEY_FILE, 'utf8')).toString('base64url');
  return `${data}.${sig}`;
}

function api(method, path, body, bearer, withOrg = true) {
  return new Promise((resolve, reject) => {
    const payload = body ? JSON.stringify(body) : null;
    const req = http.request({
      hostname: '127.0.0.1', port: 9080, path, method,
      headers: {
        Host: PUBLIC_HOST, 'X-Forwarded-Proto': 'https', 'X-Forwarded-Host': PUBLIC_HOST,
        ...(withOrg ? { 'X-Zitadel-Orgid': ORG_ID } : {}),
        Authorization: `Bearer ${bearer}`, Accept: 'application/json', 'Content-Type': 'application/json',
        ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}),
      },
    }, (res) => {
      let raw = '';
      res.on('data', (c) => (raw += c));
      res.on('end', () => (res.statusCode >= 400
        ? reject(new Error(`${res.statusCode} ${method} ${path}`))
        : resolve(raw ? JSON.parse(raw) : {})));
    });
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

async function adminToken() {
  const lc = loginClientToken();
  const s = await api('POST', '/v2/sessions', { checks: { user: { loginName: loadEnv('ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME=') } } }, lc, false);
  const p = await api('PATCH', `/v2/sessions/${s.sessionId}`, { checks: { password: { password: loadEnv('ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD=') } } }, lc, false);
  return p.sessionToken || s.sessionToken;
}

if (!PROJECT_ID) throw new Error('COOLIFY_ZITADEL_PROJECT_ID is not set');
const token = await adminToken();
const grants = await api('POST', '/management/v1/users/grants/_search', {
  query: { limit: 1000 },
  queries: [{ projectIdQuery: { projectId: PROJECT_ID } }],
}, token);

const roles = {};
for (const g of grants.result || []) {
  if (g.state && g.state !== 'USER_GRANT_STATE_ACTIVE') continue;
  const email = String(g.email || '').trim().toLowerCase();
  if (!email) continue;
  const keys = g.roleKeys || [];
  if (keys.includes('coolify_admin')) roles[email] = 'admin';
  else if (keys.includes('coolify_member') && roles[email] !== 'admin') roles[email] = 'member';
}
process.stdout.write(JSON.stringify(roles));

