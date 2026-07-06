import type { HTMLAttributes, ReactNode } from 'react'

// Design-system label/value stat row (render inside a <dl>). THE one chrome for the
// "Label · value" detail idiom — Ship uses it first; Port/Command/Map detail lists adopt it in
// their interior slices (each currently carries a local Row/Fact copy of this exact pattern).
// Spreads rest props (the Card convention) so data-testid / aria-* pass through untouched.

export function StatRow({
  label,
  value,
  hint,
  className = '',
  ...rest
}: Omit<HTMLAttributes<HTMLDivElement>, 'children'> & { label: ReactNode; value: ReactNode; hint?: ReactNode }) {
  return (
    <div className={`flex items-baseline justify-between gap-3 ${className}`} {...rest}>
      <dt className="text-ink-faint">{label}</dt>
      <dd className="text-right text-ink">
        {value}
        {hint && <span className="text-ink-faint"> {hint}</span>}
      </dd>
    </div>
  )
}
