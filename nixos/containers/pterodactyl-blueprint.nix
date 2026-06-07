{ config, pkgs, ... }:

let
  panelRoot = "/pterodactyl/html";
  stateDir = "/var/lib/pterodactyl";
  blueprintMarker = "${stateDir}/blueprint-installed";
  blueprintReleaseUrl = "https://github.com/BlueprintFramework/framework/releases/latest/download/release.zip";
  socialloginBlueprintUrl = "https://github.com/blueprint-community/extension-sociallogin/releases/download/1.2.0/sociallogin.blueprint";

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

    if [ -f "$marker" ]; then
      echo "pterodactyl-blueprint-install: Blueprint already installed"
      exit 0
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

    export PATH="${toolPath}:$PATH"
    export HOME=/var/lib/pterodactyl
    export TERM=dumb
    export LC_ALL=C.UTF-8
    export LANG=C.UTF-8
    export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
    install -d -m 0750 -o pterodactyl -g pterodactyl /var/lib/pterodactyl

    # blueprint.sh tries to mv panel/blueprint → .blueprint/blueprint on every run
    if [ -d "$panel/blueprint" ] && [ -d "$panel/.blueprint/blueprint" ]; then
      rm -rf "$panel/blueprint"
    elif [ -d "$panel/blueprint" ]; then
      rm -rf "$panel/.blueprint/blueprint"
      mv "$panel/blueprint" "$panel/.blueprint/blueprint"
    fi

    blueprint_cli() {
      if [ "$framework_ready" -eq 1 ]; then
        env HOME=/var/lib/pterodactyl TERM=dumb PATH="$PATH" ${pkgs.bash}/bin/bash "$panel/blueprint.sh" -bash "$@"
      else
        env HOME=/var/lib/pterodactyl TERM=dumb PATH="$PATH" ${pkgs.bash}/bin/bash "$panel/blueprint.sh" "$@"
      fi
    }

    if [ ! -d "$panel/node_modules" ]; then
      echo "pterodactyl-blueprint-install: installing panel node dependencies..."
      cd "$panel"
      runuser -u pterodactyl -- env HOME=/var/lib/pterodactyl TERM=dumb PATH="$PATH" yarn install --frozen-lockfile 2>/dev/null \
        || runuser -u pterodactyl -- env HOME=/var/lib/pterodactyl TERM=dumb PATH="$PATH" yarn install
    fi

    cd "$panel"
    if [ "$framework_ready" -eq 0 ]; then
      blueprint_cli
    fi

    ${pkgs.curl}/bin/curl -fsSL "${socialloginBlueprintUrl}" -o "$tmp/sociallogin.blueprint"
    install -d -m 0755 "$panel/.blueprint/extensions"
    cp "$tmp/sociallogin.blueprint" "$panel/.blueprint/extensions/"
    chown pterodactyl:pterodactyl "$panel/.blueprint/extensions/sociallogin.blueprint"

    cd "$panel"
    if ! blueprint_cli -info 2>/dev/null | grep -qi sociallogin; then
      echo "pterodactyl-blueprint-install: installing Social Login extension..."
      rm -f "$panel/.blueprint/lock"
      blueprint_cli -install sociallogin
    else
      echo "pterodactyl-blueprint-install: Social Login extension already installed"
    fi
    chown -R pterodactyl:pterodactyl "$panel"

    ${pkgs.podman}/bin/podman exec \
      -e HOME=/var/www/pterodactyl \
      -e COMPOSER_HOME=/tmp/composer \
      pterodactyl \
      sh -c 'cd /var/www/pterodactyl && composer install --no-dev --optimize-autoloader'

    ${pkgs.podman}/bin/podman exec pterodactyl \
      php /var/www/pterodactyl/artisan config:clear

    echo "blueprint+sociallogin" > "$marker"
    chown pterodactyl:pterodactyl "$marker"
    echo "pterodactyl-blueprint-install: Blueprint and Social Login extension ready"
  '';
in
{
  systemd.services.pterodactyl-blueprint-install = {
    description = "Install Blueprint framework and Social Login extension on production panel";
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
