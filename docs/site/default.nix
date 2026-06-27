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

    if grep -rq '{{#include' book/; then
      echo "error: mdbook output contains unexpanded {{#include}} directives" >&2
      grep -r '{{#include' book/ >&2 || true
      exit 1
    fi

    cp -r book $out
  ''
