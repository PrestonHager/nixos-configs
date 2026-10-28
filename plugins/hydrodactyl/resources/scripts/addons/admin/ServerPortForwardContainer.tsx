import { useState } from 'react';
import { useParams } from 'react-router-dom';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { addonError, del, get, post } from '../api';
import { Badge, Field, Grid, Loading, Notice, NumberInput, Section, Select, Table, Td } from '../ui';
import { useLoad } from '../useLoad';

interface Mapping {
    id: string;
    protocol: string;
    external_port: number;
    internal_port: number;
    inside_ip?: string;
    status: string;
}

interface AllocationRow {
    allocation_id: number;
    port: number;
    is_primary: boolean;
    target_ip: string | null;
    suggested_external_port: number;
    protocol: string;
    forward_status: string;
    mapping: Mapping | null;
}

interface Overview {
    node: { id: number; name: string | null; lan_ip: string | null };
    allocations: AllocationRow[];
    pending: AllocationRow[];
    mappings: Mapping[];
}

interface AuditEntry {
    id: number;
    action: string;
    success: number | boolean;
    error_message: string | null;
    created_at: string;
}

const statusTone = (s: string) => (s === 'active' ? 'ok' : s === 'dry_run' ? 'warn' : 'muted');

// The endpoint answers 200 with success: false when SSH itself fails.
export const testRouter = async () => {
    const r = await post<{ success: boolean; dry_run?: boolean; stderr?: string; error?: string }>('/extensions/portforward/admin/settings/test-connection');
    if (!r.success) throw new Error(r.error || r.stderr || 'Router SSH test failed.');
    return r;
};

