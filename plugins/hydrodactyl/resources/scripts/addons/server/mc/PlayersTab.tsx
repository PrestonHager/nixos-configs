import { useState } from 'react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { ServerContext } from '@/state/server';
import { addonError, get, post, put } from '../../api';
import { Area, Badge, Field, Grid, Loading, Notice, Section, Select, Table, Td, Text } from '../../ui';
import { useLoad } from '../../useLoad';
import { useMcApi } from './common';

interface Player {
    name: string;
    uuid: string | null;
    whitelisted: boolean;
    op: boolean;
    op_level: number | null;
    banned: boolean;
    ban_reason: string | null;
    notes: string | null;
}

const ACTIONS = [
    { value: 'whitelist', label: 'Add to whitelist' },
    { value: 'unwhitelist', label: 'Remove from whitelist' },
    { value: 'op', label: 'Make operator' },
    { value: 'deop', label: 'Remove operator' },
    { value: 'kick', label: 'Kick' },
    { value: 'ban', label: 'Ban' },
    { value: 'unban', label: 'Unban' },
];

const PlayersTab = () => {
    const status = ServerContext.useStoreState((state) => state.status.value);
    const { url } = useMcApi();
    const { data, error, reload } = useLoad(() => get<{ players: Player[] }>(url('/players')).then((r) => r.players), [url]);
    const [name, setName] = useState('');
    const [action, setAction] = useState('whitelist');
    const [reason, setReason] = useState('');
    const [editing, setEditing] = useState<Player>();
    const [notes, setNotes] = useState('');
    const [busy, setBusy] = useState(false);

    const run = async (player: string, act: string, why = '') => {
        setBusy(true);
        try {
            const r = await post<{ command: string }>(url('/players/action'), { player, action: act, reason: why || undefined });
            toast.success(`Sent: /${r.command}`);
            // The server writes the JSON lists a moment after the command.
            window.setTimeout(() => void reload(), 1500);
        } catch (e) {
            toast.error(addonError(e));
        } finally {
            setBusy(false);
        }
    };

    const saveNotes = async () => {
        if (!editing) return;
        try {
            await put(url('/players/notes'), { player: editing.name, uuid: editing.uuid ?? undefined, notes });
            setEditing(undefined);
            await reload();
            toast.success('Notes saved.');
        } catch (e) {
            toast.error(addonError(e));
        }
    };

    if (error) return <Notice tone='error'>{error}</Notice>;
    if (!data) return <Loading />;

    return (
        <div className='space-y-6'>
            {status !== 'running' && <Notice tone='warn'>Player actions are sent as console commands, so the server must be running.</Notice>}

            <Section title='Player action'>
                <Grid>
                    <Field label='Player name'>
                        <Text value={name} onChange={setName} placeholder='Steve (Bedrock: .Steve)' />
                    </Field>
                    <Field label='Action'>
                        <Select value={action} onChange={setAction} options={ACTIONS} />
                    </Field>
                    {(action === 'ban' || action === 'kick') && (
                        <Field label='Reason' optional>
                            <Text value={reason} onChange={setReason} maxLength={200} />
                        </Field>
                    )}
                </Grid>
                <div className='flex justify-end'>
                    <Button disabled={busy || !name.trim() || status !== 'running'} onClick={() => void run(name.trim(), action, reason)}>
                        Run
                    </Button>
                </div>
            </Section>

            {editing && (
                <Section title={`Notes for ${editing.name}`}>
                    <Area rows={4} value={notes} onChange={setNotes} />
                    <div className='flex justify-end gap-2'>
                        <Button variant='secondary' onClick={() => setEditing(undefined)}>Cancel</Button>
                        <Button onClick={() => void saveNotes()}>Save notes</Button>
                    </div>
                </Section>
            )}

            <Section title='Known players' description='From usercache, whitelist, ops and ban lists on the server, plus panel notes.'>
                <Table head={['Player', 'Status', 'Notes', '']} empty={data.length === 0 && 'No players have joined yet.'}>
                    {data.map((p) => (
                        <tr key={p.name} className='border-b border-mocha-400/40'>
                            <Td>
                                <span className='text-cream-50'>{p.name}</span>
                                {p.uuid && <div className='text-[10px] text-cream-400/40'>{p.uuid}</div>}
                            </Td>
                            <Td>
                                <div className='flex flex-wrap gap-1'>
                                    {p.whitelisted && <Badge tone='ok'>whitelisted</Badge>}
                                    {p.op && <Badge tone='warn'>op{p.op_level ? ` ${p.op_level}` : ''}</Badge>}
                                    {p.banned && <Badge tone='bad'>banned</Badge>}
                                </div>
                                {p.ban_reason && <div className='mt-1 text-xs text-cream-400/50'>{p.ban_reason}</div>}
                            </Td>
                            <Td className='max-w-64 text-xs text-cream-400/70'>{p.notes}</Td>
                            <Td>
                                <div className='flex flex-wrap justify-end gap-2'>
                                    <Button size='sm' variant='secondary' disabled={busy || status !== 'running'} onClick={() => void run(p.name, p.whitelisted ? 'unwhitelist' : 'whitelist')}>
                                        {p.whitelisted ? 'Unwhitelist' : 'Whitelist'}
                                    </Button>
                                    <Button size='sm' variant='secondary' disabled={busy || status !== 'running'} onClick={() => void run(p.name, p.op ? 'deop' : 'op')}>
                                        {p.op ? 'Deop' : 'Op'}
                                    </Button>
                                    <Button size='sm' variant='secondary' disabled={busy || status !== 'running'} onClick={() => (p.banned ? void run(p.name, 'unban') : window.confirm(`Ban ${p.name}?`) && void run(p.name, 'ban'))}>
                                        {p.banned ? 'Unban' : 'Ban'}
                                    </Button>
                                    <Button size='sm' variant='secondary' onClick={() => { setEditing(p); setNotes(p.notes ?? ''); }}>
                                        Notes
                                    </Button>
                                </div>
                            </Td>
                        </tr>
                    ))}
                </Table>
            </Section>
        </div>
    );
};

export default PlayersTab;
