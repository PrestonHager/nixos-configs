{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  jellyfinPublicUrl = "https://jellyfin.prestonhager.com";
  zitadelDomain = "zitadel.prestonhager.com";
  zitadelDiscoveryUri = "https://${zitadelDomain}/.well-known/openid-configuration";
  zitadelProjectId = "376196450586990901";
  ssoProviderName = "zitadel";
  ssoPluginVersion = "3.5.2.4";
  ssoPluginUrl = "https://github.com/9p4/jellyfin-plugin-sso/releases/download/v${ssoPluginVersion}/sso-authentication_${ssoPluginVersion}.zip";
  ssoPluginDir = "/jf/config/plugins/SSO Authentication/${ssoPluginVersion}";
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

    if [ ! -f "${ssoPluginDir}/SSO-Auth.dll" ]; then
      echo "jellyfin-sso-setup: installing SSO Authentication plugin ${ssoPluginVersion}"
      tmpdir="$(mktemp -d)"
      trap 'rm -rf "$tmpdir"' EXIT
      ${pkgs.curl}/bin/curl -fsSL -o "$tmpdir/sso.zip" "${ssoPluginUrl}"
      mkdir -p "${ssoPluginDir}"
      ${pkgs.unzip}/bin/unzip -o "$tmpdir/sso.zip" -d "${ssoPluginDir}"
      chown -R jellyfin:jellyfin "/jf/config/plugins/SSO Authentication"
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
            <string>groups</string>
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

  systemd.services.podman-jellyfin.restartTriggers = [
    config.sops.secrets."jellyfin-oauth-env".path
  ];

  virtualisation.oci-containers.containers.jellyfin = {
    autoStart = true;

    ports = [
      "8096:8096"
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

    image = "docker.io/jellyfin/jellyfin:latest";
  };
}
