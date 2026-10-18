{ lib, ... }:
{
  lanHttpTargets = [
    "https://grafana.prestonhager.com/"
    "https://cloud.prestonhager.com/"
    "https://zitadel.prestonhager.com/"
    "https://dns.prestonhager.com/"
    "https://matrix.prestonhager.com/_matrix/client/versions"
  ];

  lanDnsChecks = [
    {
      host = "grafana.prestonhager.com";
      module = "dns_lan_grafana";
      expected = "192.168.5.5";
    }
  ];

  # TCP reachability of LAN hosts (443 = Caddy on ace/crux, Wings TLS on nova).
  lanTcpTargets = [
    { target = "192.168.5.5:443"; host = "ace"; }
    { target = "192.168.5.6:443"; host = "crux"; }
    { target = "192.168.5.7:443"; host = "nova"; }
  ];
}
