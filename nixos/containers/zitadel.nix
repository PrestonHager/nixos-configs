{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  zitadelDomain = "zitadel.prestonhager.com";
  loginClientDir = "/zitadel/login-client";
  systemApiUsersJson = builtins.toJSON {
    login-client = {
      Path = "${loginClientDir}/tls.crt";
      Memberships = [{
        MemberType = "System";
        Roles = [ "IAM_LOGIN_CLIENT" ];
      }];
    };
  };
  loginClientKeyGen = pkgs.writeShellScript "zitadel-login-client-keygen" ''
    set -euo pipefail
    install -d -m 0750 -o zitadel -g zitadel ${loginClientDir}
    if [ ! -f ${loginClientDir}/tls.key ]; then
      ${pkgs.openssl}/bin/openssl genrsa -out ${loginClientDir}/tls.key 4096
      ${pkgs.openssl}/bin/openssl req -new -x509 -key ${loginClientDir}/tls.key -out ${loginClientDir}/tls.crt -days 3650 -subj "/CN=login-client" -batch
      chown zitadel:zitadel ${loginClientDir}/tls.key ${loginClientDir}/tls.crt
      chmod 640 ${loginClientDir}/tls.key
      chmod 644 ${loginClientDir}/tls.crt
    fi
  '';
in {
  sops.secrets = {
    "zitadel-env" = {
      sopsFile = "${sops-path}/secrets/containers/zitadel-config.yaml";
      key = "zitadel-env";
    };
    "zitadel-db-env" = {
      sopsFile = "${sops-path}/secrets/containers/zitadel-config.yaml";
      key = "zitadel-db-env";
    };
  };

  users.users.zitadel = {
    isSystemUser = true;
    description = "Zitadel";
    group = "zitadel";
  };
  users.groups.zitadel = { };

  # postgres:16-alpine runs as uid/gid 70; data dir must be traversable by that user.
  users.users.postgres = {
    isSystemUser = true;
    uid = 70;
    group = "postgres";
    description = "PostgreSQL (Zitadel container uid 70)";
  };
  users.groups.postgres = { gid = 70; };

  systemd.tmpfiles.rules = [
    "d /zitadel/data 0770 zitadel zitadel -"
    "d /zitadel/postgres 0700 postgres postgres -"
    "d ${loginClientDir} 0750 zitadel zitadel -"
  ];

  systemd.services.zitadel-postgres-datadir = {
    description = "Ensure Zitadel PostgreSQL data directory is owned by container uid 70";
    before = [ "podman-zitadel-db.service" ];
    requiredBy = [ "podman-zitadel-db.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/chown postgres:postgres /zitadel/postgres";
      ExecStartPost = "${pkgs.coreutils}/bin/chmod 0700 /zitadel/postgres";
    };
  };

  systemd.services.zitadel-login-client-keygen = {
    description = "Generate Zitadel login-client RSA keypair for Login UI API auth";
    wantedBy = [ "multi-user.target" ];
    before = [
      "podman-zitadel.service"
      "podman-zitadel-login.service"
    ];
    requiredBy = [
      "podman-zitadel.service"
      "podman-zitadel-login.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = loginClientKeyGen;
    };
  };

  systemd.services.pod-zitadel = {
    description = "Podman pod for Zitadel (API, login UI, PostgreSQL)";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    requiredBy = [
      "podman-zitadel-db.service"
      "podman-zitadel.service"
      "podman-zitadel-login.service"
    ];
    unitConfig.RequiresMountsFor = "/run/containers";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "pod-zitadel-create" ''
        set -euo pipefail
        hostGw="$(${pkgs.iproute2}/bin/ip -4 -o addr show podman0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
        if [ -z "''${hostGw}" ]; then
          hostGw="10.88.0.1"
        fi
        if ${pkgs.podman}/bin/podman pod exists zitadel-pod; then
          if ! ${pkgs.podman}/bin/podman pod inspect zitadel-pod --format '{{range .HostAdditions}}{{.Host}}:{{.IP}} {{end}}' \
            | grep -q "${zitadelDomain}:''${hostGw}"; then
            ${pkgs.podman}/bin/podman pod stop -t 10 zitadel-pod || true
            ${pkgs.podman}/bin/podman pod rm -f zitadel-pod || true
          fi
        fi
        if ! ${pkgs.podman}/bin/podman pod exists zitadel-pod; then
          ${pkgs.podman}/bin/podman pod create \
            --name zitadel-pod \
            --add-host=${zitadelDomain}:''${hostGw} \
            -p 9080:8080 \
            -p 9081:3000 \
            --memory 8G --cpus 0
        fi
      '';
    };
    path = [ pkgs.podman pkgs.iproute2 pkgs.gawk ];
  };

  virtualisation.oci-containers.containers.zitadel-db = {
    autoStart = true;
    image = "docker.io/library/postgres:16-alpine";
    extraOptions = [ "--pod=zitadel-pod" ];
    environmentFiles = [ config.sops.secrets."zitadel-db-env".path ];
    volumes = [
      "/zitadel/postgres:/var/lib/postgresql/data"
    ];
  };

  virtualisation.oci-containers.containers.zitadel = {
    autoStart = true;
    dependsOn = [ "zitadel-db" ];
    image = "ghcr.io/zitadel/zitadel:v4.15.0";
    cmd = [
      "start-from-init"
      "--masterkeyFromEnv"
      "--tlsMode"
      "disabled"
    ];
    extraOptions = [
      "--pod=zitadel-pod"
    ];
    environmentFiles = [ config.sops.secrets."zitadel-env".path ];
    environment = {
      ZITADEL_SYSTEMAPIUSERS = systemApiUsersJson;
    };
    volumes = [
      "/zitadel/data:/zitadel-data"
      "${loginClientDir}/tls.crt:${loginClientDir}/tls.crt:ro"
    ];
  };

  virtualisation.oci-containers.containers.zitadel-login = {
    autoStart = true;
    dependsOn = [ "zitadel" ];
    image = "ghcr.io/zitadel/zitadel-login:v4.15.0";
    extraOptions = [ "--pod=zitadel-pod" ];
    environment = {
      ZITADEL_API_URL = "http://127.0.0.1:8080";
      ZITADEL_EXTERNALDOMAIN = "${zitadelDomain}";
      ZITADEL_EXTERNALSECURE = "true";
      ZITADEL_EXTERNALPORT = "443";
      ZITADEL_LOGINCLIENT_KEYFILE = "${loginClientDir}/tls.key";
      AUDIENCE = "https://${zitadelDomain}";
      NEXT_PUBLIC_BASE_PATH = "/ui/v2/login";
      CUSTOM_REQUEST_HEADERS = "Host:${zitadelDomain},X-Forwarded-Proto:https,X-Zitadel-Public-Host:${zitadelDomain}";
      ZITADEL_TLS_ENABLED = "false";
      OTEL_SDK_DISABLED = "true";
    };
    volumes = [
      "${loginClientDir}/tls.key:${loginClientDir}/tls.key:ro"
    ];
  };
}