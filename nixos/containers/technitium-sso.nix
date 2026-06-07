{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  dataRoot = "/stor/technitium";
  technitiumApi = "http://127.0.0.1:5380";
  adminPasswordFile = "${dataRoot}/secrets/admin-password";
  ssoHashFile = "${dataRoot}/.sso-settings.sha256";
  oidcEnvFile = config.sops.secrets."technitium-oidc-env".path;

  zitadelIssuer = "https://zitadel.prestonhager.com";
  zitadelProjectId = "376196450586990901";
  adminRoleKey = "technitium_admin";
  adminLocalGroup = "Administrators";

  ssoScopes =
    "openid,profile,email,groups,urn:zitadel:iam:org:project:roles,urn:zitadel:iam:org:project:id:${zitadelProjectId}:aud";

  syncSsoScript = pkgs.writeShellScript "technitium-sync-sso" ''
    set -euo pipefail
    API="${technitiumApi}"
    PASS_FILE="${adminPasswordFile}"
    HASH_FILE="${ssoHashFile}"
    OIDC_ENV="${oidcEnvFile}"

    if [ ! -s "$OIDC_ENV" ]; then
      echo "Technitium OIDC env missing at $OIDC_ENV; run scripts/zitadel-technitium-setup.js and update technitium.yaml in sops." >&2
      exit 1
    fi

    # shellcheck disable=SC1090
    source "$OIDC_ENV"
    if [ -z "''${TECHNITIUM_OIDC_CLIENT_ID:-}" ] || [ -z "''${TECHNITIUM_OIDC_CLIENT_SECRET:-}" ]; then
      echo "TECHNITIUM_OIDC_CLIENT_ID/SECRET missing in $OIDC_ENV" >&2
      exit 1
    fi

    desired_hash=$(${pkgs.coreutils}/bin/sha256sum "$OIDC_ENV" | ${pkgs.coreutils}/bin/cut -d' ' -f1)
    desired_hash="''${desired_hash};scopes=${ssoScopes};role=${adminRoleKey}"

    if [ -f "$HASH_FILE" ] && [ "$(cat "$HASH_FILE")" = "$desired_hash" ]; then
      exit 0
    fi

    for _ in $(seq 1 90); do
      if ${pkgs.curl}/bin/curl -sf "$API/api/sso/status" >/dev/null; then
        break
      fi
      sleep 2
    done
    ${pkgs.curl}/bin/curl -sf "$API/api/sso/status" >/dev/null

    pass=$(${pkgs.coreutils}/bin/cat "$PASS_FILE")
    token=$(${pkgs.curl}/bin/curl -sf -X POST "$API/api/user/login" \
      --data-urlencode "user=admin" \
      --data-urlencode "pass=$pass" \
      | ${pkgs.jq}/bin/jq -r .token)

    ${pkgs.curl}/bin/curl -sf -X POST -H "Authorization: Bearer $token" \
      "$API/api/admin/sso/set" \
      --data-urlencode "ssoEnabled=true" \
      --data-urlencode "ssoAuthority=${zitadelIssuer}" \
      --data-urlencode "ssoClientId=$TECHNITIUM_OIDC_CLIENT_ID" \
      --data-urlencode "ssoClientSecret=$TECHNITIUM_OIDC_CLIENT_SECRET" \
      --data-urlencode "ssoMetadataAddress=${zitadelIssuer}/.well-known/openid-configuration" \
      --data-urlencode "ssoScopes=${ssoScopes}" \
      --data-urlencode "ssoAllowSignup=true" \
      --data-urlencode "ssoAllowSignupOnlyForMappedUsers=true" \
      --data-urlencode "ssoGroupMap=${adminRoleKey}|${adminLocalGroup}" >/dev/null

    echo "$desired_hash" > "$HASH_FILE"
  '';
in
{
  sops.secrets = {
    "technitium-oidc-env" = {
      sopsFile = "${sops-path}/secrets/containers/technitium.yaml";
      key = "technitium-oidc-env";
    };
  };

  systemd.services.technitium-sync-sso = {
    description = "Configure Technitium DNS SSO (Zitadel OIDC)";
    after = [
      "podman-technitium.service"
      "technitium-ensure-admin-password.service"
      "network-online.target"
    ];
    wants = [
      "podman-technitium.service"
      "technitium-ensure-admin-password.service"
      "network-online.target"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = syncSsoScript;
      RemainAfterExit = true;
    };
  };
}