const ServerPortForwardContainer = () => {
    const { id } = useParams<'id'>();
    const base = `/extensions/portforward/admin/servers/${id}/mappings`;
    const { data, error, reload } = useLoad(() => get<Overview>(base), [id]);
    const audit = useLoad(() => get<{ entries: AuditEntry[] }>('/extensions/portforward/admin/audit', { server_id: id }).then((r) => r.entries), [id]);
    const [drafts, setDrafts] = useState<Record<number, { external: number; protocol: string }>>({});
    const [custom, setCustom] = useState({ protocol: 'tcp', external_port: 0, internal_port: 0 });
    const [busy, setBusy] = useState<string>();

    const run = async (key: string, action: () => Promise<unknown>, success: string) => {
        setBusy(key);
        try {
            await action();
            await Promise.all([reload(), audit.reload()]);
            toast.success(success);
            return true;
        } catch (e) {
            toast.error(addonError(e));
            return false;
        } finally {
            setBusy(undefined);
        }
    };

    if (error) return <Notice tone='error'>{error}</Notice>;
    if (!data) return <Loading />;

    const draft = (row: AllocationRow) => drafts[row.allocation_id] ?? { external: row.mapping?.external_port ?? row.suggested_external_port, protocol: (row.protocol || 'tcp').toLowerCase() };
    const forward = (row: AllocationRow) => {
        const d = draft(row);
        return post(`${base}/forward-allocation/${row.allocation_id}`, { external_port: d.external, protocol: d.protocol });
    };
    const nodeIp = data.node.lan_ip ?? '?';

    return (
        <div className='space-y-6'>
            <Section
                title='Allocations'
                description={<>WAN forwards on the Astracap router to node <code>{data.node.name ?? data.node.id}</code> at <code>{nodeIp}</code>.</>}
                actions={
                    <>
                        <Button size='sm' disabled={!!busy} onClick={() => void run('primary', () => post(`${base}/forward-primary`), 'Primary allocation forwarded.')}>
                            Forward primary
                        </Button>
                        <Button
                            size='sm'
                            variant='secondary'
                            disabled={!!busy || data.pending.length === 0}
                            onClick={() => void run('all', async () => { for (const row of data.pending) await forward(row); }, 'Pending allocations forwarded.')}
                        >
                            Forward all pending ({data.pending.length})
                        </Button>
                        <Button size='sm' variant='secondary' disabled={!!busy} onClick={() => void run('test', () => testRouter(), 'Router SSH connection works.')}>
                            Test router SSH
                        </Button>
                    </>
                }
            >
                <Table head={['Allocation', 'External port', 'Target', 'Protocol', 'Status', '']} empty={data.allocations.length === 0 && 'No allocations assigned to this server.'}>
                    {data.allocations.map((row) => {
                        const d = draft(row);
                        const mapped = !!row.mapping?.id;
                        return (
                            <tr key={row.allocation_id} className='border-b border-mocha-400/40'>
                                <Td>
                                    <strong>{row.port}</strong> {row.is_primary && <Badge tone='ok'>primary</Badge>}
                                </Td>
                                <Td className='w-36'>
                                    <NumberInput min={1} max={65535} disabled={mapped} value={d.external} onChange={(v) => setDrafts({ ...drafts, [row.allocation_id]: { ...d, external: v } })} />
                                </Td>
                                <Td><code className='text-xs'>{(row.target_ip ?? nodeIp)}:{row.port}</code></Td>
                                <Td className='w-32'>
                                    {mapped ? (
                                        (row.mapping?.protocol ?? 'tcp').toUpperCase()
                                    ) : (
                                        <Select value={d.protocol} onChange={(v) => setDrafts({ ...drafts, [row.allocation_id]: { ...d, protocol: v } })} options={[{ value: 'tcp', label: 'TCP' }, { value: 'udp', label: 'UDP' }]} />
                                    )}
                                </Td>
                                <Td><Badge tone={statusTone(row.forward_status)}>{row.forward_status}</Badge></Td>
                                <Td>
                                    <div className='flex justify-end'>
                                        {row.forward_status === 'pending' && (
                                            <Button size='sm' disabled={!!busy} onClick={() => void run(`fwd-${row.allocation_id}`, () => forward(row), `Port ${d.external} forwarded.`)}>
                                                Forward
                                            </Button>
                                        )}
                                    </div>
                                </Td>
                            </tr>
                        );
                    })}
                </Table>
            </Section>

            <Section title='NAT mappings' description='Everything this panel has applied on the router for this server.'>
                <Table head={['Protocol', 'External', 'Internal target', 'Status', '']} empty={data.mappings.length === 0 && 'No NAT mappings recorded for this server yet.'}>
                    {data.mappings.map((m) => (
                        <tr key={m.id} className='border-b border-mocha-400/40'>
                            <Td>{(m.protocol || 'tcp').toUpperCase()}</Td>
                            <Td><code>{m.external_port}</code></Td>
                            <Td><code className='text-xs'>{(m.inside_ip ?? nodeIp)}:{m.internal_port}</code></Td>
                            <Td><Badge tone={statusTone(m.status)}>{m.status}</Badge></Td>
                            <Td>
                                <div className='flex justify-end'>
                                    <Button size='sm' variant='secondary' disabled={!!busy} onClick={() => window.confirm(`Remove ${m.protocol.toUpperCase()} ${m.external_port} from the router?`) && void run(`rm-${m.id}`, () => del(`${base}/${encodeURIComponent(m.id)}`), 'Mapping removed.')}>
                                        Remove
                                    </Button>
                                </div>
                            </Td>
                        </tr>
                    ))}
                </Table>

                <div className='rounded-lg border border-mocha-400 p-4'>
                    <p className='mb-3 text-sm text-cream-100'>Custom mapping</p>
                    <Grid>
                        <Field label='Protocol'><Select value={custom.protocol} onChange={(v) => setCustom({ ...custom, protocol: v })} options={[{ value: 'tcp', label: 'TCP' }, { value: 'udp', label: 'UDP' }]} /></Field>
                        <Field label='External port'><NumberInput min={1} max={65535} value={custom.external_port || null} onChange={(v) => setCustom({ ...custom, external_port: v })} /></Field>
                        <Field label='Internal port' hint='Defaults to the external port.' optional><NumberInput min={1} max={65535} value={custom.internal_port || null} onChange={(v) => setCustom({ ...custom, internal_port: v })} /></Field>
                    </Grid>
                    <div className='mt-3 flex justify-end'>
                        <Button
                            disabled={!!busy || !custom.external_port}
                            onClick={() =>
                                void run('custom', () => post(base, { protocol: custom.protocol, external_port: custom.external_port, internal_port: custom.internal_port || undefined }), 'Mapping created.').then((ok) => ok && setCustom({ protocol: 'tcp', external_port: 0, internal_port: 0 }))
                            }
                        >
                            Add mapping
                        </Button>
                    </div>
                </div>
            </Section>

            <Section title='Router activity'>
                <Table head={['When', 'Action', 'Result']} empty={(audit.data ?? []).length === 0 && 'Nothing logged for this server.'}>
                    {(audit.data ?? []).map((e) => (
                        <tr key={e.id} className='border-b border-mocha-400/40'>
                            <Td className='whitespace-nowrap text-xs text-cream-400/60'>{new Date(e.created_at).toLocaleString()}</Td>
                            <Td>{e.action}</Td>
                            <Td>{e.success ? <Badge tone='ok'>ok</Badge> : <span className='text-xs text-red-300'>{e.error_message ?? 'failed'}</span>}</Td>
                        </tr>
                    ))}
                </Table>
            </Section>
        </div>
    );
};

export default ServerPortForwardContainer;
