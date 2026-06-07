{ config, pkgs, lib, ... }:

let
  zitadelBase = "https://zitadel.prestonhager.com";
in {
  options.services.zitadel-sso = {
    enable = lib.mkEnableOption "Zitadel SSO endpoint metadata for integrated apps";
    externalDomain = lib.mkOption {
      type = lib.types.str;
      default = "zitadel.prestonhager.com";
    };
    issuer = lib.mkOption {
      type = lib.types.str;
      default = zitadelBase;
      description = "OIDC issuer / SAML IdP entity base URL.";
    };
  };

  config = lib.mkIf config.services.zitadel-sso.enable {
    environment.etc."zitadel-sso/endpoints.json".text = builtins.toJSON {
      issuer = config.services.zitadel-sso.issuer;
      oidc = {
        authorize = "${config.services.zitadel-sso.issuer}/oauth/v2/authorize";
        token = "${config.services.zitadel-sso.issuer}/oauth/v2/token";
        userinfo = "${config.services.zitadel-sso.issuer}/oidc/v1/userinfo";
        jwks = "${config.services.zitadel-sso.issuer}/oauth/v2/keys";
        end_session = "${config.services.zitadel-sso.issuer}/oidc/v1/end_session";
      };
      saml = {
        metadata = "${config.services.zitadel-sso.issuer}/saml/v2/metadata";
      };
      redirectUris = {
        grafana = "https://grafana.prestonhager.com/login/generic_oauth";
        matrix = "https://matrix.prestonhager.com/_synapse/client/oidc/callback";
        technitium = "https://dns.prestonhager.com/sso/callback";
        vaultwarden = "https://vault.prestonhager.com/identity/connect/oidc-signin";
        nextcloud = "https://cloud.prestonhager.com/apps/user_oidc/code";
        pterodactyl = "https://panel.prestonhager.com/oauth2/callback";
      };
    };
  };
}
