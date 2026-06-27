{ config, ... }:

{
  # Cisco LAN devices (IOS 15.x) need legacy KEX and a 2048-bit RSA key from
  # Bitwarden CLI (`bw ssh-agent`); see docs/network-ssh-ace.md.
  programs.ssh = {
    enable = true;
    enableAgent = true;
    matchBlocks = {
      astracap = {
        hostname = "192.168.5.1";
        user = "prestonh";
        extraOptions = {
          KexAlgorithms = "+diffie-hellman-group14-sha1";
          HostKeyAlgorithms = "+ssh-rsa";
          PubkeyAcceptedAlgorithms = "+ssh-rsa";
        };
      };
      astraquasar = {
        hostname = "192.168.5.3";
        user = "admin";
        extraOptions = {
          KexAlgorithms = "+diffie-hellman-group14-sha1";
          HostKeyAlgorithms = "+ssh-rsa";
          PubkeyAcceptedAlgorithms = "+ssh-rsa";
        };
      };
    };
  };
}
