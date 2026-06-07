{ config, pkgs, ... }:

let
  version = "1.11.11";
  testPanelDir = "/home/prestonh/Projects/panel";
  officialSrc = "https://github.com/pterodactyl/panel.git";
  officialBranch = "release/v${version}";
  stateDir = "/var/lib/pterodactyl-test";
  resetMarker = "${stateDir}/stock-reset-${version}";

  resetScript = pkgs.writeShellScript "pterodactyl-test-stock-reset" ''
    set -euo pipefail
    panel="${testPanelDir}"
    marker="${resetMarker}"

    if [ ! -d "$panel/app" ]; then
      echo "pterodactyl-test-stock-reset: panel not installed at $panel, skipping" >&2
      exit 0
    fi

    needs_reset() {
      if [ ! -d "$panel/.git" ]; then
        return 0
      fi
      if [ -f "$panel/app/Services/Plugins/PluginManager.php" ]; then
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
      echo "pterodactyl-test-stock-reset: already on stock ${officialBranch}"
      exit 0
    fi

    echo "pterodactyl-test-stock-reset: reverting test panel to stock ${officialBranch}..."

    env_backup=$(mktemp)
    setup_backup=$(mktemp)
    cp -a "$panel/.env" "$env_backup" 2>/dev/null || true
    cp -a "$panel/.setup_done" "$setup_backup" 2>/dev/null || true

    GIT="${pkgs.git}/bin/git -c safe.directory=$panel"
    cd "$panel"

    if [ ! -d .git ]; then
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

    rm -rf "$panel/storage/app/plugins" "$panel/public/plugins" 2>/dev/null || true
    runuser -u prestonh -- rm -rf "$panel/.blueprint" "$panel/blueprint" "$panel/blueprint.sh" "$panel/.blueprintrc" 2>/dev/null || true

    chown -R prestonh:users "$panel"
    find "$panel" -type d -exec chmod 2775 {} +
    find "$panel" -type f -exec chmod 0664 {} +
    for dir in storage bootstrap/cache vendor; do
      if [ -d "$panel/$dir" ]; then
        ${pkgs.acl}/bin/setfacl -R -m u:pterodactyl:rwx "$panel/$dir"
        ${pkgs.acl}/bin/setfacl -R -d -m u:pterodactyl:rwx "$panel/$dir"
      fi
    done

    ${pkgs.podman}/bin/podman exec \
      -e HOME=/var/www/pterodactyl \
      -e COMPOSER_HOME=/tmp/composer \
      pterodactyl-test \
      sh -c 'cd /var/www/pterodactyl && composer install --no-dev --optimize-autoloader' \
      2>/dev/null || true

    rm -f "${stateDir}/blueprint-fork-installed"
    echo "stock-${officialBranch}" > "$marker"
    chown pterodactyl:pterodactyl "$marker"
    echo "pterodactyl-test-stock-reset: test panel is stock ${officialBranch}"
  '';
in
{
  systemd.services.pterodactyl-test-stock-reset = {
    description = "Reset test Pterodactyl panel to official stock release";
    after = [ "podman-pterodactyl-test.service" "pterodactyl-test-panel-perms.service" ];
    before = [ "pterodactyl-test-blueprint-install.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = resetScript;
      RemainAfterExit = true;
      TimeoutStartSec = "45min";
    };
  };
}
