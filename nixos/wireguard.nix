{ config, ... }:

{
  # The WireGuard interface lives inside the wg-portal Podman container's
  # network namespace, not on the host, so the host has no wg0 device and
  # these options used to generate nothing. Masquerading and forwarding for
  # the tunnel are handled by the wg-portal-sidecar unit (see
  # nixos/containers/wg-portal-scripts.nix), which resolves the container veth
  # at runtime and targets bond0 -- the LACP aggregate that actually carries
  # 192.168.5.0/24.
  networking.nat = {
    enable = true;
    externalInterface = "bond0";
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

