<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginException;

class DnsLookupService
{
    public function verifyTxtRecord(string $host, string $expectedToken): bool
    {
        $host = rtrim(strtolower($host), '.');
        $records = @dns_get_record($host, DNS_TXT);

        if (!is_array($records)) {
            return false;
        }

        foreach ($records as $record) {
            $txt = (string) ($record['txt'] ?? '');
            if ($txt === $expectedToken) {
                return true;
            }
        }

        return false;
    }

    public function verifyCnameRecord(string $host, string $expectedTarget): bool
    {
        $host = rtrim(strtolower($host), '.');
        $expectedTarget = rtrim(strtolower($expectedTarget), '.');
        $records = @dns_get_record($host, DNS_CNAME);

        if (!is_array($records)) {
            return false;
        }

        foreach ($records as $record) {
            $target = rtrim(strtolower((string) ($record['target'] ?? '')), '.');
            if ($target === $expectedTarget) {
                return true;
            }
        }

        return false;
    }

    public function verifyCustomDomain(string $domain, string $token, string $cnameTarget): bool
    {
        $domain = rtrim(strtolower($domain), '.');
        $txtHost = '_dns-verify.' . $domain;

        if ($this->verifyTxtRecord($txtHost, $token)) {
            return true;
        }

        return $this->verifyCnameRecord($domain, $cnameTarget);
    }

    public function assertResolvable(string $host): void
    {
        $records = @dns_get_record(rtrim($host, '.'), DNS_ANY);
        if (!is_array($records) || $records === []) {
            throw new PluginException('DNS lookup failed for the custom domain. Ensure the record is published.');
        }
    }
}
