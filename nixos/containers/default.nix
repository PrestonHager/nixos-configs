{ config, pkgs, ... }:

{
  imports = [
    # Import specific Podman or Docker containers here
    # Be sure not to mix podman and docker configurations, and set your backend
    # properly in the virtualisation.oci-containers.backend varaible correctly.
    #./forgejo.nix
    ./grafana.nix
    ./jellyfin.nix
    ./mediawiki.nix
    # ./nextcloud-aio.nix (disabled; use nextcloud.nix)
    ./nextcloud.nix
    #./phorge.nix
    ./prometheus.nix
    ./pterodactyl.nix
    ./pterodactyl-test.nix
    #./spacetimedb.nix
    #./sui.nix
    ./vaultwarden.nix
    ./wg-portal.nix
    ./technitium.nix
    ./lancache.nix
    ./zitadel.nix
  ];

  # Enable Podman (or Docker) for use with oci-containers
  virtualisation = {
    containers.enable = true;
    podman = {
      enable = true;
      dockerCompat = true;
    };
  };

  # Some helpful packages, comment these out if they aren't needed
  environment.systemPackages = with pkgs; [
    dive # look into docker image layers
    podman-tui # status of containers in the terminal
  ];

  # The underlying Docker implementation to use
  # default is "podman", you can also use "docker"
  virtualisation.oci-containers.backend = "podman";
}


