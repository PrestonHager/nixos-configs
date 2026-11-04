# Keycloak itself: discovery, the test user's browser login, groups claim
# scope, and realm email settings.

check "realm discovery issuer" \
  test "$(curl -sS "$KC_URL/realms/$KC_REALM/.well-known/openid-configuration" | jq -r .issuer)" = "$KC_URL/realms/$KC_REALM"

sso_login "$KC_URL/realms/$KC_REALM/protocol/openid-connect/auth?client_id=opkssh&response_type=code&scope=openid&redirect_uri=http://localhost:3000/login-callback" || true
check "browser login as $SSO_USER reaches the client callback with a code" \
  bash -c '[[ "$0" == http://localhost:3000/login-callback\?*code=* ]]' "$SSO_FINAL_URL"

check "groups client scope exists" \
  bash -c 'kc_admin GET /client-scopes | jq -e "any(.[]; .name == \"groups\")"'
check "realm email (SMTP) configured" \
  bash -c 'kc_admin GET "" | jq -e ".smtpServer.host == \"smtp.mail.me.com\" and .smtpServer.from == \"admin@prestonhager.com\""'
check "Zitadel role groups exist" \
  bash -c 'kc_admin GET "/groups?briefRepresentation=true&max=200" | jq -e "[.[].name] | contains([\"grafana_admin\",\"nextcloud_admin\",\"coolify_admin\"])"'
