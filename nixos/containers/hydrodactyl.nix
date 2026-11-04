# Hydrodactyl panel flavor for the production and test panels.
#
#   homelab.panel.prod.flavor = "hydrodactyl";   # default "pterodactyl"
#   homelab.panel.test.flavor = "hydrodactyl";
#
# Switching a panel keeps its pod, MariaDB, Valkey, secrets and Caddy site
# (pterodactyl.nix / pterodactyl-test.nix) and only swaps the panel container
# for the Nix-built Hydrodactyl image, turns off the Blueprint-era units and
# adds a configure step for the native replacements in plugins/hydrodactyl.
# The first start over Pterodactyl dumps the database first (see
# hydrodactyl-docker.nix); Hydrodactyl's migrations are one-way.
# Plan: docs/hydrodactyl-migration-plan.md
{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.homelab.panel;
  kc = import ../auth/keycloak-lib.nix;
  hydro = import ./hydrodactyl-panel.nix { inherit pkgs inputs; };
  images = import ./hydrodactyl-docker.nix { inherit pkgs hydro; };
  image = "hydrodactyl-runtime:v${hydro.version}";

  testEnvFile = "/var/lib/pterodactyl-test/pterodactyl.env";
  testSecretsDir = "/var/lib/pterodactyl-test/secrets";
  testPanelDir = "/pterodactyl-test/html";

  flavorOption = name: lib.mkOption {
    type = lib.types.enum [ "pterodactyl" "hydrodactyl" ];
    default = "pterodactyl";
    description = "Panel software for the ${name} panel.";
  };

  # Keycloak client shared by both panels (and the unused oauth2-proxy in
  # pterodactyl-oauth.nix). The secret is the one the Zitadel app had,
  # PTERODACTYL_OIDC_CLIENT_SECRET in sops; keycloak-realm-sync sets it.
  ssoClientId = "pterodactyl";

  # One-time move of panel SSO links from Zitadel to Keycloak: panel user
  # email => Keycloak user id (the OIDC sub). A user whose link still holds
  # a Zitadel id (all digits), or who has no link, gets this one; a link
  # that already holds a Keycloak id is never touched. Users without an
  # entry link themselves on first login when their Keycloak email is
  # verified (sociallogin::allow_connecting). docs/pterodactyl-ace.md
  ssoLinks = {
    # Keycloak prestonh (Zitadel 376197075085302069), panel user prestonhager
    "preston@hagerfamily.com" = "99d63cf6-7775-44d9-b9c9-6be589bea2ae";
  };

  # Keycloak provider row (renamed from the Zitadel one, so existing links
  # keep their provider_id) + SSO link migration + sociallogin toggles + egg
  # loader features, all idempotent. Runs inside the panel container.
  configurePhp = pkgs.writeText "hydrodactyl-configure.php" ''
    <?php
    require "/var/www/pterodactyl/vendor/autoload.php";
    $app = require "/var/www/pterodactyl/bootstrap/app.php";
    $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

    use Illuminate\Support\Facades\DB;
    use Illuminate\Support\Facades\Crypt;
    use Pterodactyl\Addons\Sso\SocialProvider;
    use Pterodactyl\Addons\Sso\SocialConnection;
    use Pterodactyl\Models\User;

    $id = getenv("PTERODACTYL_OIDC_CLIENT_ID") ?: "";
    $secret = getenv("PTERODACTYL_OIDC_CLIENT_SECRET") ?: "";
    if ($id !== "" && $secret !== "" && $secret !== "REPLACE_ME") {
      $old = SocialProvider::query()->where("short_name", "zitadel")->first();
      if ($old && !SocialProvider::query()->where("short_name", "keycloak")->exists()) {
        $old->short_name = "keycloak";
        $old->name = "Keycloak";
        $old->save();
        echo "provider zitadel renamed to keycloak (id {$old->id})\n";
      }
      $p = SocialProvider::query()->firstOrNew(["short_name" => "keycloak"]);
      $p->fill(["enabled" => true, "name" => $p->name ?: "Keycloak", "client_id" => $id]);
      try {
        $same = $p->client_secret && Crypt::decryptString($p->client_secret) === $secret;
      } catch (Illuminate\Contracts\Encryption\DecryptException) {
        $same = false; // e.g. a prod row copied into the test panel (other APP_KEY)
      }
      if (!$same) {
        $p->client_secret = Crypt::encryptString($secret);
      }
      $p->save();
      foreach (["allow_register", "allow_connecting"] as $k) {
        DB::table("settings")->updateOrInsert(["key" => "sociallogin::$k"], ["value" => serialize("1")]);
      }
      echo "keycloak provider configured\n";

      $links = json_decode(<<<'JSON'
    ${builtins.toJSON ssoLinks}
    JSON, true);
      foreach ($links as $email => $sub) {
        $user = User::query()->where("email", $email)->first();
        if (!$user) {
          continue;
        }
        $c = SocialConnection::query()->where("user_id", $user->id)->where("provider_id", $p->id)->first();
        if ($c && !ctype_digit((string) $c->auth_id)) {
          continue; // already a Keycloak id
        }
        $taken = SocialConnection::query()->where("provider_id", $p->id)->where("auth_id", $sub)
          ->where("user_id", "<>", $user->id)->exists();
        if ($taken) {
          echo "sso link for {$email}: {$sub} already linked to another user, skipped\n";
          continue;
        }
        $from = $c ? $c->auth_id : "none";
        SocialConnection::query()->updateOrCreate(
          ["user_id" => $user->id, "provider_id" => $p->id],
          ["auth_id" => $sub, "auth_name" => $c?->auth_name ?: $user->username],
        );
        echo "sso link for {$email} (user {$user->id}): {$from} -> {$sub}\n";
      }
    }

    // Marketplace loaders (Installer page, Minecraft > Plugins & Mods) come
    // from egg features like "mod/fabric"; our Minecraft eggs only had eula.
    $features = json_decode(<<<'JSON'
    ${builtins.toJSON cfg.eggLoaderFeatures}
    JSON, true);
    foreach ($features as $egg => $wanted) {
      foreach (DB::table("eggs")->where("name", $egg)->get() as $row) {
        $current = json_decode($row->features ?? "[]", true) ?: [];
        $merged = array_values(array_unique(array_merge($current, $wanted)));
        if ($merged !== $current) {
          DB::table("eggs")->where("id", $row->id)->update(["features" => json_encode($merged)]);
          echo "egg {$row->name}: " . implode(", ", $merged) . "\n";
        }
      }
    }
  '';

  # .env keys enforced before the container starts (config is cached there).
  envScript = file: adminGroup: pkgs.writeShellScript "hydrodactyl-env" ''
    set -euo pipefail
    env=${file}
    [ -f "$env" ] || exit 0
    set_kv() {
      if grep -q "^$1=" "$env"; then
        ${pkgs.gnused}/bin/sed -i "s|^$1=.*|$1=$2|" "$env"
      else
        printf '%s=%s\n' "$1" "$2" >> "$env"
      fi
    }
    set_kv APP_LOCALE en-US
    set_kv SSO_ISSUER ${kc.issuer}
    set_kv SSO_ADMIN_GROUP ${adminGroup}
    # Left over from Zitadel and the Blueprint sociallogin extension.
    ${pkgs.gnused}/bin/sed -i '/^ZITADEL_/d' "$env"
  '';

  configureUnit = { container, after }: {
    description = "Configure Hydrodactyl addons on ${container}";
    after = [ "podman-${container}.service" ] ++ after;
    wants = after;
    requires = [ "podman-${container}.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.podman pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "15min";
    };
    script = ''
      set -euo pipefail
      # The entrypoint migrates before php-fpm starts; wait for it.
      for _ in $(seq 1 180); do
        podman exec ${container} test -f /var/www/pterodactyl/.hydrodactyl-build && break
        sleep 5
      done
      oidc=${config.sops.secrets."pterodactyl-oauth-env".path}
      if [ -f "$oidc" ]; then
        set -a; . "$oidc"; set +a
      fi
      podman exec -i \
        -e PTERODACTYL_OIDC_CLIENT_ID=${ssoClientId} \
        -e PTERODACTYL_OIDC_CLIENT_SECRET="''${PTERODACTYL_OIDC_CLIENT_SECRET:-}" \
        ${container} php < ${configurePhp}
    '';
  };

  blueprintUnitsOff = names: lib.genAttrs names (_: { enable = lib.mkForce false; });

  stripProdNodesSql = pkgs.writeText "hydrodactyl-test-strip-prod-nodes.sql" ''
    START TRANSACTION;
    CREATE TEMPORARY TABLE strip_servers AS
      SELECT s.id FROM servers s JOIN nodes n ON n.id = s.node_id WHERE n.name <> 'ace-test';
    DELETE FROM dnsrecords_data WHERE scope = 'server' AND subject_id IN (SELECT id FROM strip_servers);
    DELETE FROM portforward_data WHERE scope = 'server' AND subject_id IN (SELECT id FROM strip_servers);
    DELETE FROM activity_log_subjects WHERE subject_type IN ('server', 'Pterodactyl\\Models\\Server') AND subject_id IN (SELECT id FROM strip_servers);
    DELETE FROM servers WHERE id IN (SELECT id FROM strip_servers);
    DELETE FROM nodes WHERE name <> 'ace-test';
    COMMIT;
  '';
in
{
  options.homelab.panel = {
    prod.flavor = flavorOption "production";
    test.flavor = flavorOption "test";

    eggLoaderFeatures = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = {
        "Fabric" = [ "mod/fabric" ];
        "NeoForge" = [ "mod/neoforge" ];
        "Purpur-Geyser-Floodgate" = [ "plugin/purpur" "plugin/paper" ];
      };
      description = "Egg name => loader features added for Hydrodactyl's plugin/mod installer.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.prod.flavor == "hydrodactyl" || cfg.test.flavor == "hydrodactyl") {
      homelab.keycloak.clients.${ssoClientId} = {
        name = "Game panel";
        redirectUris = [
          "https://panel.prestonhager.com/extensions/sociallogin/callback"
          "https://test.panel.prestonhager.com/extensions/sociallogin/callback"
          # oauth2-proxy (pterodactyl-oauth.nix, not imported at the moment)
          "https://panel.prestonhager.com/oauth2/callback"
        ];
        secret = {
          file = config.sops.secrets."pterodactyl-oauth-env".path;
          key = "PTERODACTYL_OIDC_CLIENT_SECRET";
        };
      };
      homelab.keycloak.groups = [ "pterodactyl_admin" "pterodactyl_test_admin" ];
      # tests/sso/pterodactyl.test.sh: admin on the test panel only. The test
      # adds pterodactyl_admin for one login and removes it again.
      homelab.keycloak.testUser.groups = [ "pterodactyl_test_admin" ];
      # The secret changes in sops re-run the realm sync.
      sops.secrets."pterodactyl-oauth-env".restartUnits = [ "keycloak-realm-sync.service" ];
    })

    (lib.mkIf (cfg.prod.flavor == "hydrodactyl") {
      virtualisation.oci-containers.containers.pterodactyl = {
        image = lib.mkForce image;
        imageFile = lib.mkForce images.runtimeImage;
        # The sops env file (--env-file in pterodactyl.nix) says APP_LOCALE=en,
        # and real env vars win over .env. Hydrodactyl only knows en-US, so
        # creating any user failed validation. -e wins over --env-file.
        environment = lib.mkForce { APP_LOCALE = "en-US"; };
      };

      systemd.services = blueprintUnitsOff [
        "pterodactyl-stock-reset"
        "pterodactyl-blueprint-install"
        "pterodactyl-sso-configure"
      ] // {
        hydrodactyl-env = {
          description = "Enforce Hydrodactyl .env keys on the production panel";
          before = [ "podman-pterodactyl.service" ];
          requiredBy = [ "podman-pterodactyl.service" ];
          after = [ "pterodactyl-redis-auth.service" ];
          serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = envScript "/pterodactyl/html/.env" "pterodactyl_admin"; };
        };
        hydrodactyl-configure = configureUnit {
          container = "pterodactyl";
          after = [ "pterodactyl-blueprint-extensions-configure.service" ];
        };
      };
    })

    (lib.mkIf (cfg.test.flavor == "hydrodactyl") {
      # Own code dir: the Pterodactyl test panel ran from a dev checkout
      # (/home/prestonh/Projects/panel), which this must not overwrite.
      systemd.tmpfiles.rules = [ "d ${testPanelDir} 0775 pterodactyl pterodactyl -" ];

      virtualisation.oci-containers.containers.pterodactyl-test = {
        image = lib.mkForce image;
        imageFile = lib.mkForce images.runtimeImage;
        environment = lib.mkForce { };
        user = lib.mkForce "pterodactyl:pterodactyl";
        volumes = lib.mkForce [
          "/etc/passwd:/etc/passwd:ro"
          "/etc/group:/etc/group:ro"
          "${testPanelDir}:/var/www/pterodactyl"
          "/pterodactyl-test/sockets/mysqld:/run/mysqld"
          "/pterodactyl-test/sockets/php:/run/php-fpm"
          "${testSecretsDir}:/pterodactyl/secrets:ro"
          "${testEnvFile}:/var/www/pterodactyl/.env:U"
        ];
      };

      systemd.services = blueprintUnitsOff [
        "pterodactyl-test-stock-reset"
        "pterodactyl-test-blueprint-install"
        "pterodactyl-test-sso-configure"
        "pterodactyl-test-panel-perms"
        "pterodactyl-test-setup"
      ] // {
        # Caddy serves the test site from /pterodactyl-test/public.
        pterodactyl-test-public-mount.script = lib.mkForce ''
          set -euo pipefail
          install -d -m 0755 /pterodactyl-test/public
          install -d -o pterodactyl -g pterodactyl -m 0755 ${testPanelDir}/public
          if ${pkgs.util-linux}/bin/mountpoint -q /pterodactyl-test/public; then
            ${pkgs.util-linux}/bin/umount /pterodactyl-test/public
          fi
          ${pkgs.util-linux}/bin/mount --bind ${testPanelDir}/public /pterodactyl-test/public
        '';
        hydrodactyl-test-env = {
          description = "Enforce Hydrodactyl .env keys on the test panel";
          before = [ "podman-pterodactyl-test.service" ];
          requiredBy = [ "podman-pterodactyl-test.service" ];
          after = [ "pterodactyl-test-env.service" ];
          serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = envScript testEnvFile "pterodactyl_test_admin"; };
        };
        hydrodactyl-test-configure = configureUnit {
          container = "pterodactyl-test";
          after = [ "pterodactyl-test-blueprint-extensions-configure.service" ];
        };

        # Rehearsal helper (never automatic): copy the production database
        # into the test panel with DNS and port forwarding forced to dry run.
        #   systemctl start hydrodactyl-test-load-prod
        hydrodactyl-test-load-prod = {
          description = "Load a copy of the production panel database into the test panel (dry-run extensions)";
          after = [ "podman-pterodactyl-db.service" "podman-pterodactyl-test-db.service" ];
          path = [ pkgs.podman pkgs.coreutils pkgs.gnugrep ];
          serviceConfig = { Type = "oneshot"; TimeoutStartSec = "30min"; };
          script = ''
            set -euo pipefail
            set -a; . ${testEnvFile}; set +a
            test_root="$MARIADB_ROOT_PASSWORD"; test_db="$DB_DATABASE"
            systemctl stop podman-pterodactyl-test.service
            podman exec pterodactyl-db sh -c 'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction --routines --triggers panel' \
              | podman exec -i -e MYSQL_PWD="$test_root" pterodactyl-test-db sh -c "mariadb -uroot -e 'DROP DATABASE IF EXISTS \`$test_db\`; CREATE DATABASE \`$test_db\`' && mariadb -uroot \"$test_db\""
            podman exec -e MYSQL_PWD="$test_root" pterodactyl-test-db mariadb -uroot "$test_db" -e \
              "UPDATE dnsrecords_settings SET value='true' WHERE \`key\`='dry_run'; UPDATE portforward_settings SET value='true' WHERE \`key\`='dry_run';"
            # The production nodes and their servers have no place on the test
            # panel (it only drives its own ace-test node). Plain SQL: the
            # panel's deletion services would try to reach their Wings and
            # database hosts.
            podman exec -i -e MYSQL_PWD="$test_root" pterodactyl-test-db mariadb -uroot "$test_db" < ${stripProdNodesSql}
            # The test panel keeps its own APP_KEY on purpose: with prod's it
            # could decrypt the Wings node tokens and drive production game
            # servers. Encrypted copies (node tokens) stay unreadable here;
            # the SSO secret is re-seeded from sops by hydrodactyl-test-configure.
            rm -f ${testPanelDir}/.hydrodactyl-build
            # Sessions and remember-me cookies point at user ids of the old
            # database; left in place they would map onto different users of
            # the copy (and the client API answers 401). Log everyone out.
            podman exec pterodactyl-test-redis redis-cli FLUSHALL
            systemctl start podman-pterodactyl-test.service
            # The copy has no ace-test node: register it again and hand Wings
            # its new token (hydrodactyl-test-node.nix).
            if systemctl cat wings-test-config.service >/dev/null 2>&1; then
              systemctl restart wings-test-config.service wings-test.service
            fi
          '';
        };
      };
    })
  ];
}
