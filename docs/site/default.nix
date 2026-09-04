{ lib, pkgs, siteSrc, includesSrc, bootstrapPubkey ? null }:

pkgs.runCommand "nixos-configs-serverdocs"
  {
    nativeBuildInputs = [ pkgs.mdbook pkgs.mdbook-mermaid ];
  }
  ''
    mkdir -p work/src/_includes
    cp -r ${siteSrc}/* work/
    cp ${includesSrc}/*.md work/src/_includes/
    cd work
    mdbook build

    if grep -rq '{{#include _includes/' book/; then
      echo "error: mdbook output contains unexpanded {{#include _includes/...}} directives" >&2
      grep -r '{{#include _includes/' book/ --include='*.html' >&2 || true
      exit 1
    fi

    cp -r book $out

    # LAN bootstrap assets (plain text; not mdBook chapters)
    mkdir -p $out/ssh
    ${lib.optionalString (bootstrapPubkey != null) ''
      cp ${bootstrapPubkey} $out/ssh/id_ed25519.pub
    ''}
  ''
