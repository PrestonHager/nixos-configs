# Jellyfin (SSO-Auth plugin, provider `keycloak`, Keycloak client `jellyfin`):
# the SSO start URL ends with a Jellyfin session, login needs jellyfin_user
# or jellyfin_admin, IsAdministrator follows jellyfin_admin (granted and
# revoked), and the real accounts keep their Jellyfin user ids. The test
# user's Jellyfin account is deleted at the end.

JF_URL=https://jellyfin.prestonhager.com
JF_PROVIDER=keycloak
JF_DB=/jf/config/data/jellyfin.db
JF_SSO_XML=/jf/config/plugins/configurations/SSO-Auth.xml
JF_SQLITE=$(nix build --no-link --print-out-paths nixpkgs#sqlite.bin 2>/dev/null)/bin/sqlite3
JF_XML=$(nix build --no-link --print-out-paths nixpkgs#xmlstarlet 2>/dev/null)/bin/xmlstarlet

jf_sql() { "$JF_SQLITE" -readonly "$JF_DB" "$1"; }
jf_api() { # jf_api <token> <method> <path>
  # Jellyfin 12 ignores the legacy X-Emby-Token header.
  curl -sS -X "$2" -H "Authorization: MediaBrowser Token=\"$1\"" "$JF_URL$3"
}
# jf_login <jar>: SSO login, then the plugin's /Auth call the callback page
# makes in a browser. Prints the AuthenticationResult JSON (empty on failure).
jf_login() {
  local data
  sso_login "$JF_URL/sso/OID/start/$JF_PROVIDER" "$1" || return 1
  data=$(grep -o "var data = '[^']*'" "$SSO_BODY" | head -1 | sed "s/^var data = '//; s/'$//")
  [ -n "$data" ] || return 1
  curl -sS -H 'Content-Type: application/json' -H 'Accept: application/json' \
    --data-binary "{\"deviceId\":\"sso-regression-test\",\"appName\":\"sso-regression\",\"appVersion\":\"1\",\"deviceName\":\"sso-regression\",\"data\":\"$data\"}" \
    "$JF_URL/sso/OID/Auth/$JF_PROVIDER"
}
jf_logout() { [ -n "$1" ] && jf_api "$1" POST /Sessions/Logout >/dev/null; }
jf_real_accounts() {
  jf_sql "SELECT Username, Id FROM Users WHERE Username IN ('prestonh','dylanh','admin@prestonhager.com') ORDER BY Username;"
  jf_sql "SELECT u.Username, count(*) FROM UserData d JOIN Users u ON u.Id = d.UserId WHERE u.Username IN ('prestonh','dylanh') GROUP BY 1 ORDER BY 1;"
}
# Jellyfin user id the plugin's link for a Keycloak user points to, by sub or
# (before that user's first login) by username.
jf_link_for() { # jf_link_for <username>
  local sub; sub=$(kc_admin GET "/users?username=$1&exact=true" | jq -r '.[0].id // empty')
  "$JF_XML" sel -t -m "/PluginConfiguration/OidConfigs/item[key/string='$JF_PROVIDER']/value/PluginConfiguration/CanonicalLinks/item[key/string='$sub' or key/string='$1']" \
    -v value/guid -n "$JF_SSO_XML" | head -1 | tr a-f A-F
}
export JF_URL JF_PROVIDER
export -f jf_api

jf_kc_uid=$(sso_user_id)
jf_gid() { kc_admin GET "/groups?search=$1&exact=true&briefRepresentation=true" | jq -r --arg n "$1" '.[] | select(.name == $n) | .id'; }
jf_admin_gid=$(jf_gid jellyfin_admin)
jf_user_gid=$(jf_gid jellyfin_user)
jf_set_group() { kc_admin "$1" "/users/$jf_kc_uid/groups/$2" >/dev/null; } # PUT|DELETE <gid>

jf_real_before=$(jf_real_accounts)

# Plugin configuration as written by jellyfin-sso-setup.
check "SSO provider $JF_PROVIDER uses the Keycloak realm discovery" \
  bash -c '"$0" sel -t -v "/PluginConfiguration/OidConfigs/item[key/string=\"$1\"]/value/PluginConfiguration/OidEndpoint" "$2" | grep -qx "$3"' \
  "$JF_XML" "$JF_PROVIDER" "$JF_SSO_XML" "$KC_URL/realms/$KC_REALM/.well-known/openid-configuration"
check "username account adoption is disabled" \
  bash -c '"$0" sel -t -v "/PluginConfiguration/OidConfigs/item[key/string=\"$1\"]/value/PluginConfiguration/DisableUsernameAccountAdoption" "$2" | grep -qx true' \
  "$JF_XML" "$JF_PROVIDER" "$JF_SSO_XML"
for u in prestonh dylanh; do
  check "$u is linked to the existing Jellyfin user" \
    test "$(jf_link_for "$u")" = "$(jf_sql "SELECT Id FROM Users WHERE Username='$u';")"
done
check "login page offers Sign in with Keycloak" \
  bash -c 'curl -sS "$0/Branding/Configuration" | jq -e ".LoginDisclaimer | contains(\"/sso/OID/start/$1\")"' "$JF_URL" "$JF_PROVIDER"

# 1st login, jellyfin_user only: a plain account.
jf_set_group DELETE "$jf_admin_gid"
jf_set_group PUT "$jf_user_gid"
jf1=$(jf_login "$SSO_TMP/jf1" || true)
jf1_tok=$(jq -r '.AccessToken // empty' <<<"$jf1" 2>/dev/null)
check "SSO start URL ends with a Jellyfin session" test -n "$jf1_tok"
check "session is $SSO_USER" test "$(jq -r '.User.Name' <<<"$jf1")" = "$SSO_USER"
check "jellyfin_user member is not an administrator" test "$(jq -r '.User.Policy.IsAdministrator' <<<"$jf1")" = false
check "API: /Users/Me with the SSO token" \
  bash -c 'jf_api "$0" GET /Users/Me | jq -e ".Name == \"$1\""' "$jf1_tok" "$SSO_USER"
check "API: libraries visible" \
  bash -c 'jf_api "$0" GET /UserViews | jq -e ".Items | length > 0"' "$jf1_tok"
jf_uid=$(jq -r '.User.Id // empty' <<<"$jf1")

# 2nd login, with jellyfin_admin: same account, administrator.
jf_set_group PUT "$jf_admin_gid"
jf2=$(jf_login "$SSO_TMP/jf2" || true)
check "2nd login is the same Jellyfin user" test "$(jq -r '.User.Id' <<<"$jf2")" = "$jf_uid"
check "jellyfin_admin member is an administrator" test "$(jq -r '.User.Policy.IsAdministrator' <<<"$jf2")" = true
jf2_tok=$(jq -r '.AccessToken // empty' <<<"$jf2" 2>/dev/null)
check "no duplicate Jellyfin user was created" \
  test "$(jf_sql "SELECT count(*) FROM Users WHERE Username LIKE 'sso-regression%';")" = 1

# 3rd login, jellyfin_admin removed: demoted again.
jf_set_group DELETE "$jf_admin_gid"
jf3=$(jf_login "$SSO_TMP/jf3" || true)
check "without jellyfin_admin: administrator revoked" test "$(jq -r '.User.Policy.IsAdministrator' <<<"$jf3")" = false
jf3_tok=$(jq -r '.AccessToken // empty' <<<"$jf3" 2>/dev/null)

# Neither group: refused.
jf_set_group DELETE "$jf_user_gid"
jf4=$(jf_login "$SSO_TMP/jf4" || true)
check "without jellyfin_user/jellyfin_admin: login refused" \
  bash -c '[ -z "$(jq -r ".AccessToken // empty" <<<"$0" 2>/dev/null)" ]' "$jf4"
jf_set_group PUT "$jf_user_gid" # back to the declared membership

check "real Jellyfin accounts and watch data unchanged" test "$(jf_real_accounts)" = "$jf_real_before"

# Cleanup: delete the test account. Needs an admin session, so take one
# last admin login, delete, and drop the group again.
jf_logout "$jf1_tok"; jf_logout "$jf2_tok"; jf_logout "$jf3_tok"
jf_set_group PUT "$jf_admin_gid"
jf5_tok=$(jf_login "$SSO_TMP/jf5" | jq -r '.AccessToken // empty' 2>/dev/null)
jf_set_group DELETE "$jf_admin_gid"
[ -n "$jf_uid" ] && [ -n "$jf5_tok" ] && jf_api "$jf5_tok" DELETE "/Users/$jf_uid" >/dev/null
check "test Jellyfin account deleted" \
  test "$(jf_sql "SELECT count(*) FROM Users WHERE Username LIKE 'sso-regression%';")" = 0
