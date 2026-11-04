# Technitium DNS web console (built-in SSO, Keycloak client `technitium`):
# login through Keycloak, Administrators membership follows the
# technitium_admin group, sign-up only for members of a mapped group, and the
# real SSO account (prestonh) is still there. Technitium links SSO accounts by
# `sub` only; prestonh was relinked to the Keycloak sub at the cutover
# (docs/dns-ace.md). The test user's Technitium account is deleted at the end.

TD_URL=https://dns.prestonhager.com
TD_API=http://127.0.0.1:5380
TD_USER=sso-regression@prestonhager.com # Technitium names new SSO accounts by email

td_admin_token() {
  curl -sS -X POST "$TD_API/api/user/login" --data-urlencode user=admin \
    --data-urlencode "pass@/stor/technitium/secrets/admin-password" | jq -r '.token // empty'
}
printf 'Authorization: Bearer %s\n' "$(td_admin_token)" > "$SSO_TMP/td-auth"
td_admin() { curl -sS -H "@$SSO_TMP/td-auth" "$TD_API$1"; } # td_admin <path?query>
td_groups() { td_admin "/api/admin/users/get?user=$1&includeGroups=true" | jq -c '.response.memberOfGroups // []'; }

# Keycloak answers Technitium with response_mode=form_post: an auto-submitting
# form that curl does not follow. Submit it, then follow the redirects.
td_login() { # td_login <jar>
  local action args=()
  sso_login "$TD_URL/sso/login" "$1" || return 1
  action=$(grep -o '<form[^>]*action="[^"]*"' "$SSO_BODY" | head -1 | sed 's/.*action="//; s/"$//; s/&amp;/\&/g')
  [ -n "$action" ] || return 1
  while IFS= read -r inp; do
    local n v
    n=$(sed -n 's/.*name="\([^"]*\)".*/\1/p' <<<"$inp")
    v=$(sed -n 's/.*value="\([^"]*\)".*/\1/p' <<<"$inp" | sed 's/&amp;/\&/g; s/&#x2B;/+/g; s/&#x2F;/\//g; s/&#x3D;/=/g')
    [ -n "$n" ] && args+=(--data-urlencode "$n=$v")
  done < <(grep -o '<input[^>]*type="hidden"[^>]*>' "$SSO_BODY")
  SSO_FINAL_URL=$(curl -sS -c "$1" -b "$1" -L -o "$SSO_BODY" -w '%{url_effective}' "${args[@]}" "$action")
}
td_session_token() { awk '$6 == "token" { print $7 }' "$1" | tail -1; } # td_session_token <jar>
td_session_user() { curl -sS "$TD_API/api/user/session/get?token=$(td_session_token "$1")" | jq -r '.username // empty'; }
td_can_admin() { # admin-only API with the SSO session's token
  curl -sS "$TD_API/api/admin/users/list?token=$(td_session_token "$1")" | jq -e '.status == "ok"' >/dev/null
}
export TD_API TD_USER SSO_TMP
export -f td_admin td_groups td_session_token td_session_user td_can_admin

check "SSO authority is the Keycloak realm" \
  bash -c 'td_admin /api/admin/sso/get | jq -e ".response.ssoAuthority == \"$KC_URL/realms/$KC_REALM\" and .response.ssoClientId == \"technitium\""'
check "SSO scopes are openid profile email groups" \
  bash -c 'td_admin /api/admin/sso/get | jq -e "(.response.ssoScopes | sort) == [\"email\",\"groups\",\"openid\",\"profile\"]"'

td_kc_uid=$(sso_user_id)
td_gid=$(kc_admin GET "/groups?search=technitium_admin&exact=true&briefRepresentation=true" \
  | jq -r '.[] | select(.name == "technitium_admin") | .id')
td_set_group() { kc_admin "$1" "/users/$td_kc_uid/groups/$td_gid" >/dev/null; } # PUT|DELETE

td_real_before=$(td_admin /api/admin/users/list | jq -c '[.response.users[] | select(.username != env.TD_USER) | {username, type}]')

# Leftover from an interrupted run.
td_admin "/api/admin/users/delete?user=$TD_USER" >/dev/null

# Not in a mapped group, no account yet: sign-up refused.
td_set_group DELETE
td_login "$SSO_TMP/td0" || true
check "sign-up refused without technitium_admin" test -z "$(td_session_token "$SSO_TMP/td0")"
check "no account created for the refused sign-up" \
  bash -c 'td_admin "/api/admin/users/get?user=$TD_USER" | jq -e ".status != \"ok\""'

# In technitium_admin: account created, Administrators.
td_set_group PUT
td_login "$SSO_TMP/td1" || true
check "login lands on the DNS console" bash -c '[[ "$0" == '"$TD_URL"'/* ]]' "$SSO_FINAL_URL"
check "session is the SSO account $TD_USER" test "$(td_session_user "$SSO_TMP/td1")" = "$TD_USER"
check "technitium_admin member is in Administrators" \
  bash -c 'td_groups "$TD_USER" | jq -e "index(\"Administrators\")"'
check "technitium_admin member can use the admin API" td_can_admin "$SSO_TMP/td1"

# Existing account, removed from technitium_admin: same account, demoted.
td_set_group DELETE
td_login "$SSO_TMP/td2" || true
check "2nd login is the same account" test "$(td_session_user "$SSO_TMP/td2")" = "$TD_USER"
check "without technitium_admin: not in Administrators" \
  bash -c 'td_groups "$TD_USER" | jq -e "index(\"Administrators\") | not"'
check "without technitium_admin: admin API denied" bash -c '! td_can_admin "$0"' "$SSO_TMP/td2"
td_set_group PUT # back to the declared membership

check "prestonh is still an SSO account" \
  bash -c 'td_admin "/api/admin/users/get?user=prestonh" | jq -e ".response.type == \"RemoteSSO\""'
check "no duplicate account for prestonh's email" \
  bash -c 'td_admin "/api/admin/users/get?user=preston@hagerfamily.com" | jq -e ".status != \"ok\""'
check "real Technitium accounts unchanged" bash -c '[ "$0" = "$(td_admin /api/admin/users/list | jq -c "[.response.users[] | select(.username != env.TD_USER) | {username, type}]")" ]' "$td_real_before"

td_admin "/api/admin/users/delete?user=$TD_USER" >/dev/null
rm -f "$SSO_TMP/td-auth"
