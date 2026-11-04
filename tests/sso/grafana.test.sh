# Grafana (Generic OAuth, Keycloak client `grafana`): login through Keycloak,
# an existing Grafana account is matched by email (not by the IdP `sub`, which
# changed with the move off Zitadel), and GrafanaAdmin follows the
# grafana_admin group. The test user's Grafana account is deleted at the end.

GF_URL=https://grafana.prestonhager.com
GF_LOGIN=sso-regression@prestonhager.com # login = email (login_attribute_path)

# Grafana's local admin (break-glass) for the admin API, via a netrc file so
# the password never reaches argv.
( umask 077; printf 'machine grafana.prestonhager.com login admin password %s\n' \
    "$(cat /grafana/data/admin-api-pass)" > "$SSO_TMP/gf-netrc" )
gf_admin() { # gf_admin <method> <path> [json]
  if [ $# -ge 3 ]; then
    curl -sS -X "$1" --netrc-file "$SSO_TMP/gf-netrc" -H 'Content-Type: application/json' \
      --data-binary "$3" "$GF_URL$2"
  else
    curl -sS -X "$1" --netrc-file "$SSO_TMP/gf-netrc" "$GF_URL$2"
  fi
}
gf_me() { curl -sS -b "$1" "$GF_URL/api/user"; } # gf_me <jar>
gf_org_role() { curl -sS -b "$1" "$GF_URL/api/user/orgs" | jq -r '.[] | select(.orgId == 1) | .role'; }
gf_lookup_id() { gf_admin GET "/api/users/lookup?loginOrEmail=$GF_LOGIN" | jq -r '.id // empty'; }
export GF_URL GF_LOGIN
export -f gf_admin gf_me gf_org_role gf_lookup_id

gf_kc_uid=$(sso_user_id)
gf_gid=$(kc_admin GET "/groups?search=grafana_admin&exact=true&briefRepresentation=true" \
  | jq -r '.[] | select(.name == "grafana_admin") | .id')
gf_set_group() { kc_admin "$1" "/users/$gf_kc_uid/groups/$gf_gid" >/dev/null; } # PUT|DELETE

# Real accounts, to compare after the logins (never touched by this test).
gf_real_before=$(for u in preston@hagerfamily.com dylan@hagerfamily.com admin@prestonhager.com; do
  gf_admin GET "/api/users/lookup?loginOrEmail=$u" | jq -c '{id, login, email, isGrafanaAdmin}'; done)

# Leftover from an interrupted run.
gf_old=$(gf_lookup_id)
[ -n "$gf_old" ] && gf_admin DELETE "/api/admin/users/$gf_old" >/dev/null

# An existing account with no link to the new IdP, like prestonh's after the
# move (old Zitadel sub in user_auth, Keycloak sub unknown).
gf_pre_id=$(gf_admin POST /api/admin/users \
  "{\"name\":\"SSO Regression\",\"email\":\"$GF_LOGIN\",\"login\":\"$GF_LOGIN\",\"password\":\"$(head -c 24 /dev/urandom | base64 | tr -dc A-Za-z0-9)\"}" \
  | jq -r '.id // empty')
check "pre-created existing Grafana account" test -n "$gf_pre_id"

# 1st login, in grafana_admin: lands on the pre-created account, server admin.
gf_set_group PUT
sso_login "$GF_URL/login/generic_oauth" "$SSO_TMP/gf1" || true
check "login lands on Grafana, not the login page" \
  bash -c '[[ "$0" == '"$GF_URL"'/* && "$0" != */login* ]]' "$SSO_FINAL_URL"
check "session is the existing account (matched by email, not sub)" \
  test "$(gf_me "$SSO_TMP/gf1" | jq -r .id)" = "$gf_pre_id"
check "login is the email" test "$(gf_me "$SSO_TMP/gf1" | jq -r .login)" = "$GF_LOGIN"
check "grafana_admin member is Grafana server admin" \
  bash -c 'gf_me "$0" | jq -e ".isGrafanaAdmin == true"' "$SSO_TMP/gf1"
check "grafana_admin member is org Admin" test "$(gf_org_role "$SSO_TMP/gf1")" = Admin

# 2nd login, fresh cookies, without grafana_admin: same account, demoted.
gf_set_group DELETE
sso_login "$GF_URL/login/generic_oauth" "$SSO_TMP/gf2" || true
check "2nd login is the same account" test "$(gf_me "$SSO_TMP/gf2" | jq -r .id)" = "$gf_pre_id"
check "no duplicate account was created" \
  test "$(gf_admin GET "/api/users/search?query=sso-regression" | jq '.totalCount')" = 1
check "without grafana_admin: not server admin" \
  bash -c 'gf_me "$0" | jq -e ".isGrafanaAdmin == false"' "$SSO_TMP/gf2"
check "without grafana_admin: org Viewer" test "$(gf_org_role "$SSO_TMP/gf2")" = Viewer
gf_set_group PUT # back to the declared membership

check "real Grafana accounts unchanged" bash -c '[ "$0" = "$(for u in preston@hagerfamily.com dylan@hagerfamily.com admin@prestonhager.com; do
  gf_admin GET "/api/users/lookup?loginOrEmail=$u" | jq -c "{id, login, email, isGrafanaAdmin}"; done)" ]' "$gf_real_before"

gf_admin DELETE "/api/admin/users/$gf_pre_id" >/dev/null
rm -f "$SSO_TMP/gf-netrc"
