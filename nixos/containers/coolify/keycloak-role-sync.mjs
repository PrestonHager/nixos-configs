// Reads the members of the Keycloak groups coolify_admin and coolify_member
// (realm homelab) and prints {email: {role: "admin"|"member", name}}.
// Run by coolify-keycloak-roles.service (nixos/containers/coolify-sso.nix) as
// root on ace, with the homelab-config service account (client credentials,
// realm-admin of homelab only).
// Disabled users and users without an email are left out, like inactive
// Zitadel grants were. Any failure (timeout, HTTP error, missing group,
// unexpected response) exits non-zero so apply-roles.php never runs on a
// partial or empty result.
import fs from 'node:fs';

const KC_URL = process.env.KEYCLOAK_URL || 'https://keycloak.prestonhager.com';
const REALM = process.env.KEYCLOAK_REALM || 'homelab';
const SECRETS = process.env.KEYCLOAK_CONFIG_ENV || '/run/secrets/keycloak-config-env';
const GROUPS = [['coolify_admin', 'admin'], ['coolify_member', 'member']];
const TIMEOUT_MS = 15000;
const PAGE = 500;

function loadEnv(key) {
  const line = fs.readFileSync(SECRETS, 'utf8').split('\n').find((l) => l.startsWith(`${key}=`));
  const value = line?.slice(key.length + 1).trim();
  if (!value) throw new Error(`${key} not found in ${SECRETS}`);
  if (value === 'REPLACE_ME') throw new Error(`${key} in ${SECRETS} is still REPLACE_ME (docs/keycloak-ace.md)`);
  return value;
}

async function request(url, init = {}) {
  const res = await fetch(url, { ...init, signal: AbortSignal.timeout(TIMEOUT_MS) });
  const text = await res.text();
  if (!res.ok) throw new Error(`${res.status} ${init.method || 'GET'} ${url.replace(/\?.*/, '')}`);
  try {
    return JSON.parse(text);
  } catch (e) {
    throw new Error(`${url}: invalid JSON response: ${e.message}`);
  }
}

async function token() {
  const body = new URLSearchParams({
    grant_type: 'client_credentials',
    client_id: 'homelab-config',
    client_secret: loadEnv('KEYCLOAK_CONFIG_CLIENT_SECRET'),
  });
  const t = await request(`${KC_URL}/realms/${REALM}/protocol/openid-connect/token`, { method: 'POST', body });
  if (!t.access_token) throw new Error('token endpoint returned no access_token');
  return t.access_token;
}

const bearer = await token();
const admin = (path) => request(`${KC_URL}/admin/realms/${REALM}${path}`, {
  headers: { Authorization: `Bearer ${bearer}`, Accept: 'application/json' },
});

async function groupId(name) {
  const found = await admin(`/groups?search=${encodeURIComponent(name)}&exact=true&briefRepresentation=true`);
  if (!Array.isArray(found)) throw new Error(`unexpected /groups response for ${name}`);
  const g = found.find((x) => x.name === name);
  // A missing group must not read as "nobody has this role".
  if (!g?.id) throw new Error(`Keycloak group ${name} not found (homelab.keycloak.groups)`);
  return g.id;
}

async function members(id) {
  const all = [];
  for (let first = 0; ; first += PAGE) {
    const page = await admin(`/groups/${id}/members?first=${first}&max=${PAGE}&briefRepresentation=false`);
    if (!Array.isArray(page)) throw new Error(`unexpected members response for group ${id}`);
    all.push(...page);
    if (page.length < PAGE) return all;
  }
}

const out = {};
for (const [group, role] of GROUPS) {
  for (const u of await members(await groupId(group))) {
    if (u.enabled === false) continue;
    const email = String(u.email || '').trim().toLowerCase();
    if (!email) {
      process.stderr.write(`warning: ${u.username} in ${group} has no email, skipped\n`);
      continue;
    }
    if (u.emailVerified !== true) {
      // Coolify only links an OIDC login to an account when email_verified is true.
      process.stderr.write(`warning: ${email} in ${group} has an unverified email; Coolify will refuse its login\n`);
    }
    if (out[email]?.role === 'admin') continue;
    const name = [u.firstName, u.lastName].filter(Boolean).join(' ') || u.username || email;
    out[email] = { role, name };
  }
}
process.stdout.write(JSON.stringify(out));
