# Matrix / Synapse (OIDC provider `keycloak`, Keycloak client `matrix`): the
# SSO redirect flow ends with a loginToken that /login accepts, the MXID is
# stable across logins, server admin follows matrix_admin (granted and
# revoked), and the real MXIDs stay linked to their Keycloak subs.
#
# The test MXID @sso-regression is kept between runs (Synapse never frees a
# localpart; deactivating it would turn the next login into
# @sso-regression1). It always ends the run without admin and with no
# access tokens.

MX_URL=https://matrix.prestonhager.com
MX_LOCAL=http://127.0.0.1:6167 # for /_synapse/admin (LAN-only through Caddy)
MX_SERVER=matrix.prestonhager.com
MX_IDP=oidc-keycloak
MX_TEST_MXID="@$SSO_USER:$MX_SERVER"
# Real accounts: MXID -> Keycloak username (docs/matrix-ace.md).
MX_REAL_USERS="prestonh"

mx_sql() { podman exec matrix-db psql -U synapse -d synapse -tAX -c "$1"; }
# mx_login <jar>: SSO redirect flow, then m.login.token. Prints the /login JSON.
mx_login() {
  local tok
  sso_login "$MX_URL/_matrix/client/v3/login/sso/redirect/$MX_IDP?redirectUrl=https%3A%2F%2Fsso-test.invalid%2F" "$1" || return 1
  # Synapse ends on its "continue to your account" page, linking to
  # redirectUrl?loginToken=...
  tok=$(grep -o 'loginToken=[A-Za-z0-9_.~-]*' "$SSO_BODY" | head -1 | cut -d= -f2)
  [ -n "$tok" ] || { echo "mx_login: no loginToken (ended at ${SSO_FINAL_URL%%\?*})" >&2; return 1; }
  # Synapse rate-limits logins per account (a few in a burst). Runs started
  # back to back can hit it: wait out retry_after_ms once (at most 6 min).
  # The loginToken stays valid for 2 min, so get a fresh one afterwards.
  local res wait_ms
  res=$(mx_token_login "$tok")
  wait_ms=$(jq -r 'select(.errcode == "M_LIMIT_EXCEEDED") | .retry_after_ms' <<<"$res" 2>/dev/null)
  if [ -n "$wait_ms" ] && [ "$wait_ms" -le 360000 ] && [ -z "${2:-}" ]; then
    echo "  (Synapse login rate limit: waiting $((wait_ms / 1000 + 1)) s)" >&2
    sleep $((wait_ms / 1000 + 1))
    mx_login "$1.retry" retried # fresh jar: sso_login expects the login form
    return
  fi
  printf '%s' "$res"
}
mx_token_login() { # mx_token_login <loginToken>
  curl -sS -H 'Content-Type: application/json' \
    --data-binary "{\"type\":\"m.login.token\",\"token\":\"$1\",\"initial_device_display_name\":\"sso-regression\"}" \
    "$MX_URL/_matrix/client/v3/login"
}
mx_logout() { [ -n "$1" ] && curl -sS -X POST -H "Authorization: Bearer $1" "$MX_URL/_matrix/client/v3/logout" >/dev/null; }
# mx_is_admin <token>: the user's own view of the admin API (403 when not admin).
mx_is_admin() {
  curl -sS -H "Authorization: Bearer $1" "$MX_LOCAL/_synapse/admin/v1/users/$(jq -rn --arg u "$MX_TEST_MXID" '$u|@uri')/admin" | jq -r '.admin // .errcode'
}
# mx_admin_is <token> <true|M_FORBIDDEN>: the admin flag is applied by a
# login callback and its cache may lag /login by a moment; wait up to 10 s.
mx_admin_is() {
  local i
  for i in $(seq 1 10); do
    [ "$(mx_is_admin "$1")" = "$2" ] && return 0
    sleep 1
  done
  return 1
}
mx_kc_sub() { kc_admin GET "/users?username=$1&exact=true" | jq -r '.[0].id // empty'; }
mx_real_links() {
  mx_sql "SELECT auth_provider, external_id, user_id FROM user_external_ids WHERE user_id <> '$MX_TEST_MXID' ORDER BY 1,3;"
  mx_sql "SELECT name, deactivated FROM users WHERE name <> '$MX_TEST_MXID' ORDER BY 1;"
}

