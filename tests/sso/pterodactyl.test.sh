# Game panel (Hydrodactyl), production and test: Keycloak login through the
# panel's SSO button, admin only with the right group, and the existing
# accounts' links moved from Zitadel to Keycloak.
#
# sso-regression is in pterodactyl_test_admin (homelab.keycloak.testUser,
# hydrodactyl.nix). This test adds pterodactyl_admin for single logins and
# swaps the groups back afterwards. The panel users the logins create are
# deleted at the end (and before the start, in case an earlier run died).

PANEL_PROD=https://panel.prestonhager.com
PANEL_TEST=https://test.panel.prestonhager.com
PANEL_SSO_START=/extensions/sociallogin/redirect/keycloak
PANEL_SSO_EMAIL=sso-regression@prestonhager.com

# panel_sql prod|test <sql>: run SQL in the panel's database, tab-separated.
panel_sql() {
  local c=pterodactyl-db db=panel
  if [ "$1" = test ]; then
    c=pterodactyl-test-db
    db=$(grep -m1 '^DB_DATABASE=' /var/lib/pterodactyl-test/pterodactyl.env | cut -d= -f2-)
  fi
  podman exec -i "$c" sh -c 'mariadb -N -B -uroot -p"$MARIADB_ROOT_PASSWORD" "$0"' "$db" <<<"$2"
}

# panel_admin_flag prod|test: root_admin of the sso-regression panel user.
panel_admin_flag() {
  panel_sql "$1" "SELECT root_admin FROM users WHERE email = '$PANEL_SSO_EMAIL';"
}

# panel_drop_test_user prod|test: delete the sso-regression panel user.
panel_drop_test_user() {
  local c=pterodactyl
  [ "$1" = test ] && c=pterodactyl-test
  podman exec -i "$c" php <<PHP >/dev/null
<?php
require "/var/www/pterodactyl/vendor/autoload.php";
\$app = require "/var/www/pterodactyl/bootstrap/app.php";
\$app->make(Illuminate\\Contracts\\Console\\Kernel::class)->bootstrap();
foreach (Pterodactyl\\Models\\User::query()->where("email", "$PANEL_SSO_EMAIL")->get() as \$u) {
  Pterodactyl\\Addons\\Sso\\SocialConnection::query()->where("user_id", \$u->id)->delete();
  app(Pterodactyl\\Services\\Users\\UserDeletionService::class)->handle(\$u);
}
PHP
}

kc_group_id() {
  kc_admin GET "/groups?search=$1&exact=true&briefRepresentation=true" | jq -r --arg n "$1" '.[] | select(.name == $n) | .id' | head -1
}
kc_test_user_group() { # kc_test_user_group join|leave <group>
  local uid gid method=PUT
  uid=$(sso_user_id); gid=$(kc_group_id "$2")
  [ -n "$uid" ] && [ -n "$gid" ] || return 1
  [ "$1" = leave ] && method=DELETE
  kc_admin "$method" "/users/$uid/groups/$gid" >/dev/null
}

# panel_login prod|test: SSO login with a fresh cookie jar.
panel_login() {
  local base=$PANEL_PROD
  [ "$1" = test ] && base=$PANEL_TEST
  PANEL_BASE=$base
  sso_login "$base$PANEL_SSO_START" || true
}
panel_lands_home() { [ "${SSO_FINAL_URL%/}" = "$PANEL_BASE" ]; }
# Session cookie works against the client API (the SPA's own calls).
panel_account_ok() {
  local code
  code=$(curl -sS -o "$SSO_TMP/account.json" -w '%{http_code}' -b "$SSO_JAR" \
    -H 'Accept: application/json' -H "Referer: $PANEL_BASE/" "$PANEL_BASE/api/client/account")
  [ "$code" = 200 ] && jq -e --arg e "$PANEL_SSO_EMAIL" '.attributes.email == $e' "$SSO_TMP/account.json"
}
export PANEL_BASE PANEL_SSO_EMAIL SSO_JAR
export -f panel_sql panel_admin_flag panel_account_ok

