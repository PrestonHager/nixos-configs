# Public homelab home page (homelab.prestonhager.com): plain static files plus
# PNG icons and the social card rendered from the SVG sources at build time.
# Served by Caddy on ace (nixos/caddy/homepage.nix). Preview locally with
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
    rsvg-convert -w 32 -h 32 favicon.svg -o favicon-32.png
    rsvg-convert -w 180 -h 180 logo-mark.svg -o apple-touch-icon.png
    rsvg-convert -w 192 -h 192 logo-mark.svg -o icon-192.png
    rsvg-convert -w 512 -h 512 logo-mark.svg -o icon-512.png
    rsvg-convert -w 1200 -h 630 og.svg -o og.png
  ''
