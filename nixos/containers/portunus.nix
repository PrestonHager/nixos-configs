{ config, ... }:

{
  # Create the portunus user and group
  users.users.portunus = {
    isSystemUser = true;
    description = "Portunus";
    group = "portunus";
  };
  users.groups.portunus = {};

  # Create the ldap user and grou
  users.users.ldap = {
    isSystemUser = true;
    description = "LDAP";
    group = "ldap";
  };
  users.groups.ldap = {};

  # Create the data directory
  systemd.tmpfiles.rules = [
    "d /portunus/lib/portunus 0770 portunus portunus -"
  ];

  # open the firewall for ldaps port
  networking.firewall.allowedTCPPorts = [
    636
  ];

  # Define the container
  virtualisation.oci-containers.containers."portunus" = {
    autoStart = true;

    # <hostPort>:<containerPort>
    ports = [
      "8086:8080"
      "636:636"
    ];

    # User and group to run the container as
    user = "root:root";

    # Volumes to make persistent in the host/container
    volumes = [
      "/etc/passwd:/etc/passwd:ro"
      "/etc/group:/etc/group:ro"
      "/portunus/lib/portunus:/var/lib/portunus"
      "/portunus/passwords:/secrets/passwords"
      "/var/lib/acme/portunus.prestonhager.com:/var/lib/acme"
    ];

    environment = {
      PORTUNUS_LDAP_SUFFIX = "dc=prestonhager,dc=com";
      PORTUNUS_SLAPD_TLS_CERTIFICATE = "/var/lib/acme/fullchain.pem";
      PORTUNUS_SLAPD_TLS_CA_CERTIFICATE = "/var/lib/acme/ca.merged.pem";
      PORTUNUS_SLAPD_TLS_PRIVATE_KEY = "/var/lib/acme/key.pem";
      PORTUNUS_SLAPD_TLS_DOMAIN_NAME = "portunus.prestonhager.com";
    };

    # Finally, the portunus image and version
    #image = "docker.io/prestonhager/portunus:v1.0.0";
    image = "localhost/portunus:v1.0.1";
  };
}

