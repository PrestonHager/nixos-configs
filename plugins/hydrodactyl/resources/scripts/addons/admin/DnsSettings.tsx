import { useEffect, useState } from 'react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { addonError, get, put } from '../api';
import { Field, Grid, Loading, Notice, NumberInput, Section, Select, Table, Td, Text, Toggle } from '../ui';
import { useLoad } from '../useLoad';

interface SrvProfile {
    id: string;
    preset?: string;
    label?: string;
    service?: string;
    proto?: string;
    port?: number | null;
    priority?: number;
    weight?: number;
    auto_provision?: boolean;
    target_provider?: string;
}

interface PrimaryDomain {
    id: string;
    domain: string;
    zone_id?: string;
    client_selectable?: boolean;
}

export interface DnsSettingsData {
    dns_provider_mode: string;
    cloudflare_api_token_set: boolean;
    technitium_api_token_set: boolean;
    cloudflare_token_from_env: boolean;
    technitium_token_from_env: boolean;
    technitium_api_url: string;
    technitium_default_zone: string;
    zone_id: string;
    base_domain: string;
    default_ttl: number;
    auto_provision_enabled: boolean;
    update_on_allocation_change: boolean;
    dry_run: boolean;
    subdomain_generation: string;
    client_subdomain_policy: string;
    client_change_limit: number;
    client_change_period_hours: number;
    min_label_length: number;
    max_label_length: number;
    reserved_labels: string[];
    allow_custom_domain: boolean;
    custom_domain_mode: string;
    srv_profiles: SrvProfile[];
    primary_domains: PrimaryDomain[];
}

const PRESETS = ['', 'minecraft-java', 'minecraft-bedrock', 'factorio', 'terraria', 'rust', 'valheim', 'ark', 'mumble'];
const PROVIDERS = [
    { value: '', label: 'Inherit global mode' },
    { value: 'cloudflare', label: 'Cloudflare only' },
    { value: 'technitium', label: 'Technitium only' },
    { value: 'both', label: 'Both' },
];

interface AuditEntry {
    id: number;
    action: string;
    provider: string;
    record_name: string;
    created_at: string;
}

