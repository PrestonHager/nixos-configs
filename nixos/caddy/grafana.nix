{ config, ... }:

{
  services.caddy = {
    virtualHosts."grafana.prestonhager.com".extraConfig = ''
      # Prometheus scrapes Grafana on the podman0 gateway; keep metrics off the internet.
      @metrics path /metrics /metrics/*
      respond @metrics 404
      reverse_proxy http://127.0.0.1:8082
    '';
  };
}

