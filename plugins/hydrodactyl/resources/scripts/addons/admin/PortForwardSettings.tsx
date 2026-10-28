import { useEffect, useState } from 'react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { addonError, get, put } from '../api';
import { Area, Field, Grid, Loading, Notice, NumberInput, Section, Text, Toggle } from '../ui';
import { useLoad } from '../useLoad';
import { testRouter } from './ServerPortForwardContainer';

interface Settings {
    enabled: boolean;
    dry_run: boolean;
    auto_forward_on_install: boolean;
    auto_remove_on_delete: boolean;
    router_host: string;
    router_ssh_user: string;
    router_ssh_private_key_set: boolean;
    ssh_key_file_configured: boolean;
    ssh_connect_host: string;
    ssh_kex_algorithms: string;
    ssh_host_key_algorithms: string;
    ssh_pubkey_accepted_algorithms: string;
    ssh_ciphers: string;
    ssh_config_file: string;
    ssh_config_content: string;
    ssh_extra_options: string;
    wan_interface: string;
    allowed_port_min: number;
    allowed_port_max: number;
    max_mappings_per_server: number;
    blocked_ports: number[];
    node_ip_map: Record<string, string>;
}

const PortForwardSettings = () => {
    const { data, error, reload } = useLoad(() => get<{ settings: Settings }>('/extensions/portforward/admin/settings').then((r) => r.settings));
    const [form, setForm] = useState<Settings>();
    const [key, setKey] = useState('');
    const [blocked, setBlocked] = useState('');
    const [nodeMap, setNodeMap] = useState('');
    const [saving, setSaving] = useState(false);

    useEffect(() => {
        if (!data) return;
        setForm(data);
        setBlocked((data.blocked_ports ?? []).join(', '));
        setNodeMap(Object.entries(data.node_ip_map ?? {}).map(([k, v]) => `${k}=${v}`).join('\n'));
    }, [data]);

    if (error) return <Notice tone='error'>{error}</Notice>;
    if (!form) return <Loading />;

    const set = <K extends keyof Settings>(k: K, v: Settings[K]) => setForm({ ...form, [k]: v });

    const save = async () => {
        const map: Record<string, string> = {};
        for (const line of nodeMap.split('\n').map((l) => l.trim()).filter(Boolean)) {
            const [k, v] = line.split('=').map((s) => s.trim());
            if (!k || !v) {
                toast.error(`Node IP map line "${line}" should look like 1=192.168.5.6`);
                return;
            }
            map[k] = v;
        }

        setSaving(true);
        try {
            await put('/extensions/portforward/admin/settings', {
                ...form,
                router_ssh_private_key: key || undefined,
                blocked_ports: blocked.split(',').map((s) => Number(s.trim())).filter((n) => n > 0),
                node_ip_map: map,
            });
            setKey('');
            await reload();
            toast.success('Port forward settings saved.');
        } catch (e) {
            toast.error(addonError(e, 'Could not save port forward settings.'));
        } finally {
            setSaving(false);
        }
    };

    return (
        <form
            className='space-y-6'
            onSubmit={(e) => {
                e.preventDefault();
                void save();
            }}
        >
            {form.dry_run && <Notice tone='warn'>Dry-run is on: router commands are generated and logged but never sent.</Notice>}

            <Section title='Behaviour'>
                <Grid>
                    <Toggle label='Enabled' checked={form.enabled} onChange={(v) => set('enabled', v)} />
                    <Toggle label='Dry run' checked={form.dry_run} onChange={(v) => set('dry_run', v)} />
                    <Toggle label='Forward on install' hint='Forward the primary allocation when a server finishes installing.' checked={form.auto_forward_on_install} onChange={(v) => set('auto_forward_on_install', v)} />
                    <Toggle label='Remove on delete' hint='Drop a server’s NAT rules when it is deleted.' checked={form.auto_remove_on_delete} onChange={(v) => set('auto_remove_on_delete', v)} />
                </Grid>
                <Grid>
                    <Field label='Lowest allowed external port'><NumberInput min={1} max={65535} value={form.allowed_port_min} onChange={(v) => set('allowed_port_min', v)} /></Field>
                    <Field label='Highest allowed external port'><NumberInput min={1} max={65535} value={form.allowed_port_max} onChange={(v) => set('allowed_port_max', v)} /></Field>
                    <Field label='Max mappings per server'><NumberInput min={1} value={form.max_mappings_per_server} onChange={(v) => set('max_mappings_per_server', v)} /></Field>
                    <Field label='Blocked ports' hint='Comma-separated; never forwarded.'><Text value={blocked} onChange={setBlocked} /></Field>
                </Grid>
                <Field label='Node LAN IPs' hint='One "node id=ip" per line; used as the NAT inside address.'>
                    <Area rows={4} value={nodeMap} onChange={setNodeMap} />
                </Field>
            </Section>

            <Section
                title='Router (Cisco IOS over SSH)'
                actions={
                    <Button
                        type='button'
                        size='sm'
                        variant='secondary'
                        onClick={() => testRouter().then((r) => toast.success(r.dry_run ? 'Dry run: SSH skipped.' : 'Router SSH connection works.')).catch((e) => toast.error(addonError(e)))}
                    >
                        Test connection
                    </Button>
                }
            >
                <Grid>
                    <Field label='Router address'><Text value={form.router_host} onChange={(v) => set('router_host', v)} /></Field>
                    <Field label='SSH user'><Text value={form.router_ssh_user} onChange={(v) => set('router_ssh_user', v)} /></Field>
                    <Field label='SSH host alias' hint='Host entry in the SSH config, if any.'><Text value={form.ssh_connect_host} onChange={(v) => set('ssh_connect_host', v)} /></Field>
                    <Field label='WAN interface'><Text value={form.wan_interface} onChange={(v) => set('wan_interface', v)} /></Field>
                    <Field label='KexAlgorithms'><Text value={form.ssh_kex_algorithms} onChange={(v) => set('ssh_kex_algorithms', v)} /></Field>
                    <Field label='HostKeyAlgorithms'><Text value={form.ssh_host_key_algorithms} onChange={(v) => set('ssh_host_key_algorithms', v)} /></Field>
                    <Field label='PubkeyAcceptedAlgorithms'><Text value={form.ssh_pubkey_accepted_algorithms} onChange={(v) => set('ssh_pubkey_accepted_algorithms', v)} /></Field>
                    <Field label='Ciphers' optional><Text value={form.ssh_ciphers} onChange={(v) => set('ssh_ciphers', v)} /></Field>
                    <Field label='SSH config file' optional><Text value={form.ssh_config_file} onChange={(v) => set('ssh_config_file', v)} /></Field>
                    <Field label='Extra ssh options' optional><Text value={form.ssh_extra_options} onChange={(v) => set('ssh_extra_options', v)} /></Field>
                </Grid>
                <Field label='Inline SSH config' optional>
                    <Area rows={4} value={form.ssh_config_content} onChange={(v) => set('ssh_config_content', v)} />
                </Field>
                <Field
                    label='Private key'
                    optional
                    hint={form.ssh_key_file_configured ? 'Provided by the host (sops); overrides anything entered here.' : form.router_ssh_private_key_set ? 'Stored. Leave blank to keep it.' : 'Not set.'}
                >
                    <Area rows={3} value={key} onChange={setKey} placeholder='-----BEGIN OPENSSH PRIVATE KEY-----' autoComplete='off' />
                </Field>
            </Section>

            <div className='flex justify-end'>
                <Button type='submit' disabled={saving}>
                    {saving ? 'Saving…' : 'Save port forward settings'}
                </Button>
            </div>
        </form>
    );
};

export default PortForwardSettings;