const DnsSettings = () => {
    const { data, error, reload } = useLoad(() => get<{ settings: DnsSettingsData }>('/extensions/dnsrecords/admin/settings').then((r) => r.settings));
    const audit = useLoad(() => get<{ entries: AuditEntry[] }>('/extensions/dnsrecords/admin/audit', { limit: 25 }).then((r) => r.entries));
    const [form, setForm] = useState<DnsSettingsData>();
    const [secrets, setSecrets] = useState({ cloudflare_api_token: '', technitium_api_token: '' });
    const [reserved, setReserved] = useState('');
    const [saving, setSaving] = useState(false);

    useEffect(() => {
        if (data) {
            setForm(data);
            setReserved((data.reserved_labels ?? []).join(', '));
        }
    }, [data]);

    if (error) return <Notice tone='error'>{error}</Notice>;
    if (!form) return <Loading />;

    const set = <K extends keyof DnsSettingsData>(key: K, value: DnsSettingsData[K]) => setForm({ ...form, [key]: value });
    const setProfile = (i: number, patch: Partial<SrvProfile>) =>
        set('srv_profiles', form.srv_profiles.map((p, j) => (i === j ? { ...p, ...patch } : p)));
    const setDomain = (i: number, patch: Partial<PrimaryDomain>) =>
        set('primary_domains', form.primary_domains.map((d, j) => (i === j ? { ...d, ...patch } : d)));

    const save = async () => {
        setSaving(true);
        try {
            await put('/extensions/dnsrecords/admin/settings', {
                ...form,
                ...secrets,
                reserved_labels: reserved.split(',').map((s) => s.trim()).filter(Boolean),
            });
            setSecrets({ cloudflare_api_token: '', technitium_api_token: '' });
            await reload();
            toast.success('DNS settings saved.');
        } catch (e) {
            toast.error(addonError(e, 'Could not save DNS settings.'));
        } finally {
            setSaving(false);
        }
    };

    const tokenHint = (fromEnv: boolean, stored: boolean) =>
        fromEnv ? 'Provided by the host (sops); overrides anything entered here.' : stored ? 'Stored. Leave blank to keep it.' : 'Not set.';

    return (
        <form
            className='space-y-6'
            onSubmit={(e) => {
                e.preventDefault();
                void save();
            }}
        >
            {form.dry_run && <Notice tone='warn'>Dry-run is on: DNS changes are logged but not sent to any provider.</Notice>}

            <Section title='Providers' description='Where records are written. "Both" keeps Cloudflare (public) and Technitium (LAN) in sync.'>
                <Grid>
                    <Field label='Provider mode'>
                        <Select
                            value={form.dns_provider_mode}
                            onChange={(v) => set('dns_provider_mode', v)}
                            options={[
                                { value: 'cloudflare', label: 'Cloudflare' },
                                { value: 'technitium', label: 'Technitium' },
                                { value: 'both', label: 'Cloudflare + Technitium' },
                            ]}
                        />
                    </Field>
                    <Field label='Default TTL' hint='1 = automatic (Cloudflare).'>
                        <NumberInput min={1} value={form.default_ttl} onChange={(v) => set('default_ttl', v)} />
                    </Field>
                    <Field label='Cloudflare API token' hint={tokenHint(form.cloudflare_token_from_env, form.cloudflare_api_token_set)} optional>
                        <Text
                            type='password'
                            autoComplete='off'
                            value={secrets.cloudflare_api_token}
                            onChange={(v) => setSecrets({ ...secrets, cloudflare_api_token: v })}
                        />
                    </Field>
                    <Field label='Cloudflare zone ID'>
                        <Text value={form.zone_id} onChange={(v) => set('zone_id', v)} />
                    </Field>
                    <Field label='Base domain'>
                        <Text value={form.base_domain} onChange={(v) => set('base_domain', v)} />
                    </Field>
                    <Field label='Technitium API URL'>
                        <Text value={form.technitium_api_url} onChange={(v) => set('technitium_api_url', v)} />
                    </Field>
                    <Field label='Technitium default zone'>
                        <Text value={form.technitium_default_zone} onChange={(v) => set('technitium_default_zone', v)} />
                    </Field>
                    <Field label='Technitium API token' hint={tokenHint(form.technitium_token_from_env, form.technitium_api_token_set)} optional>
                        <Text
                            type='password'
                            autoComplete='off'
                            value={secrets.technitium_api_token}
                            onChange={(v) => setSecrets({ ...secrets, technitium_api_token: v })}
                        />
                    </Field>
                </Grid>
                <Grid>
                    <Toggle label='Auto-provision on install' hint='Create A + enabled SRV records when a server finishes installing.' checked={form.auto_provision_enabled} onChange={(v) => set('auto_provision_enabled', v)} />
                    <Toggle label='Follow allocation changes' hint='Update SRV ports when the primary allocation changes.' checked={form.update_on_allocation_change} onChange={(v) => set('update_on_allocation_change', v)} />
                    <Toggle label='Dry run' hint='Log changes without calling any provider.' checked={form.dry_run} onChange={(v) => set('dry_run', v)} />
                </Grid>
            </Section>

            <Section title='Hostnames' description='Vanity subdomains handed out per server.'>
                <Grid>
                    <Field label='Subdomain generation'>
                        <Select
                            value={form.subdomain_generation}
                            onChange={(v) => set('subdomain_generation', v)}
                            options={[
                                { value: 'server_slug', label: 'Server name slug + UUID suffix' },
                                { value: 'random_words', label: 'Random word pairs' },
                                { value: 'random_hex', label: 'Random hex' },
                                { value: 'uuid_only', label: 'UUID prefix' },
                            ]}
                        />
                    </Field>
                    <Field label='Client subdomain policy'>
                        <Select
                            value={form.client_subdomain_policy}
                            onChange={(v) => set('client_subdomain_policy', v)}
                            options={[
                                { value: 'never', label: 'Never (admin only)' },
                                { value: 'once_on_create', label: 'Once on create' },
                                { value: 'limited', label: 'Limited changes per period' },
                                { value: 'always', label: 'Always' },
                            ]}
                        />
                    </Field>
                    <Field label='Client change limit'>
                        <NumberInput min={0} value={form.client_change_limit} onChange={(v) => set('client_change_limit', v)} />
                    </Field>
                    <Field label='Change period (hours)'>
                        <NumberInput min={1} value={form.client_change_period_hours} onChange={(v) => set('client_change_period_hours', v)} />
                    </Field>
                    <Field label='Minimum label length'>
                        <NumberInput min={1} value={form.min_label_length} onChange={(v) => set('min_label_length', v)} />
                    </Field>
                    <Field label='Maximum label length'>
                        <NumberInput min={3} value={form.max_label_length} onChange={(v) => set('max_label_length', v)} />
                    </Field>
                    <Field label='Reserved labels' hint='Comma-separated; nobody can claim these.'>
                        <Text value={reserved} onChange={setReserved} />
                    </Field>
                    <Field label='Custom domain mode'>
                        <Select
                            value={form.custom_domain_mode}
                            onChange={(v) => set('custom_domain_mode', v)}
                            options={[
                                { value: 'cname', label: 'CNAME verification only' },
                                { value: 'nameserver', label: 'Nameserver delegation only' },
                                { value: 'both', label: 'CNAME and nameserver delegation' },
                            ]}
                        />
                    </Field>
                </Grid>
                <Toggle label='Allow custom domains' checked={form.allow_custom_domain} onChange={(v) => set('allow_custom_domain', v)} />
            </Section>

            <Section
                title='Primary domains'
                description='Domains that hostnames are created under. Leave the zone ID blank to use the default zone.'
                actions={
                    <Button type='button' size='sm' variant='secondary' onClick={() => set('primary_domains', [...form.primary_domains, { id: '', domain: '', client_selectable: true }])}>
                        Add domain
                    </Button>
                }
            >
                <Table head={['ID', 'Domain', 'Zone ID', 'Client selectable', '']} empty={form.primary_domains.length === 0 && 'Only the base domain is used.'}>
                    {form.primary_domains.map((d, i) => (
                        <tr key={i} className='border-b border-mocha-400/40'>
                            <Td><Text value={d.id} onChange={(v) => setDomain(i, { id: v })} /></Td>
                            <Td><Text value={d.domain} onChange={(v) => setDomain(i, { domain: v })} /></Td>
                            <Td><Text value={d.zone_id ?? ''} onChange={(v) => setDomain(i, { zone_id: v || undefined })} /></Td>
                            <Td><Toggle label='' checked={!!d.client_selectable} onChange={(v) => setDomain(i, { client_selectable: v })} /></Td>
                            <Td>
                                <Button type='button' size='sm' variant='secondary' onClick={() => set('primary_domains', form.primary_domains.filter((_, j) => j !== i))}>
                                    Remove
                                </Button>
                            </Td>
                        </tr>
                    ))}
                </Table>
            </Section>

            <Section
                title='SRV profiles'
                description='Game presets fill in service/protocol. Port blank = the server’s primary allocation.'
                actions={
                    <Button type='button' size='sm' variant='secondary' onClick={() => set('srv_profiles', [...form.srv_profiles, { id: '', label: '', service: '_game', proto: '_tcp', priority: 0, weight: 5, auto_provision: false }])}>
                        Add profile
                    </Button>
                }
            >
                <Table head={['ID', 'Preset', 'Label', 'Service', 'Proto', 'Port', 'Prio', 'Weight', 'Provider', 'Auto', '']}>
                    {form.srv_profiles.map((p, i) => (
                        <tr key={i} className='border-b border-mocha-400/40'>
                            <Td className='min-w-28'><Text value={p.id} onChange={(v) => setProfile(i, { id: v })} /></Td>
                            <Td className='min-w-40'><Select value={p.preset ?? ''} onChange={(v) => setProfile(i, { preset: v || undefined })} options={PRESETS.map((v) => ({ value: v, label: v || 'Custom' }))} /></Td>
                            <Td className='min-w-36'><Text value={p.label ?? ''} onChange={(v) => setProfile(i, { label: v })} /></Td>
                            <Td className='min-w-28'><Text value={p.service ?? ''} placeholder={p.preset ? 'preset' : '_game'} onChange={(v) => setProfile(i, { service: v || undefined })} /></Td>
                            <Td className='min-w-24'><Select value={p.proto ?? ''} onChange={(v) => setProfile(i, { proto: v || undefined })} options={[{ value: '', label: 'preset' }, { value: '_tcp', label: 'TCP' }, { value: '_udp', label: 'UDP' }]} /></Td>
                            <Td className='min-w-24'><Text value={p.port ?? ''} onChange={(v) => setProfile(i, { port: v === '' ? null : Number(v) })} /></Td>
                            <Td className='min-w-16'><Text value={p.priority ?? ''} onChange={(v) => setProfile(i, { priority: Number(v) })} /></Td>
                            <Td className='min-w-16'><Text value={p.weight ?? ''} onChange={(v) => setProfile(i, { weight: Number(v) })} /></Td>
                            <Td className='min-w-40'><Select value={p.target_provider ?? ''} onChange={(v) => setProfile(i, { target_provider: v || undefined })} options={PROVIDERS} /></Td>
                            <Td><Toggle label='' checked={!!p.auto_provision} onChange={(v) => setProfile(i, { auto_provision: v })} /></Td>
                            <Td>
                                <Button type='button' size='sm' variant='secondary' onClick={() => set('srv_profiles', form.srv_profiles.filter((_, j) => j !== i))}>
                                    Remove
                                </Button>
                            </Td>
                        </tr>
                    ))}
                </Table>
            </Section>

            <div className='flex justify-end'>
                <Button type='submit' disabled={saving}>
                    {saving ? 'Saving…' : 'Save DNS settings'}
                </Button>
            </div>

            <Section title='Recent DNS activity'>
                <Table head={['When', 'Action', 'Provider', 'Record']} empty={(audit.data ?? []).length === 0 && 'Nothing logged yet.'}>
                    {(audit.data ?? []).map((e) => (
                        <tr key={e.id} className='border-b border-mocha-400/40'>
                            <Td className='whitespace-nowrap text-xs text-cream-400/60'>{new Date(e.created_at).toLocaleString()}</Td>
                            <Td>{e.action}</Td>
                            <Td>{e.provider}</Td>
                            <Td><code className='text-xs'>{e.record_name}</code></Td>
                        </tr>
                    ))}
                </Table>
            </Section>
        </form>
    );
};

export default DnsSettings;
