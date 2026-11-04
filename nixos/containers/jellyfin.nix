{ config, lib, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  # Pinned for ace-service-auto-update nix-bump (do not use :latest pulls).
  # The tag stays (nix-bump rewrites it); 12.4 was tested as
  # docker.io/jellyfin/jellyfin@sha256:fea863d0cd9ec445985d9c75fc6ed64e38a1d2766cf0c250a33d553f4fc1b771.
  jellyfinVersion = "12.4";
  jellyfinPublicUrl = "https://jellyfin.prestonhager.com";
  kc = import ../auth/keycloak-lib.nix;
  discoveryUri = "${kc.issuer}/.well-known/openid-configuration";
  # Keycloak client id (homelab.keycloak.clients.jellyfin below) and the SSO
  # plugin's provider name, which is also the last part of the start/callback
  # URLs (/sso/OID/start/keycloak, /sso/OID/redirect/keycloak).
  oidcClientId = "jellyfin";
  ssoProviderName = "keycloak";
  # Existing Jellyfin accounts that Keycloak users of the same username log in
  # to. Seeded as username-keyed links; on first login the plugin rekeys each
  # to the Keycloak sub. Any other existing local account (admin@prestonhager.com)
  # is never adopted by name (DisableUsernameAccountAdoption).
  linkedUsers = [ "prestonh" "dylanh" ];
  # Upstream 9p4/jellyfin-plugin-sso is archived at 4.0.0.4 (ABI 10.11). The
  # MaxRink fork's 6.x targets ABI 12.0 and reads the same SSO-Auth.xml schema
  # (same plugin GUID, assembly SSO-Auth.dll).
  ssoPluginVersion = "6.1.0.0";
  # Hash-pinned: the plugin DLL runs inside Jellyfin with its privileges. Update the
  # hash with nix-prefetch-url when bumping ssoPluginVersion.
  ssoPluginZip = pkgs.fetchurl {
    url = "https://github.com/MaxRink/jellyfin-plugin-sso/releases/download/v${ssoPluginVersion}/sso-auth_${ssoPluginVersion}.zip";
    hash = "sha256-YxHWsW6JqR5EzptaMsCdKO2ikqEbdc1rlC17xiZkzQA=";
  };
  # Jellyfin loads plugins from plugins/<Name>_<version>/ (dll + meta.json); the
  # name matches meta.json ("SSO-Auth"), as the Jellyfin catalog installer does.
  ssoPluginDir = "/jf/config/plugins/SSO-Auth_${ssoPluginVersion}";
  ssoConfigPath = "/jf/config/plugins/configurations/SSO-Auth.xml";
  jellyfinRuntimeEnv = "/run/jellyfin/container.env";
  jellyfinSsoSetupScript = pkgs.writeShellScript "jellyfin-sso-setup" ''
    set -euo pipefail
    podman=${pkgs.podman}/bin/podman
    oauthEnv="${config.sops.secrets."jellyfin-oauth-env".path}"

    for _ in $(seq 1 60); do
      if $podman exec jellyfin true 2>/dev/null; then
        break
      fi
      sleep 2
    done

    if ! $podman exec jellyfin true 2>/dev/null; then
      echo "jellyfin-sso-setup: jellyfin container not running" >&2
      exit 1
    fi

    clientSecret="$(grep '^KEYCLOAK_CLIENT_SECRET=' "$oauthEnv" | cut -d= -f2- || true)"
    if [ -z "$clientSecret" ] || [ "$clientSecret" = "REPLACE_ME" ]; then
      echo "jellyfin-sso-setup: KEYCLOAK_CLIENT_SECRET missing or placeholder, skipping" >&2
      exit 0
    fi

    # Drop other SSO plugin versions (the 9p4 "SSO Authentication_*" folders and
    # older "SSO-Auth_*" ones) so Jellyfin does not keep a disabled copy
    # alongside the current one.
    for d in /jf/config/plugins/"SSO Authentication"* /jf/config/plugins/SSO-Auth_*; do
      if [ -e "$d" ] && [ "$d" != "${ssoPluginDir}" ]; then
        rm -rf -- "$d"
      fi
    done

    if [ ! -f "${ssoPluginDir}/SSO-Auth.dll" ]; then
      echo "jellyfin-sso-setup: installing SSO Authentication plugin ${ssoPluginVersion}"
      mkdir -p "${ssoPluginDir}"
      ${pkgs.unzip}/bin/unzip -o ${ssoPluginZip} -d "${ssoPluginDir}"
      chown -R jellyfin:jellyfin "${ssoPluginDir}"
    fi

    # Canonical links: keep the ones the plugin recorded for this provider
    # (Keycloak sub -> user id), so rewriting the file below never unlinks
    # anyone, then seed username links for linkedUsers that have none yet.
    linkItem() { # linkItem <key> <guid>
      printf '\n          <item>\n            <key>\n              <string>%s</string>\n            </key>\n            <value>\n              <guid>%s</guid>\n            </value>\n          </item>' "$1" "$2"
    }
    canonicalLinks=""
    linkedGuids=" "
    if [ -f "${ssoConfigPath}" ]; then
      while read -r key guid; do
        # Subs are UUIDs and keys/guids go back into XML: accept only safe text.
        [[ "$key" =~ ^[A-Za-z0-9._@-]+$ && "$guid" =~ ^[0-9A-Fa-f-]{36}$ ]] || continue
        canonicalLinks+="$(linkItem "$key" "$guid")"
        linkedGuids+="''${guid^^} "
      done < <(${pkgs.xmlstarlet}/bin/xmlstarlet sel -t \
        -m "/PluginConfiguration/OidConfigs/item[key/string='${ssoProviderName}']/value/PluginConfiguration/CanonicalLinks/item" \
        -v key/string -o ' ' -v value/guid -n "${ssoConfigPath}" 2>/dev/null || true)
    fi
    for name in ${lib.escapeShellArgs linkedUsers}; do
      guid="$(${pkgs.sqlite}/bin/sqlite3 -readonly /jf/config/data/jellyfin.db "SELECT Id FROM Users WHERE Username='$name' LIMIT 1;" 2>/dev/null || true)"
      [[ "$guid" =~ ^[0-9A-Fa-f-]{36}$ ]] || continue
      case "$linkedGuids" in *" ''${guid^^} "*) continue ;; esac
      canonicalLinks+="$(linkItem "$name" "$guid")"
    done

    cat > "${ssoConfigPath}" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<PluginConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <SamlConfigs />
  <OidConfigs>
    <item>
      <key>
        <string>${ssoProviderName}</string>
      </key>
      <value>
        <PluginConfiguration>
          <OidEndpoint>${discoveryUri}</OidEndpoint>
          <OidClientId>${oidcClientId}</OidClientId>
          <OidSecret>''${clientSecret}</OidSecret>
          <Enabled>true</Enabled>
          <EnableAuthorization>true</EnableAuthorization>
          <EnableAllFolders>true</EnableAllFolders>
          <EnabledFolders />
          <PreserveAdminPermissions>false</PreserveAdminPermissions>
          <DisableUsernameAccountAdoption>true</DisableUsernameAccountAdoption>
          <AdminRoles>
            <string>jellyfin_admin</string>
          </AdminRoles>
          <Roles>
            <string>jellyfin_user</string>
            <string>jellyfin_admin</string>
          </Roles>
          <EnableFolderRoles>false</EnableFolderRoles>
          <EnableLiveTvRoles>false</EnableLiveTvRoles>
          <EnableLiveTv>false</EnableLiveTv>
          <EnableLiveTvManagement>false</EnableLiveTvManagement>
          <LiveTvRoles />
          <LiveTvManagementRoles />
          <FolderRoleMappings />
          <RoleClaim>groups</RoleClaim>
          <OidScopes>
            <string>openid</string>
            <string>email</string>
            <string>profile</string>
          </OidScopes>
          <DefaultProvider>Jellyfin.Server.Implementations.Users.DefaultAuthenticationProvider</DefaultProvider>
          <SchemeOverride>https</SchemeOverride>
          <NewPath>true</NewPath>
          <CanonicalLinks>''${canonicalLinks}
          </CanonicalLinks>
          <DefaultUsernameClaim>preferred_username</DefaultUsernameClaim>
          <DisableHttps>false</DisableHttps>
          <DoNotValidateEndpoints>false</DoNotValidateEndpoints>
          <DoNotValidateIssuerName>false</DoNotValidateIssuerName>
        </PluginConfiguration>
      </value>
    </item>
  </OidConfigs>
