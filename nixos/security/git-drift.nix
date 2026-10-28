{ config, pkgs, lib, ... }:

let
  cfg = config.homelab.security;
  textfileDir = "/var/lib/node-exporter-textfile";
  driftScript = pkgs.writeShellScript "homelab-git-drift-check" ''
    set -euo pipefail
    HOST="${cfg.hostName}"
    REMOTE="${cfg.gitDrift.remote}"
    BRANCH="${cfg.gitDrift.branch}"
    OUT="${textfileDir}/homelab_git_drift.prom"
    NIXOS="/etc/nixos"

    mkdir -p "${textfileDir}"

    drift=0
    unpushed=0
    dirty=0

    if [ ! -d "$NIXOS/.git" ]; then
      echo "homelab_git_drift{host=\"$HOST\",reason=\"no_git\"} 1" > "$OUT"
      exit 0
    fi

    # The automated updaters (service bumps, nightly nixpkgs) hold this lock while
    # flake.lock or a pin is changed but not yet committed. Keep the last result
    # instead of reporting that window as drift.
    if [ -e /run/ace-service-update-rebuild.lock ] \
      && ! flock -n /run/ace-service-update-rebuild.lock true; then
      logger -t homelab-git-drift "automated update in progress; skipping check"
      exit 0
    fi

    cd "$NIXOS"
    git fetch "$REMOTE" "$BRANCH" 2>/dev/null || true

    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      dirty=1
      drift=1
    fi

    LOCAL="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
    REMOTE_REF="$REMOTE/$BRANCH"
    if git rev-parse "$REMOTE_REF" >/dev/null 2>&1; then
      UPSTREAM="$(git rev-parse "$REMOTE_REF")"
      if [ "$LOCAL" != "$UPSTREAM" ] && ! git merge-base --is-ancestor "$LOCAL" "$UPSTREAM" 2>/dev/null; then
        unpushed=1
        drift=1
      fi
      AHEAD="$(git rev-list --count "$UPSTREAM..HEAD" 2>/dev/null || echo 0)"
      BEHIND="$(git rev-list --count HEAD.."$UPSTREAM" 2>/dev/null || echo 0)"
    else
      AHEAD=0
      BEHIND=0
    fi

    {
      echo "# HELP homelab_git_drift 1 when /etc/nixos has uncommitted changes or diverged from $REMOTE/$BRANCH"
      echo "# TYPE homelab_git_drift gauge"
      echo "homelab_git_drift{host=\"$HOST\"} $drift"
      echo "homelab_git_dirty{host=\"$HOST\"} $dirty"
      echo "homelab_git_unpushed{host=\"$HOST\"} $unpushed"
      echo "homelab_git_ahead{host=\"$HOST\"} ''${AHEAD:-0}"
      echo "homelab_git_behind{host=\"$HOST\"} ''${BEHIND:-0}"
    } > "$OUT"

    if [ "$drift" -eq 1 ]; then
      logger -t homelab-git-drift "host=$HOST dirty=$dirty unpushed=$unpushed"
    fi
  '';
in {
  config = lib.mkIf cfg.enable {
    systemd.services.homelab-git-drift = {
      description = "Check /etc/nixos for uncommitted or unpushed drift";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.git pkgs.openssh pkgs.util-linux ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = driftScript;
      };
    };

    systemd.timers.homelab-git-drift = {
      description = "Periodic /etc/nixos git drift check";
      wantedBy = [ "timers.target" ];
      # Every 15 minutes: hourly left a stale "unpushed" for up to 70 minutes
      # after a push. A run is one git fetch plus local git status/rev-list.
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "15min";
        RandomizedDelaySec = "1min";
        Unit = "homelab-git-drift.service";
      };
    };
  };
}
