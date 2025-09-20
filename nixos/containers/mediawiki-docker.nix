{ pkgs ? import <nixpkgs> {}
, version ? "1.44.0"
, dockerImage ? {}
}:

let
  mwjobrunner = pkgs.writeShellScriptBin "mwjobrunner" ''
    # Put the MediaWiki installation path on the line below
    MW_INSTALL_PATH="/var/www/html"
    RUN_JOBS="$MW_INSTALL_PATH/maintenance/runJobs.php --maxtime=3600"
    echo Starting job service...
    # Wait a minute after the server starts up to give other processes time to get started
    sleep 60
    echo Started.
    while true; do
      # Job types that need to be run ASAP no matter how many of them are in the queue
      # Those jobs should be very "cheap" to run
      php $RUN_JOBS --type="enotifNotify"
      # Everything else, limit the number of jobs on each batch
      # The --wait parameter will pause the execution here until new jobs are added,
      # to avoid running the loop without anything to do
      php $RUN_JOBS --wait --maxjobs=20
      # Wait some seconds to let the CPU do other things, like handling web requests, etc
      echo Waiting for 10 seconds...
      sleep 10
    done
  '';
in
pkgs.dockerTools.buildLayeredImage {
  name = "mediawiki-redis";
  tag = "${version}";

  # create a from a base image of alpine linux
  #fromImageName = "mediawiki";
  #fromImageTag = "${version}-fpm-alpine";
  fromImage = pkgs.dockerTools.pullImage dockerImage;

  #copyToRoot = pkgs.buildEnv {
    #name = "mediawiki-redis-${version}";
    #paths = [
  contents = [
      pkgs.busybox
      pkgs.redis
      #(pkgs.php.withExtensions ({ enabled, all }: enabled ++ [
      #  all.redis
      #  all.mbstring
      #  all.xml
      #  all.intl
      #  all.opcache
      #]))
      mwjobrunner
    ];
    #pathsToLink = ["/bin" "/lib" "/lib64" "/usr" "/etc" "/nix/store"];
  #};

  config = {
    # start the redis server and mwjobrunner in the background, then run apache2
    # in the foreground.
    Cmd = [ "/bin/sh" "-c" ''
      # Start Redis server
      redis-server --daemonize yes
      # Start the job runner in the background
      mwjobrunner &
      # Start FPM PHP
      exec php-fpm -F
    '' ];
    ExposedPorts = {
      "6379/tcp" = {};
    };
  };
}
