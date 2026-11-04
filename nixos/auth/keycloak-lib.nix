# Keycloak facts shared by the container on ace (nixos/containers/keycloak.nix)
# and the server-login module (nixos/auth/sso-login.nix). Not a module:
#   let kc = import ./keycloak-lib.nix; in ...
rec {
  domain = "keycloak.prestonhager.com";
  realm = "homelab";
  issuer = "https://${domain}/realms/${realm}";
  # Caddy on ace terminates TLS for Keycloak. Servers pin the name to this
  # address in /etc/hosts so logins do not depend on LAN DNS.
  aceAddress = "192.168.5.5";

  # Public client for `opkssh login` (SSH keys carrying a Keycloak ID token).
  opksshClientId = "opkssh";
  # Confidential client SSSD uses for user/group lookups (service account)
  # and the device-code prompt for sudo.
  sssdClientId = "sssd";

  # Realm groups. Group names become POSIX groups on the servers through SSSD,
  # so never create a Keycloak group whose name a local group already has
  # (wheel, docker, users, ...): the local one wins and the grant is lost.
  allServersGroup = "srv-all";
  hostGroup = host: "srv-${host}";
  sudoFullGroup = "sudo-full";
  sudoRebuildGroup = "sudo-rebuild";

  # Hosts that get a srv-<host> group in the first realm import. Groups for
  # hosts added later are created in the admin console.
  serverHosts = [ "ace" "mars" "crux" "elara" "nova" "zenith" ];
}