mx_kc_uid=$(sso_user_id)
mx_gid=$(kc_admin GET "/groups?search=matrix_admin&exact=true&briefRepresentation=true" | jq -r '.[] | select(.name == "matrix_admin") | .id')
mx_set_group() { kc_admin "$1" "/users/$mx_kc_uid/groups/$mx_gid" >/dev/null; } # PUT|DELETE

check "client API: /_matrix/client/versions" \
  bash -c 'curl -sS "$0/_matrix/client/versions" | jq -e ".versions | length > 0"' "$MX_URL"
check "federation: /_matrix/federation/v1/version" \
  bash -c 'curl -sS "$0/_matrix/federation/v1/version" | jq -e ".server.name == \"Synapse\""' "$MX_URL"
check "federation: /.well-known/matrix/server" \
  bash -c 'curl -sS "$0/.well-known/matrix/server" | jq -e "has(\"m.server\")"' "$MX_URL"
check "login flows offer SSO via $MX_IDP only" \
  bash -c 'curl -sS "$0/_matrix/client/v3/login" | jq -e "[.flows[] | select(.type == \"m.login.sso\") | .identity_providers[].id] == [\"$1\"]"' "$MX_URL" "$MX_IDP"

for u in $MX_REAL_USERS; do
  check "@$u:$MX_SERVER is linked to Keycloak user $u's sub" \
    test "$(mx_sql "SELECT user_id FROM user_external_ids WHERE auth_provider = '$MX_IDP' AND external_id = '$(mx_kc_sub "$u")';")" = "@$u:$MX_SERVER"
done
mx_real_before=$(mx_real_links)

# 1st login, without matrix_admin.
mx_set_group DELETE
mx1=$(mx_login "$SSO_TMP/mx1" || true)
mx1_tok=$(jq -r '.access_token // empty' <<<"$mx1" 2>/dev/null)
check "SSO redirect flow: loginToken accepted by /login" test -n "$mx1_tok"
check "MXID is $MX_TEST_MXID (localpart from preferred_username)" test "$(jq -r '.user_id' <<<"$mx1")" = "$MX_TEST_MXID"
check "MXID linked to the Keycloak sub" \
  test "$(mx_sql "SELECT external_id FROM user_external_ids WHERE auth_provider = '$MX_IDP' AND user_id = '$MX_TEST_MXID';")" = "$mx_kc_uid"
check "without matrix_admin: not server admin" mx_admin_is "$mx1_tok" M_FORBIDDEN

# 2nd login, with matrix_admin: same MXID, server admin.
mx_set_group PUT
mx2=$(mx_login "$SSO_TMP/mx2" || true)
mx2_tok=$(jq -r '.access_token // empty' <<<"$mx2" 2>/dev/null)
check "repeat login maps to the same MXID" test "$(jq -r '.user_id' <<<"$mx2")" = "$MX_TEST_MXID"
check "matrix_admin member is server admin" mx_admin_is "$mx2_tok" true

# 3rd login, matrix_admin removed: admin revoked (the run ends here).
mx_set_group DELETE
mx3=$(mx_login "$SSO_TMP/mx3" || true)
mx3_tok=$(jq -r '.access_token // empty' <<<"$mx3" 2>/dev/null)
check "without matrix_admin again: admin revoked" mx_admin_is "$mx3_tok" M_FORBIDDEN
check "test MXID ends without admin" \
  test "$(mx_sql "SELECT admin FROM users WHERE name = '$MX_TEST_MXID';")" = 0
check "no duplicate MXID was created" \
  test "$(mx_sql "SELECT count(*) FROM users WHERE name LIKE '@sso-regression%';")" = 1

mx_logout "$mx1_tok"; mx_logout "$mx2_tok"
# logout/all also drops tokens an interrupted earlier run left behind.
[ -n "$mx3_tok" ] && curl -sS -X POST -H "Authorization: Bearer $mx3_tok" "$MX_URL/_matrix/client/v3/logout/all" >/dev/null
check "test MXID has no access tokens left" \
  test "$(mx_sql "SELECT count(*) FROM access_tokens WHERE user_id = '$MX_TEST_MXID';")" = 0
check "real MXIDs and their links unchanged" test "$(mx_real_links)" = "$mx_real_before"
