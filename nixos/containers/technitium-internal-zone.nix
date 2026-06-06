{ config, pkgs, lib, ... }:

let
  dataRoot = "/stor/technitium";
  technitiumApi = "http://127.0.0.1:5380";
  internalZone = "internal.prestonhager.com";
  zoneSerial = "2026060601";

  # Authoritative LAN names (edit here, then nixos-rebuild switch on ace).
  internalHosts = {
    ace = "192.168.5.5";
    crux = "192.168.5.6";
    nova = "192.168.5.7";
    grafana = "192.168.5.5";
    cloud = "192.168.5.5";
    dns = "192.168.5.5";
  };

  zoneFile = pkgs.writeText "${internalZone}.zone" ''
    $ORIGIN ${internalZone}.
    $TTL 3600
    @	IN	SOA	ace.${internalZone}. hostmaster.prestonhager.com. (
    			${zoneSerial}	; serial
    			3600		; refresh
    			1800		; retry
    			604800		; expire
    			300		; minimum
    			)
    			IN	NS	ace.${internalZone}.
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: ip: "${name}\tIN\tA\t${ip}") internalHosts
    )}
  '';

  zoneExistsJq = pkgs.writeText "technitium-zone-exists.jq" ''
    .response.zones | map(.name == $z) | any | if . then "true" else "false" end
  '';

  adminPasswordFile = "${dataRoot}/secrets/admin-password";
  zoneHashFile = "${dataRoot}/.internal-zone.sha256";

  syncScript = pkgs.writeShellScript "technitium-sync-internal-zone" ''
    set -euo pipefail
    API="${technitiumApi}"
    ZONE="${internalZone}"
    ZONE_FILE="${zoneFile}"
    HASH_FILE="${zoneHashFile}"
    PASS_FILE="${adminPasswordFile}"
    ZONE_EXISTS_JQ="${zoneExistsJq}"

    desired_hash=$(${pkgs.coreutils}/bin/sha256sum "$ZONE_FILE" | ${pkgs.coreutils}/bin/cut -d' ' -f1)
    if [ -f "$HASH_FILE" ] && [ "$(cat "$HASH_FILE")" = "$desired_hash" ]; then
      exit 0
    fi

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

  systemd.services.technitium-sync-internal-zone = {
    description = "Sync internal.prestonhager.com zone into Technitium";
    after = [ "podman-technitium.service" "technitium-ensure-admin-password.service" "network-online.target" ];
    wants = [ "podman-technitium.service" "technitium-ensure-admin-password.service" "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = syncScript;
    };
  };
}