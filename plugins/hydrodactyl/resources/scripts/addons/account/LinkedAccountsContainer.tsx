import { useState } from 'react';
import { toast } from 'sonner';
import PageContentBlock from '@/components/elements/PageContentBlock';
import { MainPageHeader } from '@/components/elements/MainPageHeader';
import { Button } from '@/components/ui/button';
import { addonError, del, get } from '../api';
import { Loading, Notice, Section, Table, Td } from '../ui';
import { useLoad } from '../useLoad';

interface Connections {
    connections: { provider: string; provider_name: string; name: string; connected_at: string | null }[];
    providers: { name: string; short_name: string }[];
}

const LinkedAccountsContainer = () => {
    const { data, error, reload } = useLoad(() => get<Connections>('/extensions/sociallogin/connections'));
    const [busy, setBusy] = useState(false);

    const unlink = async (provider: string) => {
        if (!window.confirm('Unlink this account? You will need your panel password to sign in.')) return;
        setBusy(true);
        try {
            await del(`/extensions/sociallogin/connections/${encodeURIComponent(provider)}`);
            await reload();
            toast.success('Account unlinked.');
        } catch (e) {
            toast.error(addonError(e));
        } finally {
            setBusy(false);
        }
    };

    const linked = new Set((data?.connections ?? []).map((c) => c.provider));

    return (
        <PageContentBlock title='Linked Accounts'>
            <MainPageHeader direction='column' title='Linked Accounts'>
                <p className='text-sm text-neutral-400'>Sign in to the panel through your identity provider.</p>
            </MainPageHeader>
            {error && <Notice tone='error'>{error}</Notice>}
            {!data ? (
                <Loading />
            ) : (
                <Section>
                    <Table head={['Provider', 'Identity', 'Linked', '']} empty={data.providers.length === 0 && data.connections.length === 0 && 'Single sign-on is not configured.'}>
                        {data.connections.map((c) => (
                            <tr key={c.provider} className='border-b border-mocha-400/40'>
                                <Td>{c.provider_name}</Td>
                                <Td>{c.name}</Td>
                                <Td className='text-xs text-cream-400/60'>{c.connected_at ? new Date(c.connected_at).toLocaleString() : ''}</Td>
                                <Td>
                                    <div className='flex justify-end'>
                                        <Button size='sm' variant='secondary' disabled={busy} onClick={() => void unlink(c.provider)}>
                                            Unlink
                                        </Button>
                                    </div>
                                </Td>
                            </tr>
                        ))}
                        {data.providers
                            .filter((p) => !linked.has(p.short_name))
                            .map((p) => (
                                <tr key={p.short_name} className='border-b border-mocha-400/40'>
                                    <Td>{p.name}</Td>
                                    <Td className='text-cream-400/50'>Not linked</Td>
                                    <Td />
                                    <Td>
                                        <div className='flex justify-end'>
                                            <a href={`/extensions/sociallogin/connect/${p.short_name}`}>
                                                <Button size='sm'>Link</Button>
                                            </a>
                                        </div>
                                    </Td>
                                </tr>
                            ))}
                    </Table>
                </Section>
            )}
        </PageContentBlock>
    );
};

export default LinkedAccountsContainer;
