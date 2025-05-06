{ config, ... }:

{
  networking.nat = {
    enable = true;
    externalInterface = "eno1";
    internalInterfaces = [ "wg0" ];
  };

  #networking.wireguard.interfaces = {
  #  wg0 = {
  #    ips = [ "192.168.2.0/24" ];
  #    listenPort = 51825;

  #    # This allows the wireguard server to route your traffic to the internet and hence be like a VPN
  #    # For this to work you have to set the dnsserver IP of your router (or dnsserver of choice) in your clients
  #    postSetup = ''
  #      ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 10.100.0.0/24 -o eth0 -j MASQUERADE
  #    '';

  #    # This undoes the above command
  #    postShutdown = ''
  #      ${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING -s 10.100.0.0/24 -o eth0 -j MASQUERADE
  #    '';

  #    privateKeyFile = "/srv/wireguard/key";
  #  };
  #};
}

