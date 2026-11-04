#!/usr/bin/env bash
# One-time: create the homelab-config service account that keycloak-realm-sync
# logs in as (docs/keycloak-ace.md), and store its secret in sops.
#
# Run on ace as root, interactively, with YOUR master-realm admin login:
#   bash /etc/nixos/scripts/keycloak-config-client.sh
#
# It creates (or reuses) client `homelab-config` in the homelab realm with a
# service account that holds realm-management/realm-admin of homelab only, then
# writes its secret to secrets/containers/keycloak.yaml (keycloak-config-env)
# in the nixos-secrets checkout. Secrets go through a root-only temp dir, never
# argv or the terminal. Safe to re-run; it keeps an existing client's secret.
#
# Environment:
#   KEYCLOAK_URL   default https://keycloak.prestonhager.com
#   SECRETS_DIR    default /home/prestonh/nixos-secrets
set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-https://keycloak.prestonhager.com}"
SECRETS_DIR="${SECRETS_DIR:-/home/prestonh/nixos-secrets}"
REALM=homelab
CLIENT=homelab-config
SOPS_FILE=secrets/containers/keycloak.yaml

for bin in curl jq sops; do
  command -v "$bin" >/dev/null || { echo "needs $bin: nix shell nixpkgs#jq nixpkgs#sops -c bash $0" >&2; exit 1; }
done

tmp=$(mktemp -d /run/keycloak-config-client.XXXXXX)
chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT

read -rp "Keycloak master admin username: " user; printf '%s' "$user" > "$tmp/user"
read -rsp "Password: " pass; echo; printf '%s' "$pass" > "$tmp/pass"; unset pass
read -rp "TOTP code (empty if none): " otp; printf '%s' "$otp" > "$tmp/otp"; cp "$tmp/otp" "$tmp/otp2"

token=$(curl -sS -d grant_type=password -d client_id=admin-cli \
  --data-urlencode "username@$tmp/user" --data-urlencode "password@$tmp/pass" \
  --data-urlencode "otp@$tmp/otp" --data-urlencode "totp@$tmp/otp2" \
  "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" | jq -r '.access_token // empty')
rm -f "$tmp/pass" "$tmp/otp" "$tmp/otp2"
[ -n "$token" ] || { echo "admin login failed" >&2; exit 1; }
printf 'Authorization: Bearer %s\n' "$token" > "$tmp/auth"; unset token

api() { # api <method> <path> [json]
  if [ $# -ge 3 ]; then
    printf '%s' "$3" | curl -sS --fail-with-body -X "$1" -H @"$tmp/auth" \
      -H 'Content-Type: application/json' --data-binary @- "$KEYCLOAK_URL/admin/realms/$REALM$2"
  else
    curl -sS --fail-with-body -X "$1" -H @"$tmp/auth" "$KEYCLOAK_URL/admin/realms/$REALM$2"
  fi
}

id=$(api GET "/clients?clientId=$CLIENT" | jq -r '.[0].id // empty')
if [ -z "$id" ]; then
  api POST /clients "$(jq -nc --arg c "$CLIENT" '{
    clientId: $c, name: "Nix realm sync (keycloak-realm-sync)", enabled: true,
    protocol: "openid-connect", publicClient: false, clientAuthenticatorType: "client-secret",
    serviceAccountsEnabled: true, standardFlowEnabled: false, implicitFlowEnabled: false,
    directAccessGrantsEnabled: false, redirectUris: [], webOrigins: []}')" >/dev/null
  id=$(api GET "/clients?clientId=$CLIENT" | jq -r '.[0].id')
  echo "created client $CLIENT in realm $REALM"
else
  echo "client $CLIENT already exists in realm $REALM"
fi

sa=$(api GET "/clients/$id/service-account-user" | jq -r .id)
rm_id=$(api GET "/clients?clientId=realm-management" | jq -r '.[0].id')
if ! api GET "/users/$sa/role-mappings/clients/$rm_id" | jq -e 'any(.[]; .name == "realm-admin")' >/dev/null; then
  api POST "/users/$sa/role-mappings/clients/$rm_id" "[$(api GET "/clients/$rm_id/roles/realm-admin")]" >/dev/null
  echo "granted realm-management/realm-admin (realm $REALM only)"
fi

api GET "/clients/$id/client-secret" | jq -r .value | tr -d '\n' > "$tmp/secret"
[ -s "$tmp/secret" ] || { echo "could not read the client secret" >&2; exit 1; }

# Prove the secret works before storing it.
curl -sS -d grant_type=client_credentials -d client_id="$CLIENT" --data-urlencode "client_secret@$tmp/secret" \
  "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token" | jq -e '.access_token' >/dev/null \
  || { echo "the new client's secret does not log in; nothing stored" >&2; exit 1; }

cd "$SECRETS_DIR"
jq -Rn --rawfile s "$tmp/secret" '"KEYCLOAK_CONFIG_CLIENT_SECRET=" + $s + "\n"' \
  | SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-/var/lib/sops/age/keys.txt}" \
    sops set --value-stdin "$SOPS_FILE" '["keycloak-config-env"]'
chown --reference=. "$SOPS_FILE" 2>/dev/null || true
echo "stored the $CLIENT secret in $SECRETS_DIR/$SOPS_FILE (keycloak-config-env)"
