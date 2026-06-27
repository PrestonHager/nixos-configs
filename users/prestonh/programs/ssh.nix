{ config, ... }:

{
  # Cisco LAN devices (IOS 15.x) need legacy KEX and a 2048-bit RSA key from
  # Bitwarden CLI (`bw ssh-agent`); see docs/network-ssh-ace.md.
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings = {
      "*" = {
        ForwardAgent = false;
        AddKeysToAgent = "no";
        Compression = false;
        ServerAliveInterval = 0;
        ServerAliveCountMax = 3;
        HashKnownHosts = false;
        UserKnownHostsFile = "~/.ssh/known_hosts";
        ControlMaster = "no";
        ControlPath = "~/.ssh/master-%r@%n:%p";
        ControlPersist = "no";
      };
      astracap = {
        HostName = "192.168.5.1";
        User = "prestonh";
        KexAlgorithms = "+diffie-hellman-group14-sha1";
        HostKeyAlgorithms = "+ssh-rsa";
        PubkeyAcceptedAlgorithms = "+ssh-rsa";
      };
      astraquasar = {
        HostName = "192.168.5.3";
        User = "admin";
        KexAlgorithms = "+diffie-hellman-group14-sha1";
        HostKeyAlgorithms = "+ssh-rsa";
        PubkeyAcceptedAlgorithms = "+ssh-rsa";
      };
    };
  };
}
