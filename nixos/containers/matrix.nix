{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  matrixDomain = "matrix.prestonhager.com";
  synapseImage = "docker.io/matrixdotorg/synapse@sha256:673b4223c81a7634fd07d832b939a58f97081cfdaae7cdd2d1664cdcf7611b62"; # synapse v1.165.0
  synapseDataDir = "/matrix/data";
  synapsePostgresDir = "/matrix/postgres";
  synapseOidcDir = ./matrix;
  synapsePort = 6167;
  kc = import ../auth/keycloak-lib.nix;
  # Keycloak client (homelab.keycloak.clients.matrix below). idp_id "keycloak"
  # makes Synapse's auth_provider "oidc-keycloak" in user_external_ids; existing
  # users were relinked to their Keycloak sub there (docs/matrix-ace.md).
  oidcClientId = "matrix";
  synapseInitScript = pkgs.writeShellScript "matrix-synapse-init" ''
    set -euo pipefail

    dbEnv="${config.sops.secrets."matrix-db-env".path}"
    secrets="${config.sops.secrets."matrix-secrets".path}"
    oauthEnv="${config.sops.secrets."matrix-oauth-env".path}"

    install -d -m 0750 -o matrix -g matrix ${synapseDataDir}

    pgPass="$(grep '^POSTGRES_PASSWORD=' "$dbEnv" | cut -d= -f2-)"
    regSecret="$(grep '^SYNAPSE_REGISTRATION_SHARED_SECRET=' "$secrets" | cut -d= -f2-)"
    macaroonSecret="$(grep '^SYNAPSE_MACAROON_SECRET_KEY=' "$secrets" | cut -d= -f2-)"
    formSecret="$(grep '^SYNAPSE_FORM_SECRET=' "$secrets" | cut -d= -f2-)"
    oidcClientSecret="$(grep '^KEYCLOAK_CLIENT_SECRET=' "$oauthEnv" | cut -d= -f2-)"

    if [ -z "$pgPass" ] || [ -z "$regSecret" ] || [ -z "$macaroonSecret" ] || [ -z "$formSecret" ]; then
      echo "matrix-synapse-init: missing required secrets" >&2
      exit 1
    fi
    if [ -z "$oidcClientSecret" ]; then
      echo "matrix-synapse-init: KEYCLOAK_CLIENT_SECRET missing in matrix-oauth-env" >&2
      exit 1
    fi

    signingKey="${synapseDataDir}/${matrixDomain}.signing.key"
    if [ ! -f "$signingKey" ]; then
      ${pkgs.podman}/bin/podman run --rm \
        -v ${synapseDataDir}:/data \
        -e SYNAPSE_SERVER_NAME=${matrixDomain} \
        -e SYNAPSE_REPORT_STATS=no \
        ${synapseImage} generate
      chown -R matrix:matrix ${synapseDataDir}
    fi

    homeserver="${synapseDataDir}/homeserver.yaml"
    cat > "$homeserver" <<EOF
server_name: "${matrixDomain}"
public_baseurl: "https://${matrixDomain}/"
pid_file: /data/homeserver.pid
web_client_location: https://app.element.io/
serve_server_wellknown: true
report_stats: false

listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['0.0.0.0']
    resources:
      - names: [client, federation]
        compress: false

database:
  name: psycopg2
  allow_unsafe_locale: true
  args:
    user: synapse
    password: "$pgPass"
    database: synapse
    host: 127.0.0.1
    port: 5432
    cp_min: 5
    cp_max: 10

log_config: "/data/${matrixDomain}.log.config"

media_store_path: /data/media_store
signing_key_path: /data/${matrixDomain}.signing.key
registration_shared_secret: "$regSecret"
macaroon_secret_key: "$macaroonSecret"
form_secret: "$formSecret"

enable_registration: false
enable_registration_without_verification: false
allow_guest_access: false
suppress_key_server_warning: true

# Successful-login limits (defaults: burst 5, then 1 per ~5.5 min). Logins
# are SSO only (no account has a password; a loginToken needs a fresh SSO
# round-trip), so allow a little more for tests/sso/matrix.test.sh, which
# logs in 3 times per run from ace. failed_attempts (wrong passwords) keeps
# its default.
rc_login:
  address:
    per_second: 0.05
    burst_count: 10
  account:
    per_second: 0.05
    burst_count: 10

trusted_key_servers:
  - server_name: "matrix.org"

modules:
  - module: keycloak_oidc_mapper.KeycloakAdminModule
    config:
      admin_group: matrix_admin

oidc_providers:
  - idp_id: keycloak
    idp_name: "Keycloak"
    discover: true
    issuer: "${kc.issuer}"
    client_id: "${oidcClientId}"
    client_secret: "$oidcClientSecret"
    pkce_method: always
    # The groups claim comes from the client's default "groups" scope.
    scopes:
      - openid
      - profile
      - email
    user_mapping_provider:
      module: keycloak_oidc_mapper.KeycloakOidcMappingProvider
      config:
        subject_claim: sub
        localpart_template: "{{ user.preferred_username.split('@')[0] | lower }}"
        display_name_template: "{{ user.name }}"
        email_template: "{{ user.email }}"
        admin_group: matrix_admin
EOF

    chown matrix:matrix "$homeserver"
    chmod 0640 "$homeserver"
  '';
in {
  homelab.keycloak.clients.matrix = {
    name = "Matrix";
    redirectUris = [ "https://${matrixDomain}/_synapse/client/oidc/callback" ];
    secret = { file = config.sops.secrets."matrix-oauth-env".path; key = "KEYCLOAK_CLIENT_SECRET"; };
  };

  # restartUnits, not restartTriggers on the paths: the /run/secrets path never
  # changes when the secret value does, so path triggers never fired.
  sops.secrets = let
    restartUnits = [ "matrix-synapse-init.service" "podman-matrix-synapse.service" ];
  in {
    "matrix-db-env" = {
      sopsFile = "${sops-path}/secrets/containers/matrix.yaml";
      key = "matrix-db-env";
      restartUnits = restartUnits ++ [ "podman-matrix-db.service" ];
    };
    "matrix-secrets" = {
      sopsFile = "${sops-path}/secrets/containers/matrix.yaml";
      key = "matrix-secrets";
      inherit restartUnits;
    };
    "matrix-oauth-env" = {
      sopsFile = "${sops-path}/secrets/containers/matrix.yaml";
      key = "matrix-oauth-env";
      inherit restartUnits;
    };
  };

  users.users.matrix = {
    isSystemUser = true;
    description = "Matrix Synapse";
    group = "matrix";
  };
  users.groups.matrix = { };

  systemd.tmpfiles.rules = [
    "d ${synapseDataDir} 0750 matrix matrix -"
    "d ${synapsePostgresDir} 0700 postgres postgres -"
  ];

  systemd.services.matrix-postgres-datadir = {
    description = "Ensure Matrix PostgreSQL data directory is owned by container uid 70";
    before = [ "podman-matrix-db.service" ];
    requiredBy = [ "podman-matrix-db.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/chown -R postgres:postgres ${synapsePostgresDir}";
      ExecStartPost = "${pkgs.coreutils}/bin/chmod 0700 ${synapsePostgresDir}";
    };
  };

  systemd.services.matrix-synapse-init = {
    description = "Generate Matrix Synapse homeserver.yaml and signing keys";
    wantedBy = [ "multi-user.target" ];
    before = [
      "podman-matrix-synapse.service"
      "podman-matrix-db.service"
    ];
    requiredBy = [ "podman-matrix-synapse.service" ];
    after = [ "network-online.target" "sops-nix.service" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = synapseInitScript;
    };
    restartTriggers = [ synapseInitScript ];
  };

  systemd.services.pod-matrix = {
    description = "Podman pod for Matrix Synapse (Synapse + PostgreSQL)";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "matrix-synapse-init.service" ];
    before = [
      "podman-matrix-db.service"
      "podman-matrix-synapse.service"
      "caddy.service"
    ];
    requiredBy = [
      "podman-matrix-db.service"
      "podman-matrix-synapse.service"
    ];
    unitConfig.RequiresMountsFor = "/run/containers";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "pod-matrix-create" ''
        set -euo pipefail
        podman=${pkgs.podman}/bin/podman
        # Podman copies ace's /etc/hosts, which pins every Caddy vhost to
        # 127.0.0.1 (local-service-hosts.nix); inside the pod that is the pod
        # itself. Pin Keycloak to ace's LAN address so Synapse's discovery,
        # token and JWKS calls reach Caddy (back-channel carve-out in
        # nixos/caddy/keycloak.nix). --add-host only applies at pod
        # creation, so recreate a pod that lacks it.
        if $podman pod exists matrix-pod; then
          hosts="$($podman pod inspect matrix-pod --format '{{.InfraConfig.HostAdd}}' 2>/dev/null || true)"
          if ! echo "$hosts" | grep -q '${kc.domain}:${kc.aceAddress}'; then
            echo "pod-matrix: recreating pod for the Keycloak host pin"
            $podman pod stop -t 30 matrix-pod || true
            $podman pod rm -f matrix-pod
          fi
        fi
        if ! $podman pod exists matrix-pod; then
          $podman pod create \
            --name matrix-pod \
            -p 127.0.0.1:${toString synapsePort}:8008 \
            --add-host=${kc.domain}:${kc.aceAddress} \
            --memory 4G --cpus 0
        fi
      '';
    };
    path = [ pkgs.podman ];
  };

  virtualisation.oci-containers.containers.matrix-db = {
    autoStart = true;
    image = "docker.io/library/postgres@sha256:266d3c257594e195b309ae9d1805e54c788f1d7b375f56bf6c367aac6c917e7b"; # postgres 17.11-alpine (16 -> 17 needs dump/restore: docs/major-upgrades-plan.md section 3)
    extraOptions = [ "--pod=matrix-pod" ];
    environmentFiles = [ config.sops.secrets."matrix-db-env".path ];
    environment = {
      POSTGRES_INITDB_ARGS = "--encoding=UTF-8 --lc-collate=C --lc-ctype=C";
    };
    volumes = [
      "${synapsePostgresDir}:/var/lib/postgresql/data"
    ];
  };

  virtualisation.oci-containers.containers.matrix-synapse = {
    autoStart = true;
    dependsOn = [ "matrix-db" ];
    image = synapseImage;
    cmd = [ "run" ];
    extraOptions = [
      "--pod=matrix-pod"
    ];
    user = "matrix:matrix";
    environment = {
      PYTHONPATH = "/oidc";
    };
    volumes = [
      "/etc/passwd:/etc/passwd:ro"
      "/etc/group:/etc/group:ro"
      "${synapseDataDir}:/data"
      "${synapseOidcDir}:/oidc:ro"
    ];
  };

  systemd.services.podman-matrix-synapse = {
    # Synapse fetches Keycloak's OIDC discovery at startup.
    after = [ "podman-keycloak.service" ];
    wants = [ "podman-keycloak.service" ];
    before = [ "caddy.service" ];
    restartTriggers = [ synapseInitScript ];
  };
}
