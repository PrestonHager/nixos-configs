{ config, pkgs, ... }:

let
  panelRoot = "/pterodactyl/html";
  stateDir = "/var/lib/pterodactyl";
  blueprintMarker = "${stateDir}/blueprint-installed";
  blueprintReleaseUrl = "https://github.com/BlueprintFramework/framework/releases/latest/download/release.zip";
  socialloginBlueprintUrl = "https://github.com/blueprint-community/extension-sociallogin/releases/download/1.2.0/sociallogin.blueprint";
  dnsExtensionSrc = "/etc/nixos/plugins/pterodactyl-dns-blueprint";

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

    blueprint_integrated() {
      grep -q 'Providers\\Blueprint\\RouteServiceProvider' "$panel/app/Providers/AppServiceProvider.php" \
        && grep -q "'blueprint'" "$panel/app/Http/Kernel.php" \
        && [ -f "$panel/routes/blueprint/web/sociallogin.php" ] \
        && ${pkgs.podman}/bin/podman exec pterodactyl \
          php /var/www/pterodactyl/artisan route:list 2>/dev/null \
          | ${pkgs.gnugrep}/bin/grep -q 'extensions/sociallogin'
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
      ensure_blueprint_core_patches
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
      ensure_blueprint_core_patches

      ${pkgs.podman}/bin/podman exec \
        -e HOME=/var/www/pterodactyl \
        -e COMPOSER_HOME=/tmp/composer \
        pterodactyl \
        sh -c 'cd /var/www/pterodactyl && composer install --no-dev --optimize-autoloader'

      ${pkgs.podman}/bin/podman exec pterodactyl \
        php /var/www/pterodactyl/artisan migrate --force

      ${pkgs.podman}/bin/podman exec pterodactyl \
        php /var/www/pterodactyl/artisan config:clear

      ${pkgs.podman}/bin/podman exec pterodactyl \
        php /var/www/pterodactyl/artisan view:clear

      chown -R pterodactyl:pterodactyl "$panel"
    }

    write_marker() {
      echo "blueprint+sociallogin+dnsrecords" > "$marker"
      chown pterodactyl:pterodactyl "$marker"
    }

    if blueprint_integrated \
      && [ -d "$panel/.blueprint/extensions/sociallogin" ] \
      && [ -d "$panel/.blueprint/extensions/dnsrecords" ]; then
      write_marker
      echo "pterodactyl-blueprint-install: Blueprint, Social Login, and DNS Records ready"
      exit 0
    fi

    if [ -d "$panel/.blueprint/extensions/sociallogin" ] \
      && [ -d "$panel/.blueprint/extensions/dnsrecords" ] \
      && [ -f "$panel/blueprint.sh" ] && [ -d "$panel/.blueprint/blueprint" ]; then
      echo "pterodactyl-blueprint-install: extensions present but Laravel integration missing, repairing..."
      rerun_blueprint_framework
      post_install_hooks
      write_marker
      echo "pterodactyl-blueprint-install: Blueprint integration repaired on production panel"
      exit 0
    fi

    if [ -d "$panel/.blueprint/extensions/sociallogin" ] \
      && [ -f "$panel/blueprint.sh" ] && [ -d "$panel/.blueprint/blueprint" ]; then
      echo "pterodactyl-blueprint-install: Social Login present, installing DNS Records only..."
      if ! blueprint_integrated; then
        rerun_blueprint_framework
      fi
      install_dnsrecords_extension
      post_install_hooks
      write_marker
      echo "pterodactyl-blueprint-install: DNS Records extension ready on production panel"
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
    if [ "$framework_ready" -eq 0 ] || ! blueprint_integrated; then
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
    post_install_hooks
    write_marker
    echo "pterodactyl-blueprint-install: Blueprint, Social Login, and DNS Records ready"
  '';
in
{
  systemd.services.pterodactyl-blueprint-install = {
    description = "Install Blueprint, Social Login, and DNS Records on production panel";
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
      TimeoutStartSec = "60min";
    };
    path = with pkgs; [
      bash
      curl
      unzip
      git
      util-linux
      podman
      nodejs_22
      yarn
      coreutils
    ];
  };
}
