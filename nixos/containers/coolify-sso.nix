# Keycloak login for the Coolify dashboard, plus instance settings that the
# Coolify UI must not change.
#
# Keycloak side (realm homelab, docs/keycloak-ace.md): the `coolify` client
# below, synced by keycloak-realm-sync, with Coolify's generic OIDC callback
# https://coolify.prestonhager.com/auth/oidc/callback. Its secret is
# KEYCLOAK_CLIENT_SECRET in nix-secrets secrets/containers/coolify.yaml,
# coolify-keycloak-env (the value Coolify's Zitadel app used, renamed).
# Who may use Coolify is the Keycloak groups coolify_admin / coolify_member.
#
# coolify-keycloak-oauth     writes the client into Coolify's oauth_settings
#                            (provider "oidc", self-registration off) and
#                            retires the Zitadel provider and its identity links.
# coolify-instance-settings  keeps auto-update, self-registration and DNS
#                            validation off and the unusable built-in
#                            localhost server (id 0) force-disabled.
# coolify-email-settings     points Coolify's SMTP at the iCloud+ account
#                            Nextcloud/Grafana/Keycloak use (password from
#                            nextcloud-environment SMTP_PASSWORD).
# coolify-keycloak-roles     (timer) maps group membership onto Coolify's root
#   team: coolify_admin -> admin, coolify_member -> member, neither -> removed.
#   Group members without a Coolify account get one (root team only), which
#   is the only way accounts are created: an OIDC login links to it by
#   verified email, and a login with no account is refused. The root owner
#   account (user 0) is never changed. An empty role map is refused unless
#   COOLIFY_ALLOW_EMPTY_ROLE_MAP=1 is set on the unit.
#
# The first three are Type=exec, not oneshot: systemd counts them as started as
# soon as the script runs, so `nixos-rebuild switch` and boot do not wait for
# Coolify's migrations. They wait for the API themselves, bounded by
# RuntimeMaxSec (TimeoutStartSec would only cover the instant until exec).
# Without RemainAfterExit they end inactive and every switch re-runs them,
# which is harmless because all are idempotent.
{ config, lib, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  podman = "${pkgs.podman}/bin/podman";
  curl = "${pkgs.curl}/bin/curl";
  health = "http://127.0.0.1:8000/api/health";
  kc = import ../auth/keycloak-lib.nix;

  runPhp = ./coolify/run.php;
  oauthSettingPhp = ./coolify/oauth-setting.php;
  instanceSettingsPhp = ./coolify/instance-settings.php;
  emailSettingsPhp = ./coolify/email-settings.php;
  applyRolesPhp = ./coolify/apply-roles.php;
  roleSyncJs = ./coolify/keycloak-role-sync.mjs;

  # Run a store PHP file inside the coolify container with Laravel booted.
  # `artisan tinker <file>` exits 0 on an exception (and then reads a REPL
  # from stdin), and so does `--execute`; run.php catches the exception and
  # exits 1. Each unit calls this once: the EXIT trap removes its copies.
  tinker = file: extra:
    let
      script = "/tmp/coolify-${baseNameOf file}";
      runner = "/tmp/coolify-run-${baseNameOf file}";
    in ''
      trap '${podman} exec coolify rm -f ${script} ${runner} || true' EXIT
      ${podman} cp ${runPhp} coolify:${runner}
      ${podman} cp ${file} coolify:${script}
      ${podman} exec ${extra} -e COOLIFY_TINKER_SCRIPT=${script} -w /var/www/html coolify \
        php artisan tinker --execute="require '${runner}';"
    '';

  # Coolify runs migrations on start; wait (up to 5 minutes) for its API.
  waitForCoolify = ''
    until ${curl} -fsS --max-time 5 ${health} >/dev/null; do
      if (( SECONDS >= 300 )); then
        echo "Coolify API not healthy after ''${SECONDS}s" >&2
        exit 1
      fi
      sleep 5
    done
  '';

  # Shared by the Coolify-side setup units.
  setupUnit = description: script: {
    inherit description;
    after = [ "podman-coolify.service" ];
    requires = [ "podman-coolify.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "exec";
      RuntimeMaxSec = "6min";
    };
    script = ''
      set -euo pipefail
      ${waitForCoolify}
      ${script}
    '';
  };
in
{
  # KEYCLOAK_CLIENT_SECRET (Keycloak client `coolify`)
  sops.secrets."coolify-keycloak-env" = {
    sopsFile = "${sops-path}/secrets/containers/coolify.yaml";
    mode = "0400";
    restartUnits = [ "coolify-keycloak-oauth.service" "keycloak-realm-sync.service" ];
  };
  # Re-apply SMTP when the shared password changes.
  sops.secrets."nextcloud-environment".restartUnits = [ "coolify-email-settings.service" ];

  homelab.keycloak.clients.coolify = {
    name = "Coolify";
    redirectUris = [ "https://coolify.prestonhager.com/auth/oidc/callback" ];
    webOrigins = [ "https://coolify.prestonhager.com" ];
    secret = {
      file = config.sops.secrets."coolify-keycloak-env".path;
      key = "KEYCLOAK_CLIENT_SECRET";
    };
    # Coolify sends S256 PKCE; require it.
    settings.attributes."pkce.code.challenge.method" = "S256";
  };

  systemd.services.coolify-keycloak-oauth = setupUnit "Configure Coolify's Keycloak (OIDC) login"
    (tinker oauthSettingPhp "--env-file ${config.sops.secrets."coolify-keycloak-env".path}");

  systemd.services.coolify-instance-settings = setupUnit "Pin Coolify instance settings (auto-update, registration, localhost server)"
    (tinker instanceSettingsPhp "");

  # Coolify mail through the shared iCloud+ SMTP account (coolify/email-settings.php).
  # Only the password is passed in, from a file in the unit's RuntimeDirectory
  # (0700, removed by systemd when the unit stops).
  systemd.services.coolify-email-settings = lib.recursiveUpdate
    (setupUnit "Configure Coolify SMTP (shared iCloud+ account)" ''
      env_file=/run/coolify-email-settings/smtp.env
      (umask 077; grep '^SMTP_PASSWORD=' ${config.sops.secrets."nextcloud-environment".path} > "$env_file") || {
        echo "SMTP_PASSWORD missing from nextcloud-environment" >&2
        exit 1
      }
      ${tinker emailSettingsPhp "--env-file $env_file"}
    '')
    {
      serviceConfig = {
        RuntimeDirectory = "coolify-email-settings";
        RuntimeDirectoryMode = "0700";
      };
    };

  systemd.services.coolify-keycloak-roles = {
    description = "Sync Keycloak coolify_* groups onto Coolify's root team";
    after = [ "coolify-keycloak-oauth.service" "keycloak-realm-sync.service" "podman-keycloak.service" ];
    requires = [ "podman-coolify.service" ];
    environment = {
      KEYCLOAK_URL = "https://${kc.domain}";
      KEYCLOAK_REALM = kc.realm;
      KEYCLOAK_CONFIG_ENV = config.sops.secrets."keycloak-config-env".path;
    };
    serviceConfig = {
      Type = "oneshot";
      # A few 15s-bounded Keycloak calls plus one tinker run; anything longer is a hang.
      TimeoutStartSec = "2min";
    };
    script = ''
      set -euo pipefail
      # Fail fast instead of waiting: the timer retries in 5 minutes.
      ${curl} -fsS --max-time 5 ${health} >/dev/null
      map=$(${pkgs.nodejs_22}/bin/node ${roleSyncJs})
      ${tinker applyRolesPhp "-e COOLIFY_ROLE_MAP=\"$map\" -e COOLIFY_CREATE_USERS=1 -e COOLIFY_ALLOW_EMPTY_ROLE_MAP"}
    '';
  };

  systemd.timers.coolify-keycloak-roles = {
    description = "Sync Keycloak coolify_* groups onto Coolify every 5 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "5min";
    };
  };
}
