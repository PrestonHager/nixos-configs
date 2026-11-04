# Public homelab home page (homelab.prestonhager.com): plain static files plus
# PNG icons, PNG exports of every brand image and the social card, all
# rendered from the SVG sources at build time. Served by Caddy on ace
# (nixos/caddy/homepage.nix). Preview locally with
#   nix build .#homepage && nix run nixpkgs#caddy -- file-server --root result --listen :8080
{ pkgs }:

let
  fontsConf = pkgs.makeFontsConf { fontDirectories = [ pkgs.inter pkgs.dejavu_fonts ]; };
in
pkgs.runCommand "homelab-homepage"
  {
    src = pkgs.lib.cleanSourceWith {
      src = ./.;
      filter = path: _type: baseNameOf path != "default.nix";
    };
    nativeBuildInputs = [ pkgs.librsvg ];
    FONTCONFIG_FILE = fontsConf;
  }
  ''
    cp -r $src $out
    chmod -R u+w $out
    cd $out/assets

    # Icons referenced by the pages and the web manifest
    rsvg-convert -w 32 -h 32 favicon.svg -o favicon-32.png
    rsvg-convert -w 180 -h 180 logo-mark.svg -o apple-touch-icon.png
    rsvg-convert -w 192 -h 192 logo-mark.svg -o icon-192.png
    rsvg-convert -w 512 -h 512 logo-mark.svg -o icon-512.png
    rsvg-convert -w 1200 -h 630 og.svg -o og.png

    # Brand kit PNGs (transparent background except the mark's own tile).
    # The monochrome mark uses currentColor, so render a black and a white copy.
    mkdir -p png
    for w in 600 1200 2400; do
      rsvg-convert -w $w logo.svg -o png/logo-$w.png
      rsvg-convert -w $w logo-on-light.svg -o png/logo-on-light-$w.png
    done
    for s in 256 512 1024; do
      rsvg-convert -w $s -h $s logo-mark.svg -o png/logo-mark-$s.png
      sed 's/currentColor/#121A2F/g' logo-mono.svg | rsvg-convert -w $s -h $s -o png/logo-mono-dark-$s.png
      sed 's/currentColor/#FFFFFF/g' logo-mono.svg | rsvg-convert -w $s -h $s -o png/logo-mono-white-$s.png
    done
    cp og.png png/social-card-1200x630.png
  ''
