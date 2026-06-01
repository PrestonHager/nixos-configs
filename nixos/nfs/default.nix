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
  };
  nodeNames = builtins.attrNames nodes;
in {
  fileSystems = lib.mapAttrs' (name: _:
    lib.nameValuePair "/export/pterodactyl-${name}" {
      device = "/stor/shares/private/nodes/${name}/letsencrypt";
      fsType = "none";
      options = [ "bind" "ro" ];
    }
  ) nodes;

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
    exports = lib.concatStringsSep "\n" (map (name:
      "/export/pterodactyl-${name} ${nodes.${name}.ip}(ro,sync,no_root_squash,no_subtree_check)"
    ) nodeNames);
  };

  networking.firewall.allowedTCPPorts = [ 2049 ];
}
