import type { ButtonHTMLAttributes } from 'react'

// Design-system Button. Consumes tokens only (see src/index.css @theme + README.md).
// `buttonClasses` is exported so router <Link>s can wear the exact same skin without a wrapper.

export type ButtonVariant = 'primary' | 'secondary' | 'ghost' | 'danger' | 'warning'
export type ButtonSize = 'sm' | 'md'

const VARIANT: Record<ButtonVariant, string> = {
  // Filled variants put dark app-colored text on the bright token fill (~8:1 contrast).
  primary: 'bg-accent text-app font-medium hover:bg-accent-hover',
  secondary: 'border border-edge bg-surface-2 text-ink hover:border-ink-faint/60',
  ghost: 'text-ink-muted hover:bg-surface-2 hover:text-ink',
  danger: 'bg-danger text-app font-medium hover:bg-danger-hover',
  warning: 'bg-warning text-app font-medium hover:bg-warning-hover',
}

const SIZE: Record<ButtonSize, string> = {
  sm: 'px-3 py-1 text-xs',
  md: 'px-4 py-2 text-sm',
}

export function buttonClasses(variant: ButtonVariant = 'secondary', size: ButtonSize = 'md', extra = ''): string {
  return [
    'inline-flex items-center justify-center gap-2 rounded-lg transition',
    'disabled:cursor-not-allowed disabled:opacity-45',
    VARIANT[variant],
    SIZE[size],
    extra,
  ]
    .filter(Boolean)
    .join(' ')
}

export function Button({
  variant = 'secondary',
  size = 'md',
  busy = false,
  busyLabel,
  className = '',
  children,
  disabled,
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: ButtonVariant
  size?: ButtonSize
  // Loading state: disables the button and swaps the label (the caller keeps its own phase state).
  busy?: boolean
  busyLabel?: string
}) {
  return (
    <button type="button" disabled={disabled || busy} className={buttonClasses(variant, size, className)} {...rest}>
      {busy ? (busyLabel ?? children) : children}
    </button>
  )
}
