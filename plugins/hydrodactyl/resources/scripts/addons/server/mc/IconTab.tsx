import { useState } from 'react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { addonError, del, get, post } from '../../api';
import { Field, Grid, Loading, Notice, Section, Text } from '../../ui';
import { useLoad } from '../../useLoad';
import { useMcApi } from './common';

interface IconData {
    icon: string | null;
    history: { id: number; image: string | null; created_at: string }[];
}

const IconTab = () => {
    const { url } = useMcApi();
    const { data, error, setData } = useLoad(() => get<IconData>(url('/icon')), [url]);
    const [text, setText] = useState('MC');
    const [background, setBackground] = useState('#2e86c1');
    const [color, setColor] = useState('#ffffff');
    const [preview, setPreview] = useState<string>();
    const [busy, setBusy] = useState(false);

    const call = async (action: () => Promise<IconData>, done: string) => {
        setBusy(true);
        try {
            setData(await action());
            setPreview(undefined);
            toast.success(done);
        } catch (e) {
            toast.error(addonError(e));
        } finally {
            setBusy(false);
        }
    };

    const upload = (file: File) => {
        if (file.size > 2 * 1024 * 1024) {
            toast.error('Pick an image under 2 MiB.');
            return;
        }
        const reader = new FileReader();
        reader.onload = () => void call(() => post<IconData>(url('/icon'), { image: reader.result }), 'Icon uploaded (scaled to 64×64).');
        reader.readAsDataURL(file);
    };

    if (error) return <Notice tone='error'>{error}</Notice>;
    if (!data) return <Loading />;

    const icon = (src: string | null, size = 64) =>
        src ? <img src={src} width={size} height={size} alt='' className='rounded [image-rendering:pixelated]' /> : <div style={{ width: size, height: size }} className='rounded bg-mocha-400' />;

    return (
        <div className='space-y-6'>
            <Section
                title='Current icon'
                description='Shown in the multiplayer server list. Restart (or wait for the next ping refresh) to see changes.'
                actions={
                    data.icon && (
                        <Button size='sm' variant='secondary' disabled={busy} onClick={() => window.confirm('Remove server-icon.png?') && void call(() => del<IconData>(url('/icon')), 'Icon removed.')}>
                            Remove
                        </Button>
                    )
                }
            >
                <div className='flex items-center gap-4'>
                    {icon(data.icon, 96)}
                    <label className='cursor-pointer rounded-lg border border-mocha-300 bg-mocha-400 px-4 py-2 text-sm text-cream-100 hover:bg-mocha-300'>
                        Upload image…
                        <input type='file' accept='image/png,image/jpeg,image/gif,image/webp' className='hidden' disabled={busy} onChange={(e) => e.target.files?.[0] && upload(e.target.files[0])} />
                    </label>
                </div>
            </Section>

            <Section title='Generate'>
                <Grid>
                    <Field label='Text (up to 4 characters)'><Text value={text} maxLength={4} onChange={setText} /></Field>
                    <Field label='Background'><input type='color' value={background} onChange={(e) => setBackground(e.target.value)} className='h-10 w-full rounded-lg bg-transparent' /></Field>
                    <Field label='Text colour'><input type='color' value={color} onChange={(e) => setColor(e.target.value)} className='h-10 w-full rounded-lg bg-transparent' /></Field>
                </Grid>
                <div className='flex items-center justify-end gap-3'>
                    {preview && icon(preview)}
                    <Button
                        variant='secondary'
                        disabled={busy || !text.trim()}
                        onClick={() => post<{ image: string }>(url('/icon/generate'), { text, background, color }).then((r) => setPreview(r.image)).catch((e) => toast.error(addonError(e)))}
                    >
                        Preview
                    </Button>
                    <Button disabled={busy || !preview} onClick={() => preview && void call(() => post<IconData>(url('/icon'), { image: preview }), 'Icon applied.')}>
                        Use this icon
                    </Button>
                </div>
            </Section>

            {data.history.length > 0 && (
                <Section title='History'>
                    <div className='flex flex-wrap gap-3'>
                        {data.history.map((h) => (
                            <button
                                key={h.id}
                                type='button'
                                title={`Restore (${new Date(h.created_at).toLocaleString()})`}
                                disabled={busy || !h.image}
                                className='rounded-lg border border-mocha-400 p-1 hover:border-hydro-400 disabled:opacity-40'
                                onClick={() => void call(() => post<IconData>(url(`/icon/history/${h.id}/restore`)), 'Icon restored.')}
                            >
                                {icon(h.image, 48)}
                            </button>
                        ))}
                    </div>
                </Section>
            )}
        </div>
    );
};

export default IconTab;
