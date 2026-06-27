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

    ensure_sociallogin_admin_files() {
      ctrl="$panel/app/Http/Controllers/Admin/Extensions/sociallogin/socialloginExtensionController.php"
      view="$panel/resources/views/admin/extensions/sociallogin/index.blade.php"
      prod_ctrl="$prod_panel/app/Http/Controllers/Admin/Extensions/sociallogin/socialloginExtensionController.php"
      prod_view="$prod_panel/resources/views/admin/extensions/sociallogin/index.blade.php"

      if [ ! -f "$ctrl" ]; then
        if [ -f "$prod_ctrl" ]; then
          echo "pterodactyl-test-blueprint-install: copying Social Login admin controller from production..."
          install -d -m 0755 -o prestonh -g users "$(dirname "$ctrl")"
          cp -a "$prod_ctrl" "$ctrl"
          chown prestonh:users "$ctrl"
        else
          echo "pterodactyl-test-blueprint-install: reinstalling Social Login to restore admin controller..."
          rm -f "$panel/.blueprint/lock"
          blueprint_cli -install sociallogin
        fi
      fi

      if [ ! -f "$view" ] && [ -f "$prod_view" ]; then
        echo "pterodactyl-test-blueprint-install: copying Social Login admin view from production..."
        install -d -m 0755 -o prestonh -g users "$(dirname "$view")"
        cp -a "$prod_view" "$view"
        chown prestonh:users "$view"
      fi
    }

    extension_backend_integrated() {
      for ext in sociallogin dnsrecords portforward; do
        [ -e "$panel/app/BlueprintFramework/Extensions/$ext" ] || return 1
        [ -f "$panel/app/Http/Controllers/Admin/Extensions/$ext/''${ext}ExtensionController.php" ] || return 1
      done
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
      if ! blueprint_cli -info 2>/dev/null | grep -qi sociallogin; then
        echo "pterodactyl-test-blueprint-install: Social Login required before custom extensions" >&2
        return 1
      fi
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
      ensure_blueprint_assets
      ensure_blueprint_core_patches
      ensure_sociallogin_models
      ensure_extension_app_symlinks
      ensure_storage_extension_symlinks
      ensure_sociallogin_admin_files
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
      write_marker
      echo "pterodactyl-test-blueprint-install: Blueprint, Social Login, DNS Records, and Port Forward ready"
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
        ensure_sociallogin_admin_files
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
        ensure_sociallogin_admin_files
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
