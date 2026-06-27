{ config, pkgs, ... }:

let
  inherit (import ./pterodactyl-docker.nix { inherit pkgs; }) version;
  panelRoot = "/pterodactyl/html";
  officialSrc = "https://github.com/pterodactyl/panel.git";
  officialBranch = "release/v${version}";
  stateDir = "/var/lib/pterodactyl";
  resetMarker = "${stateDir}/stock-reset-${version}";

  resetScript = pkgs.writeShellScript "pterodactyl-stock-reset" ''
    set -euo pipefail
    panel="${panelRoot}"
    marker="${resetMarker}"

    if [ ! -d "$panel/app" ]; then
      echo "pterodactyl-stock-reset: panel not installed at $panel, skipping" >&2
      exit 0
    fi

    needs_reset() {
      if [ ! -d "$panel/.git" ]; then
        return 0
      fi
      if [ -f "$panel/app/Services/Plugins/PluginManager.php" ]; then
        return 0
      fi
      if [ -f "$panel/app/Http/Middleware/HeaderAuthentication.php" ]; then
        return 0
      fi
      if grep -q HeaderAuthentication "$panel/app/Http/Kernel.php" 2>/dev/null; then
        return 0
      fi
      local remote branch
      remote=$(${pkgs.git}/bin/git -C "$panel" remote get-url origin 2>/dev/null || true)
      branch=$(${pkgs.git}/bin/git -C "$panel" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
      if [ "$remote" != "${officialSrc}" ] && [ "$remote" != "git@github.com:pterodactyl/panel.git" ]; then
        return 0
      fi
      if [ "$branch" != "${officialBranch}" ]; then
        return 0
      fi
      return 1
    }

    if [ -f "$marker" ] && ! needs_reset; then
      echo "pterodactyl-stock-reset: already on stock ${officialBranch}"
      exit 0
    fi

    echo "pterodactyl-stock-reset: reverting production panel to stock ${officialBranch}..."

    env_backup=$(mktemp)
    setup_backup=$(mktemp)
    cp -a "$panel/.env" "$env_backup" 2>/dev/null || true
    cp -a "$panel/.setup_done" "$setup_backup" 2>/dev/null || true

    GIT="${pkgs.git}/bin/git -c safe.directory=$panel"
    cd "$panel"

    if [ ! -d .git ]; then
      echo "pterodactyl-stock-reset: initializing git checkout from ${officialSrc}"
      $GIT init -b "${officialBranch}"
      $GIT remote add origin "${officialSrc}"
    else
      $GIT remote set-url origin "${officialSrc}"
      $GIT remote remove fork 2>/dev/null || true
    fi

    $GIT fetch --depth=1 origin "${officialBranch}"
    $GIT checkout -B "${officialBranch}" "origin/${officialBranch}"
    $GIT reset --hard "origin/${officialBranch}"

    cp -a "$env_backup" "$panel/.env" 2>/dev/null || true
    cp -a "$setup_backup" "$panel/.setup_done" 2>/dev/null || true
    rm -f "$env_backup" "$setup_backup"

    # Remove oauth2-proxy header-auth patches from the prior SSO approach.
    rm -f "$panel/app/Http/Middleware/HeaderAuthentication.php"
    if [ -f "$panel/app/Http/Kernel.php" ]; then
      ${pkgs.gnused}/bin/sed -i '/HeaderAuthentication::class,/d' "$panel/app/Http/Kernel.php"
    fi
    if [ -f "$panel/config/auth.php" ]; then
      ${pkgs.python3}/bin/python3 - "$panel/config/auth.php" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
text = re.sub(r"\n    'header' => \[.*?\n    \],\n", "\n", text, count=1, flags=re.S)
open(path, "w").write(text)
PY
    fi
    if [ -f "$panel/resources/views/templates/auth/core.blade.php" ]; then
      $GIT checkout HEAD -- "$panel/resources/views/templates/auth/core.blade.php" 2>/dev/null || true
    fi

    if grep -q '^AUTH_HEADER_' "$panel/.env" 2>/dev/null; then
      ${pkgs.gnused}/bin/sed -i '/^AUTH_HEADER_/d' "$panel/.env"
    fi

    chown -R pterodactyl:pterodactyl "$panel"
    chmod -R u+rwX "$panel/storage" "$panel/bootstrap/cache" 2>/dev/null || true

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
      php /var/www/pterodactyl/artisan cache:clear

    rm -f "${stateDir}/blueprint-installed"
    rm -f "$panel/.blueprint/extensions/blueprint/private/db/is_installed"

    install -d -m 0750 -o pterodactyl -g pterodactyl "${stateDir}"
    echo "stock-${officialBranch}" > "$marker"
    chown pterodactyl:pterodactyl "$marker"
    echo "pterodactyl-stock-reset: production panel is stock ${officialBranch}"
  '';
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/pterodactyl 0750 pterodactyl pterodactyl -"
  ];

  systemd.services.pterodactyl-stock-reset = {
    description = "Reset production Pterodactyl panel to official stock release";
    after = [ "podman-pterodactyl.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = resetScript;
      RemainAfterExit = true;
      TimeoutStartSec = "45min";
    };
  };
}
