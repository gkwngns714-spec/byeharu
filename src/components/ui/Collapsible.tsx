import { useId, useState, type ReactNode } from 'react'
import { Card, type CardTone } from './Card'
import { Icon } from './Icon'
import { foldStateValue, foldStorageKey, readFoldState } from './collapsibleState'

// Design-system Collapsible — the ONE disclosure implementation (owner order 2026-08-03:
// "combat report, mission report, … separate them and make it foldable"). Every fold in the app
// composes THIS: a real <button> header (native Enter/Space keyboard activation) carrying
// aria-expanded + aria-controls, a chevron that rotates open, and a stable content region whose
// children unmount while closed. Never hand-roll a show/hide button + conditional div again —
// that is the pattern this file retires (the old ReportsSection row/round-log toggles).
//
// TWO STATE MODES, one component:
//   · UNCONTROLLED — the default. Pass `defaultOpen` (and optionally `storageKey` to remember the
//     player's choice across remounts/sessions via localStorage — see collapsibleState.ts for the
//     key convention and why storage keys must be STABLE SECTION ids, never per-row ids).
//   · CONTROLLED — pass `open` + `onToggle` when the parent owns the state (e.g. ReportsSection's
//     "newest report open by default" policy, or a fold whose opening triggers a fetch).
//
// The header button must contain NO interactive children (a nested button is invalid HTML —
// the TeamRosterPanel row lesson). Put actions in the content, or outside the Collapsible.

export function Collapsible({
  header,
  open: controlledOpen,
  onToggle,
  defaultOpen = true,
  storageKey,
  headerClassName = '',
  contentClassName = '',
  chevronSize = 16,
  'data-testid': testId,
  children,
}: {
  /** Non-interactive header content rendered inside the toggle button (the chevron is appended). */
  header: ReactNode
  /** Controlled open state — when set, the component never keeps (or persists) its own. */
  open?: boolean
  /** Called with the NEXT state on every toggle (controlled callers flip their state here). */
  onToggle?: (open: boolean) => void
  /** Uncontrolled initial state (overridden by a persisted value when storageKey is set). */
  defaultOpen?: boolean
  /** Stable section id to persist the player's choice under (uncontrolled mode only). */
  storageKey?: string
  headerClassName?: string
  contentClassName?: string
  chevronSize?: number
  'data-testid'?: string
  children: ReactNode
}) {
  const contentId = useId()
  // Lazy initializer: the persisted value is read ONCE per mount (localStorage is not reactive).
  // The try/catch lives in collapsibleState.readFoldState — a private-mode storage throw falls
  // back to defaultOpen, never a crash.
  const [uncontrolledOpen, setUncontrolledOpen] = useState<boolean>(() =>
    storageKey === undefined
      ? defaultOpen
      : readFoldState((k) => window.localStorage.getItem(k), storageKey, defaultOpen),
  )
  const open = controlledOpen ?? uncontrolledOpen

  const toggle = () => {
    const next = !open
    if (controlledOpen === undefined) {
      setUncontrolledOpen(next)
      if (storageKey !== undefined) {
        try {
          window.localStorage.setItem(foldStorageKey(storageKey), foldStateValue(next))
        } catch {
          /* storage unavailable (private mode/quota) — the in-memory state still flipped */
        }
      }
    }
    onToggle?.(next)
  }

  return (
    <div data-testid={testId}>
      <button
        type="button"
        aria-expanded={open}
        aria-controls={contentId}
        onClick={toggle}
        data-testid={testId ? `${testId}-toggle` : undefined}
        className={`flex w-full items-center justify-between gap-3 text-left ${headerClassName}`}
      >
        {header}
        <Icon
          name="chevron"
          size={chevronSize}
          className={`shrink-0 text-ink-faint transition-transform ${open ? 'rotate-90' : ''}`}
        />
      </button>
      {/* The region element always exists (aria-controls stays valid either way); the CHILDREN
          unmount while closed, so a folded section does no rendering work. */}
      <div id={contentId} data-testid={testId ? `${testId}-content` : undefined}>
        {open ? <div className={contentClassName}>{children}</div> : null}
      </div>
    </div>
  )
}

/** Panel-level fold: a Card whose whole header row (CardHeader-styled title/subtitle) is the
 *  toggle. The common case for screen sections (Reports). `aside` renders on the right of the
 *  header INSIDE the button — badges/counts only, never anything interactive. */
export function CollapsibleCard({
  title,
  subtitle,
  aside,
  tone,
  defaultOpen = true,
  storageKey,
  className = '',
  'data-testid': testId,
  children,
}: {
  title: ReactNode
  subtitle?: ReactNode
  /** Non-interactive header aside (badge/count) — it sits inside the toggle button. */
  aside?: ReactNode
  tone?: CardTone
  defaultOpen?: boolean
  storageKey?: string
  className?: string
  'data-testid'?: string
  children: ReactNode
}) {
  return (
    <Card tone={tone} className={className} data-testid={testId}>
      <Collapsible
        defaultOpen={defaultOpen}
        storageKey={storageKey}
        data-testid={testId ? `${testId}-fold` : undefined}
        contentClassName="mt-3"
        header={
          <span className="flex min-w-0 flex-1 items-start justify-between gap-3">
            <span className="min-w-0">
              <span className="block text-lg font-semibold text-ink">{title}</span>
              {subtitle && <span className="mt-0.5 block text-sm text-ink-muted">{subtitle}</span>}
            </span>
            {aside && <span className="shrink-0">{aside}</span>}
          </span>
        }
      >
        {children}
      </Collapsible>
    </Card>
  )
}
