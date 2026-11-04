# Keycloak on ace: identity provider for server logins (nixos/auth/sso-login.nix,
# docs/keycloak-ace.md). Runs beside Zitadel, which still serves the web apps
# until each one moves over.
#
# Caddy (nixos/caddy/keycloak.nix) proxies https://keycloak.prestonhager.com to
# 127.0.0.1:9280, LAN/tailnet/VPN only. Management (health, metrics) is on
# 127.0.0.1:9281.
{ config, pkgs, lib, inputs, ... }:

let
  kc = import ../auth/keycloak-lib.nix;
  sops-path = builtins.toString inputs.nix-secrets;
  httpPort = 9280;
  managementPort = 9281;

  loginRedirects = [
    # opkssh listens on the first free one of these during `opkssh login`.
    "http://localhost:3000/login-callback"
    "http://localhost:10001/login-callback"
    "http://localhost:11110/login-callback"
  ];

  # Flat `groups` claim (names, not paths) in the opkssh ID token only, so the
  # group list is not handed to every client in the realm.
  groupsMapper = {
    name = "groups";
    protocol = "openid-connect";
    protocolMapper = "oidc-group-membership-mapper";
    consentRequired = false;
    config = {
      "full.path" = "false";
      "claim.name" = "groups";
      "id.token.claim" = "true";
      "access.token.claim" = "true";
      "userinfo.token.claim" = "true";
    };
  };

  # Imported by `start --import-realm` only when the realm does not exist yet;
  # after that the database is the source of truth and console edits stick.
  # ${VAR} placeholders are filled from the container environment at import.
  realm = {
    realm = kc.realm;
    enabled = true;
    displayName = "Homelab";
    sslRequired = "external";
    # Usernames are Linux login names: nobody signs themselves up, and nobody
    # renames themselves into another account (the opkssh plugin trusts
    # preferred_username).
    registrationAllowed = false;
    editUsernameAllowed = false;
    loginWithEmailAllowed = false;
    duplicateEmailsAllowed = false;
    # No SMTP configured for this realm yet.
    resetPasswordAllowed = false;
    verifyEmail = false;
    bruteForceProtected = true;
    permanentLockout = false;
    failureFactor = 10;

    groups = map (name: { inherit name; }) (
      [ kc.allServersGroup ]
      ++ map kc.hostGroup kc.serverHosts
      ++ [ kc.sudoFullGroup kc.sudoRebuildGroup ]
    );

    clients = [
      {
        clientId = kc.opksshClientId;
        name = "opkssh (server SSH login)";
        enabled = true;
        protocol = "openid-connect";
        publicClient = true;
        standardFlowEnabled = true;
        implicitFlowEnabled = false;
        directAccessGrantsEnabled = false;
        serviceAccountsEnabled = false;
        redirectUris = loginRedirects;
        webOrigins = [ ];
        protocolMappers = [ groupsMapper ];
      }
      {
        clientId = kc.sssdClientId;
        name = "SSSD (server user lookup and sudo)";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        clientAuthenticatorType = "client-secret";
        secret = "\${SSSD_CLIENT_SECRET}";
        standardFlowEnabled = false;
        implicitFlowEnabled = false;
        directAccessGrantsEnabled = false;
        serviceAccountsEnabled = true;
        attributes = {
          "oauth2.device.authorization.grant.enabled" = "true";
        };
      }
    ];

    users = [
      # SSSD looks users and groups up through the admin REST API as this
      # account; read-only roles only.
      {
        username = "service-account-${kc.sssdClientId}";
        enabled = true;
        serviceAccountClientId = kc.sssdClientId;
        clientRoles."realm-management" = [ "view-users" "query-users" "query-groups" ];
      }
      # First human account. The temporary password is
      # PRESTONH_INITIAL_PASSWORD in sops (secrets/containers/keycloak.yaml);
      # the first login forces a new password and TOTP.
      {
        username = "prestonh";
        enabled = true;
        firstName = "Preston";
        lastName = "Hager";
        groups = [ "/${kc.allServersGroup}" "/${kc.sudoFullGroup}" ];
        # Imported users do not get the realm's default roles on their own;
        # without manage-account/view-profile the account console fails.
        realmRoles = [ "default-roles-${kc.realm}" ];
        credentials = [{
          type = "password";
          value = "\${PRESTONH_INITIAL_PASSWORD}";
          temporary = true;
        }];
        # The import stores the password but does not turn `temporary` into
        # a forced change, so require it explicitly.
        requiredActions = [ "UPDATE_PASSWORD" "CONFIGURE_TOTP" ];
      }
    ];
  };

  realmFile = pkgs.writeText "${kc.realm}-realm.json" (builtins.toJSON realm);
