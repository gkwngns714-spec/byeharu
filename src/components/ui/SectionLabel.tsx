import type { ReactNode } from 'react'

// Design-system micro section label (the uppercase group heading used inside panels).

export function SectionLabel({ children, className = '' }: { children: ReactNode; className?: string }) {
  return <h3 className={`mb-2 text-xs uppercase tracking-wide text-ink-faint ${className}`}>{children}</h3>
}
