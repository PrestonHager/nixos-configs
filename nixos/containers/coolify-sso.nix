# Zitadel login for the Coolify dashboard.
#
# Zitadel side (created 2026-10-18; see docs/coolify.md):
#   project "Coolify" (id below) with "check authorization on authentication",
#   so only users granted coolify_admin or coolify_member can sign in;
#   OIDC web app "Coolify" -> https://coolify.prestonhager.com/auth/zitadel/callback.
# Client id/secret: nix-secrets secrets/containers/coolify.yaml, coolify-zitadel-env.
#
# coolify-zitadel-oauth  writes the credentials into Coolify's oauth_settings.
# coolify-zitadel-roles  (timer) maps grants onto Coolify's root team:
#   coolify_admin -> admin, coolify_member -> member, no grant -> removed.
#   The root owner account (user 0) is never changed.
{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  projectId = "395665464577001575";
  podman = "${pkgs.podman}/bin/podman";

  oauthSettingPhp = ./coolify/oauth-setting.php;
  applyRolesPhp = ./coolify/apply-roles.php;
  roleSyncJs = ./coolify/zitadel-role-sync.mjs;

  # Copy a store file into the container and run it with artisan tinker.
  tinker = file: extra: ''
    ${podman} cp ${file} coolify:/tmp/${baseNameOf file}
    ${podman} exec ${extra} -w /var/www/html coolify php artisan tinker /tmp/${baseNameOf file}
    ${podman} exec coolify rm -f /tmp/${baseNameOf file}
  '';
in
{
  sops.secrets."coolify-zitadel-env" = {
    sopsFile = "${sops-path}/secrets/containers/coolify.yaml";
    mode = "0400";
    restartUnits = [ "coolify-zitadel-oauth.service" ];
  };

  systemd.services.coolify-zitadel-oauth = {
    description = "Configure Coolify's Zitadel OAuth provider";
    after = [ "podman-coolify.service" ];
    requires = [ "podman-coolify.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Coolify runs migrations on start; wait until its API answers.
      ExecStartPre = "${pkgs.bash}/bin/bash -c 'for _ in $(seq 1 60); do ${pkgs.curl}/bin/curl -fsS http://127.0.0.1:8000/api/health >/dev/null && exit 0; sleep 5; done; exit 1'";
    };
    script = tinker oauthSettingPhp "--env-file ${config.sops.secrets."coolify-zitadel-env".path}";
  };

  systemd.services.coolify-zitadel-roles = {
    description = "Sync Zitadel Coolify roles onto Coolify's root team";
    after = [ "coolify-zitadel-oauth.service" "podman-zitadel.service" ];
    requires = [ "podman-coolify.service" ];
    environment.COOLIFY_ZITADEL_PROJECT_ID = projectId;
    serviceConfig.Type = "oneshot";
    script = ''
      set -euo pipefail
      map=$(${pkgs.nodejs_22}/bin/node ${roleSyncJs})
      ${tinker applyRolesPhp "-e COOLIFY_ROLE_MAP=\"$map\""}
    '';
  };

  systemd.timers.coolify-zitadel-roles = {
    description = "Sync Zitadel Coolify roles every 5 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "5min";
    };
  };
}

