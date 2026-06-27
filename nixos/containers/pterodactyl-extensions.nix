{ config, pkgs, lib, ... }:

let
  routerSshUser = "pterofwd";
  containerKeyPath = "/pterodactyl/secrets/pterodactyl-router-ssh-key";
  routerSshConfig = pkgs.writeText "pterodactyl-portforward-ssh-config" ''
    Host astracap
      HostName 192.168.5.1
      User ${routerSshUser}
      IdentityFile ${containerKeyPath}
      IdentitiesOnly yes
      KexAlgorithms +diffie-hellman-group14-sha1
      HostKeyAlgorithms +ssh-rsa
      PubkeyAcceptedAlgorithms +ssh-rsa
      StrictHostKeyChecking accept-new
  '';
in
{
  systemd.tmpfiles.rules = [
    "d /pterodactyl/secrets 0750 pterodactyl pterodactyl -"
    "L+ /pterodactyl/secrets/portforward-ssh-config - - - - ${routerSshConfig}"
  ];

  systemd.services.pterodactyl-blueprint-extensions-env = {
    description = "Write Pterodactyl Blueprint extension environment file";
    wantedBy = [ "multi-user.target" ];
    after = [ "sops-nix.service" ];
    requires = [ "sops-nix.service" ];
    before = [ "podman-pterodactyl.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "pterodactyl-blueprint-extensions-env" ''
        install -d -m 0750 -o pterodactyl -g pterodactyl /pterodactyl/secrets
        cat > /pterodactyl/secrets/blueprint-extensions.env <<'EOF'
PORTFORWARD_SSH_CONFIG_FILE=/pterodactyl/secrets/portforward-ssh-config
TECHNITIUM_API_URL=http://host.containers.internal:5380
EOF
        if [ -f /run/secrets/pterodactyl-router-ssh-key ]; then
          install -m 0600 -o pterodactyl -g pterodactyl \
            /run/secrets/pterodactyl-router-ssh-key ${containerKeyPath}
          echo "PORTFORWARD_SSH_KEY_FILE=${containerKeyPath}" >> /pterodactyl/secrets/blueprint-extensions.env
        else
          rm -f ${containerKeyPath}
        fi
        if [ -f /run/secrets/pterodactyl-technitium-api-token ]; then
          install -m 0600 -o pterodactyl -g pterodactyl \
            /run/secrets/pterodactyl-technitium-api-token /pterodactyl/secrets/pterodactyl-technitium-api-token
          echo "TECHNITIUM_API_TOKEN_FILE=/pterodactyl/secrets/pterodactyl-technitium-api-token" >> /pterodactyl/secrets/blueprint-extensions.env
        else
          rm -f /pterodactyl/secrets/pterodactyl-technitium-api-token
        fi
        chown pterodactyl:pterodactyl /pterodactyl/secrets/blueprint-extensions.env
        chmod 0640 /pterodactyl/secrets/blueprint-extensions.env
      '';
    };
  };
}
