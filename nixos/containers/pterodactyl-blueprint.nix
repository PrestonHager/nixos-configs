{ config, pkgs, lib, inputs, ... }:

let
    # Import central blueprint plugins configuration
  blueprintCfg = config.homelab.blueprint;
  plugins = builtins.sort (a: b: a.order < b.order) blueprintCfg.plugins;
  framework = blueprintCfg.framework;
  extensionsThemeSrc = blueprintCfg.extensionsThemeSrc;

  # Build plugin sources from flake inputs
  pluginSources = builtins.listToAttrs (builtins.map (plugin:
    { name = plugin.name; value = builtins.getAttr plugin.repo inputs; }
  ) plugins);

  blueprintExtensionsThemeSrc = extensionsThemeSrc;
  dnsExtensionSrc = pluginSources.dnsrecords;
  portforwardExtensionSrc = pluginSources.portforward;
  minecraftToolsSrc = pluginSources."minecraft-tools";
  minecraftToolsPort = ./mc-tools-port;
  blueprintReleaseUrl = framework.releaseUrl;
  blueprintReleaseHash = framework.releaseHash;
  socialloginBlueprintUrl = framework.socialloginBlueprintUrl;

  # Add imports attribute to the returned set

panelRoot = "/pterodactyl/html";
  stateDir = "/var/lib/pterodactyl";
  blueprintMarker = "${stateDir}/blueprint-installed";

  toolPath = pkgs.lib.makeBinPath [
    pkgs.bash
    pkgs.coreutils
    pkgs.gawk
    pkgs.gnused
    pkgs.gnugrep
    pkgs.diffutils
    pkgs.ncurses
    pkgs.nodejs_22
    pkgs.yarn
    pkgs.git
    pkgs.findutils
    pkgs.gnutar
    pkgs.gzip
    pkgs.zip
    pkgs.unzip
    pkgs.php83
    pkgs.procps
  ];

  blueprintRc = pkgs.writeText "pterodactyl-blueprintrc" ''
    WEBUSER="pterodactyl"
    OWNERSHIP="pterodactyl:pterodactyl"
    USERSHELL="/bin/sh"
  '';

  installScript = pkgs.writeShellScript "pterodactyl-blueprint-install" ''
    set -euo pipefail
    panel="${panelRoot}"
    marker="${blueprintMarker}"

    if [ ! -d "$panel/app" ]; then
      echo "pterodactyl-blueprint-install: panel not installed, skipping" >&2
      exit 0
    fi

    export PATH="${toolPath}:$PATH"
    export HOME=/var/lib/pterodactyl
    export TERM=dumb
    export LC_ALL=C.UTF-8
    export LANG=C.UTF-8
    export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
    install -d -m 0750 -o pterodactyl -g pterodactyl /var/lib/pterodactyl

    blueprint_cli() {
      env HOME=/var/lib/pterodactyl TERM=dumb LC_ALL=C.UTF-8 LANG=C.UTF-8 PATH="$PATH" ${pkgs.bash}/bin/bash "$panel/blueprint.sh" -bash "$@"
    }

    blueprint_cli_install() {
      env HOME=/var/lib/pterodactyl TERM=dumb LC_ALL=C.UTF-8 LANG=C.UTF-8 PATH="$PATH" ${pkgs.bash}/bin/bash "$panel/blueprint.sh" "$@"
    }

    ensure_sociallogin_models() {
      datadir="$panel/.blueprint/extensions/sociallogin/private"
      if [ ! -f "$panel/app/Models/SocialProvider.php" ] && [ -f "$datadir/SocialProvider.php" ]; then
        echo "pterodactyl-blueprint-install: installing Social Login model files..."
        cp -f "$datadir/SocialProvider.php" "$panel/app/Models/SocialProvider.php"
        cp -f "$datadir/SocialConnection.php" "$panel/app/Models/SocialConnection.php"
        chown pterodactyl:pterodactyl "$panel/app/Models/SocialProvider.php" "$panel/app/Models/SocialConnection.php"
      fi
    }

    ensure_blueprint_assets() {
      if [ -d "$panel/.blueprint/assets/Extensions" ]; then
        return 0
      fi
      if [ -d "$panel/.blueprint/blueprint/assets" ]; then
        echo "pterodactyl-blueprint-install: copying Blueprint assets from framework tree..."
        cp -a "$panel/.blueprint/blueprint/assets" "$panel/.blueprint/assets"
        chown -R pterodactyl:pterodactyl "$panel/.blueprint/assets"
      fi
    }

    ensure_extension_app_symlinks() {
      ext_root="$panel/app/BlueprintFramework/Extensions"
      install -d -m 0755 -o pterodactyl -g pterodactyl "$ext_root"
      for ext in sociallogin dnsrecords portforward minecraft-tools; do
        if [ ! -d "$panel/.blueprint/extensions/$ext/app" ]; then
          continue
        fi
        if [ -L "$ext_root/$ext" ] || [ -d "$ext_root/$ext" ]; then
          continue
        fi
        echo "pterodactyl-blueprint-install: linking $ext extension app into BlueprintFramework..."
        ln -sfn "../../../.blueprint/extensions/$ext/app" "$ext_root/$ext"
        chown -h pterodactyl:pterodactyl "$ext_root/$ext"
      done
    }

    ensure_storage_extension_symlinks() {
      storage_ext="$panel/storage/extensions"
      install -d -m 2775 -o pterodactyl -g pterodactyl "$storage_ext"
      for ext in sociallogin dnsrecords portforward minecraft-tools; do
        if [ ! -d "$panel/.blueprint/extensions/$ext/fs" ]; then
          continue
        fi
        if [ -L "$storage_ext/$ext" ] || [ -d "$storage_ext/$ext" ]; then
          continue
        fi
        echo "pterodactyl-blueprint-install: linking $ext extension public files into storage..."
        ln -sfn "../../.blueprint/extensions/$ext/fs" "$storage_ext/$ext"
        chown -h pterodactyl:pterodactyl "$storage_ext/$ext"
      done
    }

    ensure_blueprint_admin_extension_theme() {
      src="${blueprintExtensionsThemeSrc}"
      if [ ! -f "$src" ]; then
        echo "pterodactyl-blueprint-install: extension theme CSS missing at $src, skipping" >&2
        return 0
      fi
      dest="$panel/.blueprint/extensions/blueprint/assets/admin.extensions.css"
      install -d -m 0755 -o pterodactyl -g pterodactyl "$(dirname "$dest")"
      {
        printf '%s\n' '/*'
        printf '%s\n' '  Admin stylesheets for Blueprint extensions.'
        printf '%s\n' '  Synced from nixos-configs admin-extension-theme.css'
        printf '%s\n' '*/'
        cat "$src"
      } > "$dest"
      chown pterodactyl:pterodactyl "$dest"
    }

    ensure_public_assets_extension_symlinks() {
      assets_ext="$panel/public/assets/extensions"
      install -d -m 2775 -o pterodactyl -g pterodactyl "$assets_ext"
      for ext in blueprint sociallogin dnsrecords portforward minecraft-tools; do
        target="$panel/.blueprint/extensions/$ext/assets"
        if [ ! -d "$target" ]; then
          continue
        fi
        link="$assets_ext/$ext"
        resolved=""
        if [ -L "$link" ]; then
          resolved=$(${pkgs.coreutils}/bin/readlink -f "$link" 2>/dev/null || true)
        fi
        if [ "$resolved" = "$target" ]; then
          continue
        fi
        if [ -e "$link" ] && [ ! -L "$link" ]; then
          continue
        fi
        rm -f "$link"
        echo "pterodactyl-blueprint-install: linking $ext extension assets into public..."
        ln -sfn "../../../.blueprint/extensions/$ext/assets" "$link"
        chown -h pterodactyl:pterodactyl "$link"
      done
    }

    extension_public_asset_file() {
      ext="$1"
      if [ "$ext" = "blueprint" ]; then
        echo "$panel/public/assets/extensions/blueprint/logo.jpg"
      else
        echo "$panel/public/assets/extensions/$ext/icon.jpg"
      fi
    }

    extension_public_assets_integrated() {
      for ext in blueprint sociallogin dnsrecords portforward minecraft-tools; do
        asset=$(extension_public_asset_file "$ext")
        [ -f "$asset" ] || return 1
      done
    }

    minAdminViewBytes=100

    extension_admin_view_source() {
      ext="$1"
      case "$ext" in
        dnsrecords) echo "${dnsExtensionSrc}/admin/view.blade.php" ;;
        portforward) echo "${portforwardExtensionSrc}/admin/view.blade.php" ;;
        minecraft-tools) echo "${minecraftToolsSrc}/blueprint/dev/resources/views/admin/view.blade.php" ;;
        *) return 1 ;;
      esac
    }

    extension_admin_controller_source() {
      ext="$1"
      case "$ext" in
        dnsrecords) echo "${dnsExtensionSrc}/admin/controller.php" ;;
        portforward) echo "${portforwardExtensionSrc}/admin/controller.php" ;;
        *) return 1 ;;
      esac
    }

    extension_admin_view_corrupted() {
      ext="$1"
      view="$panel/resources/views/admin/extensions/$ext/index.blade.php"
      [ -f "$view" ] || return 0
      count=$(${pkgs.gnugrep}/bin/grep -c "@extends('layouts.admin')" "$view" 2>/dev/null || echo 0)
      [ "$count" -ne 1 ]
    }

    ensure_extension_admin_files() {
      for ext in sociallogin dnsrecords portforward minecraft-tools; do
        ctrl="$panel/app/Http/Controllers/Admin/Extensions/$ext/''${ext}ExtensionController.php"
        view="$panel/resources/views/admin/extensions/$ext/index.blade.php"
        src_ctrl=""
        src_view=""
        if src_path=$(extension_admin_controller_source "$ext" 2>/dev/null) && [ -f "$src_path" ]; then
          src_ctrl="$src_path"
        fi
        if src_path=$(extension_admin_view_source "$ext" 2>/dev/null) && [ -f "$src_path" ]; then
          src_view="$src_path"
        fi

        if [ -n "$src_ctrl" ]; then
          ctrl_needs_sync=0
          if [ ! -f "$ctrl" ]; then
            ctrl_needs_sync=1
          elif ! cmp -s "$src_ctrl" "$ctrl"; then
            ctrl_needs_sync=1
          fi
          if [ "$ctrl_needs_sync" -eq 1 ]; then
            echo "pterodactyl-blueprint-install: syncing $ext admin controller from plugin source..."
            install -d -m 0755 -o pterodactyl -g pterodactyl "$(dirname "$ctrl")"
            cp -a "$src_ctrl" "$ctrl"
            chown pterodactyl:pterodactyl "$ctrl"
          fi
        elif [ ! -f "$ctrl" ] && [ "$ext" = "sociallogin" ]; then
          echo "pterodactyl-blueprint-install: reinstalling Social Login to restore admin controller..."
          rm -f "$panel/.blueprint/lock"
          blueprint_cli -install sociallogin
        fi

        if [ -n "$src_view" ]; then
          view_needs_sync=0
          if [ ! -f "$view" ] || extension_admin_view_corrupted "$ext"; then
            view_needs_sync=1
          elif [ "$ext" != "minecraft-tools" ] && ! cmp -s "$src_view" "$view"; then
            view_needs_sync=1
          fi
          if [ "$view_needs_sync" -eq 1 ]; then
            echo "pterodactyl-blueprint-install: syncing $ext admin view from plugin source..."
            install -d -m 0755 -o pterodactyl -g pterodactyl "$(dirname "$view")"
            cp -a "$src_view" "$view"
            chown pterodactyl:pterodactyl "$view"
          fi
          src_partials=""
          case "$ext" in
            dnsrecords) src_partials="${dnsExtensionSrc}/admin/partials" ;;
            portforward) src_partials="${portforwardExtensionSrc}/admin/partials" ;;
          esac
          if [ -n "$src_partials" ] && [ -d "$src_partials" ]; then
            partials_dest="$panel/resources/views/admin/extensions/$ext/partials"
            if [ ! -d "$partials_dest" ] || ! ${pkgs.diffutils}/bin/diff -qr "$src_partials" "$partials_dest" >/dev/null 2>&1; then
              echo "pterodactyl-blueprint-install: syncing $ext admin view partials from plugin source..."
              install -d -m 0755 -o pterodactyl -g pterodactyl "$partials_dest"
              cp -a "$src_partials/." "$partials_dest/"
              chown -R pterodactyl:pterodactyl "$partials_dest"
            fi
          fi
        fi
      done
    }

    ensure_extension_backend_sync() {
      sync_extension_backend() {
        ext="$1"
        src="$2"
        dest="$panel/.blueprint/extensions/$ext"
        [ -d "$src" ] && [ -d "$dest" ] || return 0
        for sub in app database routes public views; do
          [ -d "$src/$sub" ] || continue
          if ! ${pkgs.diffutils}/bin/diff -qr "$src/$sub" "$dest/$sub" >/dev/null 2>&1; then
            echo "pterodactyl-blueprint-install: syncing $ext/$sub from plugin source..."
            rm -rf "$dest/$sub"
            cp -a "$src/$sub" "$dest/$sub"
            chown -R pterodactyl:pterodactyl "$dest/$sub"
            if [ "$sub" = "public" ]; then
              find "$dest/$sub" -type d -exec chmod 755 {} +
              find "$dest/$sub" -type f -exec chmod 644 {} +
            fi
          fi
        done
        public_dir="$dest/public"
        if [ -d "$public_dir" ]; then
          chmod 755 "$public_dir"
          find "$public_dir" -type d -exec chmod 755 {} +
          find "$public_dir" -type f -exec chmod 644 {} +
        fi
      }
      sync_extension_wrapper() {
        ext="$1"
        src="$2"
        src_wrapper="$src/admin/wrapper.blade.php"
        dest="$panel/.blueprint/extensions/$ext"
        dest_wrapper="$dest/wrappers/admin.blade.php"
        [ -f "$src_wrapper" ] && [ -d "$dest" ] || return 0
        install -d -m 0755 -o pterodactyl -g pterodactyl "$(dirname "$dest_wrapper")"
        if [ ! -f "$dest_wrapper" ] || ! cmp -s "$src_wrapper" "$dest_wrapper"; then
          echo "pterodactyl-blueprint-install: syncing $ext admin wrapper from plugin source..."
          cp -a "$src_wrapper" "$dest_wrapper"
          chown pterodactyl:pterodactyl "$dest_wrapper"
        fi
      }
      sync_extension_panel_routes() {
        ext="$1"
        src="$2"
        for router in web application client; do
          src_route="$src/routes/$router.php"
          dest_route="$panel/routes/blueprint/$router/$ext.php"
          [ -f "$src_route" ] || continue
          install -d -m 0755 -o pterodactyl -g pterodactyl "$(dirname "$dest_route")"
          if [ ! -f "$dest_route" ] || ! cmp -s "$src_route" "$dest_route"; then
            echo "pterodactyl-blueprint-install: syncing $ext $router routes into panel..."
            cp -a "$src_route" "$dest_route"
            chown pterodactyl:pterodactyl "$dest_route"
          fi
        done
      }
      sync_extension_backend dnsrecords "${dnsExtensionSrc}"
      sync_extension_backend portforward "${portforwardExtensionSrc}"
      sync_extension_backend minecraft-tools "${minecraftToolsSrc}/blueprint/dev"
      sync_extension_wrapper dnsrecords "${dnsExtensionSrc}"
      sync_extension_wrapper portforward "${portforwardExtensionSrc}"
      sync_extension_wrapper minecraft-tools "${minecraftToolsSrc}/blueprint/dev"
      sync_extension_panel_routes dnsrecords "${dnsExtensionSrc}"
      sync_extension_panel_routes portforward "${portforwardExtensionSrc}"
      sync_extension_panel_routes minecraft-tools "${minecraftToolsSrc}/blueprint/dev"
    }

    ensure_extension_public_permissions() {
      for ext in blueprint sociallogin dnsrecords portforward minecraft-tools; do
        public_dir="$panel/.blueprint/extensions/$ext/public"
        [ -d "$public_dir" ] || continue
        chmod 755 "$public_dir" 2>/dev/null || true
        find "$public_dir" -type d -exec chmod 755 {} + 2>/dev/null || true
        find "$public_dir" -type f -exec chmod 644 {} + 2>/dev/null || true
      done
    }

    extension_public_permissions_ok() {
      for ext in blueprint sociallogin dnsrecords portforward minecraft-tools; do
        public_dir="$panel/.blueprint/extensions/$ext/public"
        [ -d "$public_dir" ] || continue
        perms=$(${pkgs.coreutils}/bin/stat -c '%a' "$public_dir" 2>/dev/null || echo 0)
        case "$perms" in
          7??|5??) ;;
          *) return 1 ;;
        esac
      done
    }

    ensure_extension_migrations() {
      for src_dir in "${dnsExtensionSrc}/database/migrations" "${portforwardExtensionSrc}/database/migrations" "${minecraftToolsSrc}/src/Extensions/MinecraftTools/Database/Migrations"; do
        [ -d "$src_dir" ] || continue
        for migration in "$src_dir"/*.php; do
          [ -f "$migration" ] || continue
          base=$(${pkgs.coreutils}/bin/basename "$migration")
          if [ ! -f "$panel/database/migrations/$base" ]; then
            echo "pterodactyl-blueprint-install: copying missing migration $base from plugin source..."
            cp -a "$migration" "$panel/database/migrations/$base"
            chown pterodactyl:pterodactyl "$panel/database/migrations/$base"
          fi
        done
      done
    }

    ensure_extension_default_icons() {
      default_icon="$panel/.blueprint/extensions/blueprint/assets/byte.png"
      for ext in sociallogin dnsrecords portforward minecraft-tools; do
        assets_dir="$panel/.blueprint/extensions/$ext/assets"
        [ -d "$assets_dir" ] || continue
        if [ ! -f "$assets_dir/icon.jpg" ] && [ -f "$default_icon" ]; then
          ${pkgs.coreutils}/bin/install -m 0755 "$default_icon" "$assets_dir/icon.jpg"
          chown pterodactyl:pterodactyl "$assets_dir/icon.jpg"
        fi
      done
    }

    extension_admin_view_ok() {
      ext="$1"
      view="$panel/resources/views/admin/extensions/$ext/index.blade.php"
      [ -f "$view" ] || return 1
      count=$(${pkgs.gnugrep}/bin/grep -c "@extends('layouts.admin')" "$view" 2>/dev/null || echo 0)
      [ "$count" -eq 1 ]
    }

    extension_migrations_integrated() {
      for migration in \
        2026_06_07_000001_create_dnsrecords_extension_tables.php \
        2026_06_26_000001_add_dnsrecords_audit_log.php \
        2026_06_26_000001_create_portforward_extension_tables.php; do
        [ -f "$panel/database/migrations/$migration" ] || return 1
      done
    }

    extension_backend_integrated() {
      for ext in sociallogin dnsrecords portforward; do
        [ -e "$panel/app/BlueprintFramework/Extensions/$ext" ] || return 1
        [ -f "$panel/app/Http/Controllers/Admin/Extensions/$ext/''${ext}ExtensionController.php" ] || return 1
        extension_admin_view_ok "$ext" || return 1
      done
      extension_migrations_integrated && extension_public_assets_integrated && extension_public_permissions_ok
    }

    blueprint_core_backend_integrated() {
      [ -f "$panel/app/Models/SocialProvider.php" ] \
        && grep -q 'Providers\\Blueprint\\RouteServiceProvider' "$panel/app/Providers/AppServiceProvider.php" \
        && grep -q "'blueprint'" "$panel/app/Http/Kernel.php" \
        && [ -f "$panel/routes/blueprint/web/sociallogin.php" ] || return 1
      routes=$(${pkgs.podman}/bin/podman exec pterodactyl \
        php /var/www/pterodactyl/artisan route:list 2>/dev/null || true)
      case "$routes" in
        *'extensions/sociallogin'*) return 0 ;;
        *) return 1 ;;
      esac
    }

    blueprint_backend_integrated() {
      blueprint_core_backend_integrated && extension_backend_integrated
    }

    blueprint_site_config_integrated() {
      grep -q 'disable_attribution' "$panel/app/Http/ViewComposers/AssetComposer.php" 2>/dev/null \
        && grep -q 'disable_attribution' "$panel/resources/scripts/state/settings.ts" 2>/dev/null \
        && grep -q 'blueprint.dashboard.dashboard' "$panel/resources/views/templates/wrapper.blade.php" 2>/dev/null
    }

    blueprint_admin_layout_integrated() {
      grep -q 'blueprint.admin.admin' "$panel/resources/views/layouts/admin.blade.php" 2>/dev/null \
        && grep -q 'blueprint.import' "$panel/resources/views/layouts/admin.blade.php" 2>/dev/null
    }

    blueprint_placeholder_integrated() {
      [ -f "$panel/app/BlueprintFramework/Services/PlaceholderService/BlueprintPlaceholderService.php" ] \
        && ! grep -q '"::v"' "$panel/app/BlueprintFramework/Services/PlaceholderService/BlueprintPlaceholderService.php" 2>/dev/null
    }

    blueprint_framework_version() {
      ${pkgs.gnugrep}/bin/grep -m1 '^VERSION=' "$panel/blueprint.sh" 2>/dev/null \
        | ${pkgs.gnused}/bin/sed 's/VERSION="\(.*\)".*/\1/' \
        | ${pkgs.gnused}/bin/sed 's/ #;//'
    }

    refresh_blueprint_framework_release() {
      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"' RETURN
      ${pkgs.curl}/bin/curl -fsSL "${blueprintReleaseUrl}" -o "$tmp/release.zip"
      current=$(blueprint_framework_version || echo "unknown")
      remote=$(${pkgs.unzip}/bin/unzip -p "$tmp/release.zip" blueprint.sh 2>/dev/null \
        | ${pkgs.gnugrep}/bin/grep -m1 '^VERSION=' \
        | ${pkgs.gnused}/bin/sed 's/VERSION="\(.*\)".*/\1/' \
        | ${pkgs.gnused}/bin/sed 's/ #;//' || echo "unknown")
      if [ "$current" = "$remote" ] \
        && blueprint_admin_layout_integrated \
        && blueprint_placeholder_integrated; then
        return 0
      fi
      echo "pterodactyl-blueprint-install: refreshing Blueprint release ($current -> $remote)..."
      ${pkgs.unzip}/bin/unzip -o "$tmp/release.zip" -d "$panel"
      chown -R pterodactyl:pterodactyl "$panel"
      install -m 0644 ${blueprintRc} "$panel/.blueprintrc"
      chmod +x "$panel/blueprint.sh"
      chown pterodactyl:pterodactyl "$panel/.blueprintrc" "$panel/blueprint.sh"
      if [ -d "$panel/blueprint" ] && [ -d "$panel/.blueprint/blueprint" ]; then
        rm -rf "$panel/blueprint"
      elif [ -d "$panel/blueprint" ]; then
        rm -rf "$panel/.blueprint/blueprint"
        mv "$panel/blueprint" "$panel/.blueprint/blueprint"
      fi
    }

    ensure_blueprint_admin_layout_patches() {
      if blueprint_admin_layout_integrated \
        && [ -f "$panel/resources/views/blueprint/admin/admin.blade.php" ]; then
        return 0
      fi
      echo "pterodactyl-blueprint-install: restoring Blueprint admin layout patches from release..."
      patch_tmp=$(mktemp -d)
      ${pkgs.curl}/bin/curl -fsSL "${blueprintReleaseUrl}" -o "$patch_tmp/release.zip"
      ${pkgs.unzip}/bin/unzip -o "$patch_tmp/release.zip" \
        resources/views/layouts/admin.blade.php \
        "resources/views/blueprint/admin/*" \
        -d "$patch_tmp/extract"
      install -d -m 0755 -o pterodactyl -g pterodactyl "$panel/resources/views/blueprint/admin"
      cp "$patch_tmp/extract/resources/views/layouts/admin.blade.php" \
        "$panel/resources/views/layouts/admin.blade.php"
      cp -a "$patch_tmp/extract/resources/views/blueprint/admin/." \
        "$panel/resources/views/blueprint/admin/"
      chown -R pterodactyl:pterodactyl \
        "$panel/resources/views/layouts/admin.blade.php" \
        "$panel/resources/views/blueprint/admin"
      rm -rf "$patch_tmp"
    }

    ensure_blueprint_placeholder_version() {
      placeholder="$panel/app/BlueprintFramework/Services/PlaceholderService/BlueprintPlaceholderService.php"
      needs_fix=0
      if grep -q '::v' "$placeholder" 2>/dev/null; then
        needs_fix=1
      fi
      if grep -q 'NOTINSTALLED' "$placeholder" 2>/dev/null; then
        needs_fix=1
      fi
      if [ "$needs_fix" -eq 0 ]; then
        return 0
      fi
      version=$(blueprint_framework_version || echo "unknown")
      if [ "$version" = "unknown" ]; then
        echo "pterodactyl-blueprint-install: could not determine Blueprint version from blueprint.sh" >&2
        return 1
      fi
      echo "pterodactyl-blueprint-install: fixing Blueprint placeholders (version $version, installed state)..."
      rm -f "$panel/.blueprint/extensions/blueprint/private/db/version"
      ${pkgs.gnused}/bin/sed -E -i "s*::v*$version*g" "$placeholder"
      ${pkgs.gnused}/bin/sed -i "s~NOTINSTALLED~INSTALLED~g" "$placeholder"
      if [ -f "$panel/.blueprint/extensions/blueprint/public/index.html" ]; then
        ${pkgs.gnused}/bin/sed -E -i "s*::v*$version*g" \
          "$panel/.blueprint/extensions/blueprint/public/index.html"
      fi
      touch "$panel/.blueprint/extensions/blueprint/private/db/version"
      chown pterodactyl:pterodactyl "$placeholder" \
        "$panel/.blueprint/extensions/blueprint/private/db/version"
    }

    blueprint_frontend_integrated() {
      grep -q '@blueprint/components/Authentication/Container/AfterContent' \
        "$panel/resources/scripts/components/auth/LoginFormContainer.tsx" 2>/dev/null \
        && grep -q "'@blueprint'" "$panel/webpack.config.js" 2>/dev/null \
        && blueprint_site_config_integrated \
        && ${pkgs.gnugrep}/bin/grep -rq sociallogin "$panel/public/assets/"*.js 2>/dev/null
    }

    blueprint_integrated() {
      blueprint_backend_integrated && blueprint_frontend_integrated
    }

    ensure_blueprint_webpack_alias() {
      if grep -q "'@blueprint'" "$panel/webpack.config.js" 2>/dev/null; then
        return 0
      fi
      echo "pterodactyl-blueprint-install: adding @blueprint webpack alias..."
      ${pkgs.gnused}/bin/sed -i \
        "/'@feature': path.join/a\\            '@blueprint': path.join(__dirname, '/resources/scripts/blueprint')," \
        "$panel/webpack.config.js"
      chown pterodactyl:pterodactyl "$panel/webpack.config.js"
    }

    ensure_blueprint_site_config_patches() {
      if blueprint_site_config_integrated; then
        return 0
      fi

      echo "pterodactyl-blueprint-install: restoring Blueprint site configuration patches from release..."
      patch_tmp=$(mktemp -d)
      ${pkgs.curl}/bin/curl -fsSL "${blueprintReleaseUrl}" -o "$patch_tmp/release.zip"
      ${pkgs.unzip}/bin/unzip -o "$patch_tmp/release.zip" \
        app/Http/ViewComposers/AssetComposer.php \
        resources/scripts/state/settings.ts \
        resources/views/templates/wrapper.blade.php \
        -d "$patch_tmp/extract"
      cp "$patch_tmp/extract/app/Http/ViewComposers/AssetComposer.php" \
        "$panel/app/Http/ViewComposers/AssetComposer.php"
      cp "$patch_tmp/extract/resources/scripts/state/settings.ts" \
        "$panel/resources/scripts/state/settings.ts"
      cp "$patch_tmp/extract/resources/views/templates/wrapper.blade.php" \
        "$panel/resources/views/templates/wrapper.blade.php"
      chown pterodactyl:pterodactyl \
        "$panel/app/Http/ViewComposers/AssetComposer.php" \
        "$panel/resources/scripts/state/settings.ts" \
        "$panel/resources/views/templates/wrapper.blade.php"
      rm -rf "$patch_tmp"
    }

    ensure_blueprint_frontend_patches() {
      login_form="$panel/resources/scripts/components/auth/LoginFormContainer.tsx"
      needs_login_patch=0
      if ! grep -q '@blueprint/components/Authentication/Container/AfterContent' "$login_form" 2>/dev/null; then
        needs_login_patch=1
      fi

      ensure_blueprint_site_config_patches

      if [ "$needs_login_patch" -eq 0 ]; then
        ensure_blueprint_webpack_alias
        return 0
      fi

      echo "pterodactyl-blueprint-install: restoring Blueprint frontend patches from release..."
      patch_tmp=$(mktemp -d)
      ${pkgs.curl}/bin/curl -fsSL "${blueprintReleaseUrl}" -o "$patch_tmp/release.zip"
      ${pkgs.unzip}/bin/unzip -o "$patch_tmp/release.zip" \
        "resources/scripts/components/*" \
        "resources/scripts/routers/*" \
        "resources/scripts/index.tsx" \
        "resources/scripts/blueprint/extends/*" \
        -d "$patch_tmp/extract"
      cp -a "$patch_tmp/extract/resources/scripts/components/." "$panel/resources/scripts/components/"
      cp -a "$patch_tmp/extract/resources/scripts/routers/." "$panel/resources/scripts/routers/"
      cp "$patch_tmp/extract/resources/scripts/index.tsx" "$panel/resources/scripts/index.tsx"
      cp -a "$patch_tmp/extract/resources/scripts/blueprint/extends/." "$panel/resources/scripts/blueprint/extends/"
      chown -R pterodactyl:pterodactyl \
        "$panel/resources/scripts/components" \
        "$panel/resources/scripts/routers" \
        "$panel/resources/scripts/index.tsx" \
        "$panel/resources/scripts/blueprint/extends"
      rm -rf "$patch_tmp"
      ensure_blueprint_webpack_alias
    }

    ensure_frontend_built() {
      if ${pkgs.gnugrep}/bin/grep -rq sociallogin "$panel/public/assets/"*.js 2>/dev/null; then
        return 0
      fi
      echo "pterodactyl-blueprint-install: building panel frontend with Blueprint extensions..."
      cd "$panel"
      if [ ! -d "$panel/node_modules" ]; then
        runuser -u pterodactyl -- env HOME=/var/lib/pterodactyl TERM=dumb PATH="$PATH" yarn install --frozen-lockfile 2>/dev/null \
          || runuser -u pterodactyl -- env HOME=/var/lib/pterodactyl TERM=dumb PATH="$PATH" yarn install
      fi
      runuser -u pterodactyl -- env \
        HOME=/var/lib/pterodactyl \
        TERM=dumb \
        NODE_ENV=production \
        NODE_OPTIONS="--openssl-legacy-provider" \
        PATH="$PATH" \
        yarn build:production
    }

    ensure_blueprint_core_patches() {
      app_provider="$panel/app/Providers/AppServiceProvider.php"
      needs_kernel=0
      needs_app=0
      if ! grep -q "'blueprint'" "$panel/app/Http/Kernel.php" 2>/dev/null; then
        needs_kernel=1
      fi
      if ! grep -q 'Providers\\Blueprint\\RouteServiceProvider' "$app_provider" 2>/dev/null; then
        needs_app=1
      fi
      if [ "$needs_kernel" -eq 0 ] && [ "$needs_app" -eq 0 ]; then
        return 0
      fi

      echo "pterodactyl-blueprint-install: restoring Blueprint Kernel/AppServiceProvider patches from release..."
      patch_tmp=$(mktemp -d)
      trap 'rm -rf "$patch_tmp"' RETURN
      ${pkgs.curl}/bin/curl -fsSL "${blueprintReleaseUrl}" -o "$patch_tmp/release.zip"
      if [ "$needs_kernel" -eq 1 ]; then
        ${pkgs.unzip}/bin/unzip -o "$patch_tmp/release.zip" app/Http/Kernel.php -d "$patch_tmp/extract"
        cp "$patch_tmp/extract/app/Http/Kernel.php" "$panel/app/Http/Kernel.php"
      fi
      if [ "$needs_app" -eq 1 ]; then
        ${pkgs.unzip}/bin/unzip -o "$patch_tmp/release.zip" app/Providers/AppServiceProvider.php -d "$patch_tmp/extract"
        cp "$patch_tmp/extract/app/Providers/AppServiceProvider.php" "$app_provider"
      fi
      chown pterodactyl:pterodactyl "$panel/app/Http/Kernel.php" "$app_provider"
    }

    rerun_blueprint_framework() {
      echo "pterodactyl-blueprint-install: re-running Blueprint framework install..."
      refresh_blueprint_framework_release
      ensure_blueprint_core_patches
      ensure_blueprint_admin_layout_patches
      rm -f "$panel/.blueprint/extensions/blueprint/private/db/is_installed"
      rm -f "$panel/.blueprint/lock" 2>/dev/null || true
      cd "$panel"
      env BLUEPRINT_ENVIRONMENT=ci HOME=/var/lib/pterodactyl TERM=dumb LC_ALL=C.UTF-8 LANG=C.UTF-8 PATH="$PATH" \
        ${pkgs.bash}/bin/bash "$panel/blueprint.sh"
      if blueprint_cli -info 2>/dev/null | grep -qi sociallogin; then
        echo "pterodactyl-blueprint-install: re-registering Social Login extension routes..."
        rm -f "$panel/.blueprint/lock"
        blueprint_cli -install sociallogin
      fi
      ensure_blueprint_admin_layout_patches
      ensure_blueprint_placeholder_version
      ensure_blueprint_frontend_patches
      ensure_frontend_built
    }

    install_portforward_extension() {
      if [ ! -d "${portforwardExtensionSrc}" ]; then
        echo "pterodactyl-blueprint-install: Port Forward extension source missing at ${portforwardExtensionSrc}" >&2
        return 1
      fi
      if [ -d "$panel/.blueprint/extensions/portforward/private/.store" ]; then
        echo "pterodactyl-blueprint-install: Port Forward extension already present"
        return 0
      fi
      if [ -e "$panel/.blueprint/extensions/portforward" ] \
         || [ -e "$panel/public/extensions/portforward" ] \
         || [ -e "$panel/app/BlueprintFramework/Extensions/portforward" ] \
         || [ -e "$panel/storage/extensions/portforward" ]; then
        echo "pterodactyl-blueprint-install: stale Port Forward install detected, clearing for fresh install" >&2
        rm -rf "$panel/.blueprint/extensions/portforward"
        rm -f "$panel/public/extensions/portforward" "$panel/storage/extensions/portforward"
        rm -rf "$panel/app/BlueprintFramework/Extensions/portforward"
      fi
      echo "pterodactyl-blueprint-install: installing portforward extension from dev tree..."
      install -d -m 0755 -o pterodactyl -g pterodactyl "$panel/.blueprint/dev"
      rm -rf "$panel/.blueprint/dev/"*
      cp -a "${portforwardExtensionSrc}/." "$panel/.blueprint/dev/"
      chown -R pterodactyl:pterodactyl "$panel/.blueprint/dev"
      regfile="$panel/.blueprint/extensions/blueprint/private/db/installed_extensions"
      if [ -f "$regfile" ]; then
        echo "pterodactyl-blueprint-install: clearing Port Forward registry entry for fresh install" >&2
        ${pkgs.gnused}/bin/sed -i 's/|portforward,//g' "$regfile"
      fi
      if ! blueprint_cli -info 2>/dev/null | grep -qi portforward; then
        rm -f "$panel/.blueprint/lock"
        blueprint_cli -install '[developer-build]' \
          || blueprint_cli -i '[developer-build]'
      fi
    }

    install_dnsrecords_extension() {
      if [ ! -d "${dnsExtensionSrc}" ]; then
        echo "pterodactyl-blueprint-install: DNS extension source missing at ${dnsExtensionSrc}" >&2
        return 1
      fi
      if [ -d "$panel/.blueprint/extensions/dnsrecords/private/.store" ]; then
        echo "pterodactyl-blueprint-install: DNS Records extension already present"
        return 0
      fi
      if [ -e "$panel/.blueprint/extensions/dnsrecords" ] \
         || [ -e "$panel/public/extensions/dnsrecords" ] \
         || [ -e "$panel/app/BlueprintFramework/Extensions/dnsrecords" ] \
         || [ -e "$panel/storage/extensions/dnsrecords" ]; then
        echo "pterodactyl-blueprint-install: stale DNS Records install detected, clearing for fresh install" >&2
        rm -rf "$panel/.blueprint/extensions/dnsrecords"
        rm -f "$panel/public/extensions/dnsrecords" "$panel/storage/extensions/dnsrecords"
        rm -rf "$panel/app/BlueprintFramework/Extensions/dnsrecords"
      fi
      echo "pterodactyl-blueprint-install: installing dnsrecords extension from dev tree..."
      install -d -m 0755 -o pterodactyl -g pterodactyl "$panel/.blueprint/dev"
      rm -rf "$panel/.blueprint/dev/"*
      cp -a "${dnsExtensionSrc}/." "$panel/.blueprint/dev/"
      chown -R pterodactyl:pterodactyl "$panel/.blueprint/dev"
      regfile="$panel/.blueprint/extensions/blueprint/private/db/installed_extensions"
      if [ -f "$regfile" ]; then
        echo "pterodactyl-blueprint-install: clearing DNS Records registry entry for fresh install" >&2
        ${pkgs.gnused}/bin/sed -i 's/|dnsrecords,//g' "$regfile"
      fi
      if ! blueprint_cli -info 2>/dev/null | grep -qi dnsrecords; then
        rm -f "$panel/.blueprint/lock"
        blueprint_cli -install '[developer-build]' \
          || blueprint_cli -i '[developer-build]'
      fi
    }

    MinecraftToolsMigration="2024_01_01_000000_create_minecraft_tools_tables.php"

    minecraft_tools_migration_present() {
      [ -f "$panel/database/migrations/$MinecraftToolsMigration" ]
    }

    minecraft_tools_integrated() {
      [ -d "$panel/.blueprint/extensions/minecraft-tools/private/.store" ] \
        && [ -f "$panel/resources/views/admin/extensions/minecraft-tools/index.blade.php" ] \
        && minecraft_tools_migration_present
    }

    ensure_identifier_validator_patch() {
      vfile="$panel/scripts/helpers/validate-identifier.js"
      if [ -f "$vfile" ] && grep -q '\[^a-z\]' "$vfile" && ! grep -q '\[^a-z-\]' "$vfile"; then
        echo "pterodactyl-blueprint-install: relaxing extension identifier validator to allow hyphens..."
        ${pkgs.gnused}/bin/sed -i 's/\[^a-z\]/\[^a-z-]/g' "$vfile"
        chown pterodactyl:pterodactyl "$vfile"
      fi
    }

    install_minecraft_tools_extension() {
      if [ ! -d "${minecraftToolsSrc}/blueprint/dev" ]; then
        echo "pterodactyl-blueprint-install: Minecraft Tools extension source missing at ${minecraftToolsSrc}/blueprint/dev" >&2
        return 1
      fi
      ensure_identifier_validator_patch
      if [ -d "$panel/.blueprint/extensions/minecraft-tools/private/.store" ]; then
        echo "pterodactyl-blueprint-install: Minecraft Tools extension already present"
        return 0
      fi
      if [ -e "$panel/.blueprint/extensions/minecraft-tools" ] \
         || [ -e "$panel/public/extensions/minecraft-tools" ] \
         || [ -e "$panel/app/BlueprintFramework/Extensions/minecraft-tools" ] \
         || [ -e "$panel/storage/extensions/minecraft-tools" ]; then
        echo "pterodactyl-blueprint-install: stale Minecraft Tools install detected, clearing for fresh install" >&2
        rm -rf "$panel/.blueprint/extensions/minecraft-tools"
        rm -f "$panel/public/extensions/minecraft-tools" "$panel/storage/extensions/minecraft-tools"
        rm -rf "$panel/app/BlueprintFramework/Extensions/minecraft-tools"
      fi
      echo "pterodactyl-blueprint-install: installing minecraft-tools extension from dev tree..."
      install -d -m 0755 -o pterodactyl -g pterodactyl "$panel/.blueprint/dev"
      rm -rf "$panel/.blueprint/dev/"*
      cp -a "${minecraftToolsSrc}/blueprint/dev/." "$panel/.blueprint/dev/"
      chown -R pterodactyl:pterodactyl "$panel/.blueprint/dev"
      cat > "$panel/.blueprint/dev/conf.yml" <<'MC_CONF_EOF'
info:
  name: 'Minecraft Tools'
  identifier: 'minecraft-tools'
  description: 'A Pterodactyl extension for Minecraft server utilities'
  version: '1.0.0'
  target: 'beta-2025-09'
  author: 'Preston Hager'
  website: 'https://github.com/PrestonHager/nixos-configs'

admin:
  view: 'resources/views/admin/view.blade.php'

dashboard:
  components: 'dashboard/components'
MC_CONF_EOF
      chown pterodactyl:pterodactyl "$panel/.blueprint/dev/conf.yml"
      regfile="$panel/.blueprint/extensions/blueprint/private/db/installed_extensions"
      if [ -f "$regfile" ]; then
        echo "pterodactyl-blueprint-install: clearing Minecraft Tools registry entry for fresh install" >&2
        ${pkgs.gnused}/bin/sed -i 's/|minecraft-tools,//g' "$regfile"
      fi
      if ! blueprint_cli -info 2>/dev/null | grep -qi minecraft-tools; then
        rm -f "$panel/.blueprint/lock"
        blueprint_cli -install '[developer-build]' \
          || blueprint_cli -i '[developer-build]'
      fi
    }

    ensure_minecraft_tools_migration() {
      cat > "$panel/database/migrations/$MinecraftToolsMigration" <<'MC_MIG_EOF'
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::dropIfExists('minecraft_tools_plugin_configs');
        Schema::dropIfExists('minecraft_tools_modpack_configs');
        Schema::dropIfExists('minecraft_tools_icon_history');
        Schema::dropIfExists('minecraft_tools_config_backups');
        Schema::dropIfExists('minecraft_tools_player_notes');

        Schema::create('minecraft_tools_plugin_configs', function (Blueprint $table) {
            $table->id();
            $table->unsignedInteger('server_id');
            $table->string('plugin_name');
            $table->json('config')->nullable();
            $table->timestamps();

            $table->unique(['server_id', 'plugin_name']);
            $table->foreign('server_id')->references('id')->on('servers')->onDelete('cascade');
        });

        Schema::create('minecraft_tools_modpack_configs', function (Blueprint $table) {
            $table->id();
            $table->unsignedInteger('server_id');
            $table->string('modpack_name');
            $table->json('config')->nullable();
            $table->timestamps();

            $table->unique(['server_id', 'modpack_name']);
            $table->foreign('server_id')->references('id')->on('servers')->onDelete('cascade');
        });

        Schema::create('minecraft_tools_icon_history', function (Blueprint $table) {
            $table->id();
            $table->unsignedInteger('server_id');
            $table->string('url');
            $table->unsignedBigInteger('size')->default(0);
            $table->timestamps();

            $table->foreign('server_id')->references('id')->on('servers')->onDelete('cascade');
        });

        Schema::create('minecraft_tools_config_backups', function (Blueprint $table) {
            $table->id();
            $table->unsignedInteger('server_id');
            $table->string('file');
            $table->text('content');
            $table->unsignedBigInteger('size')->default(0);
            $table->timestamps();

            $table->foreign('server_id')->references('id')->on('servers')->onDelete('cascade');
        });

        Schema::create('minecraft_tools_player_notes', function (Blueprint $table) {
            $table->id();
            $table->unsignedInteger('server_id');
            $table->string('username');
            $table->string('uuid')->nullable();
            $table->text('notes')->nullable();
            $table->string('display_name')->nullable();
            $table->timestamps();

            $table->unique(['server_id', 'username']);
            $table->foreign('server_id')->references('id')->on('servers')->onDelete('cascade');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('minecraft_tools_player_notes');
        Schema::dropIfExists('minecraft_tools_config_backups');
        Schema::dropIfExists('minecraft_tools_icon_history');
        Schema::dropIfExists('minecraft_tools_modpack_configs');
        Schema::dropIfExists('minecraft_tools_plugin_configs');
    }
};
MC_MIG_EOF
      chown pterodactyl:pterodactyl "$panel/database/migrations/$MinecraftToolsMigration"
    }

    ensure_minecraft_tools_legacy_wiring() {
      port="${minecraftToolsPort}"
      if [ ! -d "$port" ]; then
        echo "pterodactyl-blueprint-install: Minecraft Tools legacy port tree missing at $port" >&2
        return 1
      fi

      echo "pterodactyl-blueprint-install: wiring Minecraft Tools legacy ABI..."

      ctrl_src="$port/app/Http/Controllers/Admin/Extensions/MinecraftTools/MinecraftToolsExtensionController.php"
      ctrl_dest="$panel/app/Http/Controllers/Admin/Extensions/MinecraftTools/MinecraftToolsExtensionController.php"
      rm -rf "$panel/app/Http/Controllers/Admin/Extensions/minecraft-tools"
      install -d -m 0755 -o pterodactyl -g pterodactyl "$(dirname "$ctrl_dest")"
      if [ ! -f "$ctrl_dest" ] || ! cmp -s "$ctrl_src" "$ctrl_dest"; then
        cp -a "$ctrl_src" "$ctrl_dest"
        chown pterodactyl:pterodactyl "$ctrl_dest"
      fi

      classes_src="$port/app/BlueprintFramework/Extensions/MinecraftTools"
      classes_dest="$panel/app/BlueprintFramework/Extensions/MinecraftTools"
      if [ ! -d "$classes_dest" ] || ! ${pkgs.diffutils}/bin/diff -qr "$classes_src" "$classes_dest" >/dev/null 2>&1; then
        rm -rf "$classes_dest"
        install -d -m 0755 -o pterodactyl -g pterodactyl "$(dirname "$classes_dest")"
        cp -a "$classes_src" "$classes_dest"
        chown -R pterodactyl:pterodactyl "$classes_dest"
      fi

      routes_src="$port/routes/blueprint/web/minecraft-tools.php"
      routes_dest="$panel/routes/blueprint/web/minecraft-tools.php"
      install -d -m 0755 -o pterodactyl -g pterodactyl "$(dirname "$routes_dest")"
      if [ ! -f "$routes_dest" ] || ! cmp -s "$routes_src" "$routes_dest"; then
        cp -a "$routes_src" "$routes_dest"
        chown pterodactyl:pterodactyl "$routes_dest"
      fi

      cfg_src="$port/config/minecraft-tools.php"
      cfg_dest="$panel/config/minecraft-tools.php"
      install -d -m 0755 -o pterodactyl -g pterodactyl "$(dirname "$cfg_dest")"
      if [ ! -f "$cfg_dest" ] || ! cmp -s "$cfg_src" "$cfg_dest"; then
        cp -a "$cfg_src" "$cfg_dest"
        chown pterodactyl:pterodactyl "$cfg_dest"
      fi

      view_src_root="${minecraftToolsSrc}/blueprint/dev/resources/views/admin"
      view_dest_root="$panel/resources/views/admin/extensions/minecraft-tools"
      install -d -m 0755 -o pterodactyl -g pterodactyl "$view_dest_root"
      if [ -d "$view_src_root" ]; then
        for blade in view plugins versions players modpacks config icon; do
          name="index"
          [ "$blade" != "view" ] && name="$blade"
          src_blade="$view_src_root/$blade.blade.php"
          [ -f "$src_blade" ] || continue
          dest_blade="$view_dest_root/$name.blade.php"
          ${pkgs.gnused}/bin/sed \
            -e "s|@extends('admin.layouts.default')|@extends('layouts.admin')|" \
            -e 's|/api/extensions/minecraft-tools|/minecraft-tools/api|g' \
            "$src_blade" > "$dest_blade"
          chown pterodactyl:pterodactyl "$dest_blade"
        done
      fi

      blueprint_routes="$panel/routes/blueprint.php"
      echo "pterodactyl-blueprint-install: checking blueprint.php admin controller resolution for hyphen identifiers..."
      ${pkgs.gnused}/bin/sed -i '/classSafe = preg_replace/d' "$blueprint_routes"
      ${pkgs.gnused}/bin/sed -i \
        "/\$controllerName = \$identifier . 'ExtensionController';/a\  \$classSafe = preg_replace(\"/-/\", \"\", \$identifier);" \
        "$blueprint_routes"
      ${pkgs.gnused}/bin/sed -i \
        's|{\$identifier}\\\\{$controllerName}"|{\$classSafe}\\\\{$classSafe}ExtensionController"|' \
        "$blueprint_routes"
      ${pkgs.gnused}/bin/sed -i \
        's|use ($identifier, $controllerName)|use ($identifier, $controllerName, $classSafe)|' \
        "$blueprint_routes"
      chown pterodactyl:pterodactyl "$blueprint_routes"

      ${pkgs.podman}/bin/podman exec \
        -e HOME=/var/www/pterodactyl \
        -e COMPOSER_HOME=/tmp/composer \
        pterodactyl \
        sh -c 'cd /var/www/pterodactyl && composer dump-autoload -o'
      ${pkgs.podman}/bin/podman exec pterodactyl php /var/www/pterodactyl/artisan route:clear
      ${pkgs.podman}/bin/podman exec pterodactyl php /var/www/pterodactyl/artisan config:clear
      ${pkgs.podman}/bin/podman exec pterodactyl php /var/www/pterodactyl/artisan view:clear

      routes=$( ${pkgs.podman}/bin/podman exec pterodactyl php /var/www/pterodactyl/artisan route:list 2>/dev/null || true)
      case "$routes" in
        *'minecraft-tools'*) echo "pterodactyl-blueprint-install: minecraft-tools routes registered" ;;
        *) echo "pterodactyl-blueprint-install: WARNING minecraft-tools routes not present in route:list" ;;
      esac
    }

    post_install_hooks() {
      ensure_blueprint_assets
      ensure_blueprint_core_patches
      ensure_identifier_validator_patch
      ensure_sociallogin_models
      ensure_extension_app_symlinks
      ensure_storage_extension_symlinks
      ensure_public_assets_extension_symlinks
      ensure_blueprint_admin_extension_theme
      ensure_extension_backend_sync
      ensure_extension_public_permissions
      ensure_extension_default_icons
      ensure_extension_admin_files
      ensure_extension_migrations
      ensure_minecraft_tools_migration
      ensure_minecraft_tools_legacy_wiring
      ensure_blueprint_admin_layout_patches
      ensure_blueprint_placeholder_version
      ensure_blueprint_frontend_patches
      ensure_frontend_built

      if [ ! -f "$panel/vendor/autoload.php" ]; then
        ${pkgs.podman}/bin/podman exec \
          -e HOME=/var/www/pterodactyl \
          -e COMPOSER_HOME=/tmp/composer \
          pterodactyl \
          sh -c 'cd /var/www/pterodactyl && composer install --no-dev --optimize-autoloader'
      else
        ${pkgs.podman}/bin/podman exec \
          -e HOME=/var/www/pterodactyl \
          -e COMPOSER_HOME=/tmp/composer \
          pterodactyl \
          sh -c 'cd /var/www/pterodactyl && composer dump-autoload -o'
      fi

      ${pkgs.podman}/bin/podman exec pterodactyl \
        php /var/www/pterodactyl/artisan migrate --force

      ${pkgs.podman}/bin/podman exec pterodactyl \
        php /var/www/pterodactyl/artisan db:seed --class=BlueprintSeeder --force

      ${pkgs.podman}/bin/podman exec pterodactyl \
        php /var/www/pterodactyl/artisan config:clear

      ${pkgs.podman}/bin/podman exec pterodactyl \
        php /var/www/pterodactyl/artisan view:clear

      chown -R pterodactyl:pterodactyl "$panel"
      find "$panel/storage" "$panel/bootstrap/cache" -type d -exec chmod 2775 {} + 2>/dev/null || true
      ensure_extension_public_permissions
    }

    write_marker() {
      echo "blueprint+sociallogin+dnsrecords+portforward+minecraft-tools" > "$marker"
      chown pterodactyl:pterodactyl "$marker"
    }

    if blueprint_integrated \
      && blueprint_admin_layout_integrated \
      && blueprint_placeholder_integrated \
      && extension_backend_integrated \
      && [ -d "$panel/.blueprint/assets/Extensions" ] \
      && [ -d "$panel/.blueprint/extensions/sociallogin" ] \
      && [ -d "$panel/.blueprint/extensions/dnsrecords" ] \
      && [ -d "$panel/.blueprint/extensions/portforward" ] \
      && [ -d "$panel/.blueprint/extensions/minecraft-tools" ] \
      && [ -f "$panel/blueprint.sh" ] && [ -d "$panel/.blueprint/blueprint" ]; then
      pre_version=$(blueprint_framework_version 2>/dev/null || echo unknown)
      refresh_blueprint_framework_release
      ensure_blueprint_placeholder_version
      ensure_minecraft_tools_legacy_wiring
      post_version=$(blueprint_framework_version 2>/dev/null || echo unknown)
      if [ "$pre_version" = "$post_version" ]; then
        ensure_extension_public_permissions
        write_marker
        echo "pterodactyl-blueprint-install: Blueprint, Social Login, DNS Records, and Port Forward ready"
        exit 0
      fi
      echo "pterodactyl-blueprint-install: Blueprint release changed ($pre_version -> $post_version), completing upgrade..."
      ensure_blueprint_core_patches
      ensure_blueprint_admin_layout_patches
      ensure_blueprint_placeholder_version
      ensure_blueprint_frontend_patches
      post_install_hooks
      write_marker
      echo "pterodactyl-blueprint-install: Blueprint $post_version, Social Login, DNS Records, and Port Forward ready"
      exit 0
    fi

    if [ -d "$panel/.blueprint/extensions/sociallogin" ] \
      && [ -d "$panel/.blueprint/extensions/dnsrecords" ] \
      && [ -d "$panel/.blueprint/extensions/portforward" ] \
      && [ -f "$panel/blueprint.sh" ] && [ -d "$panel/.blueprint/blueprint" ]; then
      if ! minecraft_tools_integrated; then
        echo "pterodactyl-blueprint-install: Minecraft Tools missing, installing before repairs..."
        install_minecraft_tools_extension
      fi
      if ! extension_backend_integrated; then
        echo "pterodactyl-blueprint-install: extension symlinks, views, or migrations incomplete, repairing..."
        ensure_blueprint_assets
        ensure_extension_app_symlinks
        ensure_storage_extension_symlinks
        ensure_public_assets_extension_symlinks
        ensure_extension_admin_files
        ensure_extension_default_icons
        ensure_extension_migrations
        post_install_hooks
        write_marker
        echo "pterodactyl-blueprint-install: extension backend repaired on production panel"
        exit 0
      fi
      if blueprint_core_backend_integrated && ! blueprint_frontend_integrated; then
        echo "pterodactyl-blueprint-install: backend ready but login UI missing Social Login, repairing frontend..."
        ensure_blueprint_frontend_patches
        ensure_frontend_built
        post_install_hooks
        write_marker
        echo "pterodactyl-blueprint-install: Blueprint Social Login frontend repaired on production panel"
        exit 0
      fi
      if ! blueprint_core_backend_integrated; then
        echo "pterodactyl-blueprint-install: extensions present but Laravel integration missing, repairing..."
        ensure_blueprint_assets
        ensure_extension_app_symlinks
        ensure_storage_extension_symlinks
        ensure_public_assets_extension_symlinks
        ensure_extension_admin_files
        ensure_extension_default_icons
        ensure_extension_migrations
        rerun_blueprint_framework
        post_install_hooks
        write_marker
        echo "pterodactyl-blueprint-install: Blueprint integration repaired on production panel"
        exit 0
      fi
      if ! blueprint_site_config_integrated || ! blueprint_frontend_integrated; then
        echo "pterodactyl-blueprint-install: site config or frontend incomplete, repairing..."
        ensure_blueprint_frontend_patches
        ensure_frontend_built
        post_install_hooks
        write_marker
        echo "pterodactyl-blueprint-install: Blueprint site config and frontend repaired on production panel"
        exit 0
      fi
      if ! blueprint_admin_layout_integrated || ! blueprint_placeholder_integrated; then
        echo "pterodactyl-blueprint-install: admin layout or Blueprint version incomplete, repairing..."
        refresh_blueprint_framework_release
        ensure_blueprint_admin_layout_patches
        ensure_blueprint_placeholder_version
        post_install_hooks
        write_marker
        echo "pterodactyl-blueprint-install: Blueprint admin layout and version repaired on production panel"
        exit 0
      fi
    fi

    if [ -d "$panel/.blueprint/extensions/sociallogin" ] \
      && [ -f "$panel/blueprint.sh" ] && [ -d "$panel/.blueprint/blueprint" ]; then
      echo "pterodactyl-blueprint-install: Social Login present, installing DNS Records only..."
      if ! blueprint_backend_integrated; then
        rerun_blueprint_framework
      elif ! blueprint_frontend_integrated; then
        ensure_blueprint_frontend_patches
        ensure_frontend_built
      fi
      install_dnsrecords_extension
      install_portforward_extension
      if ! minecraft_tools_integrated; then
        install_minecraft_tools_extension
      fi
      post_install_hooks
      write_marker
      echo "pterodactyl-blueprint-install: DNS Records extension ready on production panel"
      exit 0
    fi

    if [ -d "$panel/.blueprint/extensions/sociallogin" ] \
      && [ -d "$panel/.blueprint/extensions/dnsrecords" ] \
      && [ ! -d "$panel/.blueprint/extensions/portforward" ] \
      && [ -f "$panel/blueprint.sh" ] && [ -d "$panel/.blueprint/blueprint" ]; then
      echo "pterodactyl-blueprint-install: DNS present, installing Port Forward only..."
      install_portforward_extension
      post_install_hooks
      write_marker
      echo "pterodactyl-blueprint-install: Port Forward extension ready on production panel"
      exit 0
    fi

    if [ -f "$marker" ]; then
      echo "pterodactyl-blueprint-install: marker present but extensions incomplete, continuing install..."
    fi

    echo "pterodactyl-blueprint-install: installing Blueprint framework..."

    rm -f "$panel/.blueprint/lock" 2>/dev/null || true

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT

    framework_ready=0
    if [ -f "$panel/blueprint.sh" ] && [ -d "$panel/.blueprint/blueprint" ]; then
      framework_ready=1
      echo "pterodactyl-blueprint-install: Blueprint framework already installed"
    else
      ${pkgs.curl}/bin/curl -fsSL "${blueprintReleaseUrl}" -o "$tmp/release.zip"
      ${pkgs.unzip}/bin/unzip -o "$tmp/release.zip" -d "$panel"
      chown -R pterodactyl:pterodactyl "$panel"
      install -m 0644 ${blueprintRc} "$panel/.blueprintrc"
      chmod +x "$panel/blueprint.sh"
      chown pterodactyl:pterodactyl "$panel/.blueprintrc" "$panel/blueprint.sh"
      install -d -m 0755 -o pterodactyl -g pterodactyl "$panel/.blueprint"
    fi

    # blueprint.sh tries to mv panel/blueprint → .blueprint/blueprint on every run
    if [ -d "$panel/blueprint" ] && [ -d "$panel/.blueprint/blueprint" ]; then
      rm -rf "$panel/blueprint"
    elif [ -d "$panel/blueprint" ]; then
      rm -rf "$panel/.blueprint/blueprint"
      mv "$panel/blueprint" "$panel/.blueprint/blueprint"
    fi

    if [ ! -d "$panel/node_modules" ]; then
      echo "pterodactyl-blueprint-install: installing panel node dependencies..."
      cd "$panel"
      runuser -u pterodactyl -- env HOME=/var/lib/pterodactyl TERM=dumb PATH="$PATH" yarn install --frozen-lockfile 2>/dev/null \
        || runuser -u pterodactyl -- env HOME=/var/lib/pterodactyl TERM=dumb PATH="$PATH" yarn install
    fi

    cd "$panel"
    if [ "$framework_ready" -eq 0 ] || ! blueprint_backend_integrated; then
      blueprint_cli_install
    fi

    ${pkgs.curl}/bin/curl -fsSL "${socialloginBlueprintUrl}" -o "$tmp/sociallogin.blueprint"
    cp "$tmp/sociallogin.blueprint" "$panel/sociallogin.blueprint"
    chown pterodactyl:pterodactyl "$panel/sociallogin.blueprint"

    cd "$panel"
    sociallogin_installed=0
    if blueprint_cli -info 2>/dev/null | grep -qi sociallogin; then
      sociallogin_installed=1
    fi
    if [ "$sociallogin_installed" -eq 0 ]; then
      echo "pterodactyl-blueprint-install: installing Social Login extension..."
      rm -f "$panel/.blueprint/lock"
      blueprint_cli -install sociallogin
    else
      echo "pterodactyl-blueprint-install: Social Login extension already installed"
    fi
    rm -f "$panel/sociallogin.blueprint"
    install_dnsrecords_extension
    install_portforward_extension
    if ! minecraft_tools_integrated; then
      install_minecraft_tools_extension
    fi
    post_install_hooks
    write_marker
    echo "pterodactyl-blueprint-install: Blueprint, Social Login, DNS Records, Port Forward, and Minecraft Tools ready"
  '';
in
{
  systemd.services.pterodactyl-blueprint-install = {
    description = "Install Blueprint, Social Login, DNS Records, and Port Forward on production panel";
    after = [
      "podman-pterodactyl.service"
      "pterodactyl-stock-reset.service"
    ];
    wants = [ "pterodactyl-stock-reset.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = installScript;
      RemainAfterExit = true;
      TimeoutStartSec = "90min";
    };
    path = with pkgs; [
      bash
      curl
      unzip
      git
      jq
      util-linux
      podman
      nodejs_22
      yarn
      coreutils
      gnused
      gnugrep
      procps
    ];
  };
}