panel_drop_test_user prod
panel_drop_test_user test
kc_test_user_group leave pterodactyl_admin || true
kc_test_user_group join pterodactyl_test_admin || true

# --- production panel ---------------------------------------------------------
check "prod: SSO button route leads to the Keycloak login form" \
  bash -c 'curl -sS -L "$0" | grep -q kc-form-login' "$PANEL_PROD$PANEL_SSO_START"

panel_login prod
check "prod: SSO login lands on the panel ($SSO_FINAL_URL)" panel_lands_home
check "prod: logged in (client API answers for $PANEL_SSO_EMAIL)" panel_account_ok
check "prod: no pterodactyl_admin group -> not root admin" \
  test "$(panel_admin_flag prod)" = 0

kc_test_user_group join pterodactyl_admin
panel_login prod
check "prod: with pterodactyl_admin -> root admin" \
  test "$(panel_admin_flag prod)" = 1
check "prod: client API reports admin" \
  bash -c 'panel_account_ok && jq -e ".attributes.admin == true" "$SSO_TMP/account.json"'

kc_test_user_group leave pterodactyl_admin
panel_login prod
check "prod: group removed -> admin revoked on next login" \
  test "$(panel_admin_flag prod)" = 0

# --- test panel ---------------------------------------------------------------
panel_login test
check "test: SSO login lands on the test panel ($SSO_FINAL_URL)" panel_lands_home
check "test: logged in (client API answers for $PANEL_SSO_EMAIL)" panel_account_ok
check "test: pterodactyl_test_admin -> root admin" \
  test "$(panel_admin_flag test)" = 1

kc_test_user_group leave pterodactyl_test_admin
kc_test_user_group join pterodactyl_admin
panel_login test
check "test: production group alone does not grant test-panel admin" \
  test "$(panel_admin_flag test)" = 0
kc_test_user_group leave pterodactyl_admin
kc_test_user_group join pterodactyl_test_admin

# --- existing accounts --------------------------------------------------------
check "prod: provider is keycloak (no zitadel row left)" \
  test "$(panel_sql prod "SELECT GROUP_CONCAT(short_name) FROM social_providers;")" = keycloak
check "test: provider is keycloak (no zitadel row left)" \
  test "$(panel_sql test "SELECT GROUP_CONCAT(short_name) FROM social_providers;")" = keycloak
PRESTONH_SUB=$(kc_admin GET "/users?username=prestonh&exact=true" | jq -r '.[0].id // empty')
for p in prod test; do
  check "$p: panel user prestonhager is linked to Keycloak prestonh ($PRESTONH_SUB)" \
    test "$(panel_sql $p "SELECT c.auth_id FROM social_connections c JOIN users u ON u.id = c.user_id WHERE u.email = 'preston@hagerfamily.com';")" = "$PRESTONH_SUB"
  check "$p: no link still holds a Zitadel id" \
    test "$(panel_sql $p "SELECT COUNT(*) FROM social_connections WHERE auth_id REGEXP '^[0-9]+\$';")" = 0
done

# --- oauth2-proxy (pterodactyl-oauth.nix, only when it is deployed) -------------
if systemctl is-active -q pterodactyl-oauth2-proxy; then
  sso_login "$PANEL_PROD/oauth2/start?rd=/" || true
  check "oauth2-proxy: login lands on the panel ($SSO_FINAL_URL)" \
    bash -c '[ "${0%/}" = "$1" ]' "$SSO_FINAL_URL" "$PANEL_PROD"
else
  echo "  SKIP  oauth2-proxy: pterodactyl-oauth2-proxy is not running (pterodactyl-oauth.nix is not imported)"
fi

# --- cleanup ------------------------------------------------------------------
panel_drop_test_user prod
panel_drop_test_user test
check "no sso-regression panel user left behind" \
  test "$(panel_sql prod "SELECT COUNT(*) FROM users WHERE email = '$PANEL_SSO_EMAIL';")$(panel_sql test "SELECT COUNT(*) FROM users WHERE email = '$PANEL_SSO_EMAIL';")" = 00
