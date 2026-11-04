# wg-portal (OIDC provider `keycloak`, Keycloak client `wg-portal`): login
# through Keycloak, accounts keyed by preferred_username (so the existing
# prestonh/dylanh accounts are reused), and admin from the wg-admin group.
# The test user's wg-portal account is left in place, non-admin (the last
# login is the one without wg-admin); it can only log in through the
# sso-regression Keycloak user, which is disabled between runs.

WG_URL=https://wg.prestonhager.com
WG_DB=/srv/wireguard/data/sqlite.db
WG_SQLITE=$(nix build --no-link --print-out-paths nixpkgs#sqlite.bin)/bin/sqlite3
wg_sql() { "$WG_SQLITE" -readonly "$WG_DB" "$1"; }
wg_session() { curl -sS -b "$1" "$WG_URL/api/v0/auth/session"; } # wg_session <jar>
export WG_URL
export -f wg_session

check "Keycloak is the only OIDC provider" \
  bash -c 'curl -sS "$WG_URL/api/v0/auth/providers" | jq -e "[.[].Identifier] == [\"keycloak\"]"'

wg_kc_uid=$(sso_user_id)
wg_gid=$(kc_admin GET "/groups?search=wg-admin&exact=true&briefRepresentation=true" \
  | jq -r '.[] | select(.name == "wg-admin") | .id')
wg_set_group() { kc_admin "$1" "/users/$wg_kc_uid/groups/$wg_gid" >/dev/null; } # PUT|DELETE

wg_real_before=$(wg_sql "select identifier, email, is_admin from users where identifier != '$SSO_USER' order by identifier;")

# In wg-admin: logged in, admin.
wg_set_group PUT
sso_login "$WG_URL/api/v0/auth/login/keycloak/init?redirect=true" "$SSO_TMP/wg1" || true
check "login reaches the wg-portal callback" \
  bash -c '[[ "$0" == '"$WG_URL"'/api/v0/auth/login/keycloak/callback* ]]' "$SSO_FINAL_URL"
check "session is logged in as $SSO_USER" \
  bash -c 'wg_session "$0" | jq -e ".LoggedIn == true and .UserIdentifier == \"sso-regression\""' "$SSO_TMP/wg1"
check "wg-admin member is wg-portal admin" \
  bash -c 'wg_session "$0" | jq -e ".IsAdmin == true"' "$SSO_TMP/wg1"
check "account linked to the keycloak provider" \
  test "$(wg_sql "select count(*) from user_authentications where user_identifier = '$SSO_USER' and source = 'oauth' and provider_name = 'keycloak';")" = 1

# Without wg-admin, fresh cookies: same account, not admin.
wg_set_group DELETE
sso_login "$WG_URL/api/v0/auth/login/keycloak/init?redirect=true" "$SSO_TMP/wg2" || true
check "2nd login is the same account" \
  bash -c 'wg_session "$0" | jq -e ".LoggedIn == true and .UserIdentifier == \"sso-regression\""' "$SSO_TMP/wg2"
check "without wg-admin: not admin" \
  bash -c 'wg_session "$0" | jq -e "(.IsAdmin // false) == false"' "$SSO_TMP/wg2"
check "one wg-portal account for the test user" \
  test "$(wg_sql "select count(*) from users where identifier = '$SSO_USER';")" = 1
wg_set_group PUT # back to the declared membership

check "real wg-portal accounts unchanged" \
  test "$(wg_sql "select identifier, email, is_admin from users where identifier != '$SSO_USER' order by identifier;")" = "$wg_real_before"
