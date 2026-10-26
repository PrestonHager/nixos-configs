import { useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { addonError, del, get, post, put } from '../api';
import { Badge, Field, Grid, Loading, Notice, NumberInput, Section, Select, Table, Td, Text, Toggle } from '../ui';
import { useLoad } from '../useLoad';

interface Subdomain {
    hostname_label: string;
    hostname_mode: string;
    fqdn: string;
    primary_domain: string;
    primary_domains: { id: string; domain: string }[];
    subdomain_locked: boolean;
    label_change_count: number;
    last_label_change_at: string | null;
}

interface Profiles {
    profiles: { id: string; label: string; service: string; proto: string }[];
    enabled: string[];
    defaults: { base_domain?: string; target?: string; port?: number } | null;
}

interface DnsRecord {
    record_id?: string;
    cloudflare_id?: string;
    type: string;
    name: string;
    content?: string;
    target?: string;
    port?: number;
    service?: string;
    proto?: string;
    data?: { target?: string; port?: number };
    profile_id?: string;
    label?: string;
    provider?: string;
}

interface CustomDomain {
    custom_domain: string | null;
    custom_domain_status: string | null;
    verification: { txt_host: string; txt_value: string; cname_host: string; cname_target: string; expires_at: string | null } | null;
}

interface Nameserver {
    nameserver_domain: string | null;
    nameserver_status: string | null;
    nameservers: string[];
}

const blankRecord = { type: 'SRV', name: '', content: '', service: '_minecraft', proto: '_tcp', target: '', port: 25565, priority: 0, weight: 5 };

const attributes = <T,>(r: { attributes?: T } | T) => ((r as { attributes?: T }).attributes ?? r) as T;

const ServerDnsContainer = () => {
    const { id } = useParams<'id'>();
    const base = `/extensions/dnsrecords/admin/servers/${id}`;

    const subdomain = useLoad(() => get<{ attributes: Subdomain }>(`${base}/subdomain`).then(attributes), [id]);
    const profiles = useLoad(() => get<{ attributes: Profiles }>(`${base}/srv-profiles`).then(attributes), [id]);
    const records = useLoad(() => get<{ data: DnsRecord[] }>(`${base}/records`).then((r) => r.data ?? []), [id]);
    const custom = useLoad(() => get<{ attributes: CustomDomain }>(`${base}/custom-domain`).then(attributes).catch(() => null), [id]);
    const ns = useLoad(() => get<{ attributes: Nameserver }>(`${base}/nameserver`).then(attributes).catch(() => null), [id]);

    const [label, setLabel] = useState('');
    const [domain, setDomain] = useState('default');
    const [locked, setLocked] = useState(false);
    const [enabled, setEnabled] = useState<string[]>([]);
    const [record, setRecord] = useState(blankRecord);
    const [showForm, setShowForm] = useState(false);
    const [customInput, setCustomInput] = useState('');
    const [nsInput, setNsInput] = useState('');
    const [busy, setBusy] = useState<string>();

    useEffect(() => {
        if (subdomain.data) {
            setLabel(subdomain.data.hostname_label ?? '');
            setDomain(subdomain.data.primary_domain ?? 'default');
            setLocked(!!subdomain.data.subdomain_locked);
        }
    }, [subdomain.data]);

    useEffect(() => {
        if (profiles.data) {
            setEnabled(profiles.data.enabled ?? []);
            setRecord((r) => ({ ...r, target: profiles.data?.defaults?.target ?? r.target, port: profiles.data?.defaults?.port ?? r.port }));
        }
    }, [profiles.data]);

    const run = async (key: string, action: () => Promise<unknown>, success: string, reload: Array<() => Promise<unknown>>) => {
        setBusy(key);
        try {
            await action();
            await Promise.all(reload.map((r) => r()));
            toast.success(success);
        } catch (e) {
            toast.error(addonError(e));
        } finally {
            setBusy(undefined);
        }
    };

    if (subdomain.loading && !subdomain.data) return <Loading />;

    const sub = subdomain.data;

    const recordDetails = (r: DnsRecord) => {
        let details = r.content ?? '';
        if (r.type === 'SRV') details = `${r.service ?? ''}${r.proto ?? ''} → ${r.data?.target ?? r.target ?? ''}:${r.port ?? r.data?.port ?? ''}`;
        else if (r.type === 'CNAME') details = `→ ${r.content ?? r.target ?? ''}`;
        return r.profile_id ? `${r.label ?? r.profile_id} — ${details}` : details;
    };

    const deleteRecord = (r: DnsRecord) => {
        const recordId = r.record_id ?? r.cloudflare_id ?? '';
        if (!window.confirm(`Delete ${r.type} record ${r.name}?`)) return;
        void run(
            `del-${recordId}`,
            () =>
                recordId.includes(':')
                    ? post(`${base}/records/delete`, { record_id: recordId, name: r.name, type: r.type })
                    : del(`${base}/records/${encodeURIComponent(recordId)}?name=${encodeURIComponent(r.name)}&type=${encodeURIComponent(r.type)}`),
            'Record deleted.',
            [records.reload],
        );
    };

    const submitRecord = () => {
        if (!record.name.trim()) {
            toast.error('Name is required.');
            return;
        }
        const body: Record<string, unknown> = { type: record.type, name: record.name.trim() };
        if (record.type === 'SRV') {
            body.data = { service: record.service, proto: record.proto, target: record.target, port: record.port, priority: record.priority, weight: record.weight };
        } else {
            body.content = record.content;
            if (record.type === 'MX') body.priority = record.priority;
        }
        void run('create', () => post(`${base}/records`, body), 'Record created.', [records.reload]).then(() => {
            setShowForm(false);
            setRecord({ ...blankRecord, target: profiles.data?.defaults?.target ?? '', port: profiles.data?.defaults?.port ?? 25565 });
        });
    };

    return (
        <div className='space-y-6'>
            {[subdomain.error, profiles.error, records.error].filter(Boolean).map((e) => (
                <Notice key={e} tone='error'>{e}</Notice>
            ))}

            {sub && (
                <Section
                    title='Hostname'
                    description={<>Mode <strong>{sub.hostname_mode || 'auto'}</strong> — <code>{sub.fqdn}</code> · {sub.label_change_count ?? 0} change(s){sub.last_label_change_at ? `, last ${sub.last_label_change_at}` : ''}</>}
                    actions={
                        <>
                            <Button size='sm' variant='secondary' disabled={!!busy} onClick={() => window.confirm('Regenerate hostname? DNS records for this server will be renamed.') && void run('regen', () => post(`${base}/subdomain/regenerate`), 'Hostname regenerated.', [subdomain.reload, records.reload])}>
                                Regenerate
                            </Button>
                            <Button size='sm' variant='secondary' disabled={!!busy} onClick={() => void run('sync', () => post(`${base}/srv-profiles/sync`), 'SRV records reconciled.', [records.reload])}>
                                Reconcile SRV
                            </Button>
                        </>
                    }
                >
                    <Grid>
                        <Field label='Label'>
                            <Text value={label} onChange={setLabel} />
                        </Field>
                        {sub.primary_domains?.length > 0 && (
                            <Field label='Primary domain'>
                                <Select value={domain} onChange={setDomain} options={sub.primary_domains.map((d) => ({ value: d.id, label: d.domain }))} />
                            </Field>
                        )}
                    </Grid>
                    <Toggle label='Lock hostname' hint='Block client changes to this hostname.' checked={locked} onChange={setLocked} />
                    <div className='flex justify-end'>
                        <Button disabled={!!busy || !label.trim()} onClick={() => void run('save-sub', () => put(`${base}/subdomain`, { label: label.trim(), primary_domain: domain, subdomain_locked: locked }), 'Hostname saved.', [subdomain.reload, records.reload])}>
                            Save hostname
                        </Button>
                    </div>
                </Section>
            )}

            <Section title='SRV profiles' description='Game/service SRV records published for this server.'>
                {(profiles.data?.profiles ?? []).length === 0 ? (
                    <p className='text-sm text-cream-400/60'>No SRV profiles are configured (Extensions → DNS Records).</p>
                ) : (
                    <Grid>
                        {profiles.data?.profiles.map((p) => (
                            <Toggle
                                key={p.id}
                                label={p.label || p.id}
                                hint={`${p.service}${p.proto}`}
                                checked={enabled.includes(p.id)}
                                onChange={(on) => setEnabled(on ? [...enabled, p.id] : enabled.filter((x) => x !== p.id))}
                            />
                        ))}
                    </Grid>
                )}
                <div className='flex justify-end gap-2'>
                    <Button variant='secondary' disabled={!!busy} onClick={() => void run('sync2', () => post(`${base}/srv-profiles/sync`), 'SRV records synced.', [records.reload])}>
                        Sync SRV records
                    </Button>
                    <Button disabled={!!busy} onClick={() => void run('profiles', () => put(`${base}/srv-profiles`, { enabled }), 'SRV profiles saved.', [profiles.reload, records.reload])}>
                        Save profiles
                    </Button>
                </div>
            </Section>

            <Section
                title='Records'
                actions={
                    <Button size='sm' variant={showForm ? 'secondary' : 'default'} onClick={() => setShowForm(!showForm)}>
                        {showForm ? 'Cancel' : 'Add record'}
                    </Button>
                }
            >
                {showForm && (
                    <div className='space-y-4 rounded-lg border border-mocha-400 p-4'>
                        <Grid>
                            <Field label='Type'>
                                <Select value={record.type} onChange={(v) => setRecord({ ...record, type: v })} options={['SRV', 'A', 'AAAA', 'CNAME', 'MX', 'TXT']} />
                            </Field>
                            <Field label='Name' hint={`Subdomain (mc) or full name (mc.${profiles.data?.defaults?.base_domain ?? 'example.com'}).`}>
                                <Text value={record.name} onChange={(v) => setRecord({ ...record, name: v })} />
                            </Field>
                            {record.type === 'SRV' ? (
                                <>
                                    <Field label='Service'><Text value={record.service} onChange={(v) => setRecord({ ...record, service: v })} /></Field>
                                    <Field label='Protocol'><Select value={record.proto} onChange={(v) => setRecord({ ...record, proto: v })} options={[{ value: '_tcp', label: 'TCP' }, { value: '_udp', label: 'UDP' }]} /></Field>
                                    <Field label='Target'><Text value={record.target} onChange={(v) => setRecord({ ...record, target: v })} /></Field>
                                    <Field label='Port'><NumberInput value={record.port} onChange={(v) => setRecord({ ...record, port: v })} /></Field>
                                    <Field label='Priority'><NumberInput value={record.priority} onChange={(v) => setRecord({ ...record, priority: v })} /></Field>
                                    <Field label='Weight'><NumberInput value={record.weight} onChange={(v) => setRecord({ ...record, weight: v })} /></Field>
                                </>
                            ) : (
                                <>
                                    <Field label={record.type === 'MX' ? 'Mail server' : 'Content'}><Text value={record.content} onChange={(v) => setRecord({ ...record, content: v })} /></Field>
                                    {record.type === 'MX' && <Field label='Priority'><NumberInput value={record.priority} onChange={(v) => setRecord({ ...record, priority: v })} /></Field>}
                                </>
                            )}
                        </Grid>
                        <div className='flex justify-end'>
                            <Button disabled={!!busy} onClick={submitRecord}>
                                {busy === 'create' ? 'Creating…' : 'Create record'}
                            </Button>
                        </div>
                    </div>
                )}

                <Table head={['Type', 'Name', 'Details', 'Provider', '']} empty={(records.data ?? []).length === 0 && 'No records yet.'}>
                    {(records.data ?? []).map((r, i) => (
                        <tr key={`${r.record_id ?? r.cloudflare_id ?? i}`} className='border-b border-mocha-400/40'>
                            <Td><Badge>{r.type}</Badge></Td>
                            <Td><code className='text-xs'>{r.name}</code></Td>
                            <Td className='text-xs text-cream-400/80'>{recordDetails(r)}</Td>
                            <Td className='text-xs'>{r.provider ?? ''}</Td>
                            <Td>
                                <div className='flex justify-end'>
                                    <Button size='sm' variant='secondary' disabled={!!busy} onClick={() => deleteRecord(r)}>
                                        Delete
                                    </Button>
                                </div>
                            </Td>
                        </tr>
                    ))}
                </Table>
            </Section>

            {custom.data && (
                <Section title='Custom domain' description={custom.data.custom_domain ? <>Status: <strong>{custom.data.custom_domain_status ?? 'pending'}</strong></> : 'Point a domain the owner controls at this server.'}>
                    {custom.data.verification && (
                        <Notice>
                            Create TXT <code>{custom.data.verification.txt_host}</code> = <code>{custom.data.verification.txt_value}</code> and CNAME{' '}
                            <code>{custom.data.verification.cname_host}</code> → <code>{custom.data.verification.cname_target}</code>, then verify.
                        </Notice>
                    )}
                    <Grid>
                        <Field label='Domain'><Text value={customInput || custom.data.custom_domain || ''} onChange={setCustomInput} placeholder='play.example.org' /></Field>
                    </Grid>
                    <div className='flex justify-end gap-2'>
                        {custom.data.custom_domain && (
                            <Button variant='secondary' disabled={!!busy} onClick={() => void run('cd-verify', () => post(`${base}/custom-domain/verify`), 'Verification checked.', [custom.reload, records.reload])}>
                                Verify
                            </Button>
                        )}
                        <Button disabled={!!busy || !customInput.trim()} onClick={() => void run('cd', () => put(`${base}/custom-domain`, { domain: customInput.trim() }), 'Custom domain saved.', [custom.reload])}>
                            Save domain
                        </Button>
                    </div>
                </Section>
            )}

            {ns.data && (
                <Section title='Nameserver delegation' description={ns.data.nameserver_domain ? <>Status: <strong>{ns.data.nameserver_status ?? 'pending'}</strong></> : 'Delegate a whole domain to Cloudflare under this host.'}>
                    {ns.data.nameservers.length > 0 && <Notice>Set the domain's nameservers to: <code>{ns.data.nameservers.join(', ')}</code></Notice>}
                    <Grid>
                        <Field label='Domain'><Text value={nsInput || ns.data.nameserver_domain || ''} onChange={setNsInput} placeholder='example.org' /></Field>
                    </Grid>
                    <div className='flex justify-end gap-2'>
                        {ns.data.nameserver_domain && (
                            <>
                                <Button variant='secondary' disabled={!!busy} onClick={() => void run('ns-verify', () => post(`${base}/nameserver/verify`), 'Delegation checked.', [ns.reload])}>
                                    Verify
                                </Button>
                                {ns.data.nameserver_status === 'pending_approval' && (
                                    <Button variant='secondary' disabled={!!busy} onClick={() => void run('ns-approve', () => post(`/extensions/dnsrecords/admin/nameserver/${id}/approve`), 'Delegation approved.', [ns.reload])}>
                                        Approve
                                    </Button>
                                )}
                            </>
                        )}
                        <Button disabled={!!busy || !nsInput.trim()} onClick={() => void run('ns', () => put(`${base}/nameserver`, { domain: nsInput.trim() }), 'Delegation requested.', [ns.reload])}>
                            Save domain
                        </Button>
                    </div>
                </Section>
            )}
        </div>
    );
};

export default ServerDnsContainer;
