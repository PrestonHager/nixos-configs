import { useEffect, useState } from 'react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { addonError, del, get, post } from '../../api';
import { Badge, Field, Loading, Notice, Section, Select, Table, Td, Text } from '../../ui';
import { useLoad } from '../../useLoad';
import { useMcApi } from './common';

interface Hit {
    id: string;
    title: string;
    description: string;
    icon_url: string | null;
    downloads: number;
    versions: string[];
}

interface PackVersion {
    id: string;
    name: string;
    version_number: string;
    game_versions: string[];
    loaders: string[];
}

interface Installed {
    id: number;
    name: string;
    version_name: string;
    status: 'queued' | 'installing' | 'installed' | 'failed';
    progress: number;
    total: number;
    error: string | null;
    dependencies?: Record<string, string>;
}

const statusTone = { queued: 'muted', installing: 'warn', installed: 'ok', failed: 'bad' } as const;

const ModpacksTab = () => {
    const { url } = useMcApi();
    const installed = useLoad(() => get<{ modpacks: Installed[] }>(url('/modpacks/installed')).then((r) => r.modpacks), [url]);
    const [query, setQuery] = useState('');
    const [results, setResults] = useState<{ loader: string | null; hits: Hit[] }>();
    const [picked, setPicked] = useState<Hit>();
    const [versions, setVersions] = useState<PackVersion[]>([]);
    const [versionId, setVersionId] = useState('');
    const [busy, setBusy] = useState(false);

    const active = (installed.data ?? []).some((m) => m.status === 'queued' || m.status === 'installing');
    const reloadInstalled = installed.reload;

    // Poll while an install is running.
    useEffect(() => {
        if (!active) return;
        const t = window.setInterval(() => void reloadInstalled(), 3000);
        return () => window.clearInterval(t);
    }, [active, reloadInstalled]);

    const search = async () => {
        setBusy(true);
        try {
            setResults(await get(url('/modpacks/search'), { query }));
        } catch (e) {
            toast.error(addonError(e));
        } finally {
            setBusy(false);
        }
    };

    const pick = async (hit: Hit) => {
        setPicked(hit);
        setVersions([]);
        try {
            const r = await get<{ versions: PackVersion[] }>(url(`/modpacks/${hit.id}/versions`));
            setVersions(r.versions);
            setVersionId(r.versions[0]?.id ?? '');
        } catch (e) {
            toast.error(addonError(e));
        }
    };

    const install = async () => {
        if (!picked || !versionId) return;
        setBusy(true);
        try {
            await post(url('/modpacks'), { project_id: picked.id, version_id: versionId });
            setPicked(undefined);
            await installed.reload();
            toast.success('Modpack install queued.');
        } catch (e) {
            toast.error(addonError(e));
        } finally {
            setBusy(false);
        }
    };

    const remove = async (m: Installed) => {
        if (!window.confirm(`Remove ${m.name}? Every file it installed is deleted from the server.`)) return;
        try {
            await del(url(`/modpacks/${m.id}`));
            await installed.reload();
            toast.success(`${m.name} removed.`);
        } catch (e) {
            toast.error(addonError(e));
        }
    };

    const version = versions.find((v) => v.id === versionId);

    return (
        <div className='space-y-6'>
            <Section title='Installed modpacks'>
                {installed.error && <Notice tone='error'>{installed.error}</Notice>}
                {!installed.data ? (
                    <Loading />
                ) : (
                    <Table head={['Modpack', 'Version', 'Status', '']} empty={installed.data.length === 0 && 'No modpacks installed from this panel.'}>
                        {installed.data.map((m) => (
                            <tr key={m.id} className='border-b border-mocha-400/40'>
                                <Td>
                                    {m.name}
                                    {m.dependencies && (
                                        <div className='text-xs text-cream-400/50'>
                                            {Object.entries(m.dependencies).map(([k, v]) => `${k} ${v}`).join(' · ')}
                                        </div>
                                    )}
                                </Td>
                                <Td>{m.version_name}</Td>
                                <Td>
                                    <Badge tone={statusTone[m.status] ?? 'muted'}>{m.status}</Badge>
                                    {m.status === 'installing' && m.total > 0 && <span className='ml-2 text-xs text-cream-400/60'>{m.progress}/{m.total}</span>}
                                    {m.error && <div className='mt-1 text-xs text-red-300'>{m.error}</div>}
                                </Td>
                                <Td>
                                    <div className='flex justify-end'>
                                        <Button size='sm' variant='secondary' disabled={m.status === 'installing' || m.status === 'queued'} onClick={() => void remove(m)}>
                                            Remove
                                        </Button>
                                    </div>
                                </Td>
                            </tr>
                        ))}
                    </Table>
                )}
            </Section>

            <Section title='Install from Modrinth' description='Server-side files are downloaded straight to the server. Match the Minecraft and loader versions on the Version tab first.'>
                <form
                    className='flex gap-2'
                    onSubmit={(e) => {
                        e.preventDefault();
                        void search();
                    }}
                >
                    <Text value={query} onChange={setQuery} placeholder='Search modpacks' />
                    <Button type='submit' disabled={busy}>Search</Button>
                </form>

                {picked && (
                    <div className='space-y-3 rounded-lg border border-hydro-500/30 p-4'>
                        <p className='text-sm text-cream-50'>{picked.title}</p>
                        <Field label='Version'>
                            <Select value={versionId} onChange={setVersionId} options={versions.map((v) => ({ value: v.id, label: `${v.version_number} (${v.loaders.join(', ')} · ${v.game_versions.join(', ')})` }))} />
                        </Field>
                        {version && results?.loader && !version.loaders.includes(results.loader) && (
                            <Notice tone='warn'>This version targets {version.loaders.join(', ')}, but this server runs {results.loader}.</Notice>
                        )}
                        <div className='flex justify-end gap-2'>
                            <Button variant='secondary' onClick={() => setPicked(undefined)}>Cancel</Button>
                            <Button disabled={busy || !versionId || active} onClick={() => void install()}>Install</Button>
                        </div>
                    </div>
                )}

                {results && (
                    <div className='grid grid-cols-1 gap-3 md:grid-cols-2'>
                        {results.hits.map((h) => (
                            <button key={h.id} type='button' onClick={() => void pick(h)} className='flex gap-3 rounded-lg border border-mocha-400 p-3 text-left hover:border-hydro-400'>
                                {h.icon_url ? <img src={h.icon_url} alt='' width={48} height={48} className='h-12 w-12 rounded' /> : <div className='h-12 w-12 rounded bg-mocha-400' />}
                                <span>
                                    <span className='block text-sm text-cream-50'>{h.title}</span>
                                    <span className='line-clamp-2 block text-xs text-cream-400/60'>{h.description}</span>
                                    <span className='block text-[10px] text-cream-400/40'>{h.downloads.toLocaleString()} downloads</span>
                                </span>
                            </button>
                        ))}
                        {results.hits.length === 0 && <p className='text-sm text-cream-400/60'>No modpacks found.</p>}
                    </div>
                )}
            </Section>
        </div>
    );
};

export default ModpacksTab;
