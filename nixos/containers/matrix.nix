{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  matrixDomain = "matrix.prestonhager.com";
  synapseImage = "docker.io/matrixdotorg/synapse:v1.127.0";
  synapseDataDir = "/matrix/data";
  synapsePostgresDir = "/matrix/postgres";
  synapsePort = 6167;
  synapseInitScript = pkgs.writeShellScript "matrix-synapse-init" ''
    set -euo pipefail

    dbEnv="${config.sops.secrets."matrix-db-env".path}"
    secrets="${config.sops.secrets."matrix-secrets".path}"

    install -d -m 0750 -o matrix -g matrix ${synapseDataDir}

    pgPass="$(grep '^POSTGRES_PASSWORD=' "$dbEnv" | cut -d= -f2-)"
    regSecret="$(grep '^SYNAPSE_REGISTRATION_SHARED_SECRET=' "$secrets" | cut -d= -f2-)"
    macaroonSecret="$(grep '^SYNAPSE_MACAROON_SECRET_KEY=' "$secrets" | cut -d= -f2-)"
    formSecret="$(grep '^SYNAPSE_FORM_SECRET=' "$secrets" | cut -d= -f2-)"

    if [ -z "$pgPass" ] || [ -z "$regSecret" ] || [ -z "$macaroonSecret" ] || [ -z "$formSecret" ]; then
      echo "matrix-synapse-init: missing required secrets" >&2
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
  args:
    user: synapse
    password: "$pgPass"
    database: synapse
    host: 127.0.0.1
    port: 5432
    cp_min: 5
    cp_max: 10
    allow_unsafe_locale: true

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

trusted_key_servers:
  - server_name: "matrix.org"
EOF

    chown matrix:matrix "$homeserver"
    chmod 0640 "$homeserver"
  '';
in {
  sops.secrets = {
    "matrix-db-env" = {
      sopsFile = "${sops-path}/secrets/containers/matrix.yaml";
      key = "matrix-db-env";
    };
    "matrix-secrets" = {
      sopsFile = "${sops-path}/secrets/containers/matrix.yaml";
      key = "matrix-secrets";
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
    restartTriggers = [
      config.sops.secrets."matrix-db-env".path
      config.sops.secrets."matrix-secrets".path
    ];
  };

  systemd.services.pod-matrix = {
    description = "Podman pod for Matrix Synapse (Synapse + PostgreSQL)";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "matrix-synapse-init.service" ];
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
        if ! ${pkgs.podman}/bin/podman pod exists matrix-pod; then
          ${pkgs.podman}/bin/podman pod create \
            --name matrix-pod \
            -p ${toString synapsePort}:8008 \
            --memory 4G --cpus 0
        fi
      '';
    };
    path = [ pkgs.podman ];
  };

  virtualisation.oci-containers.containers.matrix-db = {
    autoStart = true;
    image = "docker.io/library/postgres:16-alpine";
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
    volumes = [
      "/etc/passwd:/etc/passwd:ro"
      "/etc/group:/etc/group:ro"
      "${synapseDataDir}:/data"
    ];
  };

  systemd.services.podman-matrix-synapse.restartTriggers = [
    config.sops.secrets."matrix-db-env".path
    config.sops.secrets."matrix-secrets".path
    synapseInitScript
  ];
}
