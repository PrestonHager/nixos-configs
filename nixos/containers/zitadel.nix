{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  zitadelDomain = "zitadel.prestonhager.com";
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

  systemd.tmpfiles.rules = [
    "d /zitadel/data 0770 zitadel zitadel -"
    "d /zitadel/postgres 0770 zitadel zitadel -"
  ];

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
        if ! ${pkgs.podman}/bin/podman pod exists zitadel; then
          ${pkgs.podman}/bin/podman pod create \
            --name zitadel \
            -p 9080:8080 \
            -p 9081:3000 \
            --memory 8G --cpus 0
        fi
      '';
    };
    path = [ pkgs.podman ];
  };

  virtualisation.oci-containers.containers.zitadel-db = {
    autoStart = true;
    image = "docker.io/library/postgres:16-alpine";
    user = "root:root";
    extraOptions = [ "--pod=zitadel" ];
    environmentFiles = [ config.sops.secrets."zitadel-db-env".path ];
    volumes = [
      "/zitadel/postgres:/var/lib/postgresql/data"
    ];
    healthcheck = {
      test = [ "CMD-SHELL" "pg_isready -U postgres -d zitadel" ];
      interval = "10s";
      timeout = "30s";
      retries = 5;
      startPeriod = "20s";
    };
  };

  virtualisation.oci-containers.containers.zitadel = {
    autoStart = true;
    image = "ghcr.io/zitadel/zitadel:latest";
    user = "root:root";
    cmd = [
      "start-from-init"
      "--masterkeyFromEnv"
      "--tlsMode"
      "disabled"
    ];
    extraOptions = [
      "--pod=zitadel"
    ];
    environmentFiles = [ config.sops.secrets."zitadel-env".path ];
    volumes = [
      "/zitadel/data:/zitadel-data"
    ];
    healthcheck = {
      test = [ "CMD" "/app/zitadel" "ready" ];
      interval = "10s";
      timeout = "60s";
      retries = 5;
      startPeriod = "30s";
    };
  };

  virtualisation.oci-containers.containers.zitadel-login = {
    autoStart = true;
    image = "ghcr.io/zitadel/zitadel-login:latest";
    user = "root:root";
    extraOptions = [ "--pod=zitadel" ];
    environment = {
      ZITADEL_API_URL = "http://127.0.0.1:8080";
      NEXT_PUBLIC_BASE_PATH = "/ui/v2/login";
      CUSTOM_REQUEST_HEADERS = "Host:${zitadelDomain},X-Forwarded-Proto:https";
    };
    healthcheck = {
      test = [ "CMD-SHELL" "curl -fsS http://127.0.0.1:3000/ui/v2/login/healthz || exit 1" ];
      interval = "15s";
      timeout = "10s";
      retries = 5;
      startPeriod = "30s";
    };
  };
}
