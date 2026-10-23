# Zitadel login for the Coolify dashboard, plus instance settings that the
# Coolify UI must not change.
#
# Zitadel side (created 2026-10-18; see docs/coolify-ace.md):
#   project "Coolify" (id below) with "check authorization on authentication",
#   so only users granted coolify_admin or coolify_member can sign in;
#   OIDC web app "Coolify" -> https://coolify.prestonhager.com/auth/zitadel/callback.
# Client id/secret: nix-secrets secrets/containers/coolify.yaml, coolify-zitadel-env.
#
# coolify-zitadel-oauth      writes the credentials into Coolify's oauth_settings.
# coolify-instance-settings  keeps auto-update and self-registration off and
#                            the unusable built-in localhost server (id 0)
#                            force-disabled.
# coolify-email-settings     points Coolify's SMTP at the iCloud+ account
#                            Nextcloud/Grafana/Zitadel use (password from
#                            nextcloud-environment SMTP_PASSWORD).
# coolify-zitadel-roles      (timer) maps grants onto Coolify's root team:
#   coolify_admin -> admin, coolify_member -> member, no grant -> removed.
#   The root owner account (user 0) is never changed. An empty grant list is
#   refused unless COOLIFY_ALLOW_EMPTY_ROLE_MAP=1 is set on the unit.
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
  projectId = "395665464577001575";
  podman = "${pkgs.podman}/bin/podman";
  curl = "${pkgs.curl}/bin/curl";
  health = "http://127.0.0.1:8000/api/health";

  runPhp = ./coolify/run.php;
  oauthSettingPhp = ./coolify/oauth-setting.php;
  instanceSettingsPhp = ./coolify/instance-settings.php;
  emailSettingsPhp = ./coolify/email-settings.php;
  applyRolesPhp = ./coolify/apply-roles.php;
  roleSyncJs = ./coolify/zitadel-role-sync.mjs;

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
  sops.secrets."coolify-zitadel-env" = {
    sopsFile = "${sops-path}/secrets/containers/coolify.yaml";
    mode = "0400";
    restartUnits = [ "coolify-zitadel-oauth.service" ];
  };
  # Re-apply SMTP when the shared password changes.
  sops.secrets."nextcloud-environment".restartUnits = [ "coolify-email-settings.service" ];

  systemd.services.coolify-zitadel-oauth = setupUnit "Configure Coolify's Zitadel OAuth provider"
    (tinker oauthSettingPhp "--env-file ${config.sops.secrets."coolify-zitadel-env".path}");

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

  systemd.services.coolify-zitadel-roles = {
    description = "Sync Zitadel Coolify roles onto Coolify's root team";
    after = [ "coolify-zitadel-oauth.service" "podman-zitadel.service" ];
    requires = [ "podman-coolify.service" ];
    environment.COOLIFY_ZITADEL_PROJECT_ID = projectId;
    serviceConfig = {
      Type = "oneshot";
      # Two 15s-bounded Zitadel calls plus one tinker run; anything longer is a hang.
      TimeoutStartSec = "2min";
    };
    script = ''
      set -euo pipefail
      # Fail fast instead of waiting: the timer retries in 5 minutes.
      ${curl} -fsS --max-time 5 ${health} >/dev/null
      map=$(${pkgs.nodejs_22}/bin/node ${roleSyncJs})
      ${tinker applyRolesPhp "-e COOLIFY_ROLE_MAP=\"$map\" -e COOLIFY_ALLOW_EMPTY_ROLE_MAP"}
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
