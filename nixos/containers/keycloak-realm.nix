# Declarative settings for the Keycloak homelab realm (docs/keycloak-ace.md).
#
# The realm import in keycloak.nix runs once, when the realm is created. This
# module keeps the realm in step with Nix on every switch: keycloak-config-cli
# applies `homelab.keycloak.*` through the admin API as the homelab-config
# service account (realm-admin of homelab only).
#
# Services declare their own client next to their own config:
#
#   homelab.keycloak.clients.grafana = {
#     redirectUris = [ "https://grafana.prestonhager.com/login/generic_oauth" ];
#     secret = { file = config.sops.secrets."grafana-oauth-env".path; key = "KEYCLOAK_CLIENT_SECRET"; };
#   };
#   homelab.keycloak.groups = [ "grafana_admin" ];
#
# Nothing here deletes: resources made in the admin console (users, group
# memberships, the Google provider and its flows) are left alone. Removing a
# client from Nix leaves it in Keycloak until it is deleted in the console.
{ config, lib, pkgs, ... }:

let
  cfg = config.homelab.keycloak;
  kc = import ../auth/keycloak-lib.nix;

  # Env var name for a secret reference, derived from its owner's name.
  secretVar = owner: "KCSYNC_" + lib.toUpper (lib.replaceStrings [ "-" "." ] [ "_" "_" ] owner);

  secretRefType = lib.types.submodule {
    options = {
      file = lib.mkOption {
        type = lib.types.str;
        description = "KEY=VALUE env file (a sops secret path) holding the value.";
      };
      key = lib.mkOption {
        type = lib.types.str;
        description = "Variable in that file.";
      };
    };
  };

  clientType = lib.types.submodule ({ name, ... }: {
    options = {
      clientId = lib.mkOption {
        type = lib.types.str;
        default = name;
      };
      name = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Display name on the consent and account pages.";
      };
      publicClient = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      secret = lib.mkOption {
        type = lib.types.nullOr secretRefType;
        default = null;
        description = ''
          Where the client secret comes from. Keycloak is set to this value,
          so an app keeps the secret it already has in sops.
        '';
      };
      redirectUris = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      postLogoutRedirectUris = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      webOrigins = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      groupsClaim = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Add the `groups` scope: a flat `groups` claim (group names) in ID
          token, access token and userinfo.
        '';
      };
      extraDefaultScopes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      settings = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = "Extra ClientRepresentation fields, merged last.";
      };
    };
  });

  standardScopes = [ "web-origins" "acr" "roles" "profile" "basic" "email" ];

  renderClient = name: c:
    lib.recursiveUpdate
      ({
        inherit (c) clientId name publicClient redirectUris webOrigins;
        enabled = true;
        protocol = "openid-connect";
        standardFlowEnabled = true;
        implicitFlowEnabled = false;
        directAccessGrantsEnabled = false;
        serviceAccountsEnabled = false;
        frontchannelLogout = true;
        attributes = {
          "pkce.code.challenge.method" = "";
          "post.logout.redirect.uris" = lib.concatStringsSep "##" c.postLogoutRedirectUris;
        };
        defaultClientScopes = standardScopes
          ++ lib.optional c.groupsClaim "groups"
          ++ c.extraDefaultScopes;
      }
      // lib.optionalAttrs (!c.publicClient) {
        clientAuthenticatorType = "client-secret";
      }
      // lib.optionalAttrs (c.secret != null) {
        secret = "$(env:${secretVar "client-${name}"})";
      })
      c.settings;

  smtp = cfg.smtp;

  realmBase = {
    realm = kc.realm;
    enabled = true;

    groups = map (name: { inherit name; }) (lib.unique cfg.groups);

    clientScopes = [
      {
        name = "groups";
        description = "Flat list of the user's group names";
        protocol = "openid-connect";
        attributes = {
          "include.in.token.scope" = "true";
          "display.on.consent.screen" = "false";
        };
        protocolMappers = [
          {
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
              "introspection.token.claim" = "true";
            };
          }
        ];
      }
    ];

    clients = lib.mapAttrsToList renderClient cfg.clients;
  };

  realmTestUser = lib.optionalAttrs cfg.testUser.enable {
    # Password only, no TOTP: it exists so scripts can log in. Kept disabled
    # between runs (tests/sso/lib.sh enables it for the duration of a run).
    users = [{
      username = "sso-regression";
      enabled = false;
      email = "sso-regression@prestonhager.com";
      emailVerified = true;
      firstName = "SSO";
      lastName = "Regression";
      realmRoles = [ "default-roles-${kc.realm}" ];
      groups = map (g: "/${g}") (lib.unique cfg.testUser.groups);
      requiredActions = [ ];
      credentials = [{
        type = "password";
        value = "$(env:${secretVar "test-user"})";
        temporary = false;
      }];
    }];
  };

  realmSmtp = lib.optionalAttrs smtp.enable {
    smtpServer = {
      host = smtp.host;
      port = toString smtp.port;
      from = smtp.from;
      fromDisplayName = smtp.fromName;
      replyTo = smtp.replyTo;
      starttls = "true";
      ssl = "false";
      auth = "true";
      user = smtp.user;
      password = "$(env:${secretVar "smtp"})";
    };
  };

  # "Sign in with Google": link to an existing user by email or refuse; never
  # create one. Then the user's Keycloak TOTP (requireOtp).
  google = cfg.google;
  execution = priority: authenticator: {
    inherit authenticator priority;
    requirement = "REQUIRED";
    authenticatorFlow = false;
    userSetupAllowed = false;
  };
  realmGoogle = {
    authenticationFlows = [
      {
        alias = "google-link-existing";
        description = "Google: link to an existing user by email, never create one";
        providerId = "basic-flow";
        topLevel = true;
        builtIn = false;
        authenticationExecutions = [
          (execution 10 "idp-detect-existing-broker-user")
          (execution 20 "idp-auto-link")
        ];
      }
    ] ++ lib.optional google.requireOtp {
      alias = "google-require-otp";
      description = "Google: require the Keycloak TOTP after Google";
      providerId = "basic-flow";
      topLevel = true;
      builtIn = false;
      authenticationExecutions = [ (execution 10 "auth-otp-form") ];
    };
    identityProviders = [{
      alias = "google";
      providerId = "google";
      displayName = "Google";
      enabled = true;
      # Google only returns verified addresses; the link-only flow relies on it.
      trustEmail = true;
      storeToken = false;
      addReadTokenRoleOnCreate = false;
      linkOnly = false;
      hideOnLogin = false;
      firstBrokerLoginFlowAlias = "google-link-existing";
      postBrokerLoginFlowAlias = if google.requireOtp then "google-require-otp" else "";
      config = {
        clientId = "$(env:${secretVar "google-id"})";
        clientSecret = "$(env:${secretVar "google-secret"})";
        defaultScope = "openid profile email";
        syncMode = "IMPORT";
        guiOrder = "1";
        hideOnLoginPage = "false";
        acceptsPromptNoneForwardFromClient = "false";
      };
    }];
  };

  realmImport = lib.foldl' lib.recursiveUpdate { } [
    realmBase
    realmTestUser
    realmSmtp
    cfg.realmSettings
  ];

  importFile = pkgs.writeText "keycloak-${kc.realm}-sync.json" (builtins.toJSON realmImport);
  # Used once the Google credentials in sops are real (the sync script picks).
  importFileGoogle = pkgs.writeText "keycloak-${kc.realm}-sync-google.json"
    (builtins.toJSON (lib.recursiveUpdate realmImport realmGoogle));

  # Every secret the import refers to, as env var -> { file, key }.
  secretRefs =
    lib.mapAttrs' (n: c: lib.nameValuePair (secretVar "client-${n}") c.secret)
      (lib.filterAttrs (_: c: c.secret != null) cfg.clients)
    // lib.optionalAttrs smtp.enable { ${secretVar "smtp"} = smtp.password; }
    // lib.optionalAttrs cfg.testUser.enable { ${secretVar "test-user"} = cfg.testUser.password; }
    // lib.optionalAttrs google.enable {
      ${secretVar "google-id"} = google.clientId;
      ${secretVar "google-secret"} = google.clientSecret;
    }
    // { KEYCLOAK_CLIENTSECRET = cfg.sync.credential; };

  syncScript = pkgs.writeShellScript "keycloak-realm-sync" ''
    set -euo pipefail
    PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnugrep pkgs.curl ]}

    # Pull only the referenced keys out of each env file; nothing is sourced
    # or evaluated, so secret values are taken literally.
    read_key() { # read_key <file> <key>
      local v
      v=$(grep -m1 "^$2=" "$1" | cut -d= -f2-) || true
      if [ -z "$v" ]; then
        echo "keycloak-realm-sync: $2 missing in $1" >&2
        exit 1
      fi
      printf '%s' "$v"
    }
    ${lib.concatStrings (lib.mapAttrsToList (var: ref: ''
      ${var}=$(read_key ${lib.escapeShellArg ref.file} ${lib.escapeShellArg ref.key})
      export ${var}
    '') secretRefs)}

    if [ "$KEYCLOAK_CLIENTSECRET" = REPLACE_ME ]; then
      echo "keycloak-realm-sync: homelab-config secret not set yet (docs/keycloak-ace.md), skipping" >&2
      exit 0
    fi

    IMPORT_FILES_LOCATIONS=${importFile}
    ${lib.optionalString google.enable ''
      if [ "''$${secretVar "google-id"}" = REPLACE_ME ] || [ "''$${secretVar "google-secret"}" = REPLACE_ME ]; then
        echo "keycloak-realm-sync: Google credentials not set yet (docs/keycloak-ace.md), Google login left out" >&2
      else
        IMPORT_FILES_LOCATIONS=${importFileGoogle}
      fi
    ''}
    export IMPORT_FILES_LOCATIONS

    for _ in $(seq 1 60); do
      curl -sf http://127.0.0.1:9281/health/ready >/dev/null && break
      sleep 5
    done

    exec ${cfg.sync.package}/bin/keycloak-config-cli
  '';

  managedTypes = [
    "authentication-flow" "client" "client-scope" "client-scope-mapping" "component"
    "group" "identity-provider" "identity-provider-mapper" "required-action" "role"
    "scope-mapping" "sub-component" "client-authorization-policies"
    "client-authorization-resources" "client-authorization-scopes" "message-bundles"
  ];