in
{
  imports = [ ./keycloak-realm.nix ];

  # Realm settings kept in step with Nix by keycloak-realm-sync. Services add
  # their own clients and groups in their own files.
  homelab.keycloak = {
    sync = {
      enable = true;
      # KEYCLOAK_CONFIG_CLIENT_SECRET: REPLACE_ME until the homelab-config
      # client exists (docs/keycloak-ace.md); the sync skips until then.
      credential = {
        file = config.sops.secrets."keycloak-config-env".path;
        key = "KEYCLOAK_CONFIG_CLIENT_SECRET";
      };
    };

    # Same iCloud SMTP relay and sender Zitadel used.
    smtp = {
      enable = true;
      host = "smtp.mail.me.com";
      port = 587;
      user = "prestonhager@icloud.com";
      password = {
        file = config.sops.secrets."nextcloud-environment".path;
        key = "SMTP_PASSWORD";
      };
      from = "admin@prestonhager.com";
      fromName = "Homelab";
    };

    # Zitadel's project roles, same names, as groups (Home Lab and Coolify
    # projects). Each service maps them in its own module.
    groups = [
      "admin"
      "grafana_admin"
      "jellyfin_admin"
      "jellyfin_user"
      "matrix_admin"
      "nextcloud_admin"
      "pterodactyl_admin"
      "pterodactyl_test_admin"
      "technitium_admin"
      "wg-admin"
      "coolify_admin"
      "coolify_member"
    ];

    # GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET: REPLACE_ME until the Google
    # OAuth client exists (docs/keycloak-ace.md); no Google button until then.
    google = {
      enable = true;
      clientId = { file = config.sops.secrets."keycloak-google-env".path; key = "GOOGLE_CLIENT_ID"; };
      clientSecret = { file = config.sops.secrets."keycloak-google-env".path; key = "GOOGLE_CLIENT_SECRET"; };
    };

    testUser = {
      enable = true;
      password = {
        file = config.sops.secrets."keycloak-test-env".path;
        key = "SSO_REGRESSION_PASSWORD";
      };
    };
  };

  sops.secrets = {
    # KEYCLOAK_CONFIG_CLIENT_SECRET (homelab-config service account)
    "keycloak-config-env" = {
      sopsFile = "${sops-path}/secrets/containers/keycloak.yaml";
      key = "keycloak-config-env";
      restartUnits = [ "keycloak-realm-sync.service" ];
    };
    # GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET ("Sign in with Google")
    "keycloak-google-env" = {
      sopsFile = "${sops-path}/secrets/containers/keycloak.yaml";
      key = "keycloak-google-env";
      restartUnits = [ "keycloak-realm-sync.service" ];
    };
    # SSO_REGRESSION_PASSWORD (tests/sso)
    "keycloak-test-env" = {
      sopsFile = "${sops-path}/secrets/containers/keycloak.yaml";
      key = "keycloak-test-env";
    };
    # KC_DB_PASSWORD, KC_BOOTSTRAP_ADMIN_PASSWORD, PRESTONH_INITIAL_PASSWORD
    "keycloak-env" = {
      sopsFile = "${sops-path}/secrets/containers/keycloak.yaml";
      key = "keycloak-env";
    };
    # POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB
    "keycloak-db-env" = {
      sopsFile = "${sops-path}/secrets/containers/keycloak.yaml";
      key = "keycloak-db-env";
    };
    # SSSD_CLIENT_SECRET, shared with every server running sso-login.nix.
    "sssd-keycloak-env" = {
      sopsFile = "${sops-path}/secrets/sssd-keycloak.yaml";
      key = "sssd-keycloak-env";
    };
  };

  # postgres:*-alpine runs as uid/gid 70 (users.users.postgres comes from
  # zitadel.nix; numeric ids here so this file does not depend on it).
  systemd.tmpfiles.rules = [
    "d /keycloak 0755 root root -"
    "d /keycloak/postgres 0700 70 70 -"
  ];

  systemd.services.pod-keycloak = {
    description = "Podman pod for Keycloak (server and PostgreSQL)";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    before = [ "podman-keycloak-db.service" "podman-keycloak.service" "caddy.service" ];
    requiredBy = [ "podman-keycloak-db.service" "podman-keycloak.service" ];
    unitConfig.RequiresMountsFor = "/run/containers";
    path = [ pkgs.podman ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "pod-keycloak-create" ''
        set -euo pipefail
        if ! podman pod exists keycloak-pod; then
          podman pod create \
            --name keycloak-pod \
            -p 127.0.0.1:${toString httpPort}:8080 \
            -p 127.0.0.1:${toString managementPort}:9000 \
            --memory 3G --cpus 0
        fi
      '';
    };
  };

  systemd.services."podman-keycloak" = {
    after = [ "sops-nix.service" ];
    before = [ "caddy.service" ];
  };

  virtualisation.oci-containers.containers.keycloak-db = {
    autoStart = true;
    # Same postgres 17.11-alpine digest as zitadel-db.
    image = "docker.io/library/postgres@sha256:266d3c257594e195b309ae9d1805e54c788f1d7b375f56bf6c367aac6c917e7b";
    extraOptions = [ "--pod=keycloak-pod" ];
    environmentFiles = [ config.sops.secrets."keycloak-db-env".path ];
    volumes = [ "/keycloak/postgres:/var/lib/postgresql/data" ];
  };

  virtualisation.oci-containers.containers.keycloak = {
    autoStart = true;
    dependsOn = [ "keycloak-db" ];
    image = "quay.io/keycloak/keycloak@sha256:27b3230fbabb8c9ff3c66c864cf09dcd8a41aca82e5100679d109ef0eeb05741"; # 26.8.0
    cmd = [ "start" "--import-realm" ];
    extraOptions = [ "--pod=keycloak-pod" ];
    environmentFiles = [
      config.sops.secrets."keycloak-env".path
      config.sops.secrets."sssd-keycloak-env".path
    ];
    environment = {
      KC_DB = "postgres";
      KC_DB_URL = "jdbc:postgresql://127.0.0.1:5432/keycloak";
      KC_DB_USERNAME = "keycloak";
      KC_HOSTNAME = "https://${kc.domain}";
      # TLS ends at Caddy; trust its X-Forwarded-* headers.
      KC_HTTP_ENABLED = "true";
      KC_PROXY_HEADERS = "xforwarded";
      KC_HEALTH_ENABLED = "true";
      KC_METRICS_ENABLED = "true";
      # Temporary master-realm admin, created on first start only. Replace it
      # with a permanent admin and delete it (docs/keycloak-ace.md).
      KC_BOOTSTRAP_ADMIN_USERNAME = "tmp-admin";
    };
    # The image runs as uid 1000 (prestonh on ace); the only volume is this
    # read-only, placeholder-only realm file, so nothing is written as that uid.
    volumes = [ "${realmFile}:/opt/keycloak/data/import/${kc.realm}-realm.json:ro" ];
  };
}
