{ config, inputs, ... }:

{
  imports = [
    inputs.disko.nixosModules.disko
    ./disko.nix
    ./hardware.nix
    ../../nixos/monitoring/promtail.nix
  ];

  # Keep disko.devices in git for future nixos-anywhere; never format on switch.
  disko.enableConfig = false;

  # Ace hops to this bootstrap host with /root/.ssh/id_rsa.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCH9c0aXFRwcAbO0+kCzmifsNdu+HC0v4Y43uNkpJrPgadS2QHCUFyf6VqJhEmgXtrggNeoRC+QJ/0yu5sYLDtPLltegONmz0fNiJ4XQ2kie0/HNkdn06JhRWU/SvOxDxuf3lmB9/BarLcl4vJ5FSTu3sNA9qHN/fCYFqKKED+uHacLTDM0QNDLj1hdSoSMv96vDyBjUO9DIwav97snH6cAbcd8ZG9YpZxqWO76/nbN+8yejhTCAElDOcB62B68nC4E9vjGTyg2t7czOAebmL/Sjvbe8WyWLe7kHbtyLvqt1GYG2z0/rMmqe93MD7s7tPFw+TqCkSws0F7CdFarYY8AZ2F+QHT6ixWG+jZoNXxkcMVEuZTrPTCjzEcrgodoFBe60Crsl5Zl8Bf6+j9hHCtGKQ/WJFwfLr4mLvS3YlseiJh9dgrS1AHsyCRZ/sVKY2JukugjAUZygvO7ld60rH88rCqLsUG4/8Xl44yqYH3JuOevw/fCPOJ2ZSt7yl2qOYk= root@ph-nixos"
  ];

  networking = {
    hostName = "elara";
    useDHCP = false;
    interfaces.eno1 = {
      useDHCP = false;
      ipv4.addresses = [{
        address = "192.168.5.8";
        prefixLength = 24;
      }];
    };
    defaultGateway = "192.168.5.1";
    nameservers = [ "192.168.5.5" "1.1.1.1" ];
    hosts = {
      "192.168.5.5" = [
        "panel.prestonhager.com"
        "ace.internal.prestonhager.com"
      ];
      "192.168.5.8" = [ "elara.internal.prestonhager.com" ];
    };
  };
}
