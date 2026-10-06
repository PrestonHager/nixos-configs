# Workaround: python3Packages.inline-snapshot's test suite fails
# non-deterministically in the Nix sandbox at the currently pinned nixpkgs
# rev, blocking openai -> sqlframe -> ceph/samba -> home-manager -> the whole
# system rebuild. We only need the library, not its own test suite, so disable
# the check phase for this package.
#
# The override is applied to `python3` AND `python312` separately: on
# nixos-unstable `python3` tracks 3.14 while the ceph/samba dependency chain
# still resolves 3.12, so patching only `python3` leaves python312 broken.
{ config, lib, ... }:

let
  disableInlineSnapshotCheck = super:
    super.override {
      packageOverrides = _pfinal: pprev: {
        inline-snapshot =
          pprev.inline-snapshot.overridePythonAttrs (_attrs: { doCheck = false; });
      };
    };
in
{
  nixpkgs.overlays = [
    (final: prev: {
      python3 = disableInlineSnapshotCheck prev.python3;
      python3Packages = final.python3.pkgs;
      python312 = disableInlineSnapshotCheck prev.python312;
      python312Packages = final.python312.pkgs;
    })
  ];
}
