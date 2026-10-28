/**
 * Small form/layout kit for the addon pages, built on Hydrodactyl's own
 * primitives so they match the rebuilt admin UI.
 */
import type { ReactNode } from 'react';
import { Field } from '@/components/admin/Field';
import Dropdown from '@/components/elements/Dropdown';
import { Input } from '@/components/elements/inputs';
import Spinner from '@/components/elements/Spinner';
import { Switch } from '@/components/elements/SwitchV2';
import { cn } from '@/lib/utils';

export { Field };

export const Section = ({ title, description, actions, children, className }: {
    title?: string;
    description?: ReactNode;
    actions?: ReactNode;
    children: ReactNode;
    className?: string;
}) => (
    <section className={cn('space-y-4 rounded-xl border border-mocha-400 bg-mocha-500 p-4', className)}>
        {(title || actions) && (
            <header className='flex flex-wrap items-start justify-between gap-2'>
                <div>
                    {title && <h2 className='text-base font-semibold text-cream-50'>{title}</h2>}
                    {description && <p className='mt-1 text-xs text-cream-400/60'>{description}</p>}
                </div>
                {actions && <div className='flex flex-wrap gap-2'>{actions}</div>}
            </header>
        )}
        {children}
    </section>
);

export const Grid = ({ children }: { children: ReactNode }) => (
    <div className='grid grid-cols-1 gap-4 md:grid-cols-2'>{children}</div>
);

export const Text = ({ value, onChange, ...props }: {
    value: string | number | null | undefined;
    onChange: (value: string) => void;
} & Omit<React.ComponentProps<'input'>, 'value' | 'onChange'>) => (
    <Input.Text value={value ?? ''} onChange={(e) => onChange(e.target.value)} {...props} />
);

export const NumberInput = ({ value, onChange, ...props }: {
    value: number | null | undefined;
    onChange: (value: number) => void;
} & Omit<React.ComponentProps<'input'>, 'value' | 'onChange' | 'type'>) => (
    <Input.Text type='number' value={value ?? ''} onChange={(e) => onChange(Number(e.target.value))} {...props} />
);

export const Area = ({ value, onChange, rows = 4, className, ...props }: {
    value: string | null | undefined;
    onChange: (value: string) => void;
    rows?: number;
} & Omit<React.ComponentProps<'textarea'>, 'value' | 'onChange'>) => (
    <textarea
        rows={rows}
        value={value ?? ''}
        onChange={(e) => onChange(e.target.value)}
        className={cn('w-full rounded-lg border-0 bg-overlay/7 px-4 py-2 font-mono text-xs text-primary outline-none', className)}
        {...props}
    />
);

export const Toggle = ({ label, hint, checked, onChange, disabled }: {
    label: string;
    hint?: string;
    checked: boolean;
    onChange: (value: boolean) => void;
    disabled?: boolean;
}) => (
    <label className='flex items-start justify-between gap-4 rounded-lg bg-mocha-400/40 px-3 py-2'>
        <span>
            <span className='block text-sm text-cream-100'>{label}</span>
            {hint && <span className='block text-xs text-cream-400/50'>{hint}</span>}
        </span>
        <Switch checked={checked} onCheckedChange={onChange} disabled={disabled} />
    </label>
);

export const Select = ({ value, onChange, options }: {
    value: string;
    onChange: (value: string) => void;
    options: Array<string | { value: string; label: string }>;
}) => (
    <Dropdown
        value={value}
        onChange={onChange}
        options={options.map((o) => (typeof o === 'string' ? { value: o, label: o } : o))}
    />
);

export const Loading = () => (
    <div className='flex items-center justify-center py-16'>
        <Spinner centered size={Spinner.Size.LARGE} />
    </div>
);

export const Notice = ({ tone = 'info', children }: { tone?: 'info' | 'warn' | 'error'; children: ReactNode }) => (
    <div
        className={cn(
            'rounded-lg border px-3 py-2 text-sm',
            tone === 'info' && 'border-hydro-500/30 bg-hydro-500/10 text-hydro-300',
            tone === 'warn' && 'border-yellow-500/30 bg-yellow-500/10 text-yellow-200',
            tone === 'error' && 'border-red-500/30 bg-red-500/10 text-red-300',
        )}
    >
        {children}
    </div>
);

export const Badge = ({ tone = 'muted', children }: { tone?: 'ok' | 'muted' | 'warn' | 'bad'; children: ReactNode }) => (
    <span
        className={cn(
            'rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase',
            tone === 'ok' && 'bg-hydro-500/20 text-hydro-400',
            tone === 'muted' && 'bg-mocha-300 text-cream-400',
            tone === 'warn' && 'bg-yellow-500/20 text-yellow-300',
            tone === 'bad' && 'bg-red-500/20 text-red-300',
        )}
    >
        {children}
    </span>
);

export const Table = ({ head, children, empty }: { head: ReactNode[]; children: ReactNode; empty?: string | false }) => (
    <div className='overflow-x-auto rounded-xl border border-mocha-400'>
        <table className='w-full text-sm'>
            <thead className='text-left text-xs uppercase tracking-wide text-cream-400/60'>
                <tr className='border-b border-mocha-400'>
                    {head.map((h, i) => (
                        <th key={i} className='px-4 py-3'>
                            {h}
                        </th>
                    ))}
                </tr>
            </thead>
            <tbody>
                {children}
                {empty && (
                    <tr>
                        <td colSpan={head.length} className='px-4 py-6 text-center text-cream-400/50'>
                            {empty}
                        </td>
                    </tr>
                )}
            </tbody>
        </table>
    </div>
);

export const Td = ({ children, className }: { children?: ReactNode; className?: string }) => (
    <td className={cn('px-4 py-3 align-top', className)}>{children}</td>
);
