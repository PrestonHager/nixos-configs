#!/usr/bin/env node
/** Fetch Zitadel userinfo for prestonh with Jellyfin OAuth scopes. Run on ace as root. */
const fs = require('fs');
const crypto = require('crypto');
const http = require('http');
const { URL } = require('url');

const KEY_FILE = '/zitadel/login-client/tls.key';
const SECRETS = '/run/secrets/zitadel-env';
const OAUTH = '/run/secrets/jellyfin-oauth-env';
const PUBLIC_HOST = 'zitadel.prestonhager.com';
const AUDIENCE = `https://${PUBLIC_HOST}`;
const PROJECT_ID = '376196450586990901';
const REDIRECT_URI = 'https://jellyfin.prestonhager.com/sso/OID/redirect/zitadel';

function load(path, prefix) {
  const line = fs.readFileSync(path, 'utf8').split('\n').find((l) => l.startsWith(prefix));
  if (!line) throw new Error(`${prefix} missing`);
  return line.split('=').slice(1).join('=').trim();
}

function b64url(buf) {
  return Buffer.from(buf).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function makeLoginToken() {
  const key = fs.readFileSync(KEY_FILE, 'utf8');
  const now = Math.floor(Date.now() / 1000);
  const data = `${b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))}.${b64url(JSON.stringify({ iss: 'login-client', sub: 'login-client', aud: AUDIENCE, iat: now, exp: now + 3600 }))}`;
  const sig = crypto.createSign('RSA-SHA256').update(data).sign(key).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
  return `${data}.${sig}`;
}

function request(options, body, extraHeaders = {}) {
  return new Promise((resolve, reject) => {
    const payload = body ? (typeof body === 'string' ? body : JSON.stringify(body)) : null;
    const req = http.request(
      {
        ...options,
        headers: {
          Host: PUBLIC_HOST,
          'X-Forwarded-Proto': 'https',
          Accept: 'application/json',
          ...(payload && !(body instanceof URLSearchParams)
            ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) }
            : {}),
          ...(payload && body instanceof URLSearchParams
            ? { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(payload) }
            : {}),
          ...extraHeaders,
          ...options.headers,
        },
      },
      (res) => {
        let raw = '';
        res.on('data', (c) => (raw += c));
        res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: raw }));
      },
    );
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

async function api(method, path, body) {
  const res = await request(
    {
      hostname: '127.0.0.1',
      port: 9080,
      path,
      method,
      headers: { Authorization: `Bearer ${makeLoginToken()}` },
    },
    body,
  );
  if (res.status >= 400) throw new Error(`${method} ${path} ${res.status}: ${res.body}`);
  return res.body ? JSON.parse(res.body) : {};
}

function decodeJwt(token) {
  const payload = token.split('.')[1];
  return JSON.parse(Buffer.from(payload.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString());
}

(async () => {
  const loginName = load(SECRETS, 'ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME=');
  const password = load(SECRETS, 'ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD=');
  const clientId = load(OAUTH, 'JELLYFIN_OIDC_CLIENT_ID=');
  const clientSecret = load(OAUTH, 'JELLYFIN_OIDC_CLIENT_SECRET=');
  const scopes = [
    'openid',
    'profile',
    'email',
    `urn:zitadel:iam:org:project:id:${PROJECT_ID}:aud`,
    'urn:zitadel:iam:org:project:roles',
  ];

  const verifier = b64url(crypto.randomBytes(32));
  const challenge = b64url(crypto.createHash('sha256').update(verifier).digest());

  const session = await api('POST', '/v2/sessions', { checks: { user: { loginName } } });
  const patched = await api('PATCH', `/v2/sessions/${session.sessionId}`, { checks: { password: { password } } });
  const sessionToken = patched.sessionToken || session.sessionToken;

  const authReq = await api('POST', '/v2/oidc/auth_requests', {
    scope: scopes,
    responseType: 'OIDC_RESPONSE_TYPE_CODE',
    redirectUri: REDIRECT_URI,
    prompt: [],
    loginHint: loginName,
    codeChallenge: { challenge, method: 'CODE_CHALLENGE_METHOD_S256' },
  });
  const authReqId = authReq.authRequestId || authReq.id;
  const finalized = await api('POST', `/v2/oidc/auth_requests/${authReqId}`, {
    session: { sessionId: session.sessionId, sessionToken },
  });
  const callbackUrl = finalized.callbackUrl || finalized.url;
  const code = new URL(callbackUrl).searchParams.get('code');
  if (!code) throw new Error(`No code in ${callbackUrl}`);

  const tokenBody = new URLSearchParams({
    grant_type: 'authorization_code',
    code,
    redirect_uri: REDIRECT_URI,
    client_id: clientId,
    client_secret: clientSecret,
    code_verifier: verifier,
  }).toString();

  const tokenRes = await request(
    { hostname: '127.0.0.1', port: 9080, path: '/oauth/v2/token', method: 'POST' },
    tokenBody,
  );
  if (tokenRes.status >= 400) throw new Error(`token ${tokenRes.status}: ${tokenRes.body}`);
  const tokens = JSON.parse(tokenRes.body);

  const userinfoRes = await request(
    {
      hostname: '127.0.0.1',
      port: 9080,
      path: '/oidc/v1/userinfo',
      method: 'GET',
      headers: { Authorization: `Bearer ${tokens.access_token}` },
    },
    null,
  );

  const idClaims = decodeJwt(tokens.id_token);
  const userinfo = userinfoRes.body ? JSON.parse(userinfoRes.body) : {};

  console.log('=== jellyfin_groups claim ===');
  console.log('userinfo.jellyfin_groups:', JSON.stringify(userinfo.jellyfin_groups));
  console.log('id_token.jellyfin_groups:', JSON.stringify(idClaims.jellyfin_groups));
  console.log('\n=== jellyfin role claims ===');
  for (const k of Object.keys(userinfo).filter((k) => k.includes('roles') || k.includes('jellyfin'))) {
    console.log(k, JSON.stringify(userinfo[k]));
  }
  console.log('\n=== SSO plugin expectation ===');
  console.log('RoleClaim=jellyfin_groups, expected: ["jellyfin_admin"] or ["jellyfin_user"]');
  const claim = userinfo.jellyfin_groups || idClaims.jellyfin_groups;
  const ok = Array.isArray(claim) && claim.length === 1 &&
    (claim[0] === 'jellyfin_admin' || claim[0] === 'jellyfin_user');
  console.log(ok ? 'PASS: jellyfin_groups claim valid for Jellyfin SSO' : 'FAIL: jellyfin_groups claim missing or invalid');
  process.exit(ok ? 0 : 1);
})().catch((e) => {
  console.error(e.message || e);
  process.exit(1);
});
