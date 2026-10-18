{ config, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
in
{
  sops.secrets = {
    "vaultwarden-environment" = {
      sopsFile = "${sops-path}/secrets/containers/vaultwarden.yaml";
    };
  };

  # Create the vaultwarden user and group
  users.users.vaultwarden = {
    isSystemUser = true;
    description = "Vaultwarden";
    group = "vaultwarden";
  };
  users.groups.vaultwarden = {};

  # Create the data directory
  systemd.tmpfiles.rules = [
    "d /vw-data 0770 vaultwarden vaultwarden -"
  ];

  # Define the container
  virtualisation.oci-containers.containers."vaultwarden" = {
    autoStart = true;

    # <hostPort>:<containerPort>. Loopback only: netavark DNATs published ports ahead
    # of nixos-fw, so 0.0.0.0 would expose Vaultwarden to the LAN. Caddy is the only client.
    ports = [
      "127.0.0.1:8081:8081"
    ];

    # User and group to run the container as
    user = "vaultwarden:vaultwarden";

    # Volumes to make persistent in the host/container
    volumes = [
      "/etc/passwd:/etc/passwd:ro"
      "/etc/group:/etc/group:ro"
      "/vw-data/:/data/"
    ];

    environment = {
      ROCKET_PORT = "8081";
      VOLUME = "/data";
      # All users are added; new accounts by invitation only.
      SIGNUPS_ALLOWED = "false";
#      INVITATIONS_ALLOWED = "false";
      # Or whitelist specific email domains
#      SIGNUPS_DOMAINS_WHITELIST = "example.com";
    };

    extraOptions = [
      "--env-file=${config.sops.secrets."vaultwarden-environment".path}"
    ];

    # Finally, the vaultwarden image and version
    image = "ghcr.io/dani-garcia/vaultwarden:1.37.4";
  };
}

