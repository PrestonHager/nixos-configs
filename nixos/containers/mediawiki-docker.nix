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
    AS_WWW="setpriv --reuid=www-data --regid=www-data --init-groups"
    echo Starting job service...
    sleep 60
    echo Started.
    while true; do
      $AS_WWW php $RUN_JOBS --type="enotifNotify"
      $AS_WWW php $RUN_JOBS --wait --maxjobs=20
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
      if ! php -m 2>/dev/null | grep -q '^redis$'; then
        if command -v apk >/dev/null 2>&1; then
          apk add --no-cache autoconf gcc g++ make musl-dev openssl-dev
          pecl install redis
          docker-php-ext-enable redis
        fi
      fi
      redis-server --daemonize yes
      mwjobrunner &
      exec php-fpm -F
    '' ];
    ExposedPorts = {
      "6379/tcp" = {};
    };
  };
}