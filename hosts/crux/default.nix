{ config, ... }:

{
  # Specify the networking IP address and hostname for this machine
  networking = {
    hostName = "crux";
    interfaces.enp0s31f6 = {
      ipv4.addresses = [{
        address = "192.168.5.6";
        prefixLength = 24;
      }];
    };
  };
}
