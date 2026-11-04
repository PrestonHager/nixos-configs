# Server logins from Keycloak (docs/sso-login.md).
#
#   who exists      SSSD (id_provider = idp) looks users and groups up in the
#                   Keycloak realm, so a Keycloak user is a Linux user on every
#                   enrolled host; the home directory is made on first login.
#   SSH             opkssh: `opkssh login` gets an SSH key carrying a Keycloak
#                   ID token, sshd checks it (AuthorizedKeysCommand) and the
#                   policy plugin below maps it to the account of the same name.
#   which hosts     SSSD's simple access provider in the PAM account phase:
#                   members of srv-all or srv-<hostname> only.
#   sudo            rules below name Keycloak groups; sudo authenticates SSSD
#                   users with Keycloak's device-code prompt.
#   folder access   POSIX ACLs for Keycloak groups (folderAccess).
#
# Local accounts are untouched by all of this: root and the break-glass
# account log in with the SSH keys declared in Nix, as before.
{ config, lib, pkgs, inputs, ... }:

let
  secretsRepo = builtins.toString inputs.nix-secrets;
  cfg = config.homelab.sso;
  kc = import ./keycloak-lib.nix;
  host = config.networking.hostName;
  realmUrl = "https://${kc.domain}/realms/${kc.realm}";
  oidcUrl = "${realmUrl}/protocol/openid-connect";
  opk = config.services.opkssh;

  # opkssh policy plugin. opkssh has already checked the token's signature
  # against /etc/opk/providers (Keycloak only) and runs this as opksshuser;
  # printing "allow" lets the key in. Allow only when:
  #   - the target account is not in /etc/passwd (root, the break-glass
  #     account and system users stay key-only) but does resolve, which
  #     leaves SSSD/Keycloak as its source;
  #   - the token's preferred_username is that account's name (Keycloak has
  #     username editing off, so users cannot rename themselves);
  #   - the token says the user is in srv-all or srv-<host>. SSSD checks the
  #     same thing live in PAM; this keeps a PAM mistake from opening hosts.
  opksshPolicy = pkgs.writeShellScript "opkssh-keycloak-policy" ''
    set -u
    PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gawk pkgs.getent pkgs.jq ]}
    deny() { echo deny; exit 1; }

    u="''${OPKSSH_PLUGIN_U:-}"
    [ -n "$u" ] || deny
    [ "''${OPKSSH_PLUGIN_ISS:-}" = "${kc.issuer}" ] || deny
    awk -F: -v u="$u" '$1 == u { found = 1 } END { exit !found }' /etc/passwd && deny
    getent passwd "$u" >/dev/null || deny

    name="$(printf '%s' "''${OPKSSH_PLUGIN_PAYLOAD:-}" | base64 -d 2>/dev/null \
      | jq -r '.preferred_username // empty' 2>/dev/null)"
    [ -n "$name" ] && [ "$name" = "$u" ] || deny

    printf '%s' "''${OPKSSH_PLUGIN_GROUPS:-[]}" | jq -e \
      --argjson allowed '${builtins.toJSON cfg.allowGroups}' \
      'any(.[]; . as $g | $allowed | index($g))' >/dev/null 2>&1 || deny

    echo allow
  '';

  sudoRuleType = lib.types.submodule {
    options = {
      groups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Keycloak groups the rule applies to.";
      };
      commands = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = ''
          Commands with their full path and, where it matters, their exact
          arguments. sudo matches arguments literally; a command without
          arguments allows any.
        '';
      };
      runAs = lib.mkOption {
        type = lib.types.str;
        default = "root";
      };
    };
  };

  folderAccessType = lib.types.submodule {
    options = {
      path = lib.mkOption { type = lib.types.str; };
      group = lib.mkOption {
        type = lib.types.str;
        description = "Keycloak group that gets access.";
      };
      access = lib.mkOption {
        type = lib.types.enum [ "read" "write" ];
        default = "read";
      };
    };
  };

  aclPerms = a: if a.access == "write" then "rwX" else "rX";

  # Applied after SSSD is up: the group names only resolve through it.
  # Each parent directory gets traverse (x) for the group, the path itself
  # gets the ACL recursively, and directories get a matching default ACL so
  # new files inherit it.
  folderAclScript = pkgs.writeShellScript "sso-folder-acls" ''
    set -euo pipefail
    PATH=${lib.makeBinPath [ pkgs.acl pkgs.coreutils pkgs.getent pkgs.findutils ]}
    ${lib.concatMapStrings (a: ''
      if ! getent group ${lib.escapeShellArg a.group} >/dev/null; then
        echo "sso-folder-acls: group ${a.group} does not resolve (Keycloak/SSSD down?)" >&2
        exit 1
      fi
      if [ -e ${lib.escapeShellArg a.path} ]; then
        p=$(dirname ${lib.escapeShellArg a.path})
        while [ "$p" != / ]; do
          setfacl -m g:${lib.escapeShellArg a.group}:--x "$p"
          p=$(dirname "$p")
        done
        setfacl -R -m g:${lib.escapeShellArg a.group}:${aclPerms a} ${lib.escapeShellArg a.path}
        find ${lib.escapeShellArg a.path} -type d -exec setfacl -m d:g:${lib.escapeShellArg a.group}:${aclPerms a} {} +
      else
        echo "sso-folder-acls: ${a.path} does not exist, skipped" >&2
      fi
    '') cfg.folderAccess}
  '';

  breakGlass = cfg.breakGlass;
