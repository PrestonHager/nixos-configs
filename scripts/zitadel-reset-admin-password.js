#!/usr/bin/env node
/**
 * Reset the Zitadel first-instance admin password to match sops.
 * Run on ace as root (needs /run/secrets/zitadel-env and login-client key).
 */
const fs = require('fs');
const crypto = require('crypto');
const http = require('http');

const KEY_FILE = '/zitadel/login-client/tls.key';
const SECRETS = '/run/secrets/zitadel-env';
const API_HOST = '127.0.0.1';
const API_PORT = 9080;
const PUBLIC_HOST = 'zitadel.prestonhager.com';
const AUDIENCE = `https://${PUBLIC_HOST}`;
const SUBJECT = 'login-client';

function loadPassword() {
  const env = fs.readFileSync(SECRETS, 'utf8');
  const line = env.split('\n').find((l) => l.startsWith('ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD='));
  if (!line) throw new Error('ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD not found in secrets');
  return line.split('=').slice(1).join('=').trim();
}

function loadUsername() {
  const env = fs.readFileSync(SECRETS, 'utf8');
  const line = env.split('\n').find((l) => l.startsWith('ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME='));
  if (!line) throw new Error('ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME not found in secrets');
  return line.split('=').slice(1).join('=').trim();
}

function lookupUserId(username) {
  return new Promise((resolve, reject) => {
    const { execFileSync } = require('child_process');
    try {
      const out = execFileSync(
        'podman',
        [
          'exec',
          'zitadel-db',
          'psql',
          '-U',
          'zitadel',
          '-d',
          'zitadel',
          '-t',
          '-A',
          '-c',
          `SELECT id FROM projections.users14 WHERE username = '${username.replace(/'/g, "''")}' LIMIT 1;`,
        ],
        { encoding: 'utf8' },
      ).trim();
      if (!out) reject(new Error(`No user found for username ${username}`));
      resolve(out);
    } catch (err) {
      reject(err);
    }
  });
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
          if (res.statusCode >= 400) {
            reject(new Error(`HTTP ${res.statusCode} ${path}: ${raw}`));
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

(async () => {
  const username = loadUsername();
  const password = loadPassword();
  const userId = await lookupUserId(username);
  console.log(`Resetting password for ${username} (${userId})...`);
  const reset = await api('POST', `/v2/users/${userId}/password_reset`, { returnCode: {} });
  const code = reset.verificationCode;
  if (!code) throw new Error(`No verificationCode: ${JSON.stringify(reset)}`);
  await api('POST', `/v2/users/${userId}/password`, {
    newPassword: { password, changeRequired: false },
    verificationCode: code,
  });
  console.log('Password reset OK');
})().catch((err) => {
  console.error(err.message || err);
  process.exit(1);
});
