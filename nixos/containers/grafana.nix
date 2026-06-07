{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  etc = config.environment.etc;
  etcPath = name: etc.${name}.source;
  grafanaVersion = "13.0.2";
  # Remote image renderer (replaces deprecated in-Grafana plugin). Shares pod network with Grafana.
  imageRendererVersion = "v5.8.8";
  grafanaPort = 8082;
  # Host /etc/hosts maps *.prestonhager.com → 127.0.0.1; inside the container that is
  # loopback, not Caddy on the host. Override so server-side OAuth token/userinfo calls work.
  zitadelDomain = "zitadel.prestonhager.com";
in {
  sops.secrets = {
    "grafana-oauth-env" = {
      sopsFile = "${sops-path}/secrets/containers/grafana-oauth.yaml";
      key = "grafana-oauth-env";
    };
  };

  users.users.grafana = {
    isSystemUser = true;
    description = "Grafana";
    group = "grafana";
  };
  users.groups.grafana = { };

  systemd.tmpfiles.rules = [
    "d /grafana/data 0770 grafana grafana -"
  ];

  # Recreate the container when OAuth secrets change (podman does not reload --env-file).
  systemd.services.podman-grafana.restartTriggers = [
    config.sops.secrets."grafana-oauth-env".path
  ];

  systemd.services.pod-grafana = {
    description = "Podman pod for Grafana and image renderer";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    requiredBy = [
      "podman-grafana.service"
      "podman-grafana-image-renderer.service"
    ];
    unitConfig.RequiresMountsFor = "/run/containers";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "pod-grafana-create" ''
        set -euo pipefail
        hostGw="$(${pkgs.iproute2}/bin/ip -4 -o addr show podman0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
        if [ -z "''${hostGw}" ]; then
          hostGw="10.88.0.1"
        fi
        if ${pkgs.podman}/bin/podman pod exists grafana-pod; then
          if ! ${pkgs.podman}/bin/podman pod inspect grafana-pod --format '{{range .HostAdditions}}{{.Host}}:{{.IP}} {{end}}' \
            | grep -q "${zitadelDomain}:''${hostGw}"; then
            ${pkgs.podman}/bin/podman pod stop -t 10 grafana-pod || true
            ${pkgs.podman}/bin/podman pod rm -f grafana-pod || true
          fi
        fi
        if ! ${pkgs.podman}/bin/podman pod exists grafana-pod; then
          ${pkgs.podman}/bin/podman pod create \
            --name grafana-pod \
            --add-host=${zitadelDomain}:''${hostGw} \
            --add-host=host.containers.internal:host-gateway \
            -p ${toString grafanaPort}:3000 \
            --memory 4G --cpus 0
        fi
      '';
    };
    path = [ pkgs.podman pkgs.iproute2 pkgs.gawk ];
  };

  virtualisation.oci-containers.containers.grafana = {
    autoStart = true;
    image = "docker.io/grafana/grafana-oss:${grafanaVersion}";
    user = "grafana:grafana";

    extraOptions = [
      "--pod=grafana-pod"
    ];

    environmentFiles = [
      config.sops.secrets."grafana-oauth-env".path
    ];

    environment = {
      GF_PATHS_PROVISIONING = "/etc/grafana/provisioning";
      GF_PATHS_DATA = "/var/lib/grafana";
      GF_SERVER_DOMAIN = "grafana.prestonhager.com";
      GF_SERVER_ROOT_URL = "https://grafana.prestonhager.com/";
      GF_SERVER_ENFORCE_DOMAIN = "true";
      GF_SERVER_ENABLE_GZIP = "true";
      # Zitadel OIDC is configured via sops env file.
      GF_AUTH_LDAP_ENABLED = "false";
      GF_AUTH_DISABLE_LOGIN_FORM = "false";
      # Default org role for new OAuth users when role_attribute_path does not match.
      GF_USERS_AUTO_ASSIGN_ORG_ROLE = "Viewer";
      # Remote image renderer (pod-local URLs; Chromium fetches dashboards via loopback).
      GF_RENDERING_SERVER_URL = "http://127.0.0.1:8081/render";
      GF_RENDERING_CALLBACK_URL = "http://127.0.0.1:3000/";
      GF_RENDERING_RENDERER_TOKEN = "-";
      GF_RENDERING_TIMEOUT = "30";
    };

    volumes = [
      "/etc/passwd:/etc/passwd:ro"
      "/etc/group:/etc/group:ro"
      "/grafana/data:/var/lib/grafana"
      "${etcPath "grafana/provisioning/datasources/prometheus.yaml"}:/etc/grafana/provisioning/datasources/prometheus.yaml:ro"
      "${etcPath "grafana/provisioning/dashboards/ace.yaml"}:/etc/grafana/provisioning/dashboards/ace.yaml:ro"
      "${etcPath "grafana/provisioning/dashboards/crux.yaml"}:/etc/grafana/provisioning/dashboards/crux.yaml:ro"
      "${etcPath "grafana/provisioning/dashboards/lan.yaml"}:/etc/grafana/provisioning/dashboards/lan.yaml:ro"
      "${etcPath "grafana/dashboards/ace/ace-overview.json"}:/etc/grafana/dashboards/ace/ace-overview.json:ro"
      "${etcPath "grafana/dashboards/ace/ace-services.json"}:/etc/grafana/dashboards/ace/ace-services.json:ro"
      "${etcPath "grafana/dashboards/ace/ace-uptime.json"}:/etc/grafana/dashboards/ace/ace-uptime.json:ro"
      "${etcPath "grafana/dashboards/ace/ace-http-probes.json"}:/etc/grafana/dashboards/ace/ace-http-probes.json:ro"
      "${etcPath "grafana/dashboards/ace/ace-tcp-probes.json"}:/etc/grafana/dashboards/ace/ace-tcp-probes.json:ro"
      "${etcPath "grafana/dashboards/crux/crux-uptime.json"}:/etc/grafana/dashboards/crux/crux-uptime.json:ro"
      "${etcPath "grafana/dashboards/crux/crux-http-probes.json"}:/etc/grafana/dashboards/crux/crux-http-probes.json:ro"
      "${etcPath "grafana/dashboards/lan/lan-status.json"}:/etc/grafana/dashboards/lan/lan-status.json:ro"
    ];
  };

  virtualisation.oci-containers.containers.grafana-image-renderer = {
    autoStart = true;
    dependsOn = [ "grafana" ];
    image = "docker.io/grafana/grafana-image-renderer:${imageRendererVersion}";
    extraOptions = [
      "--pod=grafana-pod"
      "--cap-add=SYS_ADMIN"
    ];
    environment = {
      AUTH_TOKEN = "-";
      GOMEMLIMIT = "1GiB";
    };
  };
}
