{ lib, pkgs, siteSrc, includesSrc }:

pkgs.runCommand "nixos-configs-serverdocs"
  {
    nativeBuildInputs = [ pkgs.mdbook ];
  }
  ''
    mkdir -p work/src/_includes
    cp -r ${siteSrc}/* work/
    cp ${includesSrc}/*.md work/src/_includes/
    cd work
    mdbook build
    cp -r book $out
  ''
