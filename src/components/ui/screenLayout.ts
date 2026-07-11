// Design-system Screen scaffold logic — pure (no React) so tests can prove the width-variant
// contract (see tests/uiPrimitives.spec.ts) and react-refresh keeps Screen.tsx component-only.

/** The Screen content column: centered, padded, space-y-4 panel rhythm. `wide` = future desktop two-column width. */
export function screenBodyClass(wide = false): string {
  return `mx-auto ${wide ? 'max-w-6xl' : 'max-w-3xl'} space-y-4 px-4 py-4 sm:px-6`
}
