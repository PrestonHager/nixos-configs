{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  zitadelDomain = "zitadel.prestonhager.com";
  loginClientDir = "/zitadel/login-client";
  zitadelRuntimeEnv = "/run/zitadel/container.env";
  zitadelEnvScript = pkgs.writeShellScript "zitadel-container-env" ''
    set -euo pipefail
    mkdir -p /run/zitadel
    cp "${config.sops.secrets."zitadel-env".path}" "${zitadelRuntimeEnv}"
    ncEnv="${config.sops.secrets."nextcloud-environment".path}"
    smtpPass="$(grep '^SMTP_PASSWORD=' "$ncEnv" | cut -d= -f2- || true)"
    if [ -z "$smtpPass" ]; then
      echo "zitadel-container-env: SMTP_PASSWORD missing from nextcloud-environment" >&2
      exit 1
    fi
    grep -v '^ZITADEL_DEFAULTINSTANCE_SMTPCONFIGURATION_SMTP_PASSWORD=' "${zitadelRuntimeEnv}" \
      > "${zitadelRuntimeEnv}.tmp" || true
    mv "${zitadelRuntimeEnv}.tmp" "${zitadelRuntimeEnv}"
    printf 'ZITADEL_DEFAULTINSTANCE_SMTPCONFIGURATION_SMTP_PASSWORD=%s\n' "$smtpPass" >> "${zitadelRuntimeEnv}"
    chmod 600 "${zitadelRuntimeEnv}"
  '';
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
      # zitadel-login runs as nextjs (uid 1001), not zitadel; key must be world-readable.
      chmod 644 ${loginClientDir}/tls.key
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
      ExecStart = "${pkgs.coreutils}/bin/chown -R postgres:postgres /zitadel/postgres";
      ExecStartPost = "${pkgs.coreutils}/bin/chmod 0700 /zitadel/postgres";
    };
  };

  systemd.services.zitadel-container-env = {
    description = "Build Zitadel container env (zitadel-env + shared iCloud SMTP password)";
    before = [ "podman-zitadel.service" ];
    requiredBy = [ "podman-zitadel.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = zitadelEnvScript;
    };
  };

  systemd.services."podman-zitadel" = {
    after = [ "zitadel-container-env.service" "sops-nix.service" ];
    requires = [ "zitadel-container-env.service" ];
    before = [ "caddy.service" ];
    serviceConfig.ExecStartPre = pkgs.lib.mkOrder 100 zitadelEnvScript;
  };

  systemd.services."podman-zitadel-login" = {
    before = [ "caddy.service" ];
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
      # Ensure existing keys are readable by zitadel-login (nextjs uid 1001).
      ExecStartPost = "${pkgs.coreutils}/bin/chmod 644 ${loginClientDir}/tls.key ${loginClientDir}/tls.crt";
    };
  };

  systemd.services.pod-zitadel = {
    description = "Podman pod for Zitadel (API, login UI, PostgreSQL)";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    before = [
      "podman-zitadel-db.service"
      "podman-zitadel.service"
      "podman-zitadel-login.service"
      "caddy.service"
    ];
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
          additions="$(${pkgs.podman}/bin/podman pod inspect zitadel-pod \
            --format '{{range .HostAdditions}}{{.Host}}:{{.IP}} {{end}}' 2>/dev/null || true)"
          if [ -z "''${additions}" ] || ! printf '%s' "''${additions}" | grep -q "${zitadelDomain}:''${hostGw}"; then
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
    image = "ghcr.io/zitadel/zitadel:v4.17.0";
    cmd = [
      "start-from-init"
      "--masterkeyFromEnv"
      # external: TLS terminated by Caddy; forces https:// in console environment.json
      "--tlsMode"
      "external"
    ];
    extraOptions = [
      "--pod=zitadel-pod"
    ];
    environmentFiles = [ zitadelRuntimeEnv ];
    environment = {
      ZITADEL_SYSTEMAPIUSERS = systemApiUsersJson;
      # iCloud SMTP relay (password injected via zitadel-container-env from nextcloud SMTP_PASSWORD)
      ZITADEL_DEFAULTINSTANCE_DOMAINPOLICY_SMTPSENDERADDRESSMATCHESINSTANCEDOMAIN = "false";
      ZITADEL_DEFAULTINSTANCE_SMTPCONFIGURATION_SMTP_HOST = "smtp.mail.me.com:587";
      ZITADEL_DEFAULTINSTANCE_SMTPCONFIGURATION_SMTP_USER = "prestonhager@icloud.com";
      ZITADEL_DEFAULTINSTANCE_SMTPCONFIGURATION_TLS = "true";
      ZITADEL_DEFAULTINSTANCE_SMTPCONFIGURATION_FROM = "admin@prestonhager.com";
      ZITADEL_DEFAULTINSTANCE_SMTPCONFIGURATION_FROMNAME = "Zitadel";
    };
    volumes = [
      "/zitadel/data:/zitadel-data"
      "${loginClientDir}/tls.crt:${loginClientDir}/tls.crt:ro"
    ];
  };

  virtualisation.oci-containers.containers.zitadel-login = {
    autoStart = true;
    dependsOn = [ "zitadel" ];
    image = "ghcr.io/zitadel/zitadel-login:v4.17.0";
    extraOptions = [ "--pod=zitadel-pod" ];
    environment = {
      ZITADEL_API_URL = "http://127.0.0.1:8080";
      ZITADEL_EXTERNALDOMAIN = "${zitadelDomain}";
      ZITADEL_EXTERNALSECURE = "true";
      ZITADEL_EXTERNALPORT = "443";
      ZITADEL_LOGINCLIENT_KEYFILE = "${loginClientDir}/tls.key";
      # Must match Zitadel system token verifier audience (https with tlsMode external).
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
