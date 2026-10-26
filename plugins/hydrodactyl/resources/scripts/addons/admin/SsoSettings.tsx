import { useEffect, useState } from 'react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { addonError, get, put } from '../api';
import { Field, Grid, Loading, Notice, Section, Text, Toggle } from '../ui';
import { useLoad } from '../useLoad';

interface SsoData {
    provider: { enabled: boolean; name: string; client_id: string; client_secret_set: boolean };
    allow_register: boolean;
    allow_connecting: boolean;
    issuer: string;
    project_id: string | null;
    admin_group: string;
    callback_url: string;
}

const SsoSettings = () => {
    const { data, error, reload } = useLoad(() => get<SsoData>('/extensions/homelab/sso'));
    const [form, setForm] = useState<{ enabled: boolean; name: string; client_id: string; allow_register: boolean; allow_connecting: boolean }>();
    const [secret, setSecret] = useState('');
    const [saving, setSaving] = useState(false);

    useEffect(() => {
        if (data) {
            setForm({ enabled: data.provider.enabled, name: data.provider.name, client_id: data.provider.client_id, allow_register: data.allow_register, allow_connecting: data.allow_connecting });
        }
    }, [data]);

    if (error) return <Notice tone='error'>{error}</Notice>;
    if (!data || !form) return <Loading />;

    const save = async () => {
        setSaving(true);
        try {
            await put('/extensions/homelab/sso', { ...form, client_secret: secret || undefined });
            setSecret('');
            await reload();
            toast.success('SSO settings saved.');
        } catch (e) {
            toast.error(addonError(e, 'Could not save SSO settings.'));
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
            <Section
                title='Zitadel'
                description={
                    <>
                        Issuer <code>{data.issuer}</code>
                        {data.project_id ? <> · project <code>{data.project_id}</code></> : null} · redirect URI <code>{data.callback_url}</code>. Members of{' '}
                        <code>{data.admin_group}</code> become panel admins on login.
                    </>
                }
            >
                <Toggle label='Show "Sign in with Zitadel"' checked={form.enabled} onChange={(v) => setForm({ ...form, enabled: v })} />
                <Grid>
                    <Field label='Button name'>
                        <Text value={form.name} onChange={(v) => setForm({ ...form, name: v })} />
                    </Field>
                    <Field label='Client ID'>
                        <Text value={form.client_id} onChange={(v) => setForm({ ...form, client_id: v })} />
                    </Field>
                    <Field label='Client secret' optional hint={data.provider.client_secret_set ? 'Stored (encrypted). Leave blank to keep it.' : 'Not set.'}>
                        <Text type='password' autoComplete='off' value={secret} onChange={setSecret} />
                    </Field>
                </Grid>
            </Section>

            <Section title='Accounts'>
                <Grid>
                    <Toggle label='Link by email' hint='An unknown Zitadel identity with a verified email links to the panel user with that email.' checked={form.allow_connecting} onChange={(v) => setForm({ ...form, allow_connecting: v })} />
                    <Toggle label='Create accounts' hint='Otherwise-unknown identities get a new panel user.' checked={form.allow_register} onChange={(v) => setForm({ ...form, allow_register: v })} />
                </Grid>
            </Section>

            <div className='flex justify-end'>
                <Button type='submit' disabled={saving}>
                    {saving ? 'Saving…' : 'Save SSO settings'}
                </Button>
            </div>
        </form>
    );
};

export default SsoSettings;
