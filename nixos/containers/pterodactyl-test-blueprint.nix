{ config, pkgs, ... }:

let
  testPanelDir = "/home/prestonh/Projects/panel";
  testPanelBranch = "release/v1.14.0";
  stateDir = "/var/lib/pterodactyl-test";
  blueprintMarker = "${stateDir}/blueprint-installed";
  blueprintReleaseUrl = "https://github.com/BlueprintFramework/framework/releases/latest/download/release.zip";
  socialloginBlueprintUrl = "https://github.com/blueprint-community/extension-sociallogin/releases/download/1.2.0/sociallogin.blueprint";
  dnsExtensionSrc = "/etc/nixos/plugins/pterodactyl-dns-blueprint";
  portforwardExtensionSrc = "/etc/nixos/plugins/pterodactyl-portforward-blueprint";
  blueprintExtensionsThemeSrc = "/etc/nixos/plugins/pterodactyl-blueprint-extensions/public/admin-extension-theme.css";

  toolPath = pkgs.lib.makeBinPath [
    pkgs.bash
    pkgs.coreutils
    pkgs.gawk
    pkgs.gnused
    pkgs.gnugrep
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

  blueprintRc = pkgs.writeText "pterodactyl-test-blueprintrc" ''
    WEBUSER="prestonh"
    OWNERSHIP="prestonh:users"
    USERSHELL="/bin/sh"
    TECHNITIUM_API_URL="https://dns.prestonhager.com"
  '';

  installScript = pkgs.writeShellScript "pterodactyl-test-blueprint-install" ''
    set -euo pipefail
    panel="${testPanelDir}"
    marker="${blueprintMarker}"

    if [ ! -d "$panel/app" ]; then
      echo "pterodactyl-test-blueprint-install: panel not installed, skipping" >&2
      exit 0
    fi

    ensure_blueprint_private_core() {
      private="$panel/.blueprint/extensions/blueprint/private"
      install -d -m 0755 -o prestonh -g users "$private/debug" "$private/db"
      for item in extensionfs.php build db; do
        if [ -e "$private/$item" ]; then
          continue
        fi
        if [ -e "$prod_panel/.blueprint/extensions/blueprint/private/$item" ]; then
          echo "pterodactyl-test-blueprint-install: copying blueprint private/$item from production..."
          cp -a "$prod_panel/.blueprint/extensions/blueprint/private/$item" "$private/$item"
          chown -R prestonh:users "$private/$item"
        elif [ -e "$panel/.blueprint/blueprint/extensions/blueprint/private/$item" ]; then
          echo "pterodactyl-test-blueprint-install: copying blueprint private/$item from framework tree..."
          cp -a "$panel/.blueprint/blueprint/extensions/blueprint/private/$item" "$private/$item"
          chown -R prestonh:users "$private/$item"
        fi
      done
    }

    export PATH="${toolPath}:$PATH"
    export HOME=/home/prestonh
    export YARN_CACHE_FOLDER=/home/prestonh/.cache/yarn-blueprint-test
    export TERM=dumb
    export LC_ALL=C.UTF-8
    export LANG=C.UTF-8
    export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
    install -d -m 0750 -o pterodactyl -g pterodactyl "${stateDir}"
    install -d -m 0755 -o prestonh -g users /home/prestonh/.cache/yarn-blueprint-test

    blueprint_cli() {
      env \
        HOME=/home/prestonh \
        TERM=dumb \
        LC_ALL=C.UTF-8 \
        LANG=C.UTF-8 \
        YARN_CACHE_FOLDER=/home/prestonh/.cache/yarn-blueprint-test \
        PATH="$PATH" \
        ${pkgs.bash}/bin/bash "$panel/blueprint.sh" -bash "$@"
    }

    blueprint_cli_install() {
      env BLUEPRINT_ENVIRONMENT=ci \
        HOME=/home/prestonh \
        TERM=dumb \
        LC_ALL=C.UTF-8 \
        LANG=C.UTF-8 \
        YARN_CACHE_FOLDER=/home/prestonh/.cache/yarn-blueprint-test \
        PATH="$PATH" \
        ${pkgs.bash}/bin/bash "$panel/blueprint.sh" "$@"
    }

    prod_panel="/pterodactyl/html"

    ensure_sociallogin_registered() {
      if blueprint_cli -info 2>/dev/null | grep -qi sociallogin; then
        return 0
      fi
      if [ ! -f "$panel/blueprint.sh" ] || [ ! -d "$panel/.blueprint/blueprint" ]; then
        echo "pterodactyl-test-blueprint-install: Blueprint framework missing, cannot register Social Login" >&2
        return 1
      fi
      echo "pterodactyl-test-blueprint-install: registering Social Login with Blueprint..."
      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"' RETURN
      ${pkgs.curl}/bin/curl -fsSL "${socialloginBlueprintUrl}" -o "$tmp/sociallogin.blueprint"
      cp "$tmp/sociallogin.blueprint" "$panel/sociallogin.blueprint"
      chown prestonh:users "$panel/sociallogin.blueprint"
      rm -f "$panel/.blueprint/lock"
      blueprint_cli -install sociallogin
      rm -f "$panel/sociallogin.blueprint"
    }

    ensure_blueprint_private_core

    ensure_sociallogin_models() {
      datadir="$panel/.blueprint/extensions/sociallogin/private"
      if [ ! -f "$panel/app/Models/SocialProvider.php" ] && [ -f "$datadir/SocialProvider.php" ]; then
        echo "pterodactyl-test-blueprint-install: installing Social Login model files..."
        cp -f "$datadir/SocialProvider.php" "$panel/app/Models/SocialProvider.php"
        cp -f "$datadir/SocialConnection.php" "$panel/app/Models/SocialConnection.php"
        chown prestonh:users "$panel/app/Models/SocialProvider.php" "$panel/app/Models/SocialConnection.php"
      elif [ ! -f "$panel/app/Models/SocialProvider.php" ] && [ -f "$prod_panel/.blueprint/extensions/sociallogin/private/SocialProvider.php" ]; then
        echo "pterodactyl-test-blueprint-install: copying Social Login models from production panel..."
        cp -f "$prod_panel/.blueprint/extensions/sociallogin/private/SocialProvider.php" "$panel/app/Models/SocialProvider.php"
        cp -f "$prod_panel/.blueprint/extensions/sociallogin/private/SocialConnection.php" "$panel/app/Models/SocialConnection.php"
        chown prestonh:users "$panel/app/Models/SocialProvider.php" "$panel/app/Models/SocialConnection.php"
      fi
    }

    ensure_installed_extension_trees() {
      installed_file="$panel/.blueprint/extensions/blueprint/private/db/installed_extensions"
      [ -f "$installed_file" ] || return 0

      for ext in sociallogin dnsrecords portforward; do
        if ! grep -q "|$ext," "$installed_file" 2>/dev/null; then
          continue
        fi
        conf="$panel/.blueprint/extensions/$ext/private/.store/conf.yml"
        if [ -f "$conf" ]; then
          continue
        fi
        if [ -d "$prod_panel/.blueprint/extensions/$ext" ]; then
          echo "pterodactyl-test-blueprint-install: copying $ext extension tree from production..."
          install -d -m 0755 -o prestonh -g users "$panel/.blueprint/extensions"
          cp -a "$prod_panel/.blueprint/extensions/$ext" "$panel/.blueprint/extensions/$ext"
          chown -R prestonh:users "$panel/.blueprint/extensions/$ext"
          continue
        fi
        case "$ext" in
          dnsrecords) install_dnsrecords_extension ;;
          portforward) install_portforward_extension ;;
          sociallogin)
            tmp=$(mktemp -d)
            ${pkgs.curl}/bin/curl -fsSL "${socialloginBlueprintUrl}" -o "$tmp/sociallogin.blueprint"
            cp "$tmp/sociallogin.blueprint" "$panel/sociallogin.blueprint"
            chown prestonh:users "$panel/sociallogin.blueprint"
            rm -f "$panel/.blueprint/lock"
            blueprint_cli -install sociallogin
            rm -f "$panel/sociallogin.blueprint"
            rm -rf "$tmp"
            ;;
        esac
      done
    }

    ensure_extension_container_permissions() {
      for ext in blueprint sociallogin dnsrecords portforward; do
        ext_dir="$panel/.blueprint/extensions/$ext"
        [ -d "$ext_dir" ] || continue
        find "$ext_dir" -type d -exec chmod 755 {} + 2>/dev/null || true
        find "$ext_dir" -type f -exec chmod 644 {} + 2>/dev/null || true
        ${pkgs.acl}/bin/setfacl -R -m u:pterodactyl:rwx "$ext_dir" 2>/dev/null || true
        ${pkgs.acl}/bin/setfacl -R -d -m u:pterodactyl:rwx "$ext_dir" 2>/dev/null || true
      done
    }

    blueprint_private_integrated() {
      [ -f "$panel/.blueprint/extensions/blueprint/private/extensionfs.php" ] \
        && [ -f "$panel/.blueprint/extensions/blueprint/private/db/installed_extensions" ]
      installed_file="$panel/.blueprint/extensions/blueprint/private/db/installed_extensions"
      for ext in sociallogin dnsrecords portforward; do
        if grep -q "|$ext," "$installed_file" 2>/dev/null; then
          [ -f "$panel/.blueprint/extensions/$ext/private/.store/conf.yml" ] || return 1
        fi
      done
    }

    ensure_blueprint_assets() {
      if [ -d "$panel/.blueprint/assets/Extensions" ]; then
        return 0
      fi
      if [ -d "$panel/.blueprint/blueprint/assets" ]; then
        echo "pterodactyl-test-blueprint-install: copying Blueprint assets from framework tree..."
        cp -a "$panel/.blueprint/blueprint/assets" "$panel/.blueprint/assets"
        chown -R prestonh:users "$panel/.blueprint/assets"
        return 0
      fi
      if [ -d "$prod_panel/.blueprint/assets" ]; then
        echo "pterodactyl-test-blueprint-install: copying Blueprint assets from production panel..."
        cp -a "$prod_panel/.blueprint/assets" "$panel/.blueprint/assets"
        chown -R prestonh:users "$panel/.blueprint/assets"
      fi
    }

    ensure_extension_app_symlinks() {
      ext_root="$panel/app/BlueprintFramework/Extensions"
      install -d -m 0755 -o prestonh -g users "$ext_root"
      for ext in sociallogin dnsrecords portforward; do
        if [ ! -d "$panel/.blueprint/extensions/$ext/app" ]; then
          continue
        fi
        if [ -L "$ext_root/$ext" ] || [ -d "$ext_root/$ext" ]; then
          continue
        fi
        echo "pterodactyl-test-blueprint-install: linking $ext extension app into BlueprintFramework..."
        ln -sfn "../../../.blueprint/extensions/$ext/app" "$ext_root/$ext"
        chown -h prestonh:users "$ext_root/$ext"
      done
    }

    ensure_storage_extension_symlinks() {
      storage_ext="$panel/storage/extensions"
      install -d -m 2775 -o prestonh -g users "$storage_ext"
      for ext in sociallogin dnsrecords portforward; do
        if [ ! -d "$panel/.blueprint/extensions/$ext/fs" ]; then
          continue
        fi
        if [ -L "$storage_ext/$ext" ] || [ -d "$storage_ext/$ext" ]; then
          continue
        fi
        echo "pterodactyl-test-blueprint-install: linking $ext extension public files into storage..."
        ln -sfn "../../.blueprint/extensions/$ext/fs" "$storage_ext/$ext"
        chown -h prestonh:users "$storage_ext/$ext"
      done
    }

    ensure_blueprint_admin_extension_theme() {
      src="${blueprintExtensionsThemeSrc}"
      if [ ! -f "$src" ]; then
        echo "pterodactyl-test-blueprint-install: extension theme CSS missing at $src, skipping" >&2
        return 0
      fi
      dest="$panel/.blueprint/extensions/blueprint/assets/admin.extensions.css"
      install -d -m 0755 -o prestonh -g users "$(dirname "$dest")"
      {
        printf '%s\n' '/*'
        printf '%s\n' '  Admin stylesheets for Blueprint extensions.'
        printf '%s\n' '  Synced from nixos-configs admin-extension-theme.css'
        printf '%s\n' '*/'
        cat "$src"
      } > "$dest"
      chown prestonh:users "$dest"
    }

    ensure_public_assets_extension_symlinks() {
      assets_ext="$panel/public/assets/extensions"
      install -d -m 2775 -o prestonh -g users "$assets_ext"
      for ext in blueprint sociallogin dnsrecords portforward; do
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
        echo "pterodactyl-test-blueprint-install: linking $ext extension assets into public..."
        ln -sfn "../../../.blueprint/extensions/$ext/assets" "$link"
        chown -h prestonh:users "$link"
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
      caddy_root="/pterodactyl-test/public"
      for ext in blueprint sociallogin dnsrecords portforward; do
        asset=$(extension_public_asset_file "$ext")
        [ -f "$asset" ] || return 1
        if [ "$ext" = "blueprint" ]; then
          caddy_file="$caddy_root/assets/extensions/blueprint/logo.jpg"
        else
          caddy_file="$caddy_root/assets/extensions/$ext/icon.jpg"
        fi
        [ -f "$caddy_file" ] || return 1
      done
    }

  minAdminViewBytes=100

    extension_admin_view_source() {
      ext="$1"
      case "$ext" in
        dnsrecords) echo "${dnsExtensionSrc}/admin/view.blade.php" ;;
        portforward) echo "${portforwardExtensionSrc}/admin/view.blade.php" ;;
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
      for ext in sociallogin dnsrecords portforward; do
        ctrl="$panel/app/Http/Controllers/Admin/Extensions/$ext/''${ext}ExtensionController.php"
        view="$panel/resources/views/admin/extensions/$ext/index.blade.php"
        prod_ctrl="$prod_panel/app/Http/Controllers/Admin/Extensions/$ext/''${ext}ExtensionController.php"
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
            echo "pterodactyl-test-blueprint-install: syncing $ext admin controller from plugin source..."
            install -d -m 0755 -o prestonh -g users "$(dirname "$ctrl")"
            cp -a "$src_ctrl" "$ctrl"
            chown prestonh:users "$ctrl"
          fi
        elif [ ! -f "$ctrl" ]; then
          if [ -f "$prod_ctrl" ]; then
            echo "pterodactyl-test-blueprint-install: copying $ext admin controller from production..."
            install -d -m 0755 -o prestonh -g users "$(dirname "$ctrl")"
            cp -a "$prod_ctrl" "$ctrl"
            chown prestonh:users "$ctrl"
          elif [ "$ext" = "sociallogin" ]; then
            echo "pterodactyl-test-blueprint-install: reinstalling Social Login to restore admin controller..."
            rm -f "$panel/.blueprint/lock"
            blueprint_cli -install sociallogin
          fi
        fi

        if [ -n "$src_view" ]; then
          view_needs_sync=0
          if [ ! -f "$view" ] || extension_admin_view_corrupted "$ext"; then
            view_needs_sync=1
          elif ! cmp -s "$src_view" "$view"; then
            view_needs_sync=1
          fi
          if [ "$view_needs_sync" -eq 1 ]; then
            echo "pterodactyl-test-blueprint-install: syncing $ext admin view from plugin source..."
            install -d -m 0755 -o prestonh -g users "$(dirname "$view")"
            cp -a "$src_view" "$view"
            chown prestonh:users "$view"
          fi
          src_partials=""
          case "$ext" in
            dnsrecords) src_partials="${dnsExtensionSrc}/admin/partials" ;;
            portforward) src_partials="${portforwardExtensionSrc}/admin/partials" ;;
          esac
          if [ -n "$src_partials" ] && [ -d "$src_partials" ]; then
            partials_dest="$panel/resources/views/admin/extensions/$ext/partials"
            if [ ! -d "$partials_dest" ] || ! ${pkgs.diffutils}/bin/diff -qr "$src_partials" "$partials_dest" >/dev/null 2>&1; then
              echo "pterodactyl-test-blueprint-install: syncing $ext admin view partials from plugin source..."
              install -d -m 0755 -o prestonh -g users "$partials_dest"
              cp -a "$src_partials/." "$partials_dest/"
              chown -R prestonh:users "$partials_dest"
            fi
          fi
          continue
        fi

        prod_view="$prod_panel/resources/views/admin/extensions/$ext/index.blade.php"
        view_bytes=0
        if [ -f "$view" ]; then
          view_bytes=$(${pkgs.coreutils}/bin/wc -c < "$view" | tr -d ' ')
        fi
        if [ -f "$prod_view" ] && { [ ! -f "$view" ] || [ "$view_bytes" -lt "$minAdminViewBytes" ]; }; then
          echo "pterodactyl-test-blueprint-install: copying $ext admin view from production..."
          install -d -m 0755 -o prestonh -g users "$(dirname "$view")"
          cp -a "$prod_view" "$view"
          chown prestonh:users "$view"
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
            echo "pterodactyl-test-blueprint-install: syncing $ext/$sub from plugin source..."
            rm -rf "$dest/$sub"
            cp -a "$src/$sub" "$dest/$sub"
            chown -R prestonh:users "$dest/$sub"
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
        install -d -m 0755 -o prestonh -g users "$(dirname "$dest_wrapper")"
        if [ ! -f "$dest_wrapper" ] || ! cmp -s "$src_wrapper" "$dest_wrapper"; then
          echo "pterodactyl-test-blueprint-install: syncing $ext admin wrapper from plugin source..."
          cp -a "$src_wrapper" "$dest_wrapper"
          chown prestonh:users "$dest_wrapper"
        fi
      }
      sync_extension_panel_routes() {
        ext="$1"
        src="$2"
        for router in web application client; do
          src_route="$src/routes/$router.php"
          dest_route="$panel/routes/blueprint/$router/$ext.php"
          [ -f "$src_route" ] || continue
          install -d -m 0755 -o prestonh -g users "$(dirname "$dest_route")"
          if [ ! -f "$dest_route" ] || ! cmp -s "$src_route" "$dest_route"; then
            echo "pterodactyl-test-blueprint-install: syncing $ext $router routes into panel..."
            cp -a "$src_route" "$dest_route"
            chown prestonh:users "$dest_route"
          fi
        done
      }
      sync_extension_backend dnsrecords "${dnsExtensionSrc}"
      sync_extension_backend portforward "${portforwardExtensionSrc}"
      sync_extension_wrapper dnsrecords "${dnsExtensionSrc}"
      sync_extension_wrapper portforward "${portforwardExtensionSrc}"
      sync_extension_panel_routes dnsrecords "${dnsExtensionSrc}"
      sync_extension_panel_routes portforward "${portforwardExtensionSrc}"
    }

    ensure_extension_public_permissions() {
      for ext in blueprint sociallogin dnsrecords portforward; do
        public_dir="$panel/.blueprint/extensions/$ext/public"
        [ -d "$public_dir" ] || continue
        chmod 755 "$public_dir" 2>/dev/null || true
        find "$public_dir" -type d -exec chmod 755 {} + 2>/dev/null || true
        find "$public_dir" -type f -exec chmod 644 {} + 2>/dev/null || true
      done
    }

    extension_public_permissions_ok() {
      for ext in blueprint sociallogin dnsrecords portforward; do
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
      for migration in "$prod_panel"/database/migrations/2026_*.php; do
        [ -f "$migration" ] || continue
        base=$(${pkgs.coreutils}/bin/basename "$migration")
        if [ ! -f "$panel/database/migrations/$base" ]; then
          echo "pterodactyl-test-blueprint-install: copying missing migration $base from production..."
          cp -a "$migration" "$panel/database/migrations/$base"
          chown prestonh:users "$panel/database/migrations/$base"
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
      blueprint_private_integrated || return 1
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
        && [ -f "$panel/routes/blueprint/web/sociallogin.php" ]
    }

    blueprint_backend_integrated() {
      blueprint_core_backend_integrated && extension_backend_integrated
    }

    blueprint_site_config_integrated() {
      grep -q 'disable_attribution' "$panel/app/Http/ViewComposers/AssetComposer.php" 2>/dev/null \
        && grep -q 'disable_attribution' "$panel/resources/scripts/state/settings.ts" 2>/dev/null \
        && grep -q 'blueprint.dashboard.dashboard' "$panel/resources/views/templates/wrapper.blade.php" 2>/dev/null
    }

    blueprint_frontend_integrated() {
      grep -q '@blueprint/components/Authentication/Container/AfterContent' \
        "$panel/resources/scripts/components/auth/LoginFormContainer.tsx" 2>/dev/null \
        && grep -q "'@blueprint'" "$panel/webpack.config.js" 2>/dev/null \
        && grep -q '"@blueprint/\*"' "$panel/tsconfig.json" 2>/dev/null \
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
      echo "pterodactyl-test-blueprint-install: adding @blueprint webpack alias..."
      ${pkgs.gnused}/bin/sed -i \
        "/'@feature': path.join/a\\            '@blueprint': path.join(__dirname, '/resources/scripts/blueprint')," \
        "$panel/webpack.config.js"
      chown prestonh:users "$panel/webpack.config.js"
    }

    ensure_blueprint_tsconfig_paths() {
      if ${pkgs.jq}/bin/jq -e '.compilerOptions.paths["@blueprint/*"]' "$panel/tsconfig.json" >/dev/null 2>&1; then
        if ${pkgs.jq}/bin/jq -e '.compilerOptions["@blueprint/*"]' "$panel/tsconfig.json" >/dev/null 2>&1; then
          echo "pterodactyl-test-blueprint-install: fixing malformed @blueprint tsconfig entry..."
          ${pkgs.jq}/bin/jq 'del(.compilerOptions["@blueprint/*"])' \
            "$panel/tsconfig.json" > "$panel/tsconfig.json.tmp"
          mv "$panel/tsconfig.json.tmp" "$panel/tsconfig.json"
        fi
        return 0
      fi
      echo "pterodactyl-test-blueprint-install: adding @blueprint tsconfig paths..."
      ${pkgs.jq}/bin/jq '.compilerOptions.paths["@blueprint/*"] = ["./resources/scripts/blueprint/*"] | del(.compilerOptions["@blueprint/*"])' \
        "$panel/tsconfig.json" > "$panel/tsconfig.json.tmp"
      mv "$panel/tsconfig.json.tmp" "$panel/tsconfig.json"
      chown prestonh:users "$panel/tsconfig.json"
    }

    ensure_blueprint_index_css() {
      if grep -q "blueprint/css/extensions.css" "$panel/resources/scripts/index.tsx" 2>/dev/null; then
        return 0
      fi
      echo "pterodactyl-test-blueprint-install: adding Blueprint css import to index.tsx..."
      ${pkgs.gnused}/bin/sed -i \
        "/import '.\/i18n';/i // Import Blueprint extensions css\nimport './blueprint/css/extensions.css';\n" \
        "$panel/resources/scripts/index.tsx"
      chown prestonh:users "$panel/resources/scripts/index.tsx"
    }

    restore_stock_panel_frontend() {
      needs_restore=0
      if grep -rq "from 'pathe'" "$panel/resources/scripts/components" 2>/dev/null; then
        needs_restore=1
      fi
      if grep -q '@blueprint/components' "$panel/resources/scripts/routers/ServerRouter.tsx" 2>/dev/null; then
        needs_restore=1
      fi
      if [ "$needs_restore" -eq 0 ]; then
        return 0
      fi
      echo "pterodactyl-test-blueprint-install: restoring stock ${testPanelBranch} frontend sources..."
      ${pkgs.git}/bin/git -c safe.directory="$panel" -C "$panel" checkout "${testPanelBranch}" -- \
        resources/scripts/components \
        resources/scripts/routers
      chown -R prestonh:users \
        "$panel/resources/scripts/components" \
        "$panel/resources/scripts/routers"
    }

    ensure_blueprint_extends_compat() {
      extends_router="$panel/resources/scripts/blueprint/extends/routers/ServerRouter.tsx"
      if [ ! -f "$extends_router" ]; then
        return 0
      fi
      if ! grep -q 'BlueprintFramework.eggId' "$extends_router" 2>/dev/null; then
        return 0
      fi
      if grep -q 'Record<string, { eggId' "$extends_router" 2>/dev/null; then
        return 0
      fi
      echo "pterodactyl-test-blueprint-install: patching Blueprint extends for Pterodactyl 1.11..."
      ${pkgs.gnused}/bin/sed -i \
        's/state\.server\.data?\.BlueprintFramework\.eggId/(state.server.data as Record<string, { eggId?: number }> | undefined)?.BlueprintFramework?.eggId/g' \
        "$extends_router"
      chown prestonh:users "$extends_router"
    }

    ensure_blueprint_site_config_patches() {
      if blueprint_site_config_integrated; then
        return 0
      fi

      echo "pterodactyl-test-blueprint-install: restoring Blueprint site configuration patches from release..."
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
      chown prestonh:users \
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
      restore_stock_panel_frontend

      if [ "$needs_login_patch" -eq 0 ]; then
        ensure_blueprint_index_css
        ensure_blueprint_webpack_alias
        ensure_blueprint_tsconfig_paths
        ensure_blueprint_extends_compat
        return 0
      fi

      echo "pterodactyl-test-blueprint-install: restoring Blueprint frontend patches from release..."
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
      chown -R prestonh:users \
        "$panel/resources/scripts/components" \
        "$panel/resources/scripts/routers" \
        "$panel/resources/scripts/index.tsx" \
        "$panel/resources/scripts/blueprint/extends"
      rm -rf "$patch_tmp"
      ensure_blueprint_index_css
      ensure_blueprint_webpack_alias
      ensure_blueprint_tsconfig_paths
      ensure_blueprint_extends_compat
    }

    ensure_frontend_built() {
      if ${pkgs.gnugrep}/bin/grep -rq sociallogin "$panel/public/assets/"*.js 2>/dev/null; then
        return 0
      fi
      if [ -f "$panel/node_modules/cross-env/src/bin/cross-env.js" ]; then
        chmod u+rx "$panel/node_modules/cross-env/src/bin/cross-env.js" 2>/dev/null || true
      fi
      for bin in "$panel/node_modules/.bin"/*; do
        if [ -L "$bin" ]; then
          target="$panel/node_modules/.bin/$(readlink "$bin")"
          [ -f "$target" ] && chmod u+rx "$target" 2>/dev/null || true
        fi
      done
      echo "pterodactyl-test-blueprint-install: building panel frontend with Blueprint extensions..."
      cd "$panel"
      runuser -u prestonh -- rm -rf "$panel/node_modules"
      runuser -u prestonh -- env HOME=/home/prestonh YARN_CACHE_FOLDER=/home/prestonh/.cache/yarn-blueprint-test TERM=dumb PATH="$PATH" yarn install --frozen-lockfile 2>/dev/null \
        || runuser -u prestonh -- env HOME=/home/prestonh YARN_CACHE_FOLDER=/home/prestonh/.cache/yarn-blueprint-test TERM=dumb PATH="$PATH" yarn install
      runuser -u prestonh -- env \
        HOME=/home/prestonh \
        YARN_CACHE_FOLDER=/home/prestonh/.cache/yarn-blueprint-test \
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

      echo "pterodactyl-test-blueprint-install: restoring Blueprint Kernel/AppServiceProvider patches from release..."
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
      chown prestonh:users "$panel/app/Http/Kernel.php" "$app_provider"
    }

    rerun_blueprint_framework() {
      echo "pterodactyl-test-blueprint-install: re-running Blueprint framework install..."
      ensure_blueprint_core_patches
      install -d -m 0755 -o prestonh -g users "$panel/.blueprint/extensions/blueprint/private/db"
      rm -f "$panel/.blueprint/extensions/blueprint/private/db/is_installed"
      rm -f "$panel/.blueprint/lock" 2>/dev/null || true
      cd "$panel"
      env BLUEPRINT_ENVIRONMENT=ci HOME=/home/prestonh TERM=dumb LC_ALL=C.UTF-8 LANG=C.UTF-8 \
        YARN_CACHE_FOLDER=/home/prestonh/.cache/yarn-blueprint-test PATH="$PATH" \
        ${pkgs.bash}/bin/bash "$panel/blueprint.sh"
      if blueprint_cli -info 2>/dev/null | grep -qi sociallogin; then
        echo "pterodactyl-test-blueprint-install: re-registering Social Login extension routes..."
        rm -f "$panel/.blueprint/lock"
        blueprint_cli -install sociallogin
      fi
      ensure_blueprint_frontend_patches
      ensure_frontend_built
    }

    install_portforward_extension() {
      if [ ! -d "${portforwardExtensionSrc}" ]; then
        echo "pterodactyl-test-blueprint-install: Port Forward extension source missing at ${portforwardExtensionSrc}" >&2
        return 1
      fi
      if [ -d "$panel/.blueprint/extensions/portforward" ]; then
        echo "pterodactyl-test-blueprint-install: Port Forward extension already present"
        return 0
      fi
      echo "pterodactyl-test-blueprint-install: installing portforward extension from dev tree..."
      install -d -m 0755 -o prestonh -g users "$panel/.blueprint/dev"
      rm -rf "$panel/.blueprint/dev/"*
      cp -a "${portforwardExtensionSrc}/." "$panel/.blueprint/dev/"
      chown -R prestonh:users "$panel/.blueprint/dev"
      if ! blueprint_cli -info 2>/dev/null | grep -qi portforward; then
        rm -f "$panel/.blueprint/lock"
        blueprint_cli -install '[developer-build]' \
          || blueprint_cli -i '[developer-build]'
      fi
    }

    install_dnsrecords_extension() {
      ensure_sociallogin_registered || return 1
      if [ ! -d "${dnsExtensionSrc}" ]; then
        echo "pterodactyl-test-blueprint-install: DNS extension source missing at ${dnsExtensionSrc}" >&2
        return 1
      fi
      if [ -d "$panel/.blueprint/extensions/dnsrecords" ]; then
        echo "pterodactyl-test-blueprint-install: DNS Records extension already present"
        return 0
      fi
      echo "pterodactyl-test-blueprint-install: installing dnsrecords extension from dev tree..."
      install -d -m 0755 -o prestonh -g users "$panel/.blueprint/dev"
      rm -rf "$panel/.blueprint/dev/"*
      cp -a "${dnsExtensionSrc}/." "$panel/.blueprint/dev/"
      chown -R prestonh:users "$panel/.blueprint/dev"
      if ! blueprint_cli -info 2>/dev/null | grep -qi dnsrecords; then
        rm -f "$panel/.blueprint/lock"
        blueprint_cli -install '[developer-build]' \
          || blueprint_cli -i '[developer-build]'
      fi
    }

    post_install_hooks() {
      ensure_blueprint_private_core
      ensure_installed_extension_trees
      ensure_blueprint_assets
      ensure_blueprint_core_patches
      ensure_sociallogin_models
      ensure_extension_container_permissions
      ensure_extension_app_symlinks
      ensure_storage_extension_symlinks
      ensure_public_assets_extension_symlinks
      ensure_blueprint_admin_extension_theme
      ensure_extension_backend_sync
      ensure_extension_public_permissions
      ensure_extension_admin_files
      ensure_extension_migrations
      ensure_blueprint_frontend_patches
      ensure_frontend_built

      if [ ! -f "$panel/vendor/autoload.php" ]; then
        ${pkgs.podman}/bin/podman exec \
          -e HOME=/var/www/pterodactyl \
          -e COMPOSER_HOME=/tmp/composer \
          pterodactyl-test \
          sh -c 'cd /var/www/pterodactyl && composer install --no-dev --optimize-autoloader'
      else
        ${pkgs.podman}/bin/podman exec \
          -e HOME=/var/www/pterodactyl \
          -e COMPOSER_HOME=/tmp/composer \
          pterodactyl-test \
          sh -c 'cd /var/www/pterodactyl && composer dump-autoload -o'
      fi

      ${pkgs.podman}/bin/podman exec pterodactyl-test \
        php /var/www/pterodactyl/artisan migrate --force

      ${pkgs.podman}/bin/podman exec pterodactyl-test \
        php /var/www/pterodactyl/artisan db:seed --class=BlueprintSeeder --force

      ${pkgs.podman}/bin/podman exec pterodactyl-test \
        php /var/www/pterodactyl/artisan config:clear

      ${pkgs.podman}/bin/podman exec pterodactyl-test \
        php /var/www/pterodactyl/artisan view:clear

      chown -R prestonh:users "$panel"
      find "$panel/storage" "$panel/bootstrap/cache" -type d -exec chmod 2775 {} + 2>/dev/null || true
      ensure_extension_public_permissions
    }

    write_marker() {
      echo "blueprint+sociallogin+dnsrecords+portforward" > "$marker"
      chown pterodactyl:pterodactyl "$marker"
    }

    if blueprint_integrated \
      && extension_backend_integrated \
      && [ -d "$panel/.blueprint/assets/Extensions" ] \
      && [ -d "$panel/.blueprint/extensions/sociallogin" ] \
      && [ -d "$panel/.blueprint/extensions/dnsrecords" ] \
      && [ -d "$panel/.blueprint/extensions/portforward" ] \
      && [ -f "$panel/blueprint.sh" ] && [ -d "$panel/.blueprint/blueprint" ]; then
      ensure_extension_public_permissions
      ensure_extension_container_permissions
      write_marker
      echo "pterodactyl-test-blueprint-install: Blueprint, Social Login, DNS Records, and Port Forward ready"
      exit 0
    fi

    if [ -f "$panel/blueprint.sh" ] \
      && [ -d "$panel/.blueprint/blueprint" ] \
      && ! blueprint_private_integrated; then
      echo "pterodactyl-test-blueprint-install: Blueprint private core or extension conf missing, repairing..."
      ensure_blueprint_private_core
      ensure_installed_extension_trees
      ensure_extension_container_permissions
      ensure_extension_app_symlinks
      ensure_storage_extension_symlinks
      post_install_hooks
      write_marker
      echo "pterodactyl-test-blueprint-install: Blueprint private core repaired on test panel"
      exit 0
    fi

    if [ -d "$panel/.blueprint/extensions/sociallogin" ] \
      && [ -d "$panel/.blueprint/extensions/dnsrecords" ] \
      && [ ! -d "$panel/.blueprint/extensions/portforward" ] \
      && [ -f "$panel/blueprint.sh" ] && [ -d "$panel/.blueprint/blueprint" ]; then
      echo "pterodactyl-test-blueprint-install: DNS present, installing Port Forward only..."
      install_portforward_extension
      post_install_hooks
      write_marker
      echo "pterodactyl-test-blueprint-install: Port Forward extension ready on test panel"
      exit 0
    fi

    if [ -d "$panel/.blueprint/extensions/sociallogin" ] \
      && [ ! -d "$panel/.blueprint/extensions/dnsrecords" ] \
      && [ -f "$panel/blueprint.sh" ] && [ -d "$panel/.blueprint/blueprint" ]; then
      echo "pterodactyl-test-blueprint-install: Social Login present, installing DNS Records and Port Forward..."
      if ! blueprint_backend_integrated; then
        rerun_blueprint_framework
      elif ! blueprint_frontend_integrated; then
        ensure_blueprint_frontend_patches
        ensure_frontend_built
      fi
      install_dnsrecords_extension
      install_portforward_extension
      post_install_hooks
      write_marker
      echo "pterodactyl-test-blueprint-install: DNS Records and Port Forward ready on test panel"
      exit 0
    fi

    if [ -d "$panel/.blueprint/extensions/dnsrecords" ] \
      && [ ! -d "$panel/.blueprint/extensions/sociallogin" ] \
      && [ -f "$panel/blueprint.sh" ] && [ -d "$panel/.blueprint/blueprint" ]; then
      echo "pterodactyl-test-blueprint-install: DNS present, installing Social Login..."
      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"' EXIT
      ${pkgs.curl}/bin/curl -fsSL "${socialloginBlueprintUrl}" -o "$tmp/sociallogin.blueprint"
      cp "$tmp/sociallogin.blueprint" "$panel/sociallogin.blueprint"
      chown prestonh:users "$panel/sociallogin.blueprint"
      rm -f "$panel/.blueprint/lock"
      blueprint_cli -install sociallogin
      rm -f "$panel/sociallogin.blueprint"
      post_install_hooks
      write_marker
      echo "pterodactyl-test-blueprint-install: Social Login extension ready on test panel"
      exit 0
    fi

    if [ -d "$panel/.blueprint/extensions/sociallogin" ] \
      && [ -d "$panel/.blueprint/extensions/dnsrecords" ] \
      && [ -f "$panel/blueprint.sh" ] && [ -d "$panel/.blueprint/blueprint" ]; then
      if [ ! -d "$panel/.blueprint/extensions/portforward" ]; then
        echo "pterodactyl-test-blueprint-install: installing missing Port Forward extension..."
        install_portforward_extension
        post_install_hooks
        write_marker
        echo "pterodactyl-test-blueprint-install: Port Forward extension ready on test panel"
        exit 0
      fi
      if blueprint_core_backend_integrated && ! blueprint_frontend_integrated; then
        echo "pterodactyl-test-blueprint-install: backend ready but frontend missing Blueprint patches, repairing..."
        ensure_blueprint_frontend_patches
        ensure_frontend_built
        post_install_hooks
        write_marker
        echo "pterodactyl-test-blueprint-install: Blueprint frontend repaired on test panel"
        exit 0
      fi
      if ! extension_backend_integrated; then
        echo "pterodactyl-test-blueprint-install: extension symlinks or admin controllers missing, repairing..."
        ensure_blueprint_assets
        ensure_extension_app_symlinks
        ensure_storage_extension_symlinks
        ensure_public_assets_extension_symlinks
        ensure_extension_admin_files
        post_install_hooks
        write_marker
        echo "pterodactyl-test-blueprint-install: extension backend repaired on test panel"
        exit 0
      fi
      if ! blueprint_core_backend_integrated; then
        echo "pterodactyl-test-blueprint-install: extensions present but Laravel integration missing, repairing..."
        ensure_blueprint_assets
        ensure_extension_app_symlinks
        ensure_storage_extension_symlinks
        ensure_public_assets_extension_symlinks
        ensure_extension_admin_files
        rerun_blueprint_framework
        post_install_hooks
        write_marker
        echo "pterodactyl-test-blueprint-install: Blueprint integration repaired on test panel"
        exit 0
      fi
      if ! blueprint_site_config_integrated || ! blueprint_frontend_integrated; then
        echo "pterodactyl-test-blueprint-install: site config or frontend incomplete, repairing..."
        ensure_blueprint_frontend_patches
        ensure_frontend_built
        post_install_hooks
        write_marker
        echo "pterodactyl-test-blueprint-install: Blueprint site config and frontend repaired on test panel"
        exit 0
      fi
    fi

    if [ -f "$marker" ]; then
      echo "pterodactyl-test-blueprint-install: marker present but integration incomplete, continuing install..."
    fi

    echo "pterodactyl-test-blueprint-install: installing upstream Blueprint framework..."

    rm -f "$panel/.blueprint/lock" 2>/dev/null || true

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT

    framework_ready=0
    if [ -f "$panel/blueprint.sh" ] && [ -d "$panel/.blueprint/blueprint" ]; then
      framework_ready=1
      echo "pterodactyl-test-blueprint-install: Blueprint framework already installed"
    else
      ${pkgs.curl}/bin/curl -fsSL "${blueprintReleaseUrl}" -o "$tmp/release.zip"
      ${pkgs.unzip}/bin/unzip -o "$tmp/release.zip" -d "$panel"
      chown -R prestonh:users "$panel"
      install -m 0644 ${blueprintRc} "$panel/.blueprintrc"
      chmod +x "$panel/blueprint.sh"
      chown prestonh:users "$panel/.blueprintrc" "$panel/blueprint.sh"
      install -d -m 0755 -o prestonh -g users "$panel/.blueprint"
      install -d -m 0755 -o prestonh -g users \
        "$panel/.blueprint/extensions/blueprint/private/debug"
      install -m 0644 /dev/null "$panel/.blueprint/extensions/blueprint/private/debug/logs.txt"
      chown prestonh:users "$panel/.blueprint/extensions/blueprint/private/debug/logs.txt"
    fi

    if [ -d "$panel/blueprint" ] && [ -d "$panel/.blueprint/blueprint" ]; then
      runuser -u prestonh -- rm -rf "$panel/blueprint"
    elif [ -d "$panel/blueprint" ]; then
      runuser -u prestonh -- rm -rf "$panel/.blueprint/blueprint" 2>/dev/null || true
      install -d -m 0755 -o prestonh -g users "$panel/.blueprint"
      runuser -u prestonh -- mv "$panel/blueprint" "$panel/.blueprint/blueprint"
      chown -R prestonh:users "$panel/.blueprint/blueprint"
    fi

    ensure_blueprint_assets

    if [ ! -d "$panel/node_modules" ]; then
      echo "pterodactyl-test-blueprint-install: installing panel node dependencies..."
      cd "$panel"
      runuser -u prestonh -- env HOME=/home/prestonh YARN_CACHE_FOLDER=/home/prestonh/.cache/yarn-blueprint-test PATH="$PATH" yarn install --frozen-lockfile 2>/dev/null \
        || runuser -u prestonh -- env HOME=/home/prestonh YARN_CACHE_FOLDER=/home/prestonh/.cache/yarn-blueprint-test PATH="$PATH" yarn install
    fi

    cd "$panel"
    if [ "$framework_ready" -eq 0 ] || ! blueprint_backend_integrated; then
      blueprint_cli_install
    fi

    ${pkgs.curl}/bin/curl -fsSL "${socialloginBlueprintUrl}" -o "$tmp/sociallogin.blueprint"
    cp "$tmp/sociallogin.blueprint" "$panel/sociallogin.blueprint"
    chown prestonh:users "$panel/sociallogin.blueprint"
    sociallogin_installed=0
    if blueprint_cli -info 2>/dev/null | grep -qi sociallogin; then
      sociallogin_installed=1
    fi
    if [ "$sociallogin_installed" -eq 0 ]; then
      echo "pterodactyl-test-blueprint-install: installing Social Login extension..."
      rm -f "$panel/.blueprint/lock"
      blueprint_cli -install sociallogin
    else
      echo "pterodactyl-test-blueprint-install: Social Login extension already installed"
    fi
    rm -f "$panel/sociallogin.blueprint"
    install_dnsrecords_extension
    install_portforward_extension
    post_install_hooks
    write_marker
    echo "pterodactyl-test-blueprint-install: Blueprint, Social Login, DNS Records, and Port Forward ready"
  '';
in
{
  systemd.services.pterodactyl-test-blueprint-install = {
    description = "Install Blueprint, Social Login, DNS Records, and Port Forward on test panel";
    after = [
      "podman-pterodactyl-test.service"
      "pterodactyl-test-stock-reset.service"
      "pterodactyl-test-panel-perms.service"
    ];
    wants = [
      "pterodactyl-test-stock-reset.service"
    ];
    requires = [ "pterodactyl-test-stock-reset.service" ];
    before = [ "pterodactyl-test-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = installScript;
      RemainAfterExit = true;
      TimeoutStartSec = "90min";
    };
    path = with pkgs; [
      curl
      unzip
      git
      jq
      util-linux
      podman
      nodejs_22
      yarn
      coreutils
      acl
      bash
      ncurses
      procps
      gnused
      gnugrep
    ];
  };
}
