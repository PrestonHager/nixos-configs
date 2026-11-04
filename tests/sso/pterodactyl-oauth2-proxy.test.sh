# oauth2-proxy for the game panel (nixos/containers/pterodactyl-oauth.nix)
# against Keycloak.
#
# The module is not imported: nothing in production routes to the proxy. So
# that its Keycloak settings stay proven, this builds the proxy's start
# script from the repo, runs it as a transient unit on 127.0.0.1:4180 (the
# address Caddy would proxy /oauth2/* to), and drives a full login the way
# Caddy would forward it (Host + X-Forwarded-Proto). Requests that would hit
# https://panel.prestonhager.com/oauth2/* go to the transient proxy instead.
# If the module is deployed (pterodactyl-oauth2-proxy active), it tests that
# instance through Caddy's address instead of starting one.

OAP_HOST=panel.prestonhager.com
OAP_ADDR=127.0.0.1:4180
OAP_UNIT=sso-test-pterodactyl-oauth2-proxy
OAP_STARTED=

oap_curl() { # oap_curl <path> [curl args...]: a request as Caddy forwards it
  local path=$1; shift
  curl -sS -H "Host: $OAP_HOST" -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-Host: '"$OAP_HOST" \
    -H 'X-Real-IP: 127.0.0.1' "$@" "http://$OAP_ADDR$path"
}
# Header value from a dumped response (case-insensitive name).
hdr() { grep -i -m1 "^$1:" "$2" | cut -d' ' -f2- | tr -d '\r'; }
# "name=value" pairs of the Set-Cookies whose name matches an ERE, joined
# for a Cookie header. Large sessions are split into _oauth2_proxy_0, _1, ...
set_cookie() {
  grep -i -E "^set-cookie: ($1)=" "$2" | sed 's/^[Ss]et-[Cc]ookie: //; s/;.*//' | tr -d '\r' | paste -sd ';' | sed 's/;/; /g'
}

if systemctl is-active -q pterodactyl-oauth2-proxy; then
  echo "  (testing the deployed pterodactyl-oauth2-proxy)"