</PluginConfiguration>
EOF
    chown jellyfin:jellyfin "${ssoConfigPath}"
    chmod 640 "${ssoConfigPath}"

    brandingPath="/jf/config/config/branding.xml"
    # HTML in LoginDisclaimer must be entity-escaped; raw tags break Jellyfin's XML deserializer.
    cat > "$brandingPath" <<BRANDING
<?xml version="1.0" encoding="utf-8"?>
<BrandingOptions xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <LoginDisclaimer>&lt;form action="${jellyfinPublicUrl}/sso/OID/start/${ssoProviderName}"&gt;&lt;button class="raised block emby-button button-submit"&gt;Sign in with Keycloak&lt;/button&gt;&lt;/form&gt;</LoginDisclaimer>
  <CustomCss>a.raised.emby-button {
  padding: 0.9em 1em;
  color: inherit !important;
}
.loginDisclaimerContainer {
  display: block;
}</CustomCss>
  <SplashscreenEnabled>true</SplashscreenEnabled>
</BrandingOptions>
BRANDING
    chown jellyfin:jellyfin "$brandingPath"
    chmod 640 "$brandingPath"

    # Jellyfin holds plugin and branding config in memory (and the plugin
    # saves its in-memory copy back over the file), so a changed setting
    # only takes effect after a restart. Fingerprint what this script
    # controls (everything but the links the plugin records) and restart
    # Jellyfin when it changed. The restart re-runs this unit (Requires=),
    # which then finds the same fingerprint and stops there.
    stamp=/jf/config/.sso-setup-hash
    hash="$( { ${pkgs.xmlstarlet}/bin/xmlstarlet ed -d '//CanonicalLinks' "${ssoConfigPath}"; cat "$brandingPath"; } | sha256sum | cut -d' ' -f1)"
    if [ "$(cat "$stamp" 2>/dev/null || true)" != "$hash" ]; then
      echo "$hash" > "$stamp"
      echo "jellyfin-sso-setup: SSO settings changed, restarting Jellyfin to load them"
      systemctl restart --no-block podman-jellyfin.service
    fi

    echo "jellyfin-sso-setup: configured provider ${ssoProviderName} (${jellyfinPublicUrl}/sso/OID/start/${ssoProviderName})"
  '';
