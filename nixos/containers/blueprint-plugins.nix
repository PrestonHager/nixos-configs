{ config, pkgs, lib, ... }:

let
  defaultPlugins = [
    {
      name = "sociallogin";
      repo = "blueprint-framework";
      installMethod = "blueprint";
      order = 10;
      adminView = null;
      adminController = null;
      adminPartials = null;
      adminWrapper = null;
      routes = [ "web" ];
      migrations = [ ];
    }
    {
      name = "dnsrecords";
      repo = "pterodactyl-dns-records";
      installMethod = "copy";
      order = 20;
      adminView = "admin/view.blade.php";
      adminController = "admin/controller.php";
      adminPartials = "admin/partials";
      adminWrapper = "admin/wrapper.blade.php";
      routes = [ "web" "application" "client" ];
      migrations = [ "database/migrations" ];
    }
    {
      name = "portforward";
      repo = "pterodactyl-port-forward";
      installMethod = "copy";
      order = 30;
      adminView = "admin/view.blade.php";
      adminController = "admin/controller.php";
      adminPartials = "admin/partials";
      adminWrapper = "admin/wrapper.blade.php";
      routes = [ "web" "application" "client" ];
      migrations = [ "database/migrations" ];
    }
    #{
      #name = "minecraft-tools";
      #repo = "pterodactyl-minecraft-tools";
      #installMethod = "copy";
      #order = 30;
      #adminView = "admin/view.blade.php";
      #adminController = "admin/controller.php";
      #adminPartials = "admin/partials";
      #adminWrapper = "admin/wrapper.blade.php";
      #routes = [ "web" "application" "client" ];
      #migrations = [ "database/migrations" ];
    #}
  ];

  defaultFramework = {
    releaseUrl = "https://github.com/BlueprintFramework/framework/releases/download/beta-2026-08/release.zip";
    releaseHash = "sha256:38bcee33b19abcbb3460578236ead74668ec39a7861200bbc6902a9152ac118d";
    socialloginBlueprintUrl = "https://github.com/blueprint-community/extension-sociallogin/releases/download/1.2.0/sociallogin.blueprint";
  };

  defaultExtensionsThemeSrc = "/etc/nixos/plugins/pterodactyl-blueprint-extensions/public/admin-extension-theme.css";
in
{
  options.homelab.blueprint = {
    enable = lib.mkEnableOption "Blueprint Framework extensions management";

    plugins = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption { type = lib.types.str; };
          repo = lib.mkOption { type = lib.types.str; };
          installMethod = lib.mkOption { type = lib.types.enum [ "blueprint" "copy" ]; default = "copy"; };
          order = lib.mkOption { type = lib.types.int; default = 50; };
          adminView = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
          adminController = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
          adminPartials = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
          adminWrapper = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
          routes = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
          migrations = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
        };
      });
      default = defaultPlugins;
      description = "List of Blueprint extensions to manage";
    };

    framework = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        releaseUrl = "https://github.com/BlueprintFramework/framework/releases/download/beta-2026-08/release.zip";
        releaseHash = "sha256:38bcee33b19abcbb3460578236ead74668ec39a7861200bbc6902a9152ac118d";
        socialloginBlueprintUrl = "https://github.com/blueprint-community/extension-sociallogin/releases/download/1.2.0/sociallogin.blueprint";
      };
      description = "Blueprint framework release configuration";
    };

    extensionsThemeSrc = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixos/plugins/pterodactyl-blueprint-extensions/public/admin-extension-theme.css";
      description = "Path to admin extension theme CSS";
    };

    pluginsConfig = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
      default = { };
      description = "Per-plugin configuration overrides";
    };
  };

  config = lib.mkIf config.homelab.blueprint.enable {
    # The actual configuration values are set by the user in their host config
    # This module just defines the options with sensible defaults
  };
}
