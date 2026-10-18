{ ... }:
let
  alertingDir = ./grafana/provisioning/alerting;
in {
  environment.etc."grafana/provisioning/alerting/alert-rules.yaml".source =
    "${alertingDir}/alert-rules.yaml";
  environment.etc."grafana/provisioning/alerting/notification-policies.yaml".source =
    "${alertingDir}/notification-policies.yaml";
}
