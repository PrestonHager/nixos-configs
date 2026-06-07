#!/usr/bin/env node
/**
 * Configure Zitadel instance SMTP (iCloud relay) via Admin API.
 * Run on ace as root after deploy (login-client key + zitadel-env + nextcloud SMTP password).
 */
const fs = require('fs');
const crypto = require('crypto');
const http = require('http');

const KEY_FILE = '/zitadel/login-client/tls.key';
const SECRETS = '/run/secrets/zitadel-env';
const NEXTCLOUD_SECRETS = '/run/secrets/nextcloud-environment';
const PUBLIC_HOST = 'zitadel.prestonhager.com';
const AUDIENCE = `https://${PUBLIC_HOST}`;

const SMTP = {
  host: 'smtp.mail.me.com:587',
  user: 'prestonhager@icloud.com',
  tls: true,
  from: 'admin@prestonhager.com',
  fromName: 'Zitadel',
};

function loadEnv(path, prefix) {
  const env = fs.readFileSync(path, 'utf8');
  const line = env.split('\n').find((l) => l.startsWith(prefix));
  if (!line) throw new Error(`${prefix} not found in ${path}`);
  return line.split('=').slice(1).join('=').trim();
}

function loadSmtpPassword() {
  return loadEnv(NEXTCLOUD_SECRETS, 'SMTP_PASSWORD=');
}

function makeLoginClientToken() {
  const key = fs.readFileSync(KEY_FILE, 'utf8');
  const b64 = (o) => Buffer.from(o).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
  const now = Math.floor(Date.now() / 1000);
  const data = `${b64(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))}.${b64(JSON.stringify({ iss: 'login-client', sub: 'login-client', aud: AUDIENCE, iat: now, exp: now + 3600 }))}`;
  const sig = crypto.createSign('RSA-SHA256').update(data).sign(key).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
  return `${data}.${sig}`;
}

function request(method, path, body, bearer) {
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
        res.on('data', (chunk) => {
          raw += chunk;
        });
        res.on('end', () => {
          if (res.statusCode >= 400) {
            reject(new Error(`HTTP ${res.statusCode} ${method} ${path}: ${raw}`));
            return;
          }
          resolve(raw ? JSON.parse(raw) : {});
        });
      },
    );
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

async function adminSessionToken() {
  const loginName = loadEnv(SECRETS, 'ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME=');
  const password = loadEnv(SECRETS, 'ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD=');
  const loginJwt = makeLoginClientToken();
  const session = await request('POST', '/v2/sessions', { checks: { user: { loginName } } }, loginJwt);
  const patched = await request(
    'PATCH',
    `/v2/sessions/${session.sessionId}`,
    { checks: { password: { password } } },
    loginJwt,
  );
  return patched.sessionToken || session.sessionToken;
}

async function adminApi(method, path, body, sessionToken) {
  return request(method, path, body, sessionToken);
}

async function listSmtpProviders(token) {
  try {
    const res = await adminApi('POST', '/admin/v1/smtp/_search', { query: { offset: '0', limit: 100, asc: true } }, token);
    return res.result || [];
  } catch (err) {
    if (!String(err.message).includes('404')) throw err;
    const res = await adminApi('POST', '/admin/v1/email/smtp/_search', { query: { offset: '0', limit: 100, asc: true } }, token);
    return res.result || [];
  }
}

async function addSmtpProvider(token, password) {
  const body = {
    senderAddress: SMTP.from,
    senderName: SMTP.fromName,
    host: SMTP.host,
    user: SMTP.user,
    password,
    tls: SMTP.tls,
    description: 'iCloud SMTP relay (nixos-configs)',
    setActive: true,
  };
  try {
    return await adminApi('POST', '/admin/v1/smtp', body, token);
  } catch (err) {
    if (!String(err.message).includes('404')) throw err;
    return adminApi('POST', '/admin/v1/email/smtp', { none: body }, token);
  }
}

async function updateSmtpProvider(token, id, password) {
  const body = {
    senderAddress: SMTP.from,
    senderName: SMTP.fromName,
    host: SMTP.host,
    user: SMTP.user,
    password,
    tls: SMTP.tls,
    description: 'iCloud SMTP relay (nixos-configs)',
  };
  await adminApi('PUT', `/admin/v1/smtp/${id}`, body, token);
}

async function activateProvider(token, id) {
  try {
    await adminApi('POST', `/admin/v1/smtp/${id}/_activate`, {}, token);
  } catch (err) {
    if (String(err.message).includes('COMMAND-vUHBSmBzaw')) return;
    if (!String(err.message).includes('404')) throw err;
    await adminApi('POST', `/admin/v1/email/smtp/${id}/_activate`, {}, token);
  }
}

async function disableSenderDomainCheck(token) {
  try {
    await adminApi(
      'PUT',
      '/admin/v1/policies/domain',
      {
        userLoginMustBeDomain: false,
        validateOrgDomains: true,
        smtpSenderAddressMatchesInstanceDomain: false,
      },
      token,
    );
    console.log('Domain policy: smtpSenderAddressMatchesInstanceDomain=false');
  } catch (err) {
    if (String(err.message).includes('INSTANCE-pl9fN')) {
      console.log('Domain policy already correct (smtpSenderAddressMatchesInstanceDomain=false)');
      return;
    }
    console.warn(`Domain policy update skipped: ${err.message}`);
  }
}

async function testProvider(token, id) {
  const body = { receiverAddress: SMTP.from };
  try {
    await adminApi('POST', `/admin/v1/smtp/${id}/_test`, body, token);
    console.log(`SMTP test email sent to ${SMTP.from}`);
    return;
  } catch (err) {
    if (!String(err.message).includes('404')) throw err;
  }
  await adminApi('POST', `/admin/v1/email/smtp/${id}/_test`, body, token);
  console.log(`SMTP test email sent to ${SMTP.from}`);
}

(async () => {
  const password = loadSmtpPassword();
  const token = await adminSessionToken();
  await disableSenderDomainCheck(token);

  const existing = await listSmtpProviders(token);
  let providerId;

  if (existing.length === 0) {
    console.log('No SMTP provider found; creating...');
    const created = await addSmtpProvider(token, password);
    providerId = created.id || created.config?.id;
    if (!providerId) throw new Error(`Create response missing id: ${JSON.stringify(created)}`);
    console.log(`Created SMTP provider ${providerId}`);
  } else {
    providerId = existing[0].id;
    console.log(`Updating SMTP provider ${providerId}...`);
    await updateSmtpProvider(token, providerId, password);
    await activateProvider(token, providerId);
    console.log('SMTP provider updated and activated');
  }

  await testProvider(token, providerId);
  console.log('Done. Check admin@prestonhager.com inbox for Zitadel test mail.');
})().catch((err) => {
  console.error(err.message || err);
  process.exit(1);
});
