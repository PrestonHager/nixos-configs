{ config, pkgs, ... }:

let
  panelRoot = "/pterodactyl/html";
  stateDir = "/var/lib/pterodactyl";
  blueprintMarker = "${stateDir}/blueprint-installed";
  blueprintReleaseUrl = "https://github.com/BlueprintFramework/framework/releases/latest/download/release.zip";
  socialloginBlueprintUrl = "https://github.com/blueprint-community/extension-sociallogin/releases/download/1.2.0/sociallogin.blueprint";

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

    if [ -f "$marker" ] && [ -f "$panel/blueprint.sh" ] && [ -d "$panel/.blueprint" ]; then
      echo "pterodactyl-blueprint-install: Blueprint already installed"
      exit 0
    fi

    echo "pterodactyl-blueprint-install: installing Blueprint framework..."

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT

    ${pkgs.curl}/bin/curl -fsSL "${blueprintReleaseUrl}" -o "$tmp/release.zip"
    ${pkgs.unzip}/bin/unzip -o "$tmp/release.zip" -d "$panel"

    install -m 0644 ${blueprintRc} "$panel/.blueprintrc"
    chmod +x "$panel/blueprint.sh"
    chown pterodactyl:pterodactyl "$panel/.blueprintrc" "$panel/blueprint.sh"

    export PATH="${pkgs.nodejs_22}/bin:${pkgs.yarn}/bin:$PATH"
    export HOME=/var/lib/pterodactyl
    export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
    install -d -m 0750 -o pterodactyl -g pterodactyl /var/lib/pterodactyl

    if [ ! -d "$panel/node_modules" ]; then
      echo "pterodactyl-blueprint-install: installing panel node dependencies..."
      cd "$panel"
      runuser -u pterodactyl -- env HOME=/var/lib/pterodactyl PATH="$PATH" yarn install --frozen-lockfile 2>/dev/null \
        || runuser -u pterodactyl -- env HOME=/var/lib/pterodactyl PATH="$PATH" yarn install
    fi

    cd "$panel"
    runuser -u pterodactyl -- env HOME=/var/lib/pterodactyl PATH="$PATH" bash "$panel/blueprint.sh"

    ${pkgs.curl}/bin/curl -fsSL "${socialloginBlueprintUrl}" -o "$tmp/sociallogin.blueprint"
    install -d -m 0755 "$panel/.blueprint/extensions"
    cp "$tmp/sociallogin.blueprint" "$panel/.blueprint/extensions/"
    chown pterodactyl:pterodactyl "$panel/.blueprint/extensions/sociallogin.blueprint"

    cd "$panel"
    if ! runuser -u pterodactyl -- env HOME=/var/lib/pterodactyl PATH="$PATH" bash "$panel/blueprint.sh" -info 2>/dev/null | grep -qi sociallogin; then
      echo "pterodactyl-blueprint-install: installing Social Login extension..."
      runuser -u pterodactyl -- env HOME=/var/lib/pterodactyl PATH="$PATH" bash "$panel/blueprint.sh" -install sociallogin \
        || runuser -u pterodactyl -- env HOME=/var/lib/pterodactyl PATH="$PATH" bash "$panel/blueprint.sh" -i sociallogin
    fi

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
