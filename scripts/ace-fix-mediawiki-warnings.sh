#!/usr/bin/env bash
# Fix MediaWiki 1.45.3 tarball leftovers that print warnings / break styling context.
# Safe to re-run after upgrading /mw/html from the official tarball.
set -euo pipefail

patch_resources() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "skip missing $f"
    return 0
  fi
  if ! grep -q "wgParserEnableLegacyMediaDOM" "$f"; then
    echo "already patched $f"
    return 0
  fi
  local ts bak start end
  ts=$(date +%Y%m%d%H%M%S)
  bak="$f.bak.$ts"
  cp -a "$f" "$bak"
  start=$(grep -n "^[[:space:]]*'mediawiki.page.gallery.styles' =>" "$f" | head -1 | cut -d: -f1)
  end=$(grep -n "^[[:space:]]*'mediawiki.page.gallery.slideshow' =>" "$f" | head -1 | cut -d: -f1)
  if [[ -z "$start" || -z "$end" ]]; then
    echo "could not find gallery.styles markers in $f" >&2
    exit 1
  fi
  {
    head -n $((start - 1)) "$f"
    cat <<'EOF'
	'mediawiki.page.gallery.styles' => [
		'styles' => [
			'resources/src/mediawiki.page.gallery.styles/gallery.less',
			'resources/src/mediawiki.page.gallery.styles/print.less' => [ 'media' => 'print' ],
		],
	],
EOF
    tail -n +"$end" "$f"
  } > "$f.new"
  mv "$f.new" "$f"
  chown --reference="$bak" "$f" 2>/dev/null || true
  chmod --reference="$bak" "$f" 2>/dev/null || true
  echo "patched $f (backup $bak)"
}

harden_localsettings() {
  local ls=/mw/html/LocalSettings.php
  if [[ ! -f "$ls" ]]; then
    echo "skip missing $ls"
    return 0
  fi
  if grep -q "ini_set( 'display_errors'" "$ls"; then
    echo "LocalSettings.php already hardened"
    return 0
  fi
  local ts
  ts=$(date +%Y%m%d%H%M%S)
  cp -a "$ls" "$ls.bak.$ts"
  awk -v q="'" '
    BEGIN { done = 0 }
    {
      print
      if (!done && $0 ~ /^<\?php/) {
        print "# Production: never print PHP warnings to visitors (docker php defaults display_errors=STDOUT)"
        print "ini_set( " q "display_errors" q ", " q "0" q " );"
        print "error_reporting( E_ALL & ~E_DEPRECATED & ~E_STRICT );"
        done = 1
      }
    }
  ' "$ls" > "$ls.tmp"
  mv "$ls.tmp" "$ls"
  chown --reference="$ls.bak.$ts" "$ls" 2>/dev/null || true
  chmod --reference="$ls.bak.$ts" "$ls" 2>/dev/null || true
  echo "hardened LocalSettings.php"
}

patch_resources /mw/html/resources/Resources.php
patch_resources /mw/mediawiki-1.45.3/resources/Resources.php
harden_localsettings

if command -v podman >/dev/null 2>&1; then
  podman exec mediawiki php -l /var/www/html/resources/Resources.php
  podman exec mediawiki php -l /var/www/html/LocalSettings.php
fi
