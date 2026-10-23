{ pkgs, ... }:
{
  # Weekly removal of dangling (untagged) podman images left behind by image bumps and
  # rebuilt nix-built images. Tagged images, containers and volumes are not touched, so
  # stopped-but-defined containers and their data are safe.
  systemd.services.podman-image-prune = {
    description = "Prune dangling podman images";
    after = [ "podman.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.podman}/bin/podman image prune --force";
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };

  systemd.timers.podman-image-prune = {
    description = "Weekly dangling podman image prune";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun 04:30";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };
}
