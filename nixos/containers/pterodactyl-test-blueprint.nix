{ config, pkgs, ... }:

let
  testPanelDir = "/home/prestonh/Projects/panel";
  stateDir = "/var/lib/pterodactyl-test";
  blueprintMarker = "${stateDir}/blueprint-fork-installed";
  blueprintForkRepo = "https://github.com/PrestonHager/framework.git";
  blueprintForkBranch = "feat/prestonhager-plugin-manager";
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
    REPOSITORY="PrestonHager/framework"
    REPOSITORY_BRANCH="${blueprintForkBranch}"
    BLUEPRINT_GITHUB_MAX_BYTES="10485760"
    TECHNITIUM_API_URL="https://dns.prestonhager.com"
  '';

  installScript = pkgs.writeShellScript "pterodactyl-test-blueprint-install" ''
    set -euo pipefail
    panel="${testPanelDir}"
    marker="${blueprintMarker}"
    fork_dir="${stateDir}/blueprint-framework"

    if [ ! -d "$panel/app" ]; then
      echo "pterodactyl-test-blueprint-install: panel not installed, skipping" >&2
      exit 0
    fi

    install -d -m 0750 -o pterodactyl -g pterodactyl "${stateDir}"

    GIT="${pkgs.git}/bin/git -c safe.directory=$fork_dir"
    if [ ! -d "$fork_dir/.git" ]; then
      echo "pterodactyl-test-blueprint-install: cloning PrestonHager/framework..."
      $GIT clone --depth 1 --branch "${blueprintForkBranch}" "${blueprintForkRepo}" "$fork_dir"
    else
      cd "$fork_dir"
      $GIT fetch origin "${blueprintForkBranch}" --depth=1
      $GIT checkout "${blueprintForkBranch}"
      $GIT reset --hard "origin/${blueprintForkBranch}"
    fi

    current_rev=$($GIT -C "$fork_dir" rev-parse HEAD)
    if [ -f "$marker" ] && grep -q "$current_rev" "$marker" \
      && [ -f "$panel/blueprint.sh" ] && [ -d "$panel/.blueprint" ] \
      && [ -d "$panel/.blueprint/extensions/dnsrecords" ]; then
      echo "pterodactyl-test-blueprint-install: forked Blueprint already at $current_rev"
      exit 0
    fi

    echo "pterodactyl-test-blueprint-install: applying PrestonHager/framework@${blueprintForkBranch}..."

    if [ ! -f "$panel/.blueprint/extensions/blueprint/private/db/is_installed" ]; then
      runuser -u prestonh -- rm -rf "$panel/.blueprint" "$panel/blueprint" 2>/dev/null || true
    fi

    archive="$fork_dir/release-overlay.zip"
    $GIT -C "$fork_dir" archive --format=zip HEAD -o "$archive"
    ${pkgs.unzip}/bin/unzip -o "$archive" -d "$panel"
    chown -R prestonh:users "$panel"

    install -m 0644 ${blueprintRc} "$panel/.blueprintrc"
    chmod +x "$panel/blueprint.sh"
    chown prestonh:users "$panel/.blueprintrc" "$panel/blueprint.sh"

    export PATH="${toolPath}:$PATH"
    export BLUEPRINT_ENVIRONMENT=ci
    export HOME=/home/prestonh
    export YARN_CACHE_FOLDER=/home/prestonh/.cache/yarn-blueprint-test
    export TERM=dumb

    install -d -m 0755 -o prestonh -g users /home/prestonh/.cache/yarn-blueprint-test
    install -d -m 0755 -o prestonh -g users "$panel/.blueprint"
    if [ -d "$panel/blueprint" ] && [ -d "$panel/.blueprint/blueprint" ]; then
      rm -rf "$panel/blueprint"
    fi

    blueprint_cli() {
      runuser -u prestonh -- env \
        HOME=/home/prestonh \
        TERM=dumb \
        YARN_CACHE_FOLDER=/home/prestonh/.cache/yarn-blueprint-test \
        PATH="$PATH" \
        BLUEPRINT_ENVIRONMENT=ci \
        ${pkgs.bash}/bin/bash "$panel/blueprint.sh" -bash "$@"
    }

    blueprint_cli_install() {
      env \
        HOME=/home/prestonh \
        TERM=dumb \
        YARN_CACHE_FOLDER=/home/prestonh/.cache/yarn-blueprint-test \
        PATH="$PATH" \
        BLUEPRINT_ENVIRONMENT=ci \
        ${pkgs.bash}/bin/bash "$panel/blueprint.sh" "$@"
    }

    if [ ! -d "$panel/node_modules" ]; then
      echo "pterodactyl-test-blueprint-install: installing panel node dependencies..."
      cd "$panel"
      runuser -u prestonh -- env HOME=/home/prestonh YARN_CACHE_FOLDER=/home/prestonh/.cache/yarn-blueprint-test PATH="$PATH" yarn install --frozen-lockfile 2>/dev/null \
        || runuser -u prestonh -- env HOME=/home/prestonh YARN_CACHE_FOLDER=/home/prestonh/.cache/yarn-blueprint-test PATH="$PATH" yarn install
    else
      cd "$panel"
      runuser -u prestonh -- env HOME=/home/prestonh YARN_CACHE_FOLDER=/home/prestonh/.cache/yarn-blueprint-test PATH="$PATH" yarn install 2>/dev/null || true
    fi

    cd "$panel"
    if [ ! -f "$panel/.blueprint/extensions/blueprint/private/db/is_installed" ]; then
      echo "pterodactyl-test-blueprint-install: running Blueprint first-time installer..."
      rm -f /usr/local/bin/blueprint
      blueprint_cli_install
      chown -R prestonh:users "$panel"
      if [ ! -f "$panel/.blueprint/extensions/blueprint/private/db/is_installed" ]; then
        echo "pterodactyl-test-blueprint-install: Blueprint first-time install did not complete" >&2
        exit 1
      fi
    else
      echo "pterodactyl-test-blueprint-install: upgrading Blueprint framework..."
      blueprint_cli -upgrade remote PrestonHager/framework "${blueprintForkBranch}" <<< "y" \
        || blueprint_cli -upgrade remote "https://github.com/PrestonHager/framework.git" "${blueprintForkBranch}" <<< "y"
    fi

    if [ -d "${dnsExtensionSrc}" ]; then
      echo "pterodactyl-test-blueprint-install: building dnsrecords extension..."
      rm -rf "$panel/.blueprint/dev/"*
      cp -a "${dnsExtensionSrc}/." "$panel/.blueprint/dev/"
      chown -R prestonh:users "$panel/.blueprint/dev"
      blueprint_cli -build
      if ! blueprint_cli -info 2>/dev/null | grep -qi dnsrecords; then
        blueprint_cli -install dnsrecords \
          || blueprint_cli -i dnsrecords
      fi
    else
      echo "pterodactyl-test-blueprint-install: DNS extension source missing at ${dnsExtensionSrc}" >&2
    fi

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

    echo "fork:''${current_rev}" > "$marker"
    chown pterodactyl:pterodactyl "$marker"
    echo "pterodactyl-test-blueprint-install: forked Blueprint + dnsrecords ready on test panel"
  '';
in
{
  systemd.services.pterodactyl-test-blueprint-install = {
    description = "Install PrestonHager Blueprint fork and DNS extension on test panel";
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
      git
      rsync
      curl
      unzip
      zip
      php83
      gawk
      gnused
      gnugrep
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
