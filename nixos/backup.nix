# Nightly backups for ace (docs/backups-ace.md).
#
# 1. homelab-db-dumps: logical dumps of every database container plus a
#    consistent copy of Vaultwarden's SQLite, written to ${dumpDir}.
# 2. restic-backups-local: snapshots the dumps and the important file trees
#    into the restic repository on /stor (the second disk, sda), so a failure
#    of the system disk (sdb) or a bad upgrade can be recovered from.
#
# This is not offsite: losing the whole machine loses these too. Add a second
# services.restic.backups.<name> with an offsite repository when one exists.
# The repository password is in nix-secrets secrets/hosts/ace/backup.yaml.
{ config, pkgs, lib, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  backupRoot = "/stor/backup";
  dumpDir = "${backupRoot}/dumps";
  repo = "${backupRoot}/restic";
  textfileDir = "/var/lib/node-exporter-textfile";
  podman = "${pkgs.podman}/bin/podman";

  mariadbContainers = [
    "mediawiki-db"
    "pterodactyl-db"
    "pterodactyl-test-db"
    "animal-search-production-db"
    "animal-search-staging-db"
  ];
  postgresContainers = [ "coolify-db" "matrix-db" "zitadel-db" ];

  dumpScript = pkgs.writeShellScript "homelab-db-dumps" ''
    set -uo pipefail
    umask 077
    mkdir -p ${dumpDir}
    failed=0

    running() {
      ${podman} container inspect "$1" --format '{{.State.Running}}' 2>/dev/null | grep -q true
    }

    # Write to a temp file and rename, so a failed dump never replaces the
    # previous good one.
    dump() {
      local name=$1; shift
      local out="${dumpDir}/$name.sql.gz"
      if "$@" | ${pkgs.gzip}/bin/gzip -c > "$out.tmp" && [ -s "$out.tmp" ]; then
        mv "$out.tmp" "$out"
        echo "dumped $name ($(${pkgs.coreutils}/bin/du -h "$out" | cut -f1))"
      else
        rm -f "$out.tmp"
        echo "FAILED to dump $name" >&2
        failed=1
      fi
    }

    for c in ${lib.concatStringsSep " " mariadbContainers}; do
      running "$c" || { echo "skipping $c (not running)"; continue; }
      # MYSQL_PWD, not -p<password>: argv of container processes shows up in host `ps`.
      dump "$c" ${podman} exec "$c" sh -c \
        'export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"; exec mariadb-dump -uroot --all-databases --single-transaction --routines --events --triggers'
    done

    # nextcloud-db: the root and app passwords in its container env no longer
    # match the database, so use the credentials Nextcloud itself connects
    # with (config.php), passed through a root-only env file.
    if running nextcloud-db && running nextcloud; then
      ncenv=$(mktemp /run/nc-dump.XXXXXX)
      ${podman} exec -u www-data nextcloud php -r \
        '$CONFIG=[]; include "/var/www/html/config/config.php"; echo "MYSQL_PWD=", $CONFIG["dbpassword"], "\nDBU=", $CONFIG["dbuser"], "\nDBN=", $CONFIG["dbname"], "\n";' > "$ncenv"
      dump nextcloud-db ${podman} exec --env-file "$ncenv" nextcloud-db sh -c \
        'exec mariadb-dump -u"$DBU" --single-transaction --routines --events --triggers --databases "$DBN"'
      ${pkgs.coreutils}/bin/shred -u "$ncenv"
    else
      echo "skipping nextcloud-db (not running)"
    fi

    for c in ${lib.concatStringsSep " " postgresContainers}; do
      running "$c" || { echo "skipping $c (not running)"; continue; }
      dump "$c" ${podman} exec "$c" sh -c 'exec pg_dumpall -U "$POSTGRES_USER"'
    done

    # SQLite's online backup API gives a consistent copy while Vaultwarden runs.
    if ${pkgs.sqlite}/bin/sqlite3 /vw-data/db.sqlite3 ".backup '${dumpDir}/vaultwarden.sqlite3.tmp'"; then
      mv ${dumpDir}/vaultwarden.sqlite3.tmp ${dumpDir}/vaultwarden.sqlite3
      echo "dumped vaultwarden"
    else
      rm -f ${dumpDir}/vaultwarden.sqlite3.tmp
      echo "FAILED to dump vaultwarden" >&2
      failed=1
    fi

    exit $failed
  '';

  # Prometheus textfile metric, written only after a successful snapshot.
  markSuccess = pkgs.writeShellScript "homelab-backup-mark-success" ''
    umask 022
    f=${textfileDir}/homelab_backup.prom
    {
      echo '# HELP homelab_backup_last_success_timestamp_seconds Unix time of the last successful backup run.'
      echo '# TYPE homelab_backup_last_success_timestamp_seconds gauge'
      echo "homelab_backup_last_success_timestamp_seconds{repo=\"local\"} $(date +%s)"
    } > "$f.tmp" && mv "$f.tmp" "$f"
  '';
in
{
  sops.secrets."restic-password" = {
    sopsFile = "${sops-path}/secrets/hosts/ace/backup.yaml";
    mode = "0400";
  };

  systemd.tmpfiles.rules = [
    "d ${backupRoot} 0700 root root -"
    "d ${dumpDir} 0700 root root -"
  ];

  services.restic.backups.local = {
    repository = repo;
    passwordFile = config.sops.secrets."restic-password".path;
    initialize = true;

    # Dumps first; if any database fails to dump, the run fails and the
    # backup-age alert fires rather than silently snapshotting stale dumps.
    backupPrepareCommand = "${dumpScript}";

    paths = [
      dumpDir
      "/vw-data"                 # Vaultwarden attachments, sends, rsa_key.pem (+ the sqlite copy above)
      "/stor/nextcloud/data"     # Nextcloud user files
      "/mw/images"               # MediaWiki uploads
      "/mw/html/LocalSettings.php"
      "/jf/config"               # Jellyfin config and metadata DB
      "/stor/coolify/app"        # Coolify SSH keys and app storage
      "/zitadel/login-client"    # Zitadel login-client key
      "/pterodactyl/secrets"
      "/stor/technitium"         # DNS server config and zones
    ];
    exclude = [
      "/vw-data/icon_cache"
      "/vw-data/db.sqlite3*"     # live DB; the consistent copy is in dumps/
      "/vw-data/tmp"
      "/jf/config/cache"
      "/jf/config/log"
      "/stor/technitium/logs"
    ];

    timerConfig = {
      OnCalendar = "03:30";
      RandomizedDelaySec = "15m";
      Persistent = true;
    };

    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 6"
    ];
  };

  systemd.services.restic-backups-local.serviceConfig.ExecStartPost = [ "${markSuccess}" ];

  # MariaDB's image only upgrades its system tables after a major version
  # bump when this is set. Without it, pterodactyl-db and nextcloud-db kept
  # 11.x system tables under 12.3, which broke dumps of stored routines.
  # The upgrade runs with --skip-grant-tables and keeps its own backup.
  virtualisation.oci-containers.containers = lib.genAttrs
    ([ "nextcloud-db" ] ++ mariadbContainers)
    (_: { environment.MARIADB_AUTO_UPGRADE = "1"; });
}

