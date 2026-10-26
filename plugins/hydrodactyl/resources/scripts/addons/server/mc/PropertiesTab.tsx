import { useEffect, useMemo, useState } from 'react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { addonError, get, post, put } from '../../api';
import { Field, Grid, Loading, Notice, Section, Select, Table, Td, Text, Toggle } from '../../ui';
import { useLoad } from '../../useLoad';
import { useMcApi } from './common';

interface PropertiesData {
    exists: boolean;
    values: Record<string, string>;
    fields: Record<string, { type: 'bool' | 'int' | 'enum' | 'string'; options: string[] | [number, number] | null }>;
    locked: string[];
}

interface Backup {
    id: number;
    size: number;
    created_at: string;
}

const PropertiesTab = () => {
    const { url } = useMcApi();
    const { data, error, setData } = useLoad(() => get<PropertiesData>(url('/properties')), [url]);
    const backups = useLoad(() => get<{ backups: Backup[] }>(url('/properties/backups')).then((r) => r.backups), [url]);
    const [values, setValues] = useState<Record<string, string>>({});
    const [showAll, setShowAll] = useState(false);
    const [saving, setSaving] = useState(false);

    useEffect(() => {
        if (data) setValues(data.values);
    }, [data]);

    const changes = useMemo(() => {
        if (!data) return {};
        return Object.fromEntries(Object.entries(values).filter(([k, v]) => data.values[k] !== v));
    }, [data, values]);

    if (error) return <Notice tone='error'>{error}</Notice>;
    if (!data) return <Loading />;
    if (!data.exists) return <Notice tone='warn'>server.properties does not exist yet. Start the server once so Minecraft generates it.</Notice>;

    const set = (k: string, v: string) => setValues({ ...values, [k]: v });

    const save = async () => {
        setSaving(true);
        try {
            setData(await put<PropertiesData>(url('/properties'), { values: changes }));
            await backups.reload();
            toast.success('server.properties saved (previous version backed up). Restart to apply.');
        } catch (e) {
            toast.error(addonError(e, 'Could not save server.properties.'));
        } finally {
            setSaving(false);
        }
    };

    const restore = async (id: number) => {
        if (!window.confirm('Restore this backup? The current file is backed up first.')) return;
        try {
            setData(await post<PropertiesData>(url(`/properties/backups/${id}/restore`)));
            await backups.reload();
            toast.success('Backup restored.');
        } catch (e) {
            toast.error(addonError(e));
        }
    };

    const typeOf = (k: string) => data.fields[k]?.type ?? 'string';
    // Only keys the file has: newer Minecraft drops some (e.g. pvp in 1.21.9+).
    const known = Object.keys(data.fields).filter((k) => k in data.values);
    const others = Object.keys(values).filter((k) => !(k in data.fields)).sort();

    const input = (k: string) => {
        const f = data.fields[k] ?? { type: 'string', options: null };
        const locked = data.locked.includes(k);
        if (f.type === 'bool') return <Toggle label={k} checked={values[k] === 'true'} disabled={locked} onChange={(v) => set(k, v ? 'true' : 'false')} />;
        if (f.type === 'enum') return <Field label={k}><Select value={values[k] ?? ''} onChange={(v) => set(k, v)} options={(f.options as string[]) ?? []} /></Field>;
        return (
            <Field label={k} hint={locked ? 'Managed by the panel.' : f.type === 'int' && f.options ? `${f.options[0]}–${f.options[1]}` : undefined}>
                <Text value={values[k] ?? ''} disabled={locked} inputMode={f.type === 'int' ? 'numeric' : undefined} onChange={(v) => set(k, v)} />
            </Field>
        );
    };

    return (
        <div className='space-y-6'>
            <Section title='Common settings'>
                <Grid>
                    {known.filter((k) => typeOf(k) !== 'bool').map((k) => <div key={k}>{input(k)}</div>)}
                </Grid>
                <Grid>
                    {known.filter((k) => typeOf(k) === 'bool').map((k) => <div key={k}>{input(k)}</div>)}
                </Grid>
            </Section>

            <Section
                title='All other properties'
                actions={<Button size='sm' variant='secondary' onClick={() => setShowAll(!showAll)}>{showAll ? 'Hide' : `Show (${others.length})`}</Button>}
            >
                {showAll && (
                    <Grid>
                        {others.map((k) => <div key={k}>{input(k)}</div>)}
                    </Grid>
                )}
            </Section>

            <div className='flex items-center justify-end gap-3'>
                {Object.keys(changes).length > 0 && <span className='text-xs text-cream-400/60'>{Object.keys(changes).length} unsaved change(s)</span>}
                <Button variant='secondary' disabled={Object.keys(changes).length === 0} onClick={() => setValues(data.values)}>
                    Discard
                </Button>
                <Button disabled={saving || Object.keys(changes).length === 0} onClick={() => void save()}>
                    {saving ? 'Saving…' : 'Save server.properties'}
                </Button>
            </div>

            <Section title='Backups' description='A copy is kept each time this page changes the file (newest 20).'>
                <Table head={['Saved', 'Size', '']} empty={(backups.data ?? []).length === 0 && 'No backups yet.'}>
                    {(backups.data ?? []).map((b) => (
                        <tr key={b.id} className='border-b border-mocha-400/40'>
                            <Td>{new Date(b.created_at).toLocaleString()}</Td>
                            <Td className='text-xs'>{b.size} B</Td>
                            <Td>
                                <div className='flex justify-end'>
                                    <Button size='sm' variant='secondary' onClick={() => void restore(b.id)}>Restore</Button>
                                </div>
                            </Td>
                        </tr>
                    ))}
                </Table>
            </Section>
        </div>
    );
};

export default PropertiesTab;
