# Ensure OpenClaw gateway uses trusted-proxy auth for Zitadel SSO (see docs/ace-openclaw-sso.md).
# Runs before openclaw-gateway on every boot/rebuild so token mode cannot persist after manual drift.
{ config, pkgs, lib, ... }:

let
  openclawBin = config.services.aceK80.openclaw.package or pkgs.openclaw;
  openclawHome = "/stor/openclaw";

  applyTrustedProxy = pkgs.writeShellScript "openclaw-trusted-proxy-config" ''
    set -euo pipefail
    if [ ! -x "${openclawBin}/bin/openclaw" ]; then
      echo "openclaw-trusted-proxy-config: openclaw binary missing" >&2
      exit 1
    fi
    if [ ! -d "${openclawHome}/.openclaw" ]; then
      echo "openclaw-trusted-proxy-config: ${openclawHome}/.openclaw missing, skipping" >&2
      exit 0
    fi
    run_oc() {
      ${pkgs.util-linux}/bin/runuser -u openclaw -- \
        env HOME=${openclawHome} OLLAMA_API_KEY=ollama-local \
        "${openclawBin}/bin/openclaw" "$@"
    }
    run_oc config set gateway.auth.mode trusted-proxy
    run_oc config unset gateway.auth.token 2>/dev/null || true
    mode="$(run_oc config get gateway.auth.mode 2>/dev/null || echo unknown)"
    if [ "$mode" != "trusted-proxy" ]; then
      echo "openclaw-trusted-proxy-config: expected trusted-proxy, got $mode" >&2
      exit 1
    fi
    echo "openclaw-trusted-proxy-config: gateway.auth.mode=$mode"
  '';
in
lib.mkIf config.services.aceK80.enableOpenClaw {
  systemd.services.openclaw-trusted-proxy-config = {
    description = "Apply OpenClaw trusted-proxy auth for Zitadel SSO";
    wantedBy = [ "multi-user.target" ];
    before = [ "openclaw-gateway.service" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = applyTrustedProxy;
    };
  };

  systemd.services.openclaw-gateway = {
    requires = [ "openclaw-trusted-proxy-config.service" ];
    restartTriggers = [ applyTrustedProxy ];
  };
}
