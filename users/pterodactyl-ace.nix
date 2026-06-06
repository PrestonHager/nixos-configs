{ config, ... }:

# NOTE: This is a host specific configuration file for the pterodactyl user
# which is to be used on a headless host with samba shares enabled.

{
  users.users."pterodactyl" = {
    isSystemUser = true;
    description = "Pterodactyl";
    group = "pterodactyl";
    extraGroups = [ "sambashare" ];
  };
}