in
{
  # Login is limited to these groups by the plugin (Roles / AdminRoles).
  homelab.keycloak.clients.jellyfin = {
    name = "Jellyfin";
    redirectUris = [
      "${jellyfinPublicUrl}/sso/OID/redirect/${ssoProviderName}"
      "${jellyfinPublicUrl}/sso/OID/r/${ssoProviderName}"
    ];
    secret = { file = config.sops.secrets."jellyfin-oauth-env".path; key = "KEYCLOAK_CLIENT_SECRET"; };
  };
  homelab.keycloak.testUser.groups = [ "jellyfin_user" ];

  sops.secrets."jellyfin-oauth-env" = {
    sopsFile = "${sops-path}/secrets/containers/jellyfin.yaml";
    key = "jellyfin-oauth-env";
    # The secret path never changes, so a restartTriggers entry on it never fired.
    restartUnits = [ "podman-jellyfin.service" "jellyfin-sso-setup.service" ];
  };

  users.users.jellyfin = {
    isSystemUser = true;
    description = "Jellyfin";
    group = "jellyfin";
  };
  users.groups.jellyfin = { };

  systemd.tmpfiles.rules = [
    "d /jf 0770 jellyfin jellyfin -"
    "d /jf/config 0770 jellyfin jellyfin -"
    "d /jf/cache 0770 jellyfin jellyfin -"
    "d /jf/media 0770 jellyfin jellyfin -"
    "d /run/jellyfin 0750 root root -"
  ];

  systemd.services.jellyfin-sso-setup = {
    description = "Install Jellyfin SSO plugin and configure Keycloak OIDC";
    wantedBy = [ "multi-user.target" ];
    after = [
      "podman-jellyfin.service"
      "sops-nix.service"
    ];
    requires = [ "podman-jellyfin.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = jellyfinSsoSetupScript;
    };
  };

  virtualisation.oci-containers.containers.jellyfin = {
    autoStart = true;

    # Not 0.0.0.0 (netavark DNATs published ports ahead of nixos-fw, so that also
    # exposed it on the tailnet and the podman bridges). Loopback for Caddy and the
    # version check; the LAN address stays for TV/app clients that talk to
    # http://192.168.5.5:8096 directly (Jellyfin requires its own login there).
    ports = [
      "127.0.0.1:8096:8096"
      "192.168.5.5:8096:8096"
    ];

    user = "jellyfin:jellyfin";

    volumes = [
      "/etc/passwd:/etc/passwd:ro"
      "/etc/group:/etc/group:ro"
      "/jf/config:/config"
      "/jf/cache:/cache"
      "/jf/media:/media"
    ];

    extraOptions = [
      "--userns=keep-id"
      "--add-host=${kc.domain}:host-gateway"
      "--add-host=host.containers.internal:host-gateway"
    ];

    image = "docker.io/jellyfin/jellyfin:${jellyfinVersion}";
  };
}
