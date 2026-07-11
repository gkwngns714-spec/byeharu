import type { SVGAttributes } from 'react'
import { ICON_PATHS, type IconName } from './icons'

// Design-system Icon: the ONE inline-SVG line-icon set (glyph data in ./icons.ts). Strokes with
// `currentColor`, so color always comes from token text utilities on the parent or via className
// (text-accent, text-ink-muted, …) — never per-icon palettes. Decorative by default (aria-hidden);
// spread an explicit aria-label + aria-hidden={false} through rest props when an icon is meaning-bearing.

export function Icon({
  name,
  size = 20,
  className = '',
  ...rest
}: Omit<SVGAttributes<SVGSVGElement>, 'name'> & { name: IconName; size?: number }) {
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
      {ICON_PATHS[name].map((d) => (
        <path key={d} d={d} />
      ))}
    </svg>
  )
}
