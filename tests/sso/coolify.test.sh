# Coolify: "Sign in with Keycloak" (generic OIDC provider) and the
# Keycloak-group -> Coolify root-team role sync (coolify-keycloak-roles).
#
# The regression user is put in coolify_member / coolify_admin for the
# duration of this test only, and its Coolify account is deleted again at the
# end (and at the start, in case an earlier run died half way).

COOLIFY_URL=https://coolify.prestonhager.com
COOLIFY_SSO_EMAIL=sso-regression@prestonhager.com

# coolify_state [delete]: JSON about the test user's Coolify account (or
# delete it). Runs PHP inside the coolify container through run.php.
coolify_state() {
  local php=$SSO_TMP/coolify-state.php out
  cat > "$php" <<'PHP'
<?php
use App\Models\OauthSetting;
use App\Models\User;
$email = getenv('SSO_EMAIL');
$u = User::whereEmail($email)->first();
if (getenv('SSO_ACTION') === 'delete') {
    if ($u) {
        $u->oauthIdentities()->delete();
        $u->delete();
    }
    echo 'SSOJSON:' . json_encode(['deleted' => (bool) $u]) . PHP_EOL;
    return;
}
$owner = User::find(0);
$oidc = OauthSetting::firstWhere('provider', 'oidc');
$zitadel = OauthSetting::firstWhere('provider', 'zitadel');
echo 'SSOJSON:' . json_encode([
    'exists' => (bool) $u,
    'root_role' => $u?->teams()->where('teams.id', 0)->first()?->pivot->role,
    'identities' => $u ? $u->oauthIdentities()->get(['provider', 'issuer'])->toArray() : [],
    'owner_email' => $owner?->email,
    'owner_role' => $owner?->teams()->where('teams.id', 0)->first()?->pivot->role,
    'oidc' => $oidc ? ['enabled' => $oidc->enabled && $oidc->couldBeEnabled(), 'base_url' => $oidc->base_url,
        'client_id' => $oidc->client_id, 'allow_registration' => $oidc->allow_registration] : null,
    'zitadel_enabled' => (bool) $zitadel?->enabled,
]) . PHP_EOL;
PHP
  podman cp ../../nixos/containers/coolify/run.php coolify:/tmp/sso-run.php >/dev/null &&
    podman cp "$php" coolify:/tmp/sso-coolify-state.php >/dev/null || return 1
  out=$(podman exec -e SSO_EMAIL="$COOLIFY_SSO_EMAIL" -e SSO_ACTION="${1:-}" \
    -e COOLIFY_TINKER_SCRIPT=/tmp/sso-coolify-state.php -w /var/www/html coolify \
    php artisan tinker --execute="require '/tmp/sso-run.php';")
  podman exec coolify rm -f /tmp/sso-run.php /tmp/sso-coolify-state.php >/dev/null 2>&1
  grep -m1 '^SSOJSON:' <<<"$out" | sed 's/^SSOJSON://'
}

coolify_kc_group_id() { # coolify_kc_group_id <name>
  kc_admin GET "/groups?search=$1&exact=true&briefRepresentation=true" \
    | jq -r --arg n "$1" '.[] | select(.name == $n) | .id' | head -1
}

coolify_set_groups() { # coolify_set_groups <group|-> ...: test user's coolify_* groups
  local uid g gid want
  uid=$(sso_user_id) || return 1
  for g in coolify_admin coolify_member; do
    gid=$(coolify_kc_group_id "$g")
    [ -n "$gid" ] || { echo "Keycloak group $g missing" >&2; return 1; }
    want=DELETE
    for w in "$@"; do [ "$w" = "$g" ] && want=PUT; done
    kc_admin "$want" "/users/$uid/groups/$gid" >/dev/null || return 1
  done
}

coolify_role_sync() { systemctl start coolify-keycloak-roles.service; }

coolify_cleanup() {
  coolify_set_groups - &&
    coolify_role_sync &&
    test "$(coolify_state delete | jq -r '.deleted | type')" = boolean
}

coolify_root_role_is() { # coolify_root_role_is <role|null>
  test "$(coolify_state | jq -r .root_role)" = "$1"
}

export COOLIFY_URL COOLIFY_SSO_EMAIL
export -f coolify_state coolify_kc_group_id coolify_set_groups coolify_role_sync coolify_cleanup coolify_root_role_is

check "Coolify API healthy" \
  curl -fsS --max-time 10 http://127.0.0.1:8000/api/health

check "Keycloak client coolify has the OIDC callback" \
  bash -c 'kc_admin GET "/clients?clientId=coolify" | jq -e ".[0].redirectUris | index(\"'"$COOLIFY_URL"'/auth/oidc/callback\")"'

state=$(coolify_state)
check "Coolify OIDC provider enabled, pointing at the homelab realm" \
  jq -e --arg b "$KC_URL/realms/$KC_REALM" '.oidc.enabled and .oidc.base_url == $b and .oidc.client_id == "coolify"' <<<"$state"
check "Coolify OIDC self-registration off (accounts come from the role sync)" \
  jq -e '.oidc.allow_registration == false' <<<"$state"
check "Coolify Zitadel provider disabled" \
  jq -e '.zitadel_enabled == false' <<<"$state"
check "root owner (user 0) is still owner of the Root Team" \
  jq -e '.owner_role == "owner"' <<<"$state"

check "clean start (test user in no coolify_* group, no Coolify account)" coolify_cleanup

# Not in a coolify_* group: no account, so the login must be refused.
sso_login "$COOLIFY_URL/auth/oidc/redirect" || true
check "login without a coolify_* group is refused (back on /login)" \
  url_starts_with "$COOLIFY_URL/login"
check "  ... and no Coolify account was created" coolify_root_role_is null
check "  ... and no account exists at all" \
  bash -c '[ "$(coolify_state | jq -r .exists)" = false ]'

check "coolify_member -> role sync" bash -c 'coolify_set_groups coolify_member && coolify_role_sync'
check "  ... adds the test user to the Root Team as member" coolify_root_role_is member

jar=$SSO_TMP/coolify.jar
sso_login "$COOLIFY_URL/auth/oidc/redirect" "$jar" || true
check "Keycloak login lands in the Coolify dashboard" \
  bash -c '[[ "$0" == "'"$COOLIFY_URL"'"/* && "$0" != *"/login"* ]]' "$SSO_FINAL_URL"
check "  ... and the session is authenticated (dashboard, not login page)" \
  bash -c '[[ "$(curl -sS -b "$0" -o /dev/null -w "%{url_effective}" -L "$COOLIFY_URL/")" != *"/login"* ]]' "$jar"
check "  ... linked an oidc identity from the homelab realm" \
  bash -c 'coolify_state | jq -e --arg i "$0" "any(.identities[]; .provider == \"oidc\" and .issuer == \$i)"' "$KC_URL/realms/$KC_REALM"

check "coolify_admin -> role sync" bash -c 'coolify_set_groups coolify_admin && coolify_role_sync'
check "  ... makes the test user admin" coolify_root_role_is admin

check "no group -> role sync" bash -c 'coolify_set_groups - && coolify_role_sync'
check "  ... removes the test user from the Root Team" coolify_root_role_is null

check "root owner (user 0) still owner after the syncs" \
  bash -c 'coolify_state | jq -e ".owner_role == \"owner\""'

check "cleanup (groups removed, Coolify account deleted)" coolify_cleanup
check "  ... test account gone" bash -c '[ "$(coolify_state | jq -r .exists)" = false ]'
