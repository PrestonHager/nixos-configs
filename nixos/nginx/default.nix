{ config, ... }:

{
  # Comment or uncomment the following imports to customize nginx
  imports = [
    # Reverse proxy configuration
    ./reverse-proxy.nix
  ];
}
