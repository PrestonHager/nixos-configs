{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  etc = config.environment.etc;
  etcPath = name: etc.${name}.source;
  grafanaVersion = "13.0.2";
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
    "d /grafana/conf 0770 grafana grafana -"
  ];

  virtualisation.oci-containers.containers.grafana = {
    autoStart = true;
    image = "docker.io/grafana/grafana-oss:${grafanaVersion}";
    user = "grafana:grafana";
    ports = [ "8082:3000/tcp" ];

    extraOptions = [
      "--add-host=host.containers.internal:host-gateway"
    ];

    environmentFiles = [
      config.sops.secrets."grafana-oauth-env".path
    ];

    environment = {
      GF_PATHS_PROVISIONING = "/etc/grafana/provisioning";
      GF_PATHS_DATA = "/var/lib/grafana";
      GF_PATHS_CONFIG = "/etc/grafana/grafana.ini";
      # Disable Portunus LDAP; Zitadel OIDC is configured via sops env file.
      GF_AUTH_LDAP_ENABLED = "false";
      GF_AUTH_DISABLE_LOGIN_FORM = "false";
    };

    volumes = [
      "/etc/passwd:/etc/passwd:ro"
      "/etc/group:/etc/group:ro"
      "/grafana/data:/var/lib/grafana"
      "/grafana/conf/grafana.ini:/etc/grafana/grafana.ini:ro"
      "${etcPath "grafana/provisioning/datasources/prometheus.yaml"}:/etc/grafana/provisioning/datasources/prometheus.yaml:ro"
      "${etcPath "grafana/provisioning/dashboards/ace.yaml"}:/etc/grafana/provisioning/dashboards/ace.yaml:ro"
      "${etcPath "grafana/dashboards/ace-overview.json"}:/etc/grafana/dashboards/ace-overview.json:ro"
      "${etcPath "grafana/dashboards/ace-services.json"}:/etc/grafana/dashboards/ace-services.json:ro"
    ];
  };
}
