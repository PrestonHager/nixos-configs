{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
in
{
  sops.secrets = {
    "zitadel-config" = {
      sopsFile = "${sops-path}/secrets/containers/zitadel-config.yaml";
    };
  };

  # Create the zitadel user and group
  users.users = {
    zitadel = {
      isSystemUser = true;
      description = "Zitadel";
      group = "zitadel";
    };
  };

  users.groups = {
    zitadel = {};
  };

  # Create the data directory
  systemd.tmpfiles.rules = [
    "d /zitadel/data 0770 zitadel zitadel -"
  ];

  # Systemd service to create the pod required by podman containers
  systemd.services.pod-zitadel = {
    description = "Start podman's 'zitadel' pod";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    requiredBy = [
      "podman-zitadel.service"
      "podman-zitadel-login.service"
      "podman-zitadel-db.service"
    ];
    unitConfig = {
      RequiresMountsFor = "/run/containers";
    };
    serviceConfig = {
      Type = "oneshot";
      Restart = "no";
      ExecStart = pkgs.writeShellScript "pod-zitadel" ''
        ${pkgs.podman}/bin/podman pod exists zitadel || \
        ${pkgs.podman}/bin/podman pod create -p 9080:8080 \
          --memory 8G --cpus 0 zitadel
      '';
    };
    path = [ pkgs.podman ];
  };

  # Define the container
  virtualisation.oci-containers.containers."zitadel" = {
    autoStart = true;

    # User and group to run the container as
    user = "zitadel:zitadel";

    # Volumes to make persistent in the host/container
    volumes = [
      "/etc/passwd:/etc/passwd:ro"
      "/etc/group:/etc/group:ro"
    ];

    environment = {
    };

    extraOptions = [
      "--pod=zitadel"
      "--env-file=/zitadel/.env"
    ];

    healthcheck = {
      test = [
        "CMD"
        "/app/zitadel"
        "ready"
      ];
      interval = "10s";
      timeout = "60s";
      retries = 5;
      startPeriod = "10s";
    };

    # Finally, the zitadel image and version
    image = "ghcr.io/zitadel/zitadel:latest";
  };
}


