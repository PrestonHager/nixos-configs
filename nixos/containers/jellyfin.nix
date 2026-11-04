{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  # Pinned for ace-service-auto-update nix-bump (do not use :latest pulls).
  # The tag stays (nix-bump rewrites it); 12.4 was tested as
  # docker.io/jellyfin/jellyfin@sha256:fea863d0cd9ec445985d9c75fc6ed64e38a1d2766cf0c250a33d553f4fc1b771.
  jellyfinVersion = "12.4";
  jellyfinPublicUrl = "https://jellyfin.prestonhager.com";
  zitadelDomain = "zitadel.prestonhager.com";
  zitadelDiscoveryUri = "https://${zitadelDomain}/.well-known/openid-configuration";
  zitadelProjectId = "376196450586990901";
  ssoProviderName = "zitadel";
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

    clientId="$(grep '^JELLYFIN_OIDC_CLIENT_ID=' "$oauthEnv" | cut -d= -f2- || true)"
    clientSecret="$(grep '^JELLYFIN_OIDC_CLIENT_SECRET=' "$oauthEnv" | cut -d= -f2- || true)"
    if [ -z "$clientId" ] || [ -z "$clientSecret" ]; then
      echo "jellyfin-sso-setup: JELLYFIN_OIDC_CLIENT_ID/SECRET missing, skipping" >&2
      exit 0
    fi
    if [ "$clientId" = "REPLACE_ZITADEL_CLIENT_ID" ] || [ "$clientSecret" = "REPLACE_ZITADEL_CLIENT_SECRET" ]; then
      echo "jellyfin-sso-setup: placeholder OIDC credentials, skipping" >&2
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

    prestonhGuid="$(${pkgs.sqlite}/bin/sqlite3 /jf/config/data/jellyfin.db "SELECT Id FROM Users WHERE Username='prestonh' LIMIT 1;" 2>/dev/null || true)"
    canonicalLinks=""
    if [ -n "''${prestonhGuid}" ]; then
      canonicalLinks="
          <item>
            <key>
              <string>prestonh</string>
            </key>
            <value>
              <guid>''${prestonhGuid}</guid>
            </value>
          </item>"
    fi

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
          <OidEndpoint>${zitadelDiscoveryUri}</OidEndpoint>
          <OidClientId>''${clientId}</OidClientId>
          <OidSecret>''${clientSecret}</OidSecret>
          <Enabled>true</Enabled>
          <EnableAuthorization>true</EnableAuthorization>
          <EnableAllFolders>true</EnableAllFolders>
          <EnabledFolders />
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
            <string>urn:zitadel:iam:org:project:roles</string>
            <string>urn:zitadel:iam:org:project:id:${zitadelProjectId}:aud</string>
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
  <LoginDisclaimer>&lt;form action="${jellyfinPublicUrl}/sso/OID/start/${ssoProviderName}"&gt;&lt;button class="raised block emby-button button-submit"&gt;Sign in with Zitadel&lt;/button&gt;&lt;/form&gt;</LoginDisclaimer>
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

    marker="/jf/config/.sso-setup-done"
    if [ ! -f "$marker" ]; then
      echo "jellyfin-sso-setup: restart jellyfin to load SSO plugin (run: systemctl restart podman-jellyfin.service)"
      touch "$marker"
    fi

    echo "jellyfin-sso-setup: configured provider ${ssoProviderName} (${jellyfinPublicUrl}/sso/OID/start/${ssoProviderName})"
  '';
in
{
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
    description = "Install Jellyfin SSO plugin and configure Zitadel OIDC";
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
      "--add-host=${zitadelDomain}:host-gateway"
      "--add-host=host.containers.internal:host-gateway"
    ];

    image = "docker.io/jellyfin/jellyfin:${jellyfinVersion}";
  };
}
