{ config, pkgs, ... }:

let
  testPanelDir = "/home/prestonh/Projects/panel";
  stateDir = "/var/lib/pterodactyl-test";
  blueprintMarker = "${stateDir}/blueprint-installed";
  blueprintReleaseUrl = "https://github.com/BlueprintFramework/framework/releases/latest/download/release.zip";
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

    install_dnsrecords_extension() {
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
      ${pkgs.podman}/bin/podman exec \
        -e HOME=/var/www/pterodactyl \
        -e COMPOSER_HOME=/tmp/composer \
        pterodactyl-test \
        sh -c 'cd /var/www/pterodactyl && composer install --no-dev --optimize-autoloader'

      ${pkgs.podman}/bin/podman exec pterodactyl-test \
        php /var/www/pterodactyl/artisan migrate --force

      ${pkgs.podman}/bin/podman exec pterodactyl-test \
        php /var/www/pterodactyl/artisan config:clear

      chown -R prestonh:users "$panel"
      find "$panel/storage" "$panel/bootstrap/cache" -type d -exec chmod 2775 {} + 2>/dev/null || true
    }

    write_marker() {
      echo "blueprint+dnsrecords" > "$marker"
      chown pterodactyl:pterodactyl "$marker"
    }

    if [ -d "$panel/.blueprint/extensions/dnsrecords" ] \
      && [ -f "$panel/blueprint.sh" ] && [ -d "$panel/.blueprint/blueprint" ]; then
      write_marker
      echo "pterodactyl-test-blueprint-install: upstream Blueprint + DNS Records ready"
      exit 0
    fi

    if [ -f "$marker" ]; then
      echo "pterodactyl-test-blueprint-install: marker present but extensions incomplete, continuing install..."
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
    fi

    if [ -d "$panel/blueprint" ] && [ -d "$panel/.blueprint/blueprint" ]; then
      runuser -u prestonh -- rm -rf "$panel/blueprint"
    elif [ -d "$panel/blueprint" ]; then
      runuser -u prestonh -- rm -rf "$panel/.blueprint/blueprint" 2>/dev/null || true
      install -d -m 0755 -o prestonh -g users "$panel/.blueprint"
      runuser -u prestonh -- mv "$panel/blueprint" "$panel/.blueprint/blueprint"
      chown -R prestonh:users "$panel/.blueprint/blueprint"
    fi

    blueprint_cli_install() {
      env \
        HOME=/home/prestonh \
        TERM=dumb \
        LC_ALL=C.UTF-8 \
        LANG=C.UTF-8 \
        YARN_CACHE_FOLDER=/home/prestonh/.cache/yarn-blueprint-test \
        PATH="$PATH" \
        ${pkgs.bash}/bin/bash "$panel/blueprint.sh" "$@"
    }

    if [ ! -d "$panel/node_modules" ]; then
      echo "pterodactyl-test-blueprint-install: installing panel node dependencies..."
      cd "$panel"
      runuser -u prestonh -- env HOME=/home/prestonh YARN_CACHE_FOLDER=/home/prestonh/.cache/yarn-blueprint-test PATH="$PATH" yarn install --frozen-lockfile 2>/dev/null \
        || runuser -u prestonh -- env HOME=/home/prestonh YARN_CACHE_FOLDER=/home/prestonh/.cache/yarn-blueprint-test PATH="$PATH" yarn install
    fi

    cd "$panel"
    if [ "$framework_ready" -eq 0 ]; then
      blueprint_cli_install
    fi

    install_dnsrecords_extension
    post_install_hooks
    write_marker
    echo "pterodactyl-test-blueprint-install: upstream Blueprint + DNS Records ready"
  '';
in
{
  systemd.services.pterodactyl-test-blueprint-install = {
    description = "Install upstream Blueprint and DNS extension on test panel";
    after = [
      "podman-pterodactyl-test.service"
      "pterodactyl-test-stock-reset.service"
      "pterodactyl-test-panel-perms.service"
    ];
    wants = [
      "pterodactyl-test-stock-reset.service"
    ];
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
      util-linux
      podman
      nodejs_22
      yarn
      coreutils
      acl
      bash
      ncurses
      procps
    ];
  };
}
