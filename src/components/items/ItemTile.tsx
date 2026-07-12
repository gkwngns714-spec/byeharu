import type { HTMLAttributes, ReactNode, SVGAttributes } from 'react'
import { CATEGORY_TONE, getItemGlyph, itemLabel, type ItemKind } from './itemGlyphs'

// ITEM-VIZ — the "displayable tablet" for every item/good/module/resource, in two densities:
//   · <ItemTile>  — a small Card-like grid tile (inventories, hangars, recipe grids): the glyph in
//                   a category-tinted rounded square + humanized name + mono qty + optional hint.
//   · <ItemChip>  — the inline compact form (loot lines, recipe costs, reward strings): tiny glyph
//                   + name + mono ×qty, font-size inherited from the surrounding text.
//   · <ItemGlyph> — the bare 24×24 currentColor SVG (the Icon.tsx contract) when a surface only
//                   needs the mark (e.g. beside an existing title row).
//
// Tokens only (category tones come from CATEGORY_TONE — never raw colors). Both densities carry
// machine-readable data-item-id / data-qty attributes and a default data-testid
// (`item-tile-<id>` / `item-chip-<id>`), overridable via rest props (the Card convention).
// Unknown ids degrade to the honest generic glyph + title-case label — never a crash.

export function ItemGlyph({
  id,
  kind,
  size = 16,
  className = '',
  ...rest
}: Omit<SVGAttributes<SVGSVGElement>, 'id'> & { id: string; kind?: ItemKind; size?: number }) {
  const { paths } = getItemGlyph(id, kind)
  return (
    <svg
      viewBox="0 0 24 24"
      width={size}
      height={size}
      fill="none"
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      className={className}
      {...rest}
    >
      {paths.map((p) => (
        <path key={p.d} d={p.d} opacity={p.soft ? 0.45 : undefined} />
      ))}
    </svg>
  )
}

/** Grid-density tablet: tinted glyph square + name + mono qty (+ optional hint line). */
export function ItemTile({
  id,
  kind,
  qty,
  label,
  hint,
  className = '',
  ...rest
}: Omit<HTMLAttributes<HTMLDivElement>, 'id'> & {
  id: string
  kind?: ItemKind
  qty?: number
  /** Display-name override (e.g. a server-provided name); defaults to itemLabel(id, kind). */
  label?: string
  hint?: ReactNode
}) {
  const { category } = getItemGlyph(id, kind)
  return (
    <div
      data-testid={`item-tile-${id}`}
      data-item-id={id}
      data-qty={qty}
      className={`flex items-center gap-2.5 rounded-lg border border-edge/60 bg-surface-2/40 px-2.5 py-2 ${className}`}
      {...rest}
    >
      <span
        className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-lg ${CATEGORY_TONE[category].tile}`}
      >
        <ItemGlyph id={id} kind={kind} size={22} />
      </span>
      <span className="min-w-0 flex-1">
        <span className="flex items-baseline justify-between gap-2">
          <span className="truncate text-xs font-medium text-ink">{label ?? itemLabel(id, kind)}</span>
          {qty != null && (
            <span className="shrink-0 font-mono text-xs tabular-nums text-ink-muted">
              ×{qty.toLocaleString()}
            </span>
          )}
        </span>
        {hint != null && <span className="block truncate text-[10px] text-ink-faint">{hint}</span>}
      </span>
    </div>
  )
}

/** Inline-density tablet: tiny glyph + name + mono ×qty (+ optional faint hint). Inherits the
 *  surrounding font size, so it sits inside dense loot lines and log sentences. `alert` renders
 *  the whole chip in the danger tone (e.g. a lacking recipe ingredient). */
export function ItemChip({
  id,
  kind,
  qty,
  label,
  hint,
  alert = false,
  className = '',
  ...rest
}: Omit<HTMLAttributes<HTMLSpanElement>, 'id'> & {
  id: string
  kind?: ItemKind
  qty?: number
  label?: string
  hint?: ReactNode
  alert?: boolean
}) {
  const { category } = getItemGlyph(id, kind)
  return (
    <span
      data-testid={`item-chip-${id}`}
      data-item-id={id}
      data-qty={qty}
      className={`inline-flex max-w-full items-center gap-1 rounded border border-edge/60 bg-surface-2/60 px-1.5 py-0.5 align-middle ${className}`}
      {...rest}
    >
      <ItemGlyph
        id={id}
        kind={kind}
        size={12}
        className={`shrink-0 ${alert ? 'text-danger' : CATEGORY_TONE[category].text}`}
      />
      <span className={`truncate ${alert ? 'text-danger' : 'text-ink'}`}>
        {label ?? itemLabel(id, kind)}
      </span>
      {qty != null && (
        <span className={`shrink-0 font-mono tabular-nums ${alert ? 'text-danger' : 'text-ink-muted'}`}>
          ×{qty.toLocaleString()}
        </span>
      )}
      {hint != null && <span className="shrink-0 text-ink-faint">({hint})</span>}
    </span>
  )
}
