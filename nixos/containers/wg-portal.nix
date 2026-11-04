{ config, lib, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  # Rendered from the sops config before every start (see preStart below).
  renderedConfig = "/run/wg-portal/config.yaml";

  # OIDC login through Keycloak (client `wg-portal`, provider id `keycloak`).
  # false keeps the old Zitadel provider; flip only once keycloak-realm-sync
  # has created the client.
  useKeycloak = false;
  kcIssuer = "https://keycloak.prestonhager.com/realms/homelab";
  idpDomain = if useKeycloak then "keycloak.prestonhager.com" else "zitadel.prestonhager.com";

  # The sops config still describes the Zitadel provider. Its client secret is
  # reused for Keycloak (the realm sync sets the `wg-portal` client to it).
  zitadelEntry = ''(.auth.oidc[] | select(.id == "zitadel"))'';
  # Accounts are keyed by preferred_username (the Keycloak username), so the
  # existing prestonh/dylanh accounts are reused; wg-portal just adds an
  # oauth/keycloak authentication to them on the first login.
  keycloakProvider = builtins.toJSON {
    id = "keycloak";
    provider_name = "keycloak";
    display_name = "Login with Keycloak";
    base_url = kcIssuer;
    client_id = "wg-portal";
    extra_scopes = [ "email" "profile" "groups" ];
    use_pkce = true;
    pkce_method = "S256";
    registration_enabled = true;
    logout_idp_session = true;
    field_map = {
      user_identifier = "preferred_username";
      email = "email";
      firstname = "given_name";
      lastname = "family_name";
      user_groups = "groups";
    };
    admin_mapping.admin_group_regex = "^wg-admin$";
  };
  # Zitadel: its urn:zitadel:iam:org:project:roles claim is an object keyed by
  # role, which wg-portal cannot read as a group list, so read the flat
  # `groups` claim from the homelabGroups action and match `wg-admin`.
  zitadelPatch = [
    ''(.auth.oidc[] | select(.id == "zitadel") | .field_map.user_groups) = "groups"''
    ''(.auth.oidc[] | select(.id == "zitadel") | .admin_mapping.admin_group_regex) = "^wg-admin$"''
  ];
  keycloakPatch = [
    ''.auth.oidc = [ ${keycloakProvider} * {"client_secret": (${zitadelEntry} | .client_secret)} ]''
  ];
  # Read by keycloak-realm-sync (homelab.keycloak.clients.wg-portal.secret).
  keycloakEnv = "/run/wg-portal-keycloak/client.env";
  #
  # The web session and CSRF secrets are generated on ace (not taken from sops)
  # so ace-secret-rotate can roll them; see docs/secret-rotation.md.
  webSecretsDir = "/var/lib/wg-portal-secrets";
  oidcPatch = lib.concatStringsSep " | " ((if useKeycloak then keycloakPatch else zitadelPatch) ++ [
    ''.web.session_secret = load_str("${webSecretsDir}/session")''
    ''.web.csrf_secret = load_str("${webSecretsDir}/csrf")''
  ]);
in
{
  homelab.keycloak.clients.wg-portal = {
    name = "WireGuard Portal";
    redirectUris = [ "https://wg.prestonhager.com/api/v0/auth/login/keycloak/callback" ];
    postLogoutRedirectUris = [ "https://wg.prestonhager.com/*" ];
    secret = { file = keycloakEnv; key = "WG_PORTAL_OIDC_CLIENT_SECRET"; };
  };
  homelab.keycloak.testUser.groups = [ "wg-admin" ];

  # The client secret lives inside the wg-portal YAML; the realm sync wants a
  # KEY=VALUE file. Extract it before every sync.
  systemd.services.wg-portal-keycloak-env = {
    description = "Extract the wg-portal OIDC client secret for keycloak-realm-sync";
    after = [ "sops-nix.service" ];
    before = [ "keycloak-realm-sync.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
      RuntimeDirectory = "wg-portal-keycloak";
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = true;
    };
    script = ''
      secret=$(${pkgs.yq-go}/bin/yq ${lib.escapeShellArg ''${zitadelEntry} | .client_secret''} \
        ${config.sops.secrets."wg-portal-config".path})
      if [ -z "$secret" ] || [ "$secret" = null ]; then
        echo "wg-portal-keycloak-env: no client_secret for the zitadel provider in wg-portal-config" >&2
        exit 1
      fi
      printf 'WG_PORTAL_OIDC_CLIENT_SECRET=%s\n' "$secret" > ${keycloakEnv}.tmp
      mv -f ${keycloakEnv}.tmp ${keycloakEnv}
    '';
  };
  systemd.services.keycloak-realm-sync = {
    wants = [ "wg-portal-keycloak-env.service" ];
    after = [ "wg-portal-keycloak-env.service" ];
  };

  sops.secrets = {
    "wg-portal-config" = {
      sopsFile = "${sops-path}/secrets/containers/wg-portal-config.yaml";
      restartUnits = [ "podman-wg-portal.service" "wg-portal-keycloak-env.service" ];
    };
  };

  systemd.services.podman-wg-portal.preStart = lib.mkBefore ''
    install -d -m 0700 /run/wg-portal ${webSecretsDir}
    umask 077
    for f in session csrf; do
      if [ ! -s ${webSecretsDir}/$f ]; then
        od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > ${webSecretsDir}/$f.tmp
        mv -f ${webSecretsDir}/$f.tmp ${webSecretsDir}/$f
      fi
    done
    ${pkgs.yq-go}/bin/yq ${lib.escapeShellArg oidcPatch} \
      ${config.sops.secrets."wg-portal-config".path} > ${renderedConfig}.tmp
    mv -f ${renderedConfig}.tmp ${renderedConfig}
  '';

  imports = [
    ./wg-portal-scripts.nix
  ];

  # Create the wireguard user and group
  users.users = {
    wireguard = {
      isSystemUser = true;
      group = "wireguard";
    };
    wg-portal = {
      isSystemUser = true;
      description = "Wireguard Portal";
      group = "wg-portal";
      extraGroups = [ "wireguard" ];
    };
  };
  users.groups = {
    wireguard = {};
    wg-portal = {};
  };

  # open the firewall for wireguard port
  networking.firewall.allowedUDPPorts = [
    51825
  ];

  # Setup NAT forwarding from the wireguard interface to the local network.
  #networking.firewall.extraCommands = ''
  #  iptables -t nat -A POSTROUTING -s 192.168.20.0/24 -o eno1 -j MASQUERADE
  #  iptables -t nat -A POSTROUTING -s 192.168.20.0/24 -o eno3 -j MASQUERADE
  #  iptables -A FORWARD -s 192.168.20.0/24 -d 192.168.8.0/24 -j ACCEPT
  #  iptables -A FORWARD -s 192.168.8.0/24 -d 192.168.20.0/24 -j ACCEPT
  #'';

  # wg-portal creates wg0 itself; load the module on the host instead of granting
  # the container CAP_SYS_MODULE.
  boot.kernelModules = [ "wireguard" ];

  # Create the data directory. wg0.conf holds the interface PrivateKey: keep it 0600.
  systemd.tmpfiles.rules = [
    "d /srv/wireguard/etc 0770 wireguard wireguard -"
    "z /srv/wireguard/etc/wg0.conf 0600 root root -"
    "d /srv/wireguard/data 0770 wireguard wireguard -"
  ];

  # Define the container
  virtualisation.oci-containers.containers."wg-portal" = {
    autoStart = true;

    # Add wireguard and web portal ports
    ports = [
      "51825:51825/udp"
      # Web UI: Caddy only. Metrics: Caddy plus Prometheus via the podman0 gateway.
      # Not 0.0.0.0: netavark DNATs ahead of nixos-fw.
      "127.0.0.1:8888:8888/tcp"
      "127.0.0.1:8787:8787/tcp"
      "10.88.0.1:8787:8787/tcp"
    ];

    # Add network admin capabilities and use the host network
    extraOptions = [
      #"--network=host"
      "--cap-add=NET_ADMIN"
      # No SYS_MODULE: the wireguard module is loaded by the host (boot.kernelModules
      # above), so the container cannot load arbitrary kernel modules.
      #"--cap-add=NET_RAW"
      # Host /etc/hosts maps the vhost to 127.0.0.1, which is the container's own
      # loopback; point it at Caddy on the host so the OIDC login works.
      "--add-host=${idpDomain}:host-gateway"
      # The image declares VOLUME /app/config; only config.yaml is bind-mounted,
      # so every run created an anonymous volume. Back image volumes with tmpfs.
      "--image-volume=tmpfs"
    ];

    # User and group to run the container as
    #user = "wg-portal:wg-portal";
    user = "root:root";

    # Volumes to make persistent in the host/container
    volumes = [
      "/etc/passwd:/etc/passwd:ro"
      "/etc/group:/etc/group:ro"
      "/srv/wireguard/etc/:/etc/wireguard/"
      "/srv/wireguard/data/:/app/data"
      "${renderedConfig}:/app/config/config.yaml:ro"
    ];

    environment = {
    };

    # Finally, the wireguard image and version
    image = "docker.io/wgportal/wg-portal:v2.3.1";
  };

  # wg-portal (root in the container) rewrites wg0.conf when peers change, and it has
  # been written world-readable before. Re-tighten it whenever it changes, not only at
  # boot/activation via tmpfiles.
  systemd.paths.wg-portal-conf-perms = {
    wantedBy = [ "multi-user.target" ];
    pathConfig.PathChanged = "/srv/wireguard/etc/wg0.conf";
  };
  systemd.services.wg-portal-conf-perms = {
    description = "Restrict wg0.conf (WireGuard private key) to root";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "-${pkgs.coreutils}/bin/chmod 0600 /srv/wireguard/etc/wg0.conf";
    };
  };
}
