#!/usr/bin/env node
/**
 * Configure Zitadel instance SMTP (iCloud relay) via Admin API.
 * Run on ace as root after deploy (login-client key + nextcloud SMTP password).
 */
const fs = require('fs');
const crypto = require('crypto');
const http = require('http');

const KEY_FILE = '/zitadel/login-client/tls.key';
const NEXTCLOUD_SECRETS = '/run/secrets/nextcloud-environment';
const API_HOST = '127.0.0.1';
const API_PORT = 9080;
const PUBLIC_HOST = 'zitadel.prestonhager.com';
const AUDIENCE = `https://${PUBLIC_HOST}`;
const SUBJECT = 'login-client';

const SMTP = {
  host: 'smtp.mail.me.com:587',
  user: 'preston.hager@icloud.com',
  tls: true,
  from: 'admin@prestonhager.com',
  fromName: 'Zitadel',
};

function loadSmtpPassword() {
  const env = fs.readFileSync(NEXTCLOUD_SECRETS, 'utf8');
  const line = env.split('\n').find((l) => l.startsWith('SMTP_PASSWORD='));
  if (!line) throw new Error('SMTP_PASSWORD not found in nextcloud-environment');
  return line.split('=').slice(1).join('=').trim();
}

function base64url(input) {
  return Buffer.from(input)
    .toString('base64')
    .replace(/=/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_');
}

function makeToken() {
  const key = fs.readFileSync(KEY_FILE, 'utf8');
  const header = base64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const now = Math.floor(Date.now() / 1000);
  const payload = base64url(
    JSON.stringify({ iss: SUBJECT, sub: SUBJECT, aud: AUDIENCE, iat: now, exp: now + 3600 }),
  );
  const data = `${header}.${payload}`;
  const sign = crypto.createSign('RSA-SHA256');
  sign.update(data);
  sign.end();
  const signature = sign
    .sign(key)
    .toString('base64')
    .replace(/=/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_');
  return `${data}.${signature}`;
}

function api(method, path, body) {
  return new Promise((resolve, reject) => {
    const token = makeToken();
    const payload = body ? JSON.stringify(body) : null;
    const req = http.request(
      {
        hostname: API_HOST,
        port: API_PORT,
        path,
        method,
        headers: {
          Host: PUBLIC_HOST,
          'X-Forwarded-Proto': 'https',
          'X-Forwarded-Host': PUBLIC_HOST,
          'X-Zitadel-Public-Host': PUBLIC_HOST,
          Authorization: `Bearer ${token}`,
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
          let parsed = raw;
          try {
            parsed = raw ? JSON.parse(raw) : {};
          } catch {
            parsed = raw;
          }
          if (res.statusCode >= 400) {
            reject(new Error(`HTTP ${res.statusCode} ${method} ${path}: ${raw}`));
            return;
          }
          resolve(parsed);
        });
      },
    );
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

async function listSmtpProviders() {
  try {
    const res = await api('POST', '/admin/v1/smtp/_search', {
      query: { offset: '0', limit: 100, asc: true },
    });
    return res.result || [];
  } catch (err) {
    if (String(err.message).includes('404')) {
      const res = await api('POST', '/admin/v1/email/smtp/_search', {
        query: { offset: '0', limit: 100, asc: true },
      });
      return res.result || [];
    }
    throw err;
  }
}

async function addSmtpProvider(password) {
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
    return await api('POST', '/admin/v1/smtp', body);
  } catch (err) {
    if (!String(err.message).includes('404')) throw err;
    return api('POST', '/admin/v1/email/smtp', {
      none: {
        senderAddress: SMTP.from,
        senderName: SMTP.fromName,
        host: SMTP.host,
        user: SMTP.user,
        password,
        tls: SMTP.tls,
        description: 'iCloud SMTP relay (nixos-configs)',
      },
    });
  }
}

async function updateSmtpProvider(id, password) {
  const body = {
    senderAddress: SMTP.from,
    senderName: SMTP.fromName,
    host: SMTP.host,
    user: SMTP.user,
    tls: SMTP.tls,
    description: 'iCloud SMTP relay (nixos-configs)',
  };
  try {
    await api('PUT', `/admin/v1/smtp/${id}`, body);
  } catch (err) {
    if (!String(err.message).includes('404')) throw err;
    await api('PUT', `/admin/v1/email/smtp/${id}`, {
      none: body,
    });
  }
  try {
    await api('PUT', `/admin/v1/smtp/${id}/password`, { password });
  } catch (err) {
    if (!String(err.message).includes('404')) throw err;
    await api('PUT', `/admin/v1/email/smtp/${id}/password`, { password });
  }
}

async function activateProvider(id) {
  try {
    await api('POST', `/admin/v1/smtp/${id}/_activate`, {});
  } catch (err) {
    if (!String(err.message).includes('404')) throw err;
    await api('POST', `/admin/v1/email/smtp/${id}/_activate`, {});
  }
}

async function disableSenderDomainCheck() {
  try {
    await api('PUT', '/admin/v1/policies/domain', {
      userLoginMustBeDomain: false,
      validateOrgDomains: true,
      smtpSenderAddressMatchesInstanceDomain: false,
    });
    console.log('Domain policy: smtpSenderAddressMatchesInstanceDomain=false');
  } catch (err) {
    console.warn(`Domain policy update skipped: ${err.message}`);
  }
}

async function testProvider(id) {
  try {
    await api('POST', `/admin/v1/smtp/${id}/_test`, {});
    console.log('SMTP test email sent (legacy endpoint)');
    return;
  } catch (err) {
    if (!String(err.message).includes('404')) throw err;
  }
  await api('POST', `/admin/v1/email/smtp/${id}/_test`, {});
  console.log('SMTP test email sent');
}

(async () => {
  const password = loadSmtpPassword();
  await disableSenderDomainCheck();

  const existing = await listSmtpProviders();
  let providerId;

  if (existing.length === 0) {
    console.log('No SMTP provider found; creating...');
    const created = await addSmtpProvider(password);
    providerId = created.id || created.config?.id;
    if (!providerId) throw new Error(`Create response missing id: ${JSON.stringify(created)}`);
    console.log(`Created SMTP provider ${providerId}`);
  } else {
    providerId = existing[0].id;
    console.log(`Updating SMTP provider ${providerId}...`);
    await updateSmtpProvider(providerId, password);
    await activateProvider(providerId);
    console.log('SMTP provider updated and activated');
  }

  await testProvider(providerId);
  console.log('Done. Check admin@prestonhager.com inbox for Zitadel test mail.');
})().catch((err) => {
  console.error(err.message || err);
  process.exit(1);
});
