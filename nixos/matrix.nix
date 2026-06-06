{ config, ... }:

{
  services.matrix-conduit = {
    enable = true;
    settings.global = {
      server_name = "matrix.prestonhager.com";
      trusted_servers = [
        "matrix.org"
        "nixos.org"
      ];
      port = 6167;
    };
  };
}