else
  OAP_SCRIPT=$(nix build --no-link --print-out-paths --impure --expr '
    let ace = (builtins.getFlake "/etc/nixos").nixosConfigurations.ace;
        x = ace.extendModules { modules = [ /etc/nixos/nixos/containers/pterodactyl-oauth.nix ]; };
    in x.config.systemd.services.pterodactyl-oauth2-proxy.serviceConfig.ExecStart' 2>/dev/null)
  check "oauth2-proxy: start script builds from the repo" test -x "$OAP_SCRIPT"
  if [ -x "$OAP_SCRIPT" ] && ! curl -s -o /dev/null "http://$OAP_ADDR/ping"; then
    systemctl stop "$OAP_UNIT" 2>/dev/null; systemctl reset-failed "$OAP_UNIT" 2>/dev/null
    systemd-run -q --unit="$OAP_UNIT" --collect -p RuntimeMaxSec=600 "$OAP_SCRIPT" && OAP_STARTED=1
    for _ in $(seq 1 30); do curl -s -o /dev/null "http://$OAP_ADDR/ping" && break; sleep 1; done
  fi
fi
check "oauth2-proxy: answers on $OAP_ADDR" curl -sf -o /dev/null "http://$OAP_ADDR/ping"

# 1. /oauth2/start -> Keycloak authorize URL for the pterodactyl client.
oap_curl '/oauth2/start?rd=/' -D "$SSO_TMP/oap1" -o /dev/null
OAP_AUTH=$(hdr location "$SSO_TMP/oap1")
OAP_CSRF=$(set_cookie _oauth2_proxy_csrf "$SSO_TMP/oap1")
check "oauth2-proxy: /oauth2/start redirects to the Keycloak realm with client pterodactyl" \
  bash -c '[[ "$0" == "$1/realms/$2/protocol/openid-connect/auth?"* && "$0" == *client_id=pterodactyl* && "$0" == *redirect_uri=https%3A%2F%2Fpanel.prestonhager.com%2Foauth2%2Fcallback* ]]' \
  "$OAP_AUTH" "$KC_URL" "$KC_REALM"

# 2. Keycloak login form, stop at the redirect back to /oauth2/callback.
OAP_JAR=$SSO_TMP/oap.jar
OAP_PAGE=$(curl -sS -c "$OAP_JAR" -b "$OAP_JAR" -L "$OAP_AUTH")
OAP_ACTION=$(grep -o 'action="[^"]*"' <<<"$OAP_PAGE" | head -1 | sed 's/^action="//; s/"$//; s/&amp;/\&/g')
_read_secret /run/secrets/keycloak-test-env SSO_REGRESSION_PASSWORD | tr -d '\n' > "$SSO_TMP/pw"
curl -sS -c "$OAP_JAR" -b "$OAP_JAR" -D "$SSO_TMP/oap2" -o /dev/null \
  --data-urlencode "username=$SSO_USER" --data-urlencode "password@$SSO_TMP/pw" "$OAP_ACTION"
rm -f "$SSO_TMP/pw"
OAP_CB=$(hdr location "$SSO_TMP/oap2")
check "oauth2-proxy: Keycloak login returns to /oauth2/callback with a code" \
  bash -c '[[ "$0" == https://panel.prestonhager.com/oauth2/callback\?*code=* ]]' "$OAP_CB"

# 3. Callback (code exchange with the client secret) -> session cookie, back to /.
oap_curl "${OAP_CB#https://"$OAP_HOST"}" -H "Cookie: $OAP_CSRF" -D "$SSO_TMP/oap3" -o /dev/null
OAP_SESSION=$(set_cookie '_oauth2_proxy(_[0-9]+)?' "$SSO_TMP/oap3")
check "oauth2-proxy: callback sets a session and lands on the panel ($(hdr location "$SSO_TMP/oap3"))" \
  bash -c '[ -n "$0" ] && [ "$1" = / ]' "$OAP_SESSION" "$(hdr location "$SSO_TMP/oap3")"

# 4. Caddy's forward_auth check: who the user is, with the groups claim.
oap_curl /oauth2/auth -H "Cookie: $OAP_SESSION" -D "$SSO_TMP/oap4" -o /dev/null
check "oauth2-proxy: /oauth2/auth accepts the session" \
  bash -c 'head -1 "$0" | grep -q " 202"' "$SSO_TMP/oap4"
# HeaderAuthentication.php matches panel users by X-Auth-Email and Caddy
# maps X-Auth-Request-Preferred-Username to X-Auth-Username.
check "oauth2-proxy: passes the user's email (got: $(hdr x-auth-request-email "$SSO_TMP/oap4"))" \
  test "$(hdr x-auth-request-email "$SSO_TMP/oap4")" = sso-regression@prestonhager.com
check "oauth2-proxy: passes the username (got: $(hdr x-auth-request-preferred-username "$SSO_TMP/oap4"))" \
  test "$(hdr x-auth-request-preferred-username "$SSO_TMP/oap4")" = sso-regression
check "oauth2-proxy: passes the Keycloak groups (pterodactyl_test_admin)" \
  bash -c 'grep -i "^x-auth-request-groups:" "$0" | grep -q pterodactyl_test_admin' "$SSO_TMP/oap4"
oap_curl /oauth2/auth -D "$SSO_TMP/oap5" -o /dev/null
check "oauth2-proxy: /oauth2/auth refuses a request without a session" \
  bash -c 'head -1 "$0" | grep -q " 401"' "$SSO_TMP/oap5"

if [ -n "$OAP_STARTED" ]; then
  systemctl stop "$OAP_UNIT" 2>/dev/null
fi
check "oauth2-proxy: transient test instance stopped" \
  bash -c '[ -z "$0" ] || ! systemctl is-active -q "$1"' "$OAP_STARTED" "$OAP_UNIT"
