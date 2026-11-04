#!/usr/bin/env bash
# "Sign in with Google" for the Keycloak homelab realm (docs/keycloak-ace.md).
#
# Google logins only LINK to users that already exist in Keycloak, matched by
# email; a Google account whose email no Keycloak user has is refused, never
# created. After a Google login Keycloak still asks for the user's TOTP, so a
# Google account alone does not open servers or sudo.
#
# The realm import (nixos/containers/keycloak.nix) runs only once, so this
# script is the source of truth for the Google setup. It is idempotent: run it
# again after a restore, a fresh realm, or to rotate the Google client secret.
#
# Run on ace as root:  bash scripts/keycloak-google-login.sh
# It prompts for a master-realm admin login (with TOTP if the admin has it)
# and the Google OAuth client ID and secret. Secrets never go on a command
# line: they pass through a root-only temp dir and are removed on exit.
#
# Environment:
#   KEYCLOAK_URL   default https://keycloak.prestonhager.com
#   REALM          default homelab
#   REQUIRE_OTP    default 1; 0 lets a Google login skip the Keycloak TOTP
set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-https://keycloak.prestonhager.com}"
REALM="${REALM:-homelab}"
REQUIRE_OTP="${REQUIRE_OTP:-1}"
IDP=google
FIRST_FLOW=google-link-existing
POST_FLOW=google-require-otp
ADMIN="$KEYCLOAK_URL/admin/realms/$REALM"

for bin in curl jq; do
  command -v "$bin" >/dev/null || { echo "needs $bin (nix shell nixpkgs#$bin)" >&2; exit 1; }
done

tmp=$(mktemp -d /run/keycloak-google.XXXXXX)
chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT

ask() { # ask <file> <prompt> [secret]
  local v
  if [ "${3:-}" = secret ]; then read -rsp "$2: " v; echo >&2; else read -rp "$2: " v; fi
  printf '%s' "$v" > "$tmp/$1"
}

ask admin_user "Keycloak master admin username"
ask admin_pass "Password" secret
ask admin_otp "TOTP code (empty if the admin has none)"
ask google_id "Google OAuth client ID (empty keeps the current one)"
ask google_secret "Google OAuth client secret (empty keeps the current one)" secret

# --- admin token (password and OTP read from files, not argv) -------------
cp "$tmp/admin_otp" "$tmp/admin_otp2"
token=$(curl -sS --fail-with-body \
  -d grant_type=password -d client_id=admin-cli \
  --data-urlencode "username@$tmp/admin_user" \
  --data-urlencode "password@$tmp/admin_pass" \
  --data-urlencode "otp@$tmp/admin_otp" \
  --data-urlencode "totp@$tmp/admin_otp2" \
  "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" | jq -r .access_token) \
  || { echo "admin login failed" >&2; exit 1; }
rm -f "$tmp/admin_pass" "$tmp/admin_otp" "$tmp/admin_otp2"
printf 'Authorization: Bearer %s\n' "$token" > "$tmp/auth"
unset token

