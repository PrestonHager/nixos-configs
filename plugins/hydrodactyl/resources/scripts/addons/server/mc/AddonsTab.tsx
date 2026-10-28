import { useState } from 'react';
import { Link } from 'react-router-dom';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { encodePathSegments } from '@/helpers';
import { ServerContext } from '@/state/server';
import { addonError, del, get, post } from '../../api';
import { Badge, Loading, Notice, Section, Table, Td } from '../../ui';
import { useLoad } from '../../useLoad';
import { useMcApi } from './common';

interface AddonFile {
    file: string;
    name: string;
    enabled: boolean;
    size: number;
}

const size = (bytes: number) => (bytes > 1048576 ? `${(bytes / 1048576).toFixed(1)} MiB` : `${Math.ceil(bytes / 1024)} KiB`);

const AddonsTab = () => {
    const id = ServerContext.useStoreState((state) => state.server.data?.id);
    const eggFeatures = ServerContext.useStoreState((state) => state.server.data?.eggFeatures) ?? [];
    const { url } = useMcApi();
    const { data, error, reload } = useLoad(() => get<{ directory: string; files: AddonFile[] }>(url('/addons')), [url]);
    const [busy, setBusy] = useState<string>();

    const hasInstaller = eggFeatures.some((f) => /^(mod|plugin)\//i.test(f));

    const act = async (file: string, action: () => Promise<unknown>, done: string) => {
        setBusy(file);
        try {
            await action();
            await reload();
            toast.success(done);
        } catch (e) {
            toast.error(addonError(e));
        } finally {
            setBusy(undefined);
        }
    };

    if (error) return <Notice tone='error'>{error}</Notice>;
    if (!data) return <Loading />;

    const plugins = data.directory === 'plugins';

    return (
        <Section
            title={plugins ? 'Plugins' : 'Mods'}
            description={
                <>
                    Jars in <code>/{data.directory}</code>. Disabling renames a jar to <code>.jar.disabled</code>; restart the server to apply.
                </>
            }
            actions={
                hasInstaller ? (
                    <Link to={`/server/${id}/installer`}>
                        <Button size='sm'>Browse {plugins ? 'plugins' : 'mods'}</Button>
                    </Link>
                ) : undefined
            }
        >
            {!hasInstaller && (
                <Notice tone='warn'>
                    The plugin/mod browser appears once this server's egg lists a loader feature (for example <code>plugin/paper</code> or{' '}
                    <code>mod/fabric</code>).
                </Notice>
            )}
            <Table head={['Name', 'Size', 'Status', '']} empty={data.files.length === 0 && `No ${plugins ? 'plugins' : 'mods'} installed.`}>
                {data.files.map((f) => (
                    <tr key={f.file} className='border-b border-mocha-400/40'>
                        <Td>
                            <span className='text-cream-50'>{f.name}</span>
                            <div className='text-xs text-cream-400/50'>{f.file}</div>
                        </Td>
                        <Td className='text-xs text-cream-400/70'>{size(f.size)}</Td>
                        <Td>{f.enabled ? <Badge tone='ok'>enabled</Badge> : <Badge>disabled</Badge>}</Td>
                        <Td>
                            <div className='flex justify-end gap-2'>
                                {plugins && (
                                    <Link to={`/server/${id}/files#${encodePathSegments(`/plugins/${f.name.replace(/[-_ ]?v?\d[\w.+-]*$/, '')}`)}`}>
                                        <Button size='sm' variant='secondary'>Config</Button>
                                    </Link>
                                )}
                                <Button
                                    size='sm'
                                    variant='secondary'
                                    disabled={busy === f.file}
                                    onClick={() => void act(f.file, () => post(url('/addons/toggle'), { file: f.file, enabled: !f.enabled }), f.enabled ? `${f.name} disabled.` : `${f.name} enabled.`)}
                                >
                                    {f.enabled ? 'Disable' : 'Enable'}
                                </Button>
                                <Button
                                    size='sm'
                                    variant='secondary'
                                    disabled={busy === f.file}
                                    onClick={() => window.confirm(`Delete ${f.file}?`) && void act(f.file, () => del(url('/addons'), { file: f.file }), `${f.file} deleted.`)}
                                >
                                    Delete
                                </Button>
                            </div>
                        </Td>
                    </tr>
                ))}
            </Table>
        </Section>
    );
};

export default AddonsTab;
