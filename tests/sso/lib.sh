# Shared helpers for the SSO regression tests (tests/sso/run.sh). Sourced, not
# run. Runs on ace as root: it reads the homelab-config and test-user secrets
# from /run/secrets.
#
# A service test (tests/sso/<service>.test.sh) is a bash file that calls
# `check` / `sso_login` and friends; run.sh sources each one in turn. The
# sso-regression user is enabled for the duration of run.sh only.

KC_URL="${KC_URL:-https://keycloak.prestonhager.com}"
KC_REALM="${KC_REALM:-homelab}"
SSO_USER=sso-regression
SSO_TMP="${SSO_TMP:-$(mktemp -d /run/sso-test.XXXXXX)}"
chmod 700 "$SSO_TMP"

SSO_PASS=0
SSO_FAIL=0

_read_secret() { # _read_secret <file> <key>
  grep -m1 "^$2=" "$1" | cut -d= -f2-
}

sso_admin_token() {
  local s
  s=$(_read_secret /run/secrets/keycloak-config-env KEYCLOAK_CONFIG_CLIENT_SECRET)
  printf '%s' "$s" > "$SSO_TMP/cfg"
  curl -sS -d grant_type=client_credentials -d client_id=homelab-config \
    --data-urlencode "client_secret@$SSO_TMP/cfg" \
    "$KC_URL/realms/$KC_REALM/protocol/openid-connect/token" | jq -r '.access_token // empty'
  rm -f "$SSO_TMP/cfg"
}

kc_admin() { # kc_admin <method> <path> [json]
  local tok; tok=$(sso_admin_token)
  [ -n "$tok" ] || { echo "kc_admin: no homelab-config token" >&2; return 1; }
  if [ $# -ge 3 ]; then
    curl -sS -X "$1" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
      --data-binary "$3" "$KC_URL/admin/realms/$KC_REALM$2"
  else
    curl -sS -X "$1" -H "Authorization: Bearer $tok" "$KC_URL/admin/realms/$KC_REALM$2"
  fi
}

sso_user_id() {
  kc_admin GET "/users?username=$SSO_USER&exact=true" | jq -r '.[0].id // empty'
}

sso_user_enabled() { # sso_user_enabled true|false
  local id; id=$(sso_user_id)
  [ -n "$id" ] || { echo "sso-regression user missing (homelab.keycloak.testUser)" >&2; return 1; }
  kc_admin PUT "/users/$id" "{\"enabled\": $1}" >/dev/null
}

# sso_login <start-url> [jar]
# Follows redirects from an app's "log in with SSO" URL to the Keycloak form,
# submits the test user's password, and follows redirects back. Sets:
#   SSO_FINAL_URL  where the redirect chain ended
#   SSO_BODY       file with the last response body
#   SSO_JAR        cookie jar (reuse it for authenticated follow-up requests)
sso_login() {
  local start=$1 page action
  SSO_JAR=${2:-$SSO_TMP/jar.$RANDOM}
  SSO_BODY=$SSO_TMP/body.$RANDOM
  page=$(curl -sS -c "$SSO_JAR" -b "$SSO_JAR" -L "$start")
  action=$(grep -o 'id="kc-form-login"[^>]*action="[^"]*"\|action="[^"]*"[^>]*id="kc-form-login"' <<<"$page" \
    | grep -o 'action="[^"]*"' | head -1 | sed 's/^action="//; s/"$//; s/&amp;/\&/g')
  if [ -z "$action" ]; then
    SSO_FINAL_URL="(no Keycloak login form reached from $start)"
    printf '%s' "$page" > "$SSO_BODY"
    return 1
  fi
  _read_secret /run/secrets/keycloak-test-env SSO_REGRESSION_PASSWORD > "$SSO_TMP/pw"
  SSO_FINAL_URL=$(curl -sS -c "$SSO_JAR" -b "$SSO_JAR" -L --max-redirs 20 -o "$SSO_BODY" -w '%{url_effective}' \
    --data-urlencode "username=$SSO_USER" --data-urlencode "password@$SSO_TMP/pw" "$action")
  rm -f "$SSO_TMP/pw"
}

# check <description> <command...>: run a command, count pass/fail.
check() {
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then
    printf '  PASS  %s\n' "$desc"; SSO_PASS=$((SSO_PASS + 1))
  else
    printf '  FAIL  %s\n' "$desc"; SSO_FAIL=$((SSO_FAIL + 1))
  fi
}

# Small predicates for `check`.
url_starts_with() { case "$SSO_FINAL_URL" in "$1"*) return 0;; *) return 1;; esac; }
body_has() { grep -q -- "$1" "$SSO_BODY"; }
http_ok() { # http_ok <url> [jar]: 2xx with the cookie jar
  local code; code=$(curl -sS -o /dev/null -w '%{http_code}' ${2:+-b "$2"} "$1")
  [ "${code:0:1}" = 2 ]
}

# So `check "..." bash -c '...kc_admin...'` works in a child shell.
export KC_URL KC_REALM SSO_USER SSO_TMP
export -f _read_secret sso_admin_token kc_admin sso_user_id url_starts_with body_has http_ok
