import { NavLink, Outlet } from 'react-router-dom';
import { MainPageHeader } from '@/components/elements/MainPageHeader';
import PageContentBlock from '@/components/elements/PageContentBlock';
import { cn } from '@/lib/utils';

const tabs = [
    { label: 'DNS Records', to: '/extensions', end: true },
    { label: 'Port Forward', to: '/extensions/port-forward', end: false },
    { label: 'Single Sign-On', to: '/extensions/sso', end: false },
];

const ExtensionsLayout = () => (
    <PageContentBlock title='Extensions'>
        <MainPageHeader direction='column' title='Extensions'>
            <p className='text-sm text-neutral-400'>
                Homelab integrations: Cloudflare/Technitium DNS, Astracap router NAT and Zitadel login. Per-server DNS and
                port forwards live on each server's DNS and Port Forward tabs.
            </p>
        </MainPageHeader>

        <div className='mb-6 flex flex-wrap items-center gap-1 rounded-xl border border-mocha-400 bg-mocha-500 p-1'>
            {tabs.map((tab) => (
                <NavLink
                    key={tab.to}
                    to={tab.to}
                    end={tab.end}
                    className={({ isActive }) =>
                        cn(
                            'rounded-lg px-3 py-1.5 text-sm transition-colors',
                            isActive
                                ? 'bg-hydro-500/15 font-medium text-hydro-400'
                                : 'text-cream-400/70 hover:bg-mocha-400 hover:text-cream-100',
                        )
                    }
                >
                    {tab.label}
                </NavLink>
            ))}
        </div>

        <Outlet />
    </PageContentBlock>
);

export default ExtensionsLayout;
