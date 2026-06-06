{ config, pkgs, lib, ... }:

let
  dataRoot = "/stor/technitium";
  technitiumApi = "http://127.0.0.1:5380";
  adminPasswordFile = "${dataRoot}/secrets/admin-password";

  internalZone = "internal.prestonhager.com";
  publicZone = "prestonhager.com";

  internalSerial = "2026060687";
  publicSerial = "2026060970";

  # Authoritative LAN names under internal.prestonhager.com (edit here, then nixos-rebuild switch on ace).
  internalHosts = {
    ace = "192.168.5.5";
    crux = "192.168.5.6";
    nova = "192.168.5.7";
    grafana = "192.168.5.5";
    cloud = "192.168.5.5";
    dns = "192.168.5.5";
  };

  cname = target: {
    type = "CNAME";
    value = target;
  };

  cnameInternal = name: cname "${name}.${internalZone}";

  # LAN-facing prestonhager.com names (Technitium primary zone). Prefer CNAME to internal.* where it exists.
  prestonhagerHosts =
    let
      viaAce = cnameInternal "ace";
      aceHosted = [
        "ai"
        "panel"
        "test.panel"
        "testpanel"
        "prometheus"
        "jellyfin"
        "vault"
        "wg"
        "metrics.wg"
        "zitadel"
        "portunus"
        "git"
        "matrix"
        "spacetime"
        "test.sui"
        "faucet.test.sui"
        "indexer.test.sui"
        "factorio"
        "game"
        "lancache"
        "mc"
        "vpn"
      ];
    in
    {
      ace = cnameInternal "ace";
      crux = cnameInternal "crux";
      nova = cnameInternal "nova";
      grafana = cnameInternal "grafana";
      cloud = cnameInternal "cloud";
      dns = cnameInternal "dns";
      "crux.lc1.nm.us" = cnameInternal "crux";
      "nova.lc1.nm.us" = cnameInternal "nova";
    }
    // lib.genAttrs aceHosted (_: viaAce)
    // lib.mapAttrs (_: target: cname target) {
      "app.dontgetgot" = "prestonhager.github.io";
      badday = "prestonhager.github.io";
      blog = "prestonhager.github.io";
      creaturecafe = "prestonhager.github.io";
      dontgetgot = "d-7jli0nnhpl.execute-api.us-west-2.amazonaws.com";
      galactic = "prestonhager.github.io";
      knuckles = "prestonhager.github.io";
      latex = "prestonhager.github.io";
      peachjar = "prestonhager.github.io";
      pmsm = "readthedocs.io";
      q = "prestonhager.github.io";
      vge = "prestonhager.github.io";
      "_6441af74ee5e805282cfa6549f1a6ae5" =
        "_e18abbf1720ee0b306dd0a9e3fcc5f08.sdgjtdhdhz.acm-validations.aws";
      "_cee2704a79c1a0f628a0d4502b01479c.dontgetgot" =
        "_36f66018425469248d4d097831f6055b.djqtsrsxkq.acm-validations.aws";
      "sig1._domainkey" = "sig1.dkim.prestonhager.com.at.icloudmailadmin.com";
    };

  # Apex / validation records copied from Cloudflare (no ip1.lc1 overrides).
  publicZoneExtraLines = [
    "@	IN	MX	10 mx01.mail.icloud.com."
    "@	IN	MX	20 mx02.mail.icloud.com."
    "@	IN	TXT	\"v=spf1 include:icloud.com ~all\""
    "@	IN	TXT	\"apple-domain=98VopwxLPIzr8mSZ\""
    "_discord	IN	TXT	\"dh=5d07df7dd5e560625b28ef50fadc4813138d481f\""
    "_github-pages-challenge-prestonhager	IN	TXT	\"040ac1b62714a9955b5ef43a03d674\""
    "_github-pages-challenge-prestonhager.n5bl	IN	TXT	\"7251bf6d645386301e9adf71d98cf1\""
    "_visual-studio-marketplace-prestonhager	IN	TXT	\"5fa516ee-97a2-4b59-92cb-296593635780\""
    "_factorio._udp.factorio	IN	SRV	10 10 34197 game.prestonhager.com."
    "_minecraft._tcp.ead	IN	SRV	10 10 25566 game.prestonhager.com."
  ];

  renderRecord = name: record:
    if record.type == "A" then
      "${name}\tIN\tA\t${record.value}"
    else if record.type == "CNAME" then
      "${name}\tIN\tCNAME\t${record.value}."
    else
      throw "Unknown DNS record type: ${record.type}";

  mkZoneFile =
    {
      zone,
      serial,
      hosts,
      soaMname ? "ace.${internalZone}.",
      soaRname ? "hostmaster.prestonhager.com.",
      ns ? [ "ace.${internalZone}." ],
      extraLines ? [ ],
    }:
    pkgs.writeText "${zone}.zone" ''
      $ORIGIN ${zone}.
      $TTL 3600
      @	IN	SOA	${soaMname} ${soaRname} (
      			${serial}	; serial
      			3600		; refresh
      			1800		; retry
      			604800		; expire
      			300		; minimum
      			)
      ${lib.concatStringsSep "\n" (map (host: "@\tIN\tNS\t${host}") ns)}
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: record: renderRecord name record) hosts
      )}
      ${lib.concatStringsSep "\n" extraLines}
    '';

  internalZoneFile = mkZoneFile {
    zone = internalZone;
    serial = internalSerial;
    hosts = lib.mapAttrs (_: ip: { type = "A"; value = ip; }) internalHosts;
    ns = [ "ace.${internalZone}." ];
  };

  publicZoneFile = mkZoneFile {
    zone = publicZone;
    serial = publicSerial;
    hosts = prestonhagerHosts;
    ns = [ "ace.${internalZone}." ];
    extraLines = publicZoneExtraLines;
  };

  zoneHashFile = zone: "${dataRoot}/.${lib.replaceStrings [ "." ] [ "-" ] zone}-zone.sha256";

  syncScript = pkgs.writeShellScript "technitium-sync-zones" ''
    set -euo pipefail
    API="${technitiumApi}"
    PASS_FILE="${adminPasswordFile}"

    sync_one() {
      local ZONE="$1"
      local ZONE_FILE="$2"
      local HASH_FILE="$3"

      desired_hash=$(${pkgs.coreutils}/bin/sha256sum "$ZONE_FILE" | ${pkgs.coreutils}/bin/cut -d' ' -f1)
      if [ -f "$HASH_FILE" ] && [ "$(cat "$HASH_FILE")" = "$desired_hash" ]; then
        return 0
      fi

      zone_exists=$(${pkgs.curl}/bin/curl -sf -H "Authorization: Bearer $token" \
        "$API/api/zones/list" \
        | ${pkgs.jq}/bin/jq -r --arg z "$ZONE" 'if ([.response.zones[]?.name == $z] | any) then "true" else "false" end')

      if [ "$zone_exists" = "true" ]; then
        ${pkgs.curl}/bin/curl -sf -X POST -H "Authorization: Bearer $token" \
          -H "Content-Type: text/plain" \
          --data-binary "@$ZONE_FILE" \
          "$API/api/zones/import?zone=$ZONE&overwrite=true&overwriteZone=true"
      else
        ${pkgs.curl}/bin/curl -sf -X POST -H "Authorization: Bearer $token" \
          -F "zoneFile=@$ZONE_FILE" \
          "$API/api/zones/create?zone=$ZONE&type=Primary"
      fi

      echo "$desired_hash" > "$HASH_FILE"
    }

    for _ in $(seq 1 90); do
      if ${pkgs.curl}/bin/curl -sf "$API/api/sso/status" >/dev/null; then
        break
      fi
      sleep 2
    done
    ${pkgs.curl}/bin/curl -sf "$API/api/sso/status" >/dev/null

    pass=$(${pkgs.coreutils}/bin/cat "$PASS_FILE")
    token=$(${pkgs.curl}/bin/curl -sf -X POST "$API/api/user/login" \
      --data-urlencode "user=admin" \
      --data-urlencode "pass=$pass" \
      | ${pkgs.jq}/bin/jq -r .token)

    sync_one "${internalZone}" "${internalZoneFile}" "${zoneHashFile internalZone}"
    sync_one "${publicZone}" "${publicZoneFile}" "${zoneHashFile publicZone}"
  '';
in
{
  systemd.services.technitium-ensure-admin-password = {
    description = "Create Technitium admin password file if missing";
    serviceConfig.Type = "oneshot";
    wantedBy = [ "multi-user.target" ];
    before = [ "podman-technitium.service" ];
    script = ''
      mkdir -p ${dataRoot}/secrets
      if [ ! -s ${adminPasswordFile} ]; then
        ${pkgs.openssl}/bin/openssl rand -base64 32 | tr -d '\n' > ${adminPasswordFile}
        chmod 600 ${adminPasswordFile}
      fi
    '';
  };

  systemd.services.technitium-sync-zones = {
    description = "Sync Technitium primary zones (internal + prestonhager.com)";
    after = [ "podman-technitium.service" "technitium-ensure-admin-password.service" "network-online.target" ];
    wants = [ "podman-technitium.service" "technitium-ensure-admin-password.service" "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = syncScript;
    };
  };
}
