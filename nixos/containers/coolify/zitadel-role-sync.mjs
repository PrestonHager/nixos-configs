// Reads Coolify role grants from Zitadel and prints {email: "admin"|"member"}.
// Run by coolify-zitadel-roles.service (nixos/containers/coolify-sso.nix) as
// root on ace; uses the same login-client + admin session as Zitadel's console.
// The admin session is deleted again afterwards so runs do not pile up.
// Any failure (timeout, HTTP error, unexpected response) exits non-zero so
// apply-roles.php never runs on a partial or empty result.
import fs from 'node:fs';
import crypto from 'node:crypto';
import http from 'node:http';

const KEY_FILE = '/zitadel/login-client/tls.key';
const SECRETS = '/run/secrets/zitadel-env';
const PUBLIC_HOST = 'zitadel.prestonhager.com';
const ORG_ID = '376181820519160098';
const PROJECT_ID = process.env.COOLIFY_ZITADEL_PROJECT_ID;
const TIMEOUT_MS = 15000;

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
      res.on('error', reject);
      res.on('end', () => {
        if (res.statusCode >= 400) return reject(new Error(`${res.statusCode} ${method} ${path}`));
        try {
          resolve(raw ? JSON.parse(raw) : {});
        } catch (e) {
          reject(new Error(`${method} ${path}: invalid JSON response: ${e.message}`));
        }
      });
    });
    // Covers both connect and idle time; destroy() makes the request emit 'error'.
    req.setTimeout(TIMEOUT_MS, () => req.destroy(new Error(`${method} ${path}: timed out after ${TIMEOUT_MS}ms`)));
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

// Returns { sessionId, sessionToken } for the instance admin.
async function adminSession(lc) {
  const s = await api('POST', '/v2/sessions', { checks: { user: { loginName: loadEnv('ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME=') } } }, lc, false);
  if (!s.sessionId) throw new Error('POST /v2/sessions returned no sessionId');
  try {
    const p = await api('PATCH', `/v2/sessions/${s.sessionId}`, { checks: { password: { password: loadEnv('ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD=') } } }, lc, false);
    const sessionToken = p.sessionToken || s.sessionToken;
    if (!sessionToken) throw new Error('PATCH /v2/sessions returned no sessionToken');
    return { sessionId: s.sessionId, sessionToken };
  } catch (e) {
    await deleteSession(lc, s.sessionId, s.sessionToken);
    throw e;
  }
}

// DELETE /v2/sessions/{sessionId} (SessionService.DeleteSession). The login
// client has session.delete; the session token is sent too, which Zitadel
// accepts on its own for the session it belongs to. Best effort: a failure is
// logged, since the grants were already read and the session expires anyway.
async function deleteSession(lc, sessionId, sessionToken) {
  try {
    await api('DELETE', `/v2/sessions/${sessionId}`, sessionToken ? { sessionToken } : null, lc, false);
  } catch (e) {
    process.stderr.write(`warning: could not delete Zitadel session ${sessionId}: ${e.message}\n`);
  }
}

if (!PROJECT_ID) throw new Error('COOLIFY_ZITADEL_PROJECT_ID is not set');
const lc = loginClientToken();
const session = await adminSession(lc);
let grants;
try {
  grants = await api('POST', '/management/v1/users/grants/_search', {
    query: { limit: 1000 },
    queries: [{ projectIdQuery: { projectId: PROJECT_ID } }],
  }, session.sessionToken);
} finally {
  await deleteSession(lc, session.sessionId, session.sessionToken);
}

// A missing or malformed result must not read as "nobody has a role":
// apply-roles.php would then remove everyone from the root team.
if (!grants || !Array.isArray(grants.result)) {
  const total = grants?.details?.totalResult;
  // Zitadel omits `result` when the search matched nothing; accept that only
  // when it explicitly reports zero hits.
  if (grants && grants.result === undefined && (total === '0' || total === 0)) {
    grants.result = [];
  } else {
    throw new Error(`unexpected grants response: ${JSON.stringify(grants).slice(0, 500)}`);
  }
}

const roles = {};
for (const g of grants.result) {
  if (g.state && g.state !== 'USER_GRANT_STATE_ACTIVE') continue;
  const email = String(g.email || '').trim().toLowerCase();
  if (!email) continue;
  const keys = g.roleKeys || [];
  if (keys.includes('coolify_admin')) roles[email] = 'admin';
  else if (keys.includes('coolify_member') && roles[email] !== 'admin') roles[email] = 'member';
}
process.stdout.write(JSON.stringify(roles));
