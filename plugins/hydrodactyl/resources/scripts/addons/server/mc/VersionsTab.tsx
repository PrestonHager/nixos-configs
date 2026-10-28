import { useEffect, useState } from 'react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { addonError, get, put } from '../../api';
import { Field, Grid, Loading, Notice, Section, Select, Toggle } from '../../ui';
import { useLoad } from '../../useLoad';
import { LOADER_NAMES, useMcApi, type VersionVariable } from './common';

interface VersionsData {
    loader: string | null;
    variables: Record<string, VersionVariable>;
    versions: string[];
}

// Which variable holds the Minecraft version and which the build/loader.
const LAYOUT: Record<string, { mc?: string; build?: string; buildLabel?: string }> = {
    paper: { mc: 'MINECRAFT_VERSION', build: 'BUILD_NUMBER', buildLabel: 'Paper build' },
    purpur: { mc: 'MINECRAFT_VERSION', build: 'BUILD_NUMBER', buildLabel: 'Purpur build' },
    fabric: { mc: 'MC_VERSION', build: 'LOADER_VERSION', buildLabel: 'Fabric loader' },
    neoforge: { mc: 'MC_VERSION', build: 'NEOFORGE_VERSION', buildLabel: 'NeoForge version' },
    forge: { mc: 'MC_VERSION', build: 'FORGE_VERSION', buildLabel: 'Forge version' },
    vanilla: { mc: 'VANILLA_VERSION' },
};

const VersionsTab = () => {
    const { url } = useMcApi();
    const { data, error, reload } = useLoad(() => get<VersionsData>(url('/versions')), [url('')]);
    const [mc, setMc] = useState('');
    const [build, setBuild] = useState('');
    const [builds, setBuilds] = useState<string[]>([]);
    const [reinstall, setReinstall] = useState(true);
    const [saving, setSaving] = useState(false);

    const layout = data?.loader ? LAYOUT[data.loader] ?? {} : {};

    useEffect(() => {
        if (!data) return;
        setMc(data.variables[layout.mc ?? '']?.value ?? 'latest');
        setBuild(data.variables[layout.build ?? '']?.value ?? 'latest');
    }, [data, layout.mc, layout.build]);

    useEffect(() => {
        if (!layout.build || !mc) return;
        // "latest" for the MC version means the newest release.
        const version = mc === 'latest' ? data?.versions[0] : mc;
        if (!version) return;
        get<{ builds: string[] }>(url('/versions/builds'), { version })
            .then((r) => setBuilds(r.builds))
            .catch(() => setBuilds([]));
    }, [mc, layout.build, data, url]);

    if (error) return <Notice tone='error'>{error}</Notice>;
    if (!data) return <Loading />;
    if (!data.loader) {
        return <Notice tone='warn'>This egg's startup variables don't match a known Minecraft server type, so its version can't be managed here. Use the Startup page.</Notice>;
    }

    const editable = (env?: string) => !!env && !!data.variables[env]?.editable;
    const withCurrent = (list: string[], current: string) => ['latest', ...(current && current !== 'latest' && !list.includes(current) ? [current] : []), ...list];

    const save = async () => {
        const variables: Record<string, string> = {};
        if (layout.mc && mc !== data.variables[layout.mc]?.value) variables[layout.mc] = mc;
        if (layout.build && build !== data.variables[layout.build]?.value) variables[layout.build] = build;
        if (Object.keys(variables).length === 0) {
            toast.info('Nothing changed.');
            return;
        }

        setSaving(true);
        try {
            await put(url('/versions'), { variables, reinstall });
            await reload();
            toast.success(reinstall ? 'Version saved; reinstall started to fetch the new jar.' : 'Version saved. Reinstall the server to apply it.');
        } catch (e) {
            toast.error(addonError(e, 'Could not change the version.'));
        } finally {
            setSaving(false);
        }
    };

    return (
        <Section
            title={`${LOADER_NAMES[data.loader] ?? data.loader} server`}
            description='Changes the egg’s version variables. The egg’s install script downloads the matching jar; worlds, plugins and mods are left in place.'
        >
            <Grid>
                {layout.mc && (
                    <Field label='Minecraft version' hint={editable(layout.mc) ? undefined : 'Read-only for this server.'}>
                        <Select value={mc} onChange={(v) => { setMc(v); setBuild('latest'); }} options={withCurrent(data.versions, data.variables[layout.mc]?.value ?? '')} />
                    </Field>
                )}
                {layout.build && (
                    <Field label={layout.buildLabel ?? 'Build'} hint={editable(layout.build) ? undefined : 'Read-only for this server.'}>
                        <Select value={build} onChange={setBuild} options={withCurrent(builds, data.variables[layout.build]?.value ?? '')} />
                    </Field>
                )}
            </Grid>
            {data.loader === 'fabric' && data.variables.FABRIC_VERSION && (
                <p className='text-xs text-cream-400/60'>Fabric installer: {data.variables.FABRIC_VERSION.value ?? 'latest'} (change it on the Startup page if needed).</p>
            )}
            <Toggle label='Reinstall after saving' hint='Runs the egg install script now so the new jar is downloaded. The server is stopped while it runs.' checked={reinstall} onChange={setReinstall} />
            <div className='flex justify-end'>
                <Button disabled={saving} onClick={() => void save()}>
                    {saving ? 'Saving…' : 'Save version'}
                </Button>
            </div>
        </Section>
    );
};

export default VersionsTab;
