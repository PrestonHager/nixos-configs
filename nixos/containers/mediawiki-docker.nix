{ pkgs ? import <nixpkgs> {}
, version ? "1.44.0"
, dockerImage ? {}
}:

let
  mwjobrunner = pkgs.writeShellScriptBin "mwjobrunner" ''
    MW_INSTALL_PATH="/var/www/html"
    RUN_JOBS="$MW_INSTALL_PATH/maintenance/runJobs.php --maxtime=3600"
    echo Starting job service...
    sleep 60
    echo Started.
    while true; do
      php $RUN_JOBS --type="enotifNotify"
      php $RUN_JOBS --wait --maxjobs=20
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
    pkgs.busybox
    pkgs.redis
    mwjobrunner
  ];

  config = {
    Cmd = [ "/bin/sh" "-c" ''
      /sbin/apk add --no-cache php83-pecl-redis
      redis-server --daemonize yes
      mwjobrunner &
      exec php-fpm -F
    '' ];
    ExposedPorts = {
      "6379/tcp" = {};
    };
  };
}