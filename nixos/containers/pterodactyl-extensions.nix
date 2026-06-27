{ config, pkgs, lib, ... }:

let
  routerSshConfig = pkgs.writeText "pterodactyl-portforward-ssh-config" ''
    Host astracap
      HostName 192.168.5.1
      User prestonh
      IdentityFile /run/secrets/pterodactyl-router-ssh-key
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
          echo "PORTFORWARD_SSH_KEY_FILE=/run/secrets/pterodactyl-router-ssh-key" >> /pterodactyl/secrets/blueprint-extensions.env
        fi
        if [ -f /run/secrets/pterodactyl-technitium-api-token ]; then
          echo "TECHNITIUM_API_TOKEN_FILE=/run/secrets/pterodactyl-technitium-api-token" >> /pterodactyl/secrets/blueprint-extensions.env
        fi
        chown pterodactyl:pterodactyl /pterodactyl/secrets/blueprint-extensions.env
        chmod 0640 /pterodactyl/secrets/blueprint-extensions.env
      '';
    };
  };
}
