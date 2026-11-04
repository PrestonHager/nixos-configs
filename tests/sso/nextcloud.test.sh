# Nextcloud (user_oidc, provider `keycloak`): login through Keycloak, a stable
# uid (preferred_username, no duplicate on the second login), and admin
# from the nextcloud_admin group (client role -> `groups: ["admin"]`).
# The test user's Nextcloud account is deleted at the end.

NC_URL=https://cloud.prestonhager.com
nc_occ() { podman exec -u www-data nextcloud php /var/www/html/occ "$@"; }
nc_user_json() { nc_occ user:info "$1" --output=json 2>/dev/null; }
nc_whoami() { # nc_whoami <jar>: uid of the session in the cookie jar
  curl -sS -b "$1" -H 'OCS-APIRequest: true' "$NC_URL/ocs/v2.php/cloud/user?format=json" | jq -r '.ocs.data.id // empty'
}
nc_kc_group_id() {
  kc_admin GET "/groups?search=nextcloud_admin&exact=true&briefRepresentation=true" | jq -r '.[] | select(.name == "nextcloud_admin") | .id'
}
export -f nc_occ nc_user_json nc_whoami

# Uids and sizes of the real accounts, to compare after the logins.
nc_real_before=$(for u in prestonh dylanh nextcloud-admin; do nc_user_json "$u" | jq -c '{user_id, backend, groups, used: .storage.used}'; done)

nc_pid=$(nc_occ user_oidc:provider keycloak --output=json 2>/dev/null | jq -r '.id // empty')
check "user_oidc provider keycloak exists" test -n "$nc_pid"
check "provider maps uid from preferred_username, unique-uid off" \
  bash -c 'nc_occ user_oidc:provider keycloak --output=json | jq -e ".settings.mappingUid == \"preferred_username\" and .settings.uniqueUid == false and .settings.providerBasedId == false"'
check "provider discovery is the Keycloak realm" \
  bash -c 'nc_occ user_oidc:provider keycloak --output=json | jq -e ".discoveryEndpoint == \"$KC_URL/realms/$KC_REALM/.well-known/openid-configuration\""'

# A leftover account from an interrupted run would hide a duplicate.
nc_occ user:delete "$SSO_USER" >/dev/null 2>&1 || true

nc_kc_uid=$(sso_user_id)
nc_gid=$(nc_kc_group_id)
nc_in_group() { kc_admin GET "/users/$nc_kc_uid/groups?briefRepresentation=true" | jq -e 'any(.[]; .name == "nextcloud_admin")' >/dev/null; }
nc_set_group() { # nc_set_group PUT|DELETE
  kc_admin "$1" "/users/$nc_kc_uid/groups/$nc_gid" >/dev/null
}
nc_was_member=no
nc_in_group && nc_was_member=yes
[ "$nc_was_member" = yes ] || nc_set_group PUT

# 1st login: account created as uid sso-regression, admin from nextcloud_admin.
sso_login "$NC_URL/apps/user_oidc/login/$nc_pid" "$SSO_TMP/nc1" || true
check "login lands on Nextcloud, not the login page" \
  bash -c '[[ "$0" == '"$NC_URL"'/* && "$0" != */login* ]]' "$SSO_FINAL_URL"
check "session is logged in as $SSO_USER" test "$(nc_whoami "$SSO_TMP/nc1")" = "$SSO_USER"
check "account uses the user_oidc backend" \
  bash -c 'nc_user_json "$0" | jq -e ".backend == \"user_oidc\""' "$SSO_USER"
check "nextcloud_admin member is in Nextcloud admin" \
  bash -c 'nc_user_json "$0" | jq -e ".groups | index(\"admin\")"' "$SSO_USER"

# 2nd login, fresh cookies: same account, no second one.
sso_login "$NC_URL/apps/user_oidc/login/$nc_pid" "$SSO_TMP/nc2" || true
check "second login maps to the same uid" test "$(nc_whoami "$SSO_TMP/nc2")" = "$SSO_USER"
check "no duplicate account (exactly one user named like the test user)" \
  bash -c 'nc_occ user:list --output=json | jq -e "[keys[] | select(test(\"sso\"; \"i\"))] == [\"$0\"]"' "$SSO_USER"
check "no hashed (unique-uid) account created" \
  bash -c 'nc_occ user:list --output=json | jq -e "[keys[] | select(test(\"^[0-9a-f]{64}$\"))] | length == 0"'

# Out of nextcloud_admin: the next login drops Nextcloud admin.
nc_set_group DELETE
sso_login "$NC_URL/apps/user_oidc/login/$nc_pid" "$SSO_TMP/nc3" || true
check "without nextcloud_admin the login drops Nextcloud admin" \
  bash -c 'nc_user_json "$0" | jq -e "(.groups | index(\"admin\")) == null"' "$SSO_USER"
[ "$nc_was_member" = yes ] && nc_set_group PUT

# The real accounts are untouched.
nc_real_after=$(for u in prestonh dylanh nextcloud-admin; do nc_user_json "$u" | jq -c '{user_id, backend, groups, used: .storage.used}'; done)
check "prestonh, dylanh, nextcloud-admin unchanged (uid, backend, groups)" \
  test "$(jq -c 'del(.used)' <<<"$nc_real_before")" = "$(jq -c 'del(.used)' <<<"$nc_real_after")"
check "local nextcloud-admin still in admin" \
  bash -c 'nc_user_json nextcloud-admin | jq -e ".backend == \"Database\" and (.groups | index(\"admin\"))"'

nc_occ user:delete "$SSO_USER" >/dev/null 2>&1
check "test user's Nextcloud account cleaned up" bash -c '! nc_user_json "$0" >/dev/null' "$SSO_USER"
