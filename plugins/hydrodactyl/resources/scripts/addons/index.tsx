/**
 * Homelab addons (DNS records, router port forwarding, Zitadel SSO, Minecraft
 * tools). Core files only import from here, so the patch that wires this in
 * stays a handful of lines; see plugins/hydrodactyl/patches.
 */
import { CubeIcon, Link01Icon, PuzzleIcon } from '@hugeicons/core-free-icons';
import type { IconSvgElement } from '@hugeicons/react';
import { lazy, type RefObject, useMemo, useRef } from 'react';
import { Route } from 'react-router-dom';
import type { RouteDefinition, ServerRouteDefinition } from '@/routers/routes';

const ExtensionsLayout = lazy(() => import('./admin/ExtensionsLayout'));
const DnsSettings = lazy(() => import('./admin/DnsSettings'));
const PortForwardSettings = lazy(() => import('./admin/PortForwardSettings'));
const SsoSettings = lazy(() => import('./admin/SsoSettings'));
const ServerDnsContainer = lazy(() => import('./admin/ServerDnsContainer'));
const ServerPortForwardContainer = lazy(() => import('./admin/ServerPortForwardContainer'));
const MinecraftContainer = lazy(() => import('./server/MinecraftContainer'));
const LinkedAccountsContainer = lazy(() => import('./account/LinkedAccountsContainer'));

export { default as SsoButtons } from './auth/SsoButtons';

// Every Minecraft egg we run advertises the EULA feature.
export const isMinecraft = (eggFeatures: string[] | undefined) => (eggFeatures ?? []).includes('eula');

interface NavItem {
    to: string;
    icon: IconSvgElement;
    text: string;
    tabName: string;
    ref: RefObject<HTMLAnchorElement | null>;
    end: boolean;
    permission?: string | string[];
}

/**
 * Wraps UnifiedRouter's sidebar items: adds "Minecraft" on Minecraft servers
 * and "Linked Accounts" on account pages.
 */
export function useAddonNav<T>(
    core: T[],
    { isServerRoute, id, eggFeatures }: { isServerRoute: boolean; id?: string; eggFeatures?: string[] },
): T[] {
    const minecraft = useRef<HTMLAnchorElement>(null);
    const linked = useRef<HTMLAnchorElement>(null);
    const showMinecraft = isServerRoute && !!id && isMinecraft(eggFeatures);

    return useMemo(() => {
        const extra: NavItem[] = [];
        if (showMinecraft) {
            extra.push({ to: `/server/${id}/minecraft`, icon: CubeIcon, text: 'Minecraft', tabName: 'minecraft', ref: minecraft, end: false, permission: 'file.*' });
        } else if (!isServerRoute) {
            extra.push({ to: '/account/linked-accounts', icon: Link01Icon, text: 'Linked Accounts', tabName: 'linked-accounts', ref: linked, end: true });
        }

        if (extra.length === 0 || core.length === 0) return core;

        // Keep the core "Settings" item last on account pages.
        return isServerRoute ? [...core, ...(extra as T[])] : [...core.slice(0, -1), ...(extra as T[]), ...core.slice(-1)];
    }, [core, showMinecraft, isServerRoute, id]);
}

/** Admin sidebar entry, spread into AdminApp's navItems. */
export const useAddonAdminNav = () => {
    const ref = useRef<HTMLAnchorElement>(null);

    return [{ to: '/extensions', icon: PuzzleIcon, text: 'Extensions', tabName: 'extensions', ref, end: false }];
};

/** Top-level admin routes (inside AdminApp's <Routes>). */
export const addonAdminRoutes = () => (
    <Route key='addons-extensions' path='/extensions' element={<ExtensionsLayout />}>
        <Route index element={<DnsSettings />} />
        <Route path='port-forward' element={<PortForwardSettings />} />
        <Route path='sso' element={<SsoSettings />} />
    </Route>
);

/** Extra tabs under /admin/servers/:id (inside its <Route>). */
export const addonAdminServerRoutes = () => [
    <Route key='addons-dns' path='dns' element={<ServerDnsContainer />} />,
    <Route key='addons-port-forward' path='port-forward' element={<ServerPortForwardContainer />} />,
];

export const addonAdminServerTabs = (base: string) => [
    { label: 'DNS', to: `${base}/dns`, end: false },
    { label: 'Port Forward', to: `${base}/port-forward`, end: false },
];

/** Client server routes, appended to routes.server (nav comes from useAddonNav). */
export const addonServerRoutes: ServerRouteDefinition[] = [
    {
        route: 'minecraft/*',
        permission: 'file.*',
        name: undefined,
        component: MinecraftContainer,
        isSubRoute: true,
    },
];

/** Account pages, appended to routes.account. */
export const addonAccountRoutes: RouteDefinition[] = [
    { route: 'linked-accounts', path: 'linked-accounts', name: 'Linked Accounts', component: LinkedAccountsContainer },
];
