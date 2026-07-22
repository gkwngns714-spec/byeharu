// WORLD EDITOR — V5: the entity SEARCH BOX (shell UI). A read-only NAVIGATION control: type a name,
// pick a result, and the shell SELECTS that entity (its existing `selected` model) and JUMPS the
// camera to it. It owns ZERO domain knowledge and ZERO camera math — it calls the pure
// worldEditorSearch authority (searchEntities) and hands the chosen match back through onSelect; the
// shell applies entityNavigation. Results are grouped/labeled by domain via the ONE layer registry
// (adapter.title), so there is no parallel domain list here. No writes, no drafts, no RPC.
import { useMemo, useRef, useState, type KeyboardEvent } from 'react'
import { WORLD_EDITOR_LAYERS } from './worldEditorRegistry'
import { searchEntities, type EntityMatch } from './worldEditorSearch'
import type { LayerId, LayerItem } from './worldEditorTypes'

/** Domain display labels — DERIVED from the ONE registry (adapter.id → adapter.title), never a
 *  second hand-maintained map. Registry order is also the group order. */
const DOMAIN_ORDER: readonly LayerId[] = WORLD_EDITOR_LAYERS.map((e) => e.adapter.id)
const DOMAIN_TITLE: Record<LayerId, string> = Object.fromEntries(
  WORLD_EDITOR_LAYERS.map((e) => [e.adapter.id, e.adapter.title]),
) as Record<LayerId, string>

interface Props {
  readonly itemsByLayer: ReadonlyMap<LayerId, readonly LayerItem[]>
  readonly onSelect: (match: EntityMatch) => void
}

export function WorldEditorSearchBox({ itemsByLayer, onSelect }: Props) {
  const [query, setQuery] = useState('')
  const [active, setActive] = useState(0) // highlighted index into the DISPLAY-ordered flat list
  const [open, setOpen] = useState(false)
  const inputRef = useRef<HTMLInputElement | null>(null)

  const matches = useMemo(() => searchEntities(itemsByLayer, query), [itemsByLayer, query])

  // Display order: registry-domain order, ranked matches within each domain (so arrow-key traversal
  // and the grouped render share one index space). Groups with no matches are dropped.
  const groups = useMemo(() => {
    const byDomain = new Map<LayerId, EntityMatch[]>()
    for (const m of matches) {
      const list = byDomain.get(m.domain)
      if (list) list.push(m)
      else byDomain.set(m.domain, [m])
    }
    return DOMAIN_ORDER.filter((d) => byDomain.has(d)).map((d) => ({
      domain: d,
      title: DOMAIN_TITLE[d],
      matches: byDomain.get(d)!,
    }))
  }, [matches])

  const flat = useMemo(() => groups.flatMap((g) => g.matches), [groups])
  const showResults = open && query.trim() !== ''

  const commit = (match: EntityMatch) => {
    onSelect(match)
    setQuery('')
    setActive(0)
    setOpen(false)
    inputRef.current?.blur()
  }

  const onKeyDown = (e: KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Escape') {
      setQuery('')
      setOpen(false)
      return
    }
    if (flat.length === 0) return
    if (e.key === 'ArrowDown') {
      e.preventDefault()
      setActive((i) => (i + 1) % flat.length)
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      setActive((i) => (i - 1 + flat.length) % flat.length)
    } else if (e.key === 'Enter') {
      e.preventDefault()
      const pick = flat[Math.min(active, flat.length - 1)]
      if (pick) commit(pick)
    }
  }

  // A stable per-match key + its flat display index (for highlight + click).
  const indexOf = (domain: LayerId, id: string) => flat.findIndex((m) => m.domain === domain && m.id === id)

  return (
    <section className="rounded-card border border-edge bg-surface p-3">
      <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-ink-muted">Search</div>
      <div className="relative">
        <input
          ref={inputRef}
          value={query}
          onChange={(e) => {
            setQuery(e.target.value)
            setActive(0)
            setOpen(true)
          }}
          onFocus={() => setOpen(true)}
          onKeyDown={onKeyDown}
          placeholder="Find any location, mining field, or zone by name…"
          aria-label="Search world entities by name"
          className="w-full rounded-lg border border-edge bg-surface-2 px-2 py-1 text-sm text-ink"
          data-testid="worldeditor-search-input"
        />

        {showResults &&
          (flat.length === 0 ? (
            <p className="mt-2 text-xs text-ink-faint" data-testid="worldeditor-search-empty">
              No entities match “{query.trim()}”.
            </p>
          ) : (
            <ul
              className="mt-2 max-h-72 overflow-y-auto rounded-lg border border-edge bg-surface-2"
              data-testid="worldeditor-search-results"
              role="listbox"
            >
              {groups.map((g) => (
                <li key={g.domain}>
                  <div className="sticky top-0 bg-surface-2 px-2 py-1 text-[11px] font-semibold uppercase tracking-wide text-ink-faint">
                    {g.title}
                  </div>
                  <ul>
                    {g.matches.map((m) => {
                      const idx = indexOf(m.domain, m.id)
                      const isActive = idx === active
                      return (
                        <li key={`${m.domain}:${m.id}`} role="option" aria-selected={isActive}>
                          <button
                            type="button"
                            // pointer-down (not click) so the input's blur doesn't close the list first
                            onMouseDown={(e) => {
                              e.preventDefault()
                              commit(m)
                            }}
                            onMouseEnter={() => setActive(idx)}
                            className={`flex w-full items-center justify-between gap-2 px-3 py-1.5 text-left text-sm ${
                              isActive ? 'bg-accent-soft text-ink' : 'text-ink-muted'
                            }`}
                          >
                            <span className="truncate">{m.name}</span>
                          </button>
                        </li>
                      )
                    })}
                  </ul>
                </li>
              ))}
            </ul>
          ))}
      </div>
      <p className="mt-1.5 text-xs text-ink-faint">
        Selects the entity and frames the camera on it. Navigation only — nothing is written.
      </p>
    </section>
  )
}
