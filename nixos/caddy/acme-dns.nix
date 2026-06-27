# Cloudflare DNS-01 for Caddy TLS — auto-issue certs without per-hostname Cloudflare edits.
# Enable after adding CLOUDFLARE_API_TOKEN to nix-secrets (see docs/dns-ace.md).
{ config, pkgs, lib, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  cfg = config.homelab.caddy.cloudflareAcme;
in {
  options.homelab.caddy.cloudflareAcme = {
    enable = lib.mkEnableOption ''
      Obtain Let's Encrypt certificates via Cloudflare DNS-01 challenge.
      Requires a scoped API token in nix-secrets and bypasses split-horizon DNS
      for _acme-challenge (Caddy uses 1.1.1.1 for propagation checks).
    '';

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.caddy.withPlugins {
        plugins = [ "github.com/caddy-dns/cloudflare@v0.2.2" ];
        hash = "sha256-7g8zDx5RhbptXFyEPtexxkHX8hw/gF001bZ7wX4Mjhs=";
      };
      description = "Caddy binary with github.com/caddy-dns/cloudflare plugin.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."cloudflare-acme-env" = {
      sopsFile = "${sops-path}/secrets/cloudflare.yaml";
      key = "acme-env";
      mode = "0400";
    };

    services.caddy = {
      package = cfg.package;
      globalConfig = lib.mkAfter ''
        acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}
      '';
    };

    systemd.services.caddy.serviceConfig = {
      EnvironmentFile = lib.mkAfter [ config.sops.secrets."cloudflare-acme-env".path ];
    };
  };
}
