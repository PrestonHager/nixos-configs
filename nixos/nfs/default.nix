{ config, pkgs, lib ? pkgs.lib, ... }:

let
  nodes = {
    crux = {
      ip = "192.168.5.6";
      domain = "crux.lc1.nm.us.prestonhager.com";
    };
    nova = {
      ip = "192.168.5.7";
      domain = "nova.lc1.nm.us.prestonhager.com";
    };
    elara = {
      ip = "192.168.5.8";
      domain = "elara.lc1.nm.us.prestonhager.com";
    };
    zenith = {
      ip = "192.168.5.9";
      domain = "zenith.lc1.nm.us.prestonhager.com";
    };
  };
  nodeNames = builtins.attrNames nodes;
  # Only nodes that exist get an export and an NFS firewall hole: nova and
  # zenith are not connected, and anything that took over their addresses
  # would otherwise be handed their TLS keys. Caddy still writes all four
  # certificate directories (nixos/caddy/certificates.nix).
  activeNodes = [ "crux" "elara" ];
  active = lib.getAttrs activeNodes nodes;
in {
  fileSystems = lib.mapAttrs' (name: _:
    lib.nameValuePair "/export/pterodactyl-${name}" {
      device = "/stor/shares/private/nodes/${name}/letsencrypt";
      fsType = "none";
      options = [ "bind" "ro" ];
    }
  ) active;

  systemd.tmpfiles.rules =
    [
      "d /stor/shares/private 0750 994 100 - -"
    ]
    ++ lib.concatLists (map (name: [
      "d /stor/shares/private/nodes/${name} 0750 994 100 - -"
      "d /stor/shares/private/nodes/${name}/letsencrypt 0775 root users - -"
    ]) nodeNames);

  services.nfs.server = {
    enable = true;
    # root_squash: nothing on a node reads the share as root. Wings runs as
    # the pterodactyl user and reads its 0640 root:users key through its
    # `users` group (gid 100, not squashed); link-letsencrypt only mounts the
    # share and checks that the 0775 directories exist.
    exports = lib.concatStringsSep "\n" (map (name:
      "/export/pterodactyl-${name} ${nodes.${name}.ip}(ro,sync,root_squash,no_subtree_check)"
    ) activeNodes);
  };

  # NFSv4 for the active Wings nodes only.
  networking.firewall.extraCommands = lib.mkAfter (lib.concatMapStrings (name: ''
    iptables -A nixos-fw -p tcp -s ${nodes.${name}.ip} --dport 2049 -j nixos-fw-accept
  '') activeNodes);
}