in
{
  options.homelab.keycloak = {
    sync = {
      enable = lib.mkEnableOption "keycloak-config-cli sync of the homelab realm";
      package = lib.mkPackageOption pkgs "keycloak-config-cli" { };
      credential = lib.mkOption {
        type = secretRefType;
        description = "Client secret of the homelab-config service account.";
      };
      url = lib.mkOption {
        type = lib.types.str;
        default = "https://${kc.domain}";
      };
    };

    groups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Realm groups that must exist. Membership is managed in the admin
        console (docs/keycloak-users.md), never here. Never use a local
        group name (wheel, docker, users, ...): SSSD turns groups into POSIX
        groups on the servers and the local one wins.
      '';
    };

    clients = lib.mkOption {
      type = lib.types.attrsOf clientType;
      default = { };
    };

    google = {
      enable = lib.mkEnableOption ''"Sign in with Google" (links existing users by email only)'';
      clientId = lib.mkOption { type = secretRefType; };
      clientSecret = lib.mkOption { type = secretRefType; };
      requireOtp = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Ask for the user's Keycloak TOTP after a Google login.";
      };
    };

    testUser = {
      enable = lib.mkEnableOption "the sso-regression user for tests/sso";
      password = lib.mkOption { type = secretRefType; };
      groups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Groups the regression user needs for the service tests. It is
          created disabled; tests/sso enables it only while tests run.
        '';
      };
    };

    realmSettings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Extra RealmRepresentation fields.";
    };

    smtp = {
      enable = lib.mkEnableOption "realm email (verify email, password reset, admin-triggered emails)";
      host = lib.mkOption { type = lib.types.str; };
      port = lib.mkOption { type = lib.types.port; default = 587; };
      user = lib.mkOption { type = lib.types.str; };
      password = lib.mkOption { type = secretRefType; };
      from = lib.mkOption { type = lib.types.str; };
      fromName = lib.mkOption { type = lib.types.str; default = "Homelab"; };
      replyTo = lib.mkOption { type = lib.types.str; default = ""; };
    };
  };

  config = lib.mkIf cfg.sync.enable {
    systemd.services.keycloak-realm-sync = {
      description = "Apply Nix-declared settings to the Keycloak homelab realm";
      wantedBy = [ "multi-user.target" ];
      after = [ "podman-keycloak.service" "caddy.service" "sops-nix.service" ];
      wants = [ "podman-keycloak.service" ];
      # Re-run on every switch that changes what it applies.
      restartTriggers = [ importFile importFileGoogle syncScript ];
      environment = {
        KEYCLOAK_URL = cfg.sync.url;
        KEYCLOAK_LOGINREALM = kc.realm;
        KEYCLOAK_GRANTTYPE = "client_credentials";
        KEYCLOAK_CLIENTID = "homelab-config";
        KEYCLOAK_AVAILABILITYCHECK_ENABLED = "true";
        KEYCLOAK_AVAILABILITYCHECK_TIMEOUT = "120s";
        # The service account can only see homelab, not /admin/serverinfo.
        KEYCLOAK_SKIPSERVERINFO = "true";
        IMPORT_VARSUBSTITUTION_ENABLED = "true";
        # Remote state lives in the realm's attributes; keep it so repeat
        # runs only touch what changed.
        IMPORT_REMOTESTATE_ENABLED = "true";
        IMPORT_CACHE_ENABLED = "false";
        LOGGING_LEVEL_ROOT = "warn";
        LOGGING_LEVEL_DE_ADORSYS = "info";
        SPRING_MAIN_BANNERMODE = "off";
      } // lib.listToAttrs (map (t: lib.nameValuePair
        ("IMPORT_MANAGED_" + lib.toUpper (lib.replaceStrings [ "-" ] [ "" ] t)) "no-delete") managedTypes);
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = syncScript;
        DynamicUser = false;
        PrivateTmp = true;
        NoNewPrivileges = true;
        Restart = "on-failure";
        RestartSec = 60;
      };
      startLimitIntervalSec = 1800;
      startLimitBurst = 5;
    };
  };
}
