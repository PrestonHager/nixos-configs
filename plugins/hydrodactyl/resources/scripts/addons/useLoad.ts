import { useCallback, useEffect, useState } from 'react';
import { addonError } from './api';

/**
 * Load JSON once (and on demand via reload). Keeps the last good data while
 * reloading so forms don't flash.
 */
export function useLoad<T>(loader: () => Promise<T>, deps: unknown[] = []) {
    const [data, setData] = useState<T>();
    const [error, setError] = useState<string>();
    const [loading, setLoading] = useState(true);

    // biome-ignore lint/correctness/useExhaustiveDependencies: deps are the caller's
    const reload = useCallback(async () => {
        setLoading(true);
        try {
            const result = await loader();
            setData(result);
            setError(undefined);
            return result;
        } catch (e) {
            setError(addonError(e));
            return undefined;
        } finally {
            setLoading(false);
        }
    }, deps);

    useEffect(() => {
        void reload();
    }, [reload]);

    return { data, setData, error, loading, reload };
}
