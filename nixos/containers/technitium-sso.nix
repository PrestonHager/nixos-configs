{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  dataRoot = "/stor/technitium";
  technitiumApi = "http://127.0.0.1:5380";
  adminPasswordFile = "${dataRoot}/secrets/admin-password";
  ssoHashFile = "${dataRoot}/.sso-settings.sha256";

  zitadelIssuer = "https://zitadel.prestonhager.com";
  # Home Lab project (same as Grafana/Matrix OIDC apps).
  zitadelProjectId = "376196450586990901";
  adminRoleKey = "technitium_admin";
  adminLocalGroup = "Administrators";

  ssoScopes =
    "openid profile email groups urn:zitadel:iam:org:project:roles urn:zitadel:iam:org:project:id:${zitadelProjectId}:aud";

  syncSsoScript = pkgs.writeShellScript "technitium-sync-sso" ''
    set -euo pipefail
    API="${technitiumApi}"
    PASS_FILE="${adminPasswordFile}"
    HASH_FILE="${ssoHashFile}"
    CLIENT_ID_FILE="${config.sops.secrets."technitium-oidc-client-id".path}"
    CLIENT_SECRET_FILE="${config.sops.secrets."technitium-oidc-client-secret".path}"

    if [ ! -s "$CLIENT_ID_FILE" ] || [ ! -s "$CLIENT_SECRET_FILE" ]; then
      echo "Technitium OIDC secrets missing; run scripts/zitadel-technitium-setup.js and update technitium.yaml in sops." >&2
      exit 1
    fi

    client_id=$(${pkgs.coreutils}/bin/cat "$CLIENT_ID_FILE")
    client_secret=$(${pkgs.coreutils}/bin/cat "$CLIENT_SECRET_FILE")
    desired_hash=$(${pkgs.coreutils}/bin/sha256sum "$CLIENT_ID_FILE" "$CLIENT_SECRET_FILE" \
      | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)
    desired_hash="''${desired_hash};scopes=${ssoScopes};role=${adminRoleKey}"

    if [ -f "$HASH_FILE" ] && [ "$(cat "$HASH_FILE")" = "''${desired_hash}" ]; then
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
      --data-urlencode "ssoClientId=$client_id" \
      --data-urlencode "ssoClientSecret=$client_secret" \
      --data-urlencode "ssoMetadataAddress=${zitadelIssuer}/.well-known/openid-configuration" \
      --data-urlencode "ssoScopes=${ssoScopes}" \
      --data-urlencode "ssoAllowSignup=true" \
      --data-urlencode "ssoAllowSignupOnlyForMappedUsers=true" \
      --data-urlencode "ssoGroupMap=${adminRoleKey}|${adminLocalGroup}" >/dev/null

    echo "''${desired_hash}" > "$HASH_FILE"
  '';
in
{
  sops.secrets = {
    "technitium-oidc-client-id" = {
      sopsFile = "${sops-path}/secrets/containers/technitium.yaml";
      key = "technitium-oidc-client-id";
    };
    "technitium-oidc-client-secret" = {
      sopsFile = "${sops-path}/secrets/containers/technitium.yaml";
      key = "technitium-oidc-client-secret";
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
