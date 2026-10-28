{ config, lib, pkgs, ... }:

# Make each pod-<name>.service own its pod's infra container.
#
# Without this, the infra container is started lazily by whichever member
# runs `podman run --pod=...` first, so its conmon lives in that member's
# systemd cgroup. Restarting that member (an image or env change on switch)
# kills the infra, podman starts a fresh one with a new network namespace, and
# the members that were not restarted keep the old, dead namespace: they can no
# longer reach 127.0.0.1 siblings and Caddy gets 502 (Pterodactyl 2026-10-18 and
# 2026-10-19, coolify-redis 2026-10-18).
#
# Here the pod unit starts the infra itself (conmon stays in pod-<name>.service,
# which is RemainAfterExit), every member is ordered after it, and the infra is
# stopped only when the pod unit stops, after all members (which Require it).
# A single member restart then never touches the namespace.
#
# Pods are found from `--pod=<pod>` in oci-containers extraOptions. The unit is
# pod-<pod> with a trailing "-pod" dropped (grafana-pod -> pod-grafana).
let
  podman = "${pkgs.podman}/bin/podman";

  podOf = c:
    let m = lib.findFirst (o: lib.hasPrefix "--pod=" o) null c.extraOptions;
    in if m == null then null else lib.removePrefix "--pod=" m;

  members = lib.filterAttrs (_: c: podOf c != null) config.virtualisation.oci-containers.containers;

  pods = lib.unique (lib.mapAttrsToList (_: podOf) members);

  unitOf = pod: "pod-${lib.removeSuffix "-pod" pod}";

  startInfra = pod: pkgs.writeShellScript "${unitOf pod}-start-infra" ''
    set -euo pipefail
    infra="$(${podman} pod inspect ${pod} --format '{{.InfraContainerID}}')"
    if [ "$(${podman} container inspect "$infra" --format '{{.State.Running}}')" != true ]; then
      ${podman} start "$infra" >/dev/null
    fi
    conmon="$(${podman} container inspect "$infra" --format '{{.State.ConmonPid}}')"
    if ! ${pkgs.gnugrep}/bin/grep -q "/${unitOf pod}.service$" "/proc/$conmon/cgroup"; then
      echo "${unitOf pod}: infra conmon is not in this unit's cgroup ($(${pkgs.coreutils}/bin/cat /proc/$conmon/cgroup)); a member restart may reset the pod network" >&2
    fi
  '';

  stopInfra = pod: pkgs.writeShellScript "${unitOf pod}-stop-infra" ''
    infra="$(${podman} pod inspect ${pod} --format '{{.InfraContainerID}}' 2>/dev/null)" || exit 0
    ${podman} stop -t 10 "$infra" >/dev/null 2>&1 || true
  '';
in
{
  systemd.services = lib.mkMerge [
    (lib.listToAttrs (map (pod: lib.nameValuePair (unitOf pod) {
      # Restart in place on switch so the restart propagates to the members
      # (Requires=) instead of a stop now and a start that leaves them down.
      stopIfChanged = false;
      serviceConfig = {
        RemainAfterExit = lib.mkForce true;
        ExecStartPost = [ (startInfra pod) ];
        ExecStop = [ (stopInfra pod) ];
      };
    }) pods))

    (lib.mapAttrs' (name: c: lib.nameValuePair "podman-${name}" {
      requires = [ "${unitOf (podOf c)}.service" ];
      after = [ "${unitOf (podOf c)}.service" ];
    }) members)
  ];

  assertions = map (pod: {
    assertion = (config.systemd.services.${unitOf pod}.serviceConfig.ExecStart or null) != null;
    message = "pod-infra.nix: containers use --pod=${pod} but ${unitOf pod}.service does not create it";
  }) pods;
}
