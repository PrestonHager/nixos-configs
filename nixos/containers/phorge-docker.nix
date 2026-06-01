{ pkgs, ... }:

let
  # Fetch Phorge and Arcanist repositories
  phorgeSrc = pkgs.fetchFromGitHub {
    owner = "phorgeit";
    repo = "phorge";
    rev = "master";
    sha256 = "sha256-nssciDEaZtst4ETCGJwsLvcyUlWwvM18KWVs9sOJt7M=";
  };

  arcanistSrc = pkgs.fetchFromGitHub {
    owner = "phorgeit";
    repo = "arcanist";
    rev = "master";
    sha256 = "sha256-u+3IWQ2JGCZqZMocDnNXEp80Vlw1S/lAF2St6V3pMTY=";
  };

  # Copy repos to /opt where they won't be overwritten by volumes
  phorge = pkgs.runCommand "phorge" {} ''
    mkdir -p $out/opt/phorge-src
    cp -r ${phorgeSrc}/* $out/opt/phorge-src/
  '';

  arcanist = pkgs.runCommand "arcanist" {} ''
    mkdir -p $out/opt/arcanist-src
    cp -r ${arcanistSrc}/* $out/opt/arcanist-src/
  '';

  # Apache config
  httpdConf = pkgs.writeTextDir "/etc/apache2/httpd.conf" ''
    <VirtualHost *>
      ServerName "''${PHORGE_BASE_URI:-localhost}"
      DocumentRoot /var/www/html/webroot
      RewriteEngine on
      RewriteRule ^(.*)$ /index.php?__path__=$1  [B,L,QSA,UnsafeAllow3F]
    </VirtualHost>
    <Directory "/var/www/html/webroot">
      Require all granted
    </Directory>
  '';

  # Entrypoint script
  entrypointScript = pkgs.writeShellScriptBin "phorge-entrypoint" ''
    #!/bin/sh
    set -e

    echo "Checking if /var/www/html is initialized..."
    if [ ! -f /var/www/html/.initialized ]; then
      echo "Copying Phorge source to /var/www/html"
      cp -r /opt/phorge-src/* /var/www/html/
      touch /var/www/html/.initialized
    fi

    if [ ! -f /var/www/arcanist/.initialized ]; then
      echo "Copying Arcanist source to /var/www/arcanist"
      cp -r /opt/arcanist-src/* /var/www/arcanist/
      touch /var/www/arcanist/.initialized
    fi

    DB_HOST=''${PHORGE_DB_HOST:-127.0.0.1}
    DB_USER=''${PHORGE_DB_USER:-phorge}

    DB_ROOT_PASS=''${MYSQL_ROOT_PASSWORD:-''${MARIADB_ROOT_PASSWORD:-}}
    DB_USER_PASS=''${MYSQL_PWD:-''${MARIADB_PASSWORD:-}}

    if [ -z "''${DB_ROOT_PASS}" ]; then
      echo >&2 "ERROR: Need MYSQL_ROOT_PASSWORD or MARIADB_ROOT_PASSWORD"
      exit 1
    fi

    echo "Waiting for DB at ''${DB_HOST}..."
    until mysql -h "''${DB_HOST}" -uroot -p"''${DB_ROOT_PASS}" -e "SELECT 1;" > /dev/null 2>&1; do
      echo "Waiting for DB…"
      sleep 1
    done

    mysql -h "$DB_HOST" -uroot -p"$DB_ROOT_PASS" <<EOF
GRANT ALL PRIVILEGES ON \`phabricator\_%\`.* TO $DB_USER@'%';
FLUSH PRIVILEGES;
EOF

    cd /var/www/html
    if [ ! -f /var/www/html/.dbupgraded ]; then
      echo "Configuring Phorge database connection..."
      php ./bin/config set mysql.host "''${DB_HOST}"
      php ./bin/config set mysql.user "''${DB_USER}"
      php ./bin/config set mysql.pass "''${DB_USER_PASS}"

      echo "Running Phorge schema upgrade..."
      php ./bin/storage upgrade --force --user "''${DB_USER}"
      touch /var/www/html/.dbupgraded
    fi

    echo "Starting Apache..."
    exec apache2-foreground
  '';
in

pkgs.dockerTools.buildImage {
  name = "phorge";
  tag = "latest";
  fromImageName = "php";
  fromImageTag = "8.4-apache";

  copyToRoot = pkgs.buildEnv {
    name = "image-root";
    paths = [
      phorge
      arcanist
      httpdConf
      entrypointScript
      pkgs.mariadb
      pkgs.mariadb.client
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.php
      pkgs.phpExtensions.mbstring
      pkgs.phpExtensions.iconv
      pkgs.phpExtensions.mysqli
      pkgs.phpExtensions.curl
      pkgs.phpExtensions.pcntl
      pkgs.phpExtensions.gd
      pkgs.phpExtensions.zip
    ];
    pathsToLink = [
      "/opt"
      "/etc/apache2"
      "/bin"
      "/usr/bin"
    ];
    ignoreCollisions = true;
  };

  runAsRoot = ''
    ${pkgs.dockerTools.shadowSetup}
  '';

  config = {
    Entrypoint = [ "/bin/phorge-entrypoint" ];
    Volumes = {
      "/var/www/html" = {};
      "/var/www/arcanist" = {};
    };
  };
}