api() { # api <method> <path> [json-body]
  local method=$1 path=$2
  if [ $# -ge 3 ]; then
    printf '%s' "$3" | curl -sS --fail-with-body -X "$method" -H @"$tmp/auth" \
      -H 'Content-Type: application/json' --data-binary @- "$ADMIN$path"
  else
    curl -sS --fail-with-body -X "$method" -H @"$tmp/auth" "$ADMIN$path"
  fi
}

# --- flows ----------------------------------------------------------------
# ensure_flow <alias> <description> <provider>...: a top-level flow whose
# executions are exactly these providers, each REQUIRED, in this order.
ensure_flow() {
  local alias=$1 desc=$2; shift 2
  if ! api GET /authentication/flows | jq -e --arg a "$alias" 'any(.[]; .alias == $a)' >/dev/null; then
    api POST /authentication/flows "$(jq -nc --arg a "$alias" --arg d "$desc" \
      '{alias: $a, description: $d, providerId: "basic-flow", topLevel: true, builtIn: false}')" >/dev/null
    echo "created flow $alias"
  fi
  local provider execs
  for provider in "$@"; do
    execs=$(api GET "/authentication/flows/$alias/executions")
    if ! jq -e --arg p "$provider" 'any(.[]; .providerId == $p)' <<<"$execs" >/dev/null; then
      api POST "/authentication/flows/$alias/executions/execution" \
        "$(jq -nc --arg p "$provider" '{provider: $p}')" >/dev/null
      echo "  added $provider"
      execs=$(api GET "/authentication/flows/$alias/executions")
    fi
    jq -c --arg p "$provider" '.[] | select(.providerId == $p)' <<<"$execs" | while read -r e; do
      if [ "$(jq -r .requirement <<<"$e")" != REQUIRED ]; then
        api PUT "/authentication/flows/$alias/executions" "$(jq -c '.requirement = "REQUIRED"' <<<"$e")" >/dev/null
        echo "  $provider -> REQUIRED"
      fi
    done
  done
}

# First Google login: link to the Keycloak user with the same email or
# fail. No "Create User If Unique", no review-profile, no registration.
ensure_flow "$FIRST_FLOW" "Google: link to an existing user by email, never create one" \
  idp-detect-existing-broker-user idp-auto-link

# Every Google login: also pass the user's Keycloak TOTP.
if [ "$REQUIRE_OTP" = 1 ]; then
  ensure_flow "$POST_FLOW" "Google: require the Keycloak TOTP after Google" auth-otp-form
  post_flow=$POST_FLOW
else
  post_flow=""
fi

# --- identity provider ----------------------------------------------------
existing=$(api GET "/identity-provider/instances" | jq -c --arg a "$IDP" '.[] | select(.alias == $a)')
google_id=$(cat "$tmp/google_id")
google_secret=$(cat "$tmp/google_secret")
if [ -z "$existing" ] && { [ -z "$google_id" ] || [ -z "$google_secret" ]; }; then
  echo "no Google provider yet: client ID and secret are required" >&2
  exit 1
fi
# Keycloak returns the stored secret masked; sending the mask back keeps it.
[ -n "$google_id" ] || google_id=$(jq -r '.config.clientId' <<<"$existing")
[ -n "$google_secret" ] || google_secret="**********"

body=$(jq -nc \
  --arg alias "$IDP" --arg id "$google_id" --arg first "$FIRST_FLOW" --arg post "$post_flow" \
  --rawfile secret <(printf '%s' "$google_secret") '{
    alias: $alias,
    providerId: "google",
    displayName: "Google",
    enabled: true,
    # Google only returns verified addresses; the link-only flow relies on it.
    trustEmail: true,
    storeToken: false,
    addReadTokenRoleOnCreate: false,
    linkOnly: false,
    hideOnLogin: false,
    firstBrokerLoginFlowAlias: $first,
    postBrokerLoginFlowAlias: $post,
    config: {
      clientId: $id,
      clientSecret: $secret,
      defaultScope: "openid profile email",
      syncMode: "IMPORT",
      guiOrder: "1",
      hideOnLoginPage: "false",
      acceptsPromptNoneForwardFromClient: "false",
      disableUserInfo: "false"
    }
  }')
unset google_secret

if [ -z "$existing" ]; then
  api POST /identity-provider/instances "$body" >/dev/null
  echo "created identity provider $IDP"
else
  api PUT "/identity-provider/instances/$IDP" "$body" >/dev/null
  echo "updated identity provider $IDP"
fi

api GET "/identity-provider/instances/$IDP" | jq -c '{alias, enabled, trustEmail,
  firstBrokerLoginFlowAlias, postBrokerLoginFlowAlias, clientId: .config.clientId}'
echo "Google redirect URI: $KEYCLOAK_URL/realms/$REALM/broker/$IDP/endpoint"
