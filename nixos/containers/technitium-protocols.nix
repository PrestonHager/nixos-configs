{ config, pkgs, lib, ... }:

let
  dataRoot = "/stor/technitium";
  technitiumApi = "http://127.0.0.1:5380";
  adminPasswordFile = "${dataRoot}/secrets/admin-password";
  dohBackendPort = 8053;
  dotPort = 853;
  dohDomain = "dns.prestonhager.com";
  caddyCertDir =
    "/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${dohDomain}";
  pfxPasswordFile = "${dataRoot}/secrets/pfx-password";
  containerPfxPath = "/etc/dns/certs/${dohDomain}.pfx";
  hostPfxPath = "${dataRoot}/certs/${dohDomain}.pfx";
  protocolsHashFile = "${dataRoot}/.protocols-settings.sha256";

  syncTlsCertScript = pkgs.writeShellScript "technitium-sync-tls-cert" ''
    set -euo pipefail
    src="${caddyCertDir}"
    dest="${hostPfxPath}"
    pass_file="${pfxPasswordFile}"

    if [ ! -f "$src/${dohDomain}.crt" ] || [ ! -f "$src/${dohDomain}.key" ]; then
      echo "Caddy certificate not ready for ${dohDomain}: $src" >&2
      exit 1
    fi

    mkdir -p "${dataRoot}/certs"
    ${pkgs.openssl}/bin/openssl pkcs12 -export \
      -out "$dest" \
      -inkey "$src/${dohDomain}.key" \
      -in "$src/${dohDomain}.crt" \
      -passout file:"$pass_file"
    chmod 640 "$dest"
  '';

  syncProtocolsScript = pkgs.writeShellScript "technitium-sync-protocols" ''
    set -euo pipefail
    API="${technitiumApi}"
    PASS_FILE="${adminPasswordFile}"
    HASH_FILE="${protocolsHashFile}"

    if [ ! -f "${hostPfxPath}" ]; then
      echo "Technitium PFX not ready: ${hostPfxPath}" >&2
      exit 1
    fi

    pfx_hash=$(${pkgs.coreutils}/bin/sha256sum "${hostPfxPath}" | ${pkgs.coreutils}/bin/cut -d' ' -f1)
    desired_hash="doh=${toString dohBackendPort};dot=${toString dotPort};pfx=$pfx_hash"
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

    pfx_pass=$(${pkgs.coreutils}/bin/cat "${pfxPasswordFile}")

    ${pkgs.curl}/bin/curl -sf -X POST -H "Authorization: Bearer $token" \
      "$API/api/settings/set" \
      --data-urlencode "enableDnsOverHttp=true" \
      --data-urlencode "dnsOverHttpPort=${toString dohBackendPort}" \
      --data-urlencode "dnsReverseProxyNetworkACL=127.0.0.0/8,::1/128,10.88.0.0/24" \
      --data-urlencode "dnsOverHttpRealIpHeader=X-Real-IP" \
      --data-urlencode "enableDnsOverTls=true" \
      --data-urlencode "dnsOverTlsPort=${toString dotPort}" \
      --data-urlencode "enableDnsOverHttps=false" \
      --data-urlencode "enableDnsOverHttp3=false" \
      --data-urlencode "enableDnsOverQuic=false" \
      --data-urlencode "dnsTlsCertificatePath=${containerPfxPath}" \
      --data-urlencode "dnsTlsCertificatePassword=$pfx_pass" >/dev/null

    echo "$desired_hash" > "$HASH_FILE"
  '';
in
{
  systemd.tmpfiles.rules = [
    "d ${dataRoot}/certs 0750 root root -"
  ];

  systemd.services.technitium-ensure-pfx-password = {
    description = "Create Technitium PFX export password if missing";
    serviceConfig.Type = "oneshot";
    wantedBy = [ "multi-user.target" ];
    before = [
      "technitium-sync-tls-cert.service"
      "technitium-sync-protocols.service"
    ];
    script = ''
      mkdir -p ${dataRoot}/secrets
      if [ ! -s ${pfxPasswordFile} ]; then
        ${pkgs.openssl}/bin/openssl rand -base64 24 | tr -d '\n' > ${pfxPasswordFile}
        chmod 600 ${pfxPasswordFile}
      fi
    '';
  };

  systemd.services.technitium-sync-tls-cert = {
    description = "Export Caddy LE certificate to PKCS#12 for Technitium DoT";
    after = [ "caddy.service" "technitium-ensure-pfx-password.service" ];
    before = [ "technitium-sync-protocols.service" ];
    wants = [ "caddy.service" "technitium-ensure-pfx-password.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = syncTlsCertScript;
      RemainAfterExit = true;
    };
  };

  systemd.paths.technitium-sync-tls-cert = {
    description = "Re-export Technitium PFX when Caddy renews dns.prestonhager.com";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = caddyCertDir;
      Unit = "technitium-sync-tls-cert.service";
    };
  };

  systemd.services.technitium-sync-protocols = {
    description = "Configure Technitium DNS-over-HTTP (DoH backend) and DNS-over-TLS";
    after = [
      "podman-technitium.service"
      "technitium-ensure-admin-password.service"
      "technitium-sync-tls-cert.service"
      "network-online.target"
    ];
    requires = [ "technitium-sync-tls-cert.service" ];
    wants = [
      "podman-technitium.service"
      "technitium-ensure-admin-password.service"
      "network-online.target"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = syncProtocolsScript;
      RemainAfterExit = true;
    };
  };

  systemd.paths.technitium-sync-protocols-on-pfx = {
    description = "Re-apply Technitium protocol settings when PFX is renewed";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = hostPfxPath;
      Unit = "technitium-sync-protocols.service";
    };
  };
}
