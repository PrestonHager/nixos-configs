import { useCallback } from 'react';
import { ServerContext } from '@/state/server';
import { serverApi } from '../../api';

/** Base URL for this server's Minecraft API (stable between renders). */
export const useMcApi = () => {
    const uuid = ServerContext.useStoreState((state) => state.server.data?.uuid) ?? '';
    const url = useCallback((path = '') => serverApi(uuid, `/minecraft${path}`), [uuid]);

    return { uuid, url };
};

export const LOADER_NAMES: Record<string, string> = {
    paper: 'Paper',
    purpur: 'Purpur',
    fabric: 'Fabric',
    neoforge: 'NeoForge',
    forge: 'Forge',
    vanilla: 'Vanilla',
};

export interface VersionVariable {
    value: string | null;
    editable: boolean;
    rules: string;
}
