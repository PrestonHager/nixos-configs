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

    accountId = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "12f5428fd594b9e9c2eaadfdd0fdc857";
      description = ''
        Cloudflare account id (not secret). Not used by caddy-dns/cloudflare for
        DNS-01; stored for scripts/docs. Set via homelab.caddy.cloudflareAcme.accountId.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default =
        let
          base = pkgs.caddy.withPlugins {
            # v0.2.3 + postPatch: accept cfat_/cfut_ tokens (>50 chars); upstream #123.
            plugins = [ "github.com/caddy-dns/cloudflare@v0.2.3" ];
            hash = "sha256-peY/XG37RC0e7FafJ3qNk53srtXZagxN/Hfexcc2TMM=";
          };
        in
        base.overrideAttrs (old: {
          postPatch = (old.postPatch or "") + ''
            sed -i 's/{35,50}/{35,256}/' vendor/github.com/caddy-dns/cloudflare/cloudflare.go
          '';
        });
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
