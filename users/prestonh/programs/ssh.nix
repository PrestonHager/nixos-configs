{ config, ... }:

{
  # Cisco LAN devices (IOS 15.x) need legacy algorithms and a 2048-bit RSA key.
  programs.ssh = {
    enable = true;
    matchBlocks = {
      astracap = {
        hostname = "192.168.5.1";
        user = "prestonh";
        identitiesOnly = true;
        identityFile = "~/.ssh/id_rsa_astracap";
        extraOptions = {
          IdentityAgent = "none";
          KexAlgorithms = "+diffie-hellman-group14-sha1";
          HostKeyAlgorithms = "+ssh-rsa";
          PubkeyAcceptedAlgorithms = "+ssh-rsa";
        };
      };
      astraquasar = {
        hostname = "192.168.5.3";
        user = "admin";
        identitiesOnly = true;
        identityFile = "~/.ssh/id_rsa_astracap";
        extraOptions = {
          IdentityAgent = "none";
          KexAlgorithms = "+diffie-hellman-group14-sha1";
          HostKeyAlgorithms = "+ssh-rsa";
          PubkeyAcceptedAlgorithms = "+ssh-rsa";
        };
      };
    };
  };
}
