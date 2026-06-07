{ lib, ... }:
{
  lanHttpHosts = [
    "grafana.prestonhager.com"
    "cloud.prestonhager.com"
    "zitadel.prestonhager.com"
    "dns.prestonhager.com"
    "matrix.prestonhager.com"
  ];

  lanDnsChecks = [
    {
      host = "grafana.prestonhager.com";
      module = "dns_lan_grafana";
      expected = "192.168.5.5";
    }
  ];
}