in
{
  options.homelab.sso = {
    enable = lib.mkEnableOption "server logins from the Keycloak realm (SSSD + opkssh)";

    allowGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ kc.allServersGroup (kc.hostGroup host) ];
      defaultText = lib.literalExpression ''[ "srv-all" "srv-''${hostName}" ]'';
      description = "Keycloak groups whose members may log in to this host.";
    };

    keyLifetime = lib.mkOption {
      type = lib.types.enum [ "12h" "24h" "48h" "1week" "oidc" "oidc-refreshed" ];
      default = "12h";
      description = ''
        How long an `opkssh login` key is accepted. Removing someone's group
        in Keycloak blocks them at once through SSSD (after its cache,
        cacheTimeout); this only bounds how long a stolen key stays useful.
      '';
    };

    cacheTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "Seconds SSSD trusts a cached user or group before asking Keycloak again.";
    };

    rebuildFlake = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/etc/nixos#ace";
      description = ''
        Flake reference sudo-rebuild may switch to. null leaves the
        sudo-rebuild group without a rule (hosts deployed from ace, which
        have no local checkout to build from). The checkout must not be
        writable by the group, or the rule is full root.
      '';
    };

    sudoRules = lib.mkOption {
      type = lib.types.attrsOf sudoRuleType;
      default = { };
      example = lib.literalExpression ''
        {
          wings = {
            groups = [ "wings-ops" ];
            commands = [
              "/run/current-system/sw/bin/systemctl restart wings.service"
              "/run/current-system/sw/bin/journalctl -u wings.service"
            ];
          };
        }
      '';
      description = ''
        Extra sudo rules for Keycloak groups. Do not grant editors, pagers,
        shells, interpreters or file tools (vim, less, find, tar, cp, rsync,
        tee, ...): each of them can start a root shell. For file access use
        folderAccess instead.
      '';
    };

    folderAccess = lib.mkOption {
      type = lib.types.listOf folderAccessType;
      default = [ ];
      example = lib.literalExpression ''
        [ { path = "/var/lib/pterodactyl/backups"; group = "game-backups"; access = "read"; } ]
      '';
      description = ''
        POSIX ACLs giving a Keycloak group read or write access to a tree it
        does not own, without sudo. A later chmod by a service can narrow
        the ACL mask and with it this access.
      '';
    };

    breakGlass = {
      user = lib.mkOption {
        type = lib.types.str;
        default = "phadmin";
        description = ''
          Local admin account that never depends on Keycloak: wheel, SSH
          keys from Nix, sudo password from sops.
        '';
      };
      uid = lib.mkOption {
        type = lib.types.int;
        default = 1000;
      };
      keys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      passwordSecret = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "users/prestonh/passwd";
        description = ''
          Key in secrets/users.yaml holding the account's password hash (for
          sudo and the console). The default keeps the old prestonh password.
        '';
      };
      migrateHomeFrom = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "prestonh";
        description = ''
          Former name of this local account (same uid). On the first switch
          its home directory is moved to the new name, so the Keycloak
          account of the old name starts with a fresh home.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = breakGlass.migrateHomeFrom == null
          || !(config.users.users ? ${breakGlass.migrateHomeFrom});
        message = ''
          homelab.sso: users.users.${toString breakGlass.migrateHomeFrom} is still
          declared locally; it would shadow the Keycloak account of that name.
          Drop it (e.g. the users/prestonh import) on SSO hosts.
        '';
      }
    ];

    # Keycloak by name even when LAN DNS is down.
    networking.hosts.${kc.aceAddress} = [ kc.domain ];

    # ---- Break-glass local account -----------------------------------------
    users.mutableUsers = false;
    users.users.${breakGlass.user} = {
      isNormalUser = true;
      uid = breakGlass.uid;
      description = "Local break-glass admin (no Keycloak)";
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = breakGlass.keys;
      hashedPasswordFile = lib.mkIf (breakGlass.passwordSecret != null)
        config.sops.secrets.${breakGlass.passwordSecret}.path;
    };
    sops.secrets = lib.mkMerge [
      (lib.mkIf (breakGlass.passwordSecret != null) {
        ${breakGlass.passwordSecret} = {
          sopsFile = "${secretsRepo}/secrets/users.yaml";
          neededForUsers = true;
        };
      })
      {
        "sssd-keycloak-env" = {
          sopsFile = "${secretsRepo}/secrets/sssd-keycloak.yaml";
          key = "sssd-keycloak-env";
          restartUnits = [ "sssd.service" ];
        };
      }
    ];

    # Runs before the users script, so the renamed account takes over its old
    # home instead of getting an empty one. Only moves a home that still
    # belongs to the break-glass uid.
    system.activationScripts.ssoBreakGlassHome = lib.mkIf (breakGlass.migrateHomeFrom != null) {
      supportsDryActivation = true;
      text = ''
        old=/home/${breakGlass.migrateHomeFrom}
        new=/home/${breakGlass.user}
        if [ -d "$old" ] && [ ! -e "$new" ] \
          && [ "$(${pkgs.coreutils}/bin/stat -c %u "$old")" = "${toString breakGlass.uid}" ]; then
          if [ "''${NIXOS_ACTION:-}" = dry-activate ]; then
            echo "would move $old to $new"
          else
            echo "moving $old to $new (break-glass account rename)"
            mv "$old" "$new"
          fi
        fi
      '';
    };
    system.activationScripts.users.deps = lib.mkIf (breakGlass.migrateHomeFrom != null)
      [ "ssoBreakGlassHome" ];

    # ---- SSSD: users, groups, host access, sudo authentication -------------
    services.sssd = {
      enable = true;
      environmentFile = config.sops.secrets."sssd-keycloak-env".path;
      settings = {
        sssd = {
          services = "nss, pam";
          domains = "keycloak";
        };
        nss = {
          # Never let the IdP answer for local system names.
          filter_users = "root, ${breakGlass.user}";
          filter_groups = "root, wheel";
        };
        pam = { };
        "domain/keycloak" = {
          id_provider = "idp";
          auth_provider = "idp";
          access_provider = "simple";
          simple_allow_groups = lib.concatStringsSep ", " cfg.allowGroups;

          idp_type = "keycloak:https://${kc.domain}/admin/realms/${kc.realm}/";
          idp_client_id = kc.sssdClientId;
          idp_client_secret = "$SSSD_CLIENT_SECRET";
          idp_token_endpoint = "${oidcUrl}/token";
          idp_userinfo_endpoint = "${oidcUrl}/userinfo";
          idp_device_auth_endpoint = "${oidcUrl}/auth/device";
          idp_id_scope = "profile";
          idp_auth_scope = "openid profile email";

          use_fully_qualified_names = false;
          override_homedir = "/home/%u";
          default_shell = "/run/current-system/sw/bin/bash";
          entry_cache_timeout = cfg.cacheTimeout;
          # Users and groups stay resolvable from the cache while Keycloak is
          # down; new logins and sudo need it.
          cache_credentials = false;
        };
      };
    };

    # SSSD's access decision must be final: with the default "sufficient",
    # a denial would fall through to pam_unix's account check and pass.
    security.pam.services.sshd.sssdStrictAccess = true;
    security.pam.services.sudo.sssdStrictAccess = true;
    security.pam.services.login.sssdStrictAccess = true;

    # pam_sss runs before pam_unix for sudo and prompts itself (device code);
    # NixOS's default stack puts it after pam_unix with use_first_pass, which
    # would feed it a typed password. Local users (unknown to SSSD) fall
    # through to pam_unix and their sops password.
    security.pam.services.sudo.rules.auth.sss = {
      order = config.security.pam.services.sudo.rules.auth.unix.order - 10;
      control = lib.mkForce "[success=done new_authtok_reqd=done user_unknown=ignore authinfo_unavail=ignore default=die]";
      settings.use_first_pass = lib.mkForce false;
    };

    security.pam.services.sshd.makeHomeDir = true;
    security.pam.makeHomeDir.umask = "0077";

    # ---- SSH: opkssh ------------------------------------------------------
    services.opkssh = {
      enable = true;
      providers = {
        keycloak = {
          issuer = kc.issuer;
          clientId = kc.opksshClientId;
          lifetime = cfg.keyLifetime;
        };
      };
      # No static auth_id rules: the plugin decides.
      authorizations = [ ];
    };

    environment.etc."opk/policy.d/keycloak.yml" = {
      mode = "0640";
      user = "root";
      group = opk.group;
      text = ''
        name: Keycloak account of the same name
        command: ${opksshPolicy}
      '';
    };

    systemd.tmpfiles.rules = [
      "f /var/log/opkssh.log 0660 ${opk.user} ${opk.group} -"
    ];

    environment.systemPackages = [ opk.package ];

    # ---- sudo -------------------------------------------------------------
    security.sudo.extraRules =
      [
        {
          groups = [ kc.sudoFullGroup ];
          commands = [ { command = "ALL"; } ];
        }
      ]
      ++ lib.optional (cfg.rebuildFlake != null) {
        groups = [ kc.sudoRebuildGroup ];
        commands = map (action: {
          command = "/run/current-system/sw/bin/nixos-rebuild ${action} --flake ${cfg.rebuildFlake}";
        }) [ "switch" "boot" "test" "build" ];
      }
      ++ lib.mapAttrsToList (_: r: {
        inherit (r) groups runAs;
        commands = map (c: { command = c; }) r.commands;
      }) cfg.sudoRules;

    # ---- Folder ACLs -------------------------------------------------------
    systemd.services.sso-folder-acls = lib.mkIf (cfg.folderAccess != [ ]) {
      description = "Apply POSIX ACLs for Keycloak groups";
      wantedBy = [ "multi-user.target" ];
      wants = [ "sssd.service" "network-online.target" ];
      after = [ "sssd.service" "network-online.target" ];
      restartTriggers = [ folderAclScript ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = folderAclScript;
        Restart = "on-failure";
        RestartSec = 60;
      };
    };
  };
}
