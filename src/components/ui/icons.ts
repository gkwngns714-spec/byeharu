// Design-system icon glyphs — the ONE inline-SVG set (UI R0, Mission Control). Pure data
// (no React) so tests can prove the name→glyph contract (see tests/uiPrimitives.spec.ts).
// Every glyph is 1.5px-stroke line work on a 24×24 viewBox, drawn with `currentColor` by
// <Icon> so it always wears token colors (text-accent, text-ink-muted, …) — never raw hex.

export const ICON_NAMES = [
  'map',
  'ship',
  'anchor',
  'command',
  'combat',
  'repair',
  'compass',
  'chevron',
  'close',
  'plus',
  'layers',
  'search',
  'info',
  'edit',
  'history',
] as const

export type IconName = (typeof ICON_NAMES)[number]

/** SVG path `d` strings per glyph (one or more subpaths, all stroked, fill none). */
export const ICON_PATHS: Record<IconName, readonly string[]> = {
  // Folded chart — the Map destination.
  map: ['M9 4 3.5 6v14L9 18l6 2 5.5-2V4L15 6 9 4Z', 'M9 4v14', 'M15 6v14'],
  // Nose-up rocket — the Ship destination.
  ship: [
    'M12 2.5C14.7 4.8 16 8 16 11.5V15H8v-3.5C8 8 9.3 4.8 12 2.5Z',
    'M8 11.5 5.5 14.5V18L8 16.5',
    'M16 11.5l2.5 3V18L16 16.5',
    'M12 7.3a1.7 1.7 0 1 0 0 3.4 1.7 1.7 0 0 0 0-3.4Z',
    'M10.5 18c0 1.4.5 2.4 1.5 3.5 1-1.1 1.5-2.1 1.5-3.5',
  ],
  // Anchor — the Port destination.
  anchor: [
    'M12 7.5V21',
    'M12 2.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5Z',
    'M5 13H2a10 10 0 0 0 20 0h-3',
    'M8.5 10.5h7',
  ],
  // Radar sweep — the Command destination (ops console).
  command: ['M12 3a9 9 0 1 0 9 9', 'M12 7.5A4.5 4.5 0 1 0 16.5 12', 'M18.4 5.6 12 12'],
  // Crosshair — combat / targeting.
  combat: [
    'M12 5.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13Z',
    'M12 2v3.5',
    'M12 18.5V22',
    'M2 12h3.5',
    'M18.5 12H22',
  ],
  // Wrench — repair / maintenance.
  repair: [
    'M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76Z',
  ],
  // Compass — navigation / heading.
  compass: [
    'M12 2.5a9.5 9.5 0 1 0 0 19 9.5 9.5 0 0 0 0-19Z',
    'm15.5 8.5-2 5-5 2 2-5 5-2Z',
  ],
  // Chevron (points right; rotate via className for other directions).
  chevron: ['m9 5 7 7-7 7'],
  // Close / dismiss.
  close: ['M6 6l12 12', 'M18 6 6 18'],
  // Plus / add.
  plus: ['M12 5v14', 'M5 12h14'],
  // Stacked sheets — map layer visibility.
  layers: ['M12 3 3 7.5l9 4.5 9-4.5L12 3Z', 'M3 12.5 12 17l9-4.5', 'M3 17 12 21.5 21 17'],
  // Magnifier — find / search.
  search: ['M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14Z', 'm16.2 16.2 4.3 4.3'],
  // Circled i — details / inspector.
  info: ['M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18Z', 'M12 11v5.5', 'M12 7.6v.9'],
  // Pencil — authoring / drafts.
  edit: ['M4 20h4L19.5 8.5a2.1 2.1 0 0 0-3-3L5 17v3Z', 'm14.5 6.5 3 3'],
  // Clock with a back-arrow tick — the audit history.
  history: ['M12 3a9 9 0 1 0 9 9', 'M12 3 8.5 5.5 12 8', 'M12 7.5V12l3.5 2.5'],
}
