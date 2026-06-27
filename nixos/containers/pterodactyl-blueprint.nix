{ config, pkgs, ... }:

let
  panelRoot = "/pterodactyl/html";
  stateDir = "/var/lib/pterodactyl";
  blueprintMarker = "${stateDir}/blueprint-installed";
  blueprintReleaseUrl = "https://github.com/BlueprintFramework/framework/releases/latest/download/release.zip";
  socialloginBlueprintUrl = "https://github.com/blueprint-community/extension-sociallogin/releases/download/1.2.0/sociallogin.blueprint";
  dnsExtensionSrc = "/etc/nixos/plugins/pterodactyl-dns-blueprint";
  portforwardExtensionSrc = "/etc/nixos/plugins/pterodactyl-portforward-blueprint";

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
      for ext in sociallogin dnsrecords portforward; do
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
      for ext in sociallogin dnsrecords portforward; do
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

    ensure_public_assets_extension_symlinks() {
      assets_ext="$panel/public/assets/extensions"
      install -d -m 2775 -o pterodactyl -g pterodactyl "$assets_ext"
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
      for ext in blueprint sociallogin dnsrecords portforward; do
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
        src_ctrl=""
        src_view=""
        if src_path=$(extension_admin_controller_source "$ext" 2>/dev/null) && [ -f "$src_path" ]; then
          src_ctrl="$src_path"
        fi
        if src_path=$(extension_admin_view_source "$ext" 2>/dev/null) && [ -f "$src_path" ]; then
          src_view="$src_path"
        fi

        if [ -n "$src_ctrl" ] && [ ! -f "$ctrl" ]; then
          echo "pterodactyl-blueprint-install: installing $ext admin controller from plugin source..."
          install -d -m 0755 -o pterodactyl -g pterodactyl "$(dirname "$ctrl")"
          cp -a "$src_ctrl" "$ctrl"
          chown pterodactyl:pterodactyl "$ctrl"
        elif [ ! -f "$ctrl" ] && [ "$ext" = "sociallogin" ]; then
          echo "pterodactyl-blueprint-install: reinstalling Social Login to restore admin controller..."
          rm -f "$panel/.blueprint/lock"
          blueprint_cli -install sociallogin
        fi

        if [ -n "$src_view" ]; then
          if [ ! -f "$view" ] || extension_admin_view_corrupted "$ext"; then
            echo "pterodactyl-blueprint-install: installing $ext admin view from plugin source..."
            install -d -m 0755 -o pterodactyl -g pterodactyl "$(dirname "$view")"
            cp -a "$src_view" "$view"
            chown pterodactyl:pterodactyl "$view"
          fi
        fi
      done
    }

    ensure_extension_migrations() {
      for src_dir in "${dnsExtensionSrc}/database/migrations" "${portforwardExtensionSrc}/database/migrations"; do
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
      extension_migrations_integrated && extension_public_assets_integrated
    }

    blueprint_core_backend_integrated() {
      [ -f "$panel/app/Models/SocialProvider.php" ] \
        && grep -q 'Providers\\Blueprint\\RouteServiceProvider' "$panel/app/Providers/AppServiceProvider.php" \
        && grep -q "'blueprint'" "$panel/app/Http/Kernel.php" \
        && [ -f "$panel/routes/blueprint/web/sociallogin.php" ] \
        && ${pkgs.podman}/bin/podman exec pterodactyl \
          php /var/www/pterodactyl/artisan route:list 2>/dev/null \
          | ${pkgs.gnugrep}/bin/grep -q 'extensions/sociallogin'
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
      ensure_blueprint_frontend_patches
      ensure_frontend_built
    }

    install_portforward_extension() {
      if [ ! -d "${portforwardExtensionSrc}" ]; then
        echo "pterodactyl-blueprint-install: Port Forward extension source missing at ${portforwardExtensionSrc}" >&2
        return 1
      fi
      if [ -d "$panel/.blueprint/extensions/portforward" ]; then
        echo "pterodactyl-blueprint-install: Port Forward extension already present"
        return 0
      fi
      echo "pterodactyl-blueprint-install: installing portforward extension from dev tree..."
      install -d -m 0755 -o pterodactyl -g pterodactyl "$panel/.blueprint/dev"
      rm -rf "$panel/.blueprint/dev/"*
      cp -a "${portforwardExtensionSrc}/." "$panel/.blueprint/dev/"
      chown -R pterodactyl:pterodactyl "$panel/.blueprint/dev"
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
      if [ -d "$panel/.blueprint/extensions/dnsrecords" ]; then
        echo "pterodactyl-blueprint-install: DNS Records extension already present"
        return 0
      fi
      echo "pterodactyl-blueprint-install: installing dnsrecords extension from dev tree..."
      install -d -m 0755 -o pterodactyl -g pterodactyl "$panel/.blueprint/dev"
      rm -rf "$panel/.blueprint/dev/"*
      cp -a "${dnsExtensionSrc}/." "$panel/.blueprint/dev/"
      chown -R pterodactyl:pterodactyl "$panel/.blueprint/dev"
      if ! blueprint_cli -info 2>/dev/null | grep -qi dnsrecords; then
        rm -f "$panel/.blueprint/lock"
        blueprint_cli -install '[developer-build]' \
          || blueprint_cli -i '[developer-build]'
      fi
    }

    post_install_hooks() {
      ensure_blueprint_assets
      ensure_blueprint_core_patches
      ensure_sociallogin_models
      ensure_extension_app_symlinks
      ensure_storage_extension_symlinks
      ensure_public_assets_extension_symlinks
      ensure_extension_admin_files
      ensure_extension_migrations
      ensure_blueprint_admin_layout_patches
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
    }

    write_marker() {
      echo "blueprint+sociallogin+dnsrecords+portforward" > "$marker"
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
      && [ -f "$panel/blueprint.sh" ] && [ -d "$panel/.blueprint/blueprint" ]; then
      write_marker
      echo "pterodactyl-blueprint-install: Blueprint, Social Login, DNS Records, and Port Forward ready"
      exit 0
    fi

    if [ -d "$panel/.blueprint/extensions/sociallogin" ] \
      && [ -d "$panel/.blueprint/extensions/dnsrecords" ] \
      && [ -d "$panel/.blueprint/extensions/portforward" ] \
      && [ -f "$panel/blueprint.sh" ] && [ -d "$panel/.blueprint/blueprint" ]; then
      if ! extension_backend_integrated; then
        echo "pterodactyl-blueprint-install: extension symlinks, views, or migrations incomplete, repairing..."
        ensure_blueprint_assets
        ensure_extension_app_symlinks
        ensure_storage_extension_symlinks
        ensure_public_assets_extension_symlinks
        ensure_extension_admin_files
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
        rerun_blueprint_framework
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
    post_install_hooks
    write_marker
    echo "pterodactyl-blueprint-install: Blueprint, Social Login, DNS Records, and Port Forward ready"
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
