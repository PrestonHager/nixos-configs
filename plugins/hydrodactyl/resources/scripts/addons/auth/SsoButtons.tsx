import { useEffect, useState } from 'react';
import { get } from '../api';

interface Provider {
    name: string;
    short_name: string;
    url: string;
}

const ERRORS: Record<string, string> = {
    expired: 'The sign-in attempt expired. Please try again.',
    denied: 'Sign-in was cancelled at the identity provider.',
    state: 'The sign-in response did not match this browser session. Please try again.',
    exchange: 'The identity provider could not be reached. Please try again.',
    notconnected: 'No panel account is linked to that identity. Sign in with your password and link it under Account → Linked Accounts.',
};

/** "Sign in with Zitadel" under the login form (plus SSO error messages). */
const SsoButtons = () => {
    const [providers, setProviders] = useState<Provider[]>([]);
    const error = new URLSearchParams(window.location.search).get('sso_error');

    useEffect(() => {
        get<Provider[]>('/extensions/sociallogin/providers')
            .then(setProviders)
            .catch(() => setProviders([]));
    }, []);

    if (providers.length === 0 && !error) return null;

    return (
        <div className='flex flex-col gap-3'>
            {error && (
                <p className='rounded-lg border border-red-500/30 bg-red-500/10 px-3 py-2 text-sm text-red-300'>
                    {ERRORS[error] ?? 'Single sign-on failed.'}
                </p>
            )}
            {providers.length > 0 && (
                <>
                    <div className='flex items-center gap-3 text-xs uppercase tracking-wide text-cream-400/50'>
                        <span className='h-px flex-1 bg-cream-500/10' />
                        or
                        <span className='h-px flex-1 bg-cream-500/10' />
                    </div>
                    {providers.map((p) => (
                        <a
                            key={p.short_name}
                            href={p.url}
                            className='w-full rounded-lg border border-cream-500/20 bg-mocha-400 px-4 py-3 text-center text-sm font-medium text-cream-100 transition-colors hover:bg-mocha-300'
                        >
                            Sign in with {p.name}
                        </a>
                    ))}
                </>
            )}
        </div>
    );
};

export default SsoButtons;
