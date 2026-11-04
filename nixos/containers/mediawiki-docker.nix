{ pkgs ? import <nixpkgs> {}
, version ? "1.44.0"
, dockerImage ? {}
}:

let
  mwjobrunner = pkgs.writeShellScriptBin "mwjobrunner" ''
    MW_INSTALL_PATH="/var/www/html"
    RUN_JOBS="$MW_INSTALL_PATH/maintenance/runJobs.php --maxtime=3600"
    # The container runs as root; run jobs as php-fpm's user so thumbnails and
    # uploads written by jobs stay writable by the web workers.
    # The image ships BusyBox, whose setpriv has no --reuid, so use su.
    as_www() { su -s /bin/sh www-data -c "$*"; }
    echo Starting job service...
    sleep 60
    echo Started.
    while true; do
      as_www php $RUN_JOBS --type="enotifNotify"
      as_www php $RUN_JOBS --wait --maxjobs=20
      echo Waiting for 10 seconds...
      sleep 10
    done
  '';
in
pkgs.dockerTools.buildLayeredImage {
  name = "mediawiki-redis";
  tag = "${version}";

  fromImage = pkgs.dockerTools.pullImage dockerImage;

  contents = [
    pkgs.redis
    mwjobrunner
  ];

  config = {
    Cmd = [ "/bin/sh" "-c" ''
      # LocalSettings.php uses Redis for caches/jobs, so MediaWiki 500s on every
      # request without the extension. Retry the install (it needs network at
      # boot) and exit non-zero if it never succeeds, so systemd restarts the
      # container instead of php-fpm serving a broken site.
      tries=0
      while ! php -m 2>/dev/null | grep -q '^redis$'; do
        tries=$((tries + 1))
        if [ "$tries" -gt 10 ]; then
          echo "FATAL: php redis extension could not be installed" >&2
          exit 1
        fi
        echo "Installing php redis extension (attempt $tries)..."
        apk add --no-cache autoconf gcc g++ make musl-dev openssl-dev \
          && printf '\n' | pecl install redis \
          && docker-php-ext-enable redis \
          || sleep 15
      done
      redis-server --daemonize yes
      mwjobrunner &
      exec php-fpm -F
    '' ];
    ExposedPorts = {
      "6379/tcp" = {};
    };
  };
}