{ pkgs, lib }:

let
  migrateSrc = lib.cleanSourceWith {
    src = ./.;
    filter = path: type:
      type == "directory"
      || lib.hasSuffix ".py" path
      || lib.hasSuffix ".sh" path
      || lib.hasSuffix ".example" path
      || lib.hasSuffix "README.md" path
      || baseNameOf path == "lib"
      || baseNameOf path == "icloud"
      || baseNameOf path == "onedrive";
    name = "nextcloud-migrate";
  };
in
pkgs.writeShellScriptBin "nextcloud-migrate" ''
  export PATH="${lib.makeBinPath [
    pkgs.rclone
    pkgs.icloudpd
    pkgs.podman
    pkgs.python3
  ]}:$PATH"
  exec ${pkgs.python3}/bin/python3 ${migrateSrc}/migrate.py "$@"
''
