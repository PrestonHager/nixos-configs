import { lazy, Suspense } from 'react';
import { NavLink, Route, Routes } from 'react-router-dom';
import ServerContentBlock from '@/components/elements/ServerContentBlock';
import { MainPageHeader } from '@/components/elements/MainPageHeader';
import { cn } from '@/lib/utils';
import { ServerContext } from '@/state/server';
import { Loading } from '../ui';

const VersionsTab = lazy(() => import('./mc/VersionsTab'));
const AddonsTab = lazy(() => import('./mc/AddonsTab'));
const PlayersTab = lazy(() => import('./mc/PlayersTab'));
const PropertiesTab = lazy(() => import('./mc/PropertiesTab'));
const IconTab = lazy(() => import('./mc/IconTab'));
const ModpacksTab = lazy(() => import('./mc/ModpacksTab'));

const tabs = [
    { path: '', label: 'Version', element: <VersionsTab /> },
    { path: 'addons', label: 'Plugins & Mods', element: <AddonsTab /> },
    { path: 'players', label: 'Players', element: <PlayersTab /> },
    { path: 'properties', label: 'server.properties', element: <PropertiesTab /> },
    { path: 'icon', label: 'Server icon', element: <IconTab /> },
    { path: 'modpacks', label: 'Modpacks', element: <ModpacksTab /> },
];

const MinecraftContainer = () => {
    const id = ServerContext.useStoreState((state) => state.server.data?.id);
    const base = `/server/${id}/minecraft`;

    return (
        <ServerContentBlock title='Minecraft'>
            <MainPageHeader direction='column' title='Minecraft'>
                <p className='text-sm text-neutral-400'>Version, plugins and mods, players, settings and the server icon.</p>
            </MainPageHeader>

            <div className='mb-6 flex flex-wrap items-center gap-1 rounded-xl border border-mocha-400 bg-mocha-500 p-1'>
                {tabs.map((tab) => (
                    <NavLink
                        key={tab.path}
                        to={tab.path ? `${base}/${tab.path}` : base}
                        end
                        className={({ isActive }) =>
                            cn(
                                'rounded-lg px-3 py-1.5 text-sm transition-colors',
                                isActive ? 'bg-hydro-500/15 font-medium text-hydro-400' : 'text-cream-400/70 hover:bg-mocha-400 hover:text-cream-100',
                            )
                        }
                    >
                        {tab.label}
                    </NavLink>
                ))}
            </div>

            <Suspense fallback={<Loading />}>
                <Routes>
                    {tabs.map((tab) => (
                        <Route key={tab.path} path={tab.path} element={tab.element} />
                    ))}
                </Routes>
            </Suspense>
        </ServerContentBlock>
    );
};

export default MinecraftContainer;
