{ config, pkgs, lib, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  etc = config.environment.etc;
  etcPath = name: etc.${name}.source;
  # Provisioning files that other modules add to /etc only when enabled
  # (grafana-security-alerting.nix: security rules and the Loki datasource).
  optionalProvisioning = builtins.filter (name: etc ? ${name}) [
    "grafana/provisioning/alerting/security-alert-rules.yaml"
    "grafana/provisioning/datasources/loki.yaml"
  ];
  grafanaVersion = "13.3.0";
  # Remote image renderer (replaces deprecated in-Grafana plugin). Shares pod network with Grafana.
  imageRendererImage = "docker.io/grafana/grafana-image-renderer@sha256:24df1663f600abc6daa8ef006a0749c1d8f532e43a4542baf55ba15c5a3eaeac"; # v5.12.9
  grafanaPort = 8082;
  grafanaRuntimeEnv = "/run/grafana/container.env";
  rendererRuntimeEnv = "/run/grafana/renderer.env";
  grafanaAlertingDir = "/run/grafana/provisioning/alerting";
  # Host /etc/hosts maps *.prestonhager.com → 127.0.0.1; inside the container that is
  # loopback, not Caddy on the host. Override so server-side OAuth token/userinfo calls work.
  zitadelDomain = "zitadel.prestonhager.com";
  grafanaContainerEnvScript = pkgs.writeShellScript "grafana-container-env" ''
    set -euo pipefail
    # Secrets land in these files; never let them exist world-readable, even briefly.
    umask 077
    mkdir -p /run/grafana/provisioning/alerting
    cp "${config.sops.secrets."grafana-oauth-env".path}" "${grafanaRuntimeEnv}"
    # The image renderer only needs its shared token, not the OAuth client secret.
    grep '^AUTH_TOKEN=' "${grafanaRuntimeEnv}" > "${rendererRuntimeEnv}" || {
      echo "grafana-container-env: AUTH_TOKEN missing from grafana-oauth-env" >&2
      exit 1
    }
    ncEnv="${config.sops.secrets."nextcloud-environment".path}"
    smtpPass="$(grep '^SMTP_PASSWORD=' "$ncEnv" | cut -d= -f2- || true)"
    if [ -z "$smtpPass" ]; then
      echo "grafana-container-env: SMTP_PASSWORD missing from nextcloud-environment" >&2
      exit 1
    fi
    grep -v '^GF_SMTP_' "${grafanaRuntimeEnv}" > "${grafanaRuntimeEnv}.tmp" || true
    mv "${grafanaRuntimeEnv}.tmp" "${grafanaRuntimeEnv}"
    {
      printf '%s\n' 'GF_SMTP_ENABLED=true'
      printf '%s\n' 'GF_SMTP_HOST=smtp.mail.me.com:587'
      printf '%s\n' 'GF_SMTP_USER=prestonhager@icloud.com'
      printf 'GF_SMTP_PASSWORD=%s\n' "$smtpPass"
      printf '%s\n' 'GF_SMTP_FROM_ADDRESS=admin@prestonhager.com'
      printf '%s\n' 'GF_SMTP_FROM_NAME=Grafana Ace Alerts'
      printf '%s\n' 'GF_SMTP_STARTTLS_POLICY=Mandatory'
    } >> "${grafanaRuntimeEnv}"
    chmod 600 "${grafanaRuntimeEnv}"
  '';
  grafanaAlertingProvisionScript = pkgs.writeShellScript "grafana-alerting-provision" ''
    set -euo pipefail
    envFile="${grafanaRuntimeEnv}"
    outFile="${grafanaAlertingDir}/contact-points.yaml"
    mkdir -p "${grafanaAlertingDir}"
    emails="$(grep '^GRAFANA_ALERT_EMAILS=' "$envFile" | cut -d= -f2- || true)"
    if [ -z "$emails" ]; then
      echo "grafana-alerting-provision: GRAFANA_ALERT_EMAILS missing from ${grafanaRuntimeEnv}" >&2
      exit 1
    fi
    addrs="$(printf '%s' "$emails" | ${pkgs.gnused}/bin/sed 's/[[:space:]]*,[[:space:]]*/;/g; s/[[:space:]]*;[[:space:]]*/;/g')"
    cat > "$outFile" <<EOF
apiVersion: 1
contactPoints:
  - orgId: 1
    name: ace-email
    receivers:
      - uid: ace-email
        type: email
        settings:
          addresses: $addrs
          singleEmail: true
EOF
    chmod 644 "$outFile"
  '';
in {
  sops.secrets = {
    "grafana-oauth-env" = {
      sopsFile = "${sops-path}/secrets/containers/grafana-oauth.yaml";
      key = "grafana-oauth-env";
      # The secret path never changes, so a restartTriggers entry on it never fired.
      restartUnits = [ "podman-grafana.service" "podman-grafana-image-renderer.service" ];
    };
    # Grafana's alert mail reuses the Nextcloud SMTP password.
    "nextcloud-environment".restartUnits = [ "podman-grafana.service" ];
  };

  users.users.grafana = {
    isSystemUser = true;
    description = "Grafana";
    group = "grafana";
  };
  users.groups.grafana = { };

  systemd.tmpfiles.rules = [
    "d /grafana/data 0770 grafana grafana -"
    "d /run/grafana/provisioning/alerting 0755 root root -"
  ];

  systemd.services.grafana-container-env = {
    description = "Build Grafana container env (OAuth + shared iCloud SMTP password)";
    before = [
      "grafana-alerting-provision.service"
      "podman-grafana.service"
      "podman-grafana-image-renderer.service"
    ];
    requiredBy = [ "podman-grafana.service" "podman-grafana-image-renderer.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
      ExecStart = grafanaContainerEnvScript;
    };
  };

  systemd.services.grafana-alerting-provision = {
    description = "Generate Grafana alerting contact points from GRAFANA_ALERT_EMAILS";
    after = [ "grafana-container-env.service" ];
    before = [ "podman-grafana.service" ];
    requiredBy = [ "podman-grafana.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
      ExecStart = grafanaAlertingProvisionScript;
    };
  };

  # Recreate containers when provisioned files change (podman bind-mounts store paths).
  # Secret changes restart them through sops restartUnits above.
  systemd.services.podman-grafana.restartTriggers = [
    (etcPath "grafana/provisioning/datasources/prometheus.yaml")
    (pkgs.writeText "grafana-alert-rules" (builtins.readFile ../monitoring/grafana/provisioning/alerting/alert-rules.yaml))
    (pkgs.writeText "grafana-notification-policies" (builtins.readFile ../monitoring/grafana/provisioning/alerting/notification-policies.yaml))
    (etcPath "grafana/provisioning/dashboards/ace.yaml")
    (etcPath "grafana/provisioning/dashboards/crux.yaml")
    (etcPath "grafana/provisioning/dashboards/lan.yaml")
    (etcPath "grafana/provisioning/dashboards/security.yaml")
    (etcPath "grafana/dashboards/security/suricata-alerts.json")
    (etcPath "grafana/dashboards/ace/ace-uptime.json")
    (etcPath "grafana/dashboards/ace/ace-overview.json")
    (etcPath "grafana/dashboards/ace/ace-services.json")
    (etcPath "grafana/dashboards/ace/ace-http-probes.json")
    (etcPath "grafana/dashboards/ace/ace-tcp-probes.json")
    (etcPath "grafana/dashboards/ace/ace-versions.json")
    (etcPath "grafana/dashboards/ace/coolify.json")
    (etcPath "grafana/dashboards/crux/crux-uptime.json")
    (etcPath "grafana/dashboards/crux/crux-http-probes.json")
    (etcPath "grafana/dashboards/lan/lan-status.json")
    (etcPath "grafana/dashboards/lan/network-topology.json")
  ] ++ map etcPath optionalProvisioning;

  systemd.services.pod-grafana = {
    description = "Podman pod for Grafana and image renderer";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    # Without before=, requiredBy alone lets the containers start in parallel with
    # the pod and fail with "no such pod" (seen on the 2026-10-18 switch).
    before = [
      "podman-grafana.service"
      "podman-grafana-image-renderer.service"
    ];
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
          if ! ${pkgs.podman}/bin/podman pod inspect grafana-pod --format '{{range .InfraConfig.HostAdd}}{{.}} {{end}}' \
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
            --dns=192.168.5.5 \
            -p 127.0.0.1:${toString grafanaPort}:3000 \
            -p 10.88.0.1:${toString grafanaPort}:3000 \
            --memory 4G --cpus 0
        fi
      '';
    };
    path = [ pkgs.podman pkgs.iproute2 pkgs.gawk ];
  };

  virtualisation.oci-containers.containers.grafana = {
    autoStart = true;
    image = "docker.io/grafana/grafana:${grafanaVersion}";
    user = "grafana:grafana";

    extraOptions = [
      "--pod=grafana-pod"
    ];

    environmentFiles = [
      grafanaRuntimeEnv
    ];

    environment = {
      GF_PATHS_PROVISIONING = "/etc/grafana/provisioning";
      GF_PATHS_DATA = "/var/lib/grafana";
      GF_SERVER_DOMAIN = "grafana.prestonhager.com";
      GF_SERVER_ROOT_URL = "https://grafana.prestonhager.com/";
      GF_SERVER_ENFORCE_DOMAIN = "true";
      GF_SERVER_ENABLE_GZIP = "true";
      # Zitadel OIDC and SMTP password are configured via runtime env file.
      GF_AUTH_LDAP_ENABLED = "false";
      GF_AUTH_DISABLE_LOGIN_FORM = "false";
      # Default org role for new OAuth users when role_attribute_path does not match.
      GF_USERS_AUTO_ASSIGN_ORG_ROLE = "Viewer";
      # Remote image renderer (pod-local URLs; Chromium fetches dashboards via loopback).
      # GF_RENDERING_RENDERER_TOKEN and AUTH_TOKEN come from grafana-oauth-env sops file.
      GF_RENDERING_SERVER_URL = "http://127.0.0.1:8081/render";
      GF_RENDERING_CALLBACK_URL = "http://127.0.0.1:3000/";
      GF_RENDERING_TIMEOUT = "30";
      GF_UNIFIED_ALERTING_ENABLED = "true";
    };

    volumes = [
      "/etc/passwd:/etc/passwd:ro"
      "/etc/group:/etc/group:ro"
      "/grafana/data:/var/lib/grafana"
      "${etcPath "grafana/provisioning/datasources/prometheus.yaml"}:/etc/grafana/provisioning/datasources/prometheus.yaml:ro"
      "${etcPath "grafana/provisioning/dashboards/ace.yaml"}:/etc/grafana/provisioning/dashboards/ace.yaml:ro"
      "${etcPath "grafana/provisioning/dashboards/crux.yaml"}:/etc/grafana/provisioning/dashboards/crux.yaml:ro"
      "${etcPath "grafana/provisioning/dashboards/lan.yaml"}:/etc/grafana/provisioning/dashboards/lan.yaml:ro"
      "${etcPath "grafana/provisioning/dashboards/security.yaml"}:/etc/grafana/provisioning/dashboards/security.yaml:ro"
      "${grafanaAlertingDir}/contact-points.yaml:/etc/grafana/provisioning/alerting/contact-points.yaml:ro"
      "${etcPath "grafana/provisioning/alerting/alert-rules.yaml"}:/etc/grafana/provisioning/alerting/alert-rules.yaml:ro"
      "${etcPath "grafana/provisioning/alerting/notification-policies.yaml"}:/etc/grafana/provisioning/alerting/notification-policies.yaml:ro"
      "${etcPath "grafana/dashboards/ace/ace-overview.json"}:/etc/grafana/dashboards/ace/ace-overview.json:ro"
      "${etcPath "grafana/dashboards/ace/ace-services.json"}:/etc/grafana/dashboards/ace/ace-services.json:ro"
      "${etcPath "grafana/dashboards/ace/ace-uptime.json"}:/etc/grafana/dashboards/ace/ace-uptime.json:ro"
      "${etcPath "grafana/dashboards/ace/ace-http-probes.json"}:/etc/grafana/dashboards/ace/ace-http-probes.json:ro"
      "${etcPath "grafana/dashboards/ace/ace-tcp-probes.json"}:/etc/grafana/dashboards/ace/ace-tcp-probes.json:ro"
      "${etcPath "grafana/dashboards/ace/ace-versions.json"}:/etc/grafana/dashboards/ace/ace-versions.json:ro"
      "${etcPath "grafana/dashboards/ace/coolify.json"}:/etc/grafana/dashboards/ace/coolify.json:ro"
      "${etcPath "grafana/dashboards/crux/crux-uptime.json"}:/etc/grafana/dashboards/crux/crux-uptime.json:ro"
      "${etcPath "grafana/dashboards/crux/crux-http-probes.json"}:/etc/grafana/dashboards/crux/crux-http-probes.json:ro"
      "${etcPath "grafana/dashboards/lan/lan-status.json"}:/etc/grafana/dashboards/lan/lan-status.json:ro"
      "${etcPath "grafana/dashboards/security/suricata-alerts.json"}:/etc/grafana/dashboards/security/suricata-alerts.json:ro"
      "${etcPath "grafana/dashboards/lan/network-topology.json"}:/etc/grafana/dashboards/lan/network-topology.json:ro"
    ] ++ map (name: "${etcPath name}:/etc/${name}:ro") optionalProvisioning;
  };

  virtualisation.oci-containers.containers.grafana-image-renderer = {
    autoStart = true;
    dependsOn = [ "grafana" ];
    image = imageRendererImage;
    extraOptions = [
      "--pod=grafana-pod"
      # No CAP_SYS_ADMIN: renderer v5 defaults to browser.sandbox=false and
      # browser.namespaced=false; only the namespaced mode needs SYS_ADMIN/SYS_CHROOT.
    ];
    # AUTH_TOKEN only (written by grafana-container-env).
    environmentFiles = [ rendererRuntimeEnv ];
    environment = {
      GOMEMLIMIT = "1GiB";
    };
  };
}
