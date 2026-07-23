// WORLD EDITOR — V5: the COORDINATE JUMP control (shell UI). The sibling of the entity SEARCH box: two
// small number inputs (X, Y) + a "Go" button (Enter submits from either field). A read-only NAVIGATION
// control — it owns ZERO camera math and ZERO bounds rule: it calls the pure worldEditorGoto authority
// (gotoCamera) and, on a valid in-bounds point, hands the resulting Camera back through onGoto; the
// shell applies it with the SAME setView path the search jump uses. An invalid coordinate (non-numeric
// or outside ±10000) shows an inline hint and performs NO navigation. No writes, no drafts, no RPC.
import { useState, type KeyboardEvent } from 'react'
import { WORLD_MAX, WORLD_MIN } from '../map/openSpaceTransform'
import { gotoCamera } from './worldEditorGoto'
import type { Camera } from '../map/galaxyCamera'

interface Props {
  readonly onGoto: (camera: Camera) => void
}

/** Empty/whitespace → NaN (rejected as not-finite) rather than Number('')===0 silently jumping to an
 *  axis. Anything else defers to Number() so "abc"/"1,2" become NaN and gotoCamera rejects them. */
const parse = (s: string): number => (s.trim() === '' ? Number.NaN : Number(s))

export function WorldEditorGotoBox({ onGoto }: Props) {
  const [x, setX] = useState('')
  const [y, setY] = useState('')
  const [hint, setHint] = useState<string | null>(null)

  const submit = () => {
    const result = gotoCamera(parse(x), parse(y))
    if (!result.ok) {
      setHint(
        result.reason === 'out-of-bounds'
          ? `Coordinates must be within ${WORLD_MIN} to ${WORLD_MAX} on both axes.`
          : 'Enter numeric X and Y coordinates.',
      )
      return
    }
    setHint(null)
    onGoto(result.camera)
  }

  const onKeyDown = (e: KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') {
      e.preventDefault()
      submit()
    }
  }

  const inputClass =
    'w-full rounded-lg border border-edge bg-surface-2 px-2 py-1 text-sm text-ink'

  return (
    <section className="rounded-card border border-edge bg-surface p-3">
      <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-ink-muted">Go to coordinate</div>
      <div className="flex items-center gap-2">
        <input
          type="number"
          inputMode="numeric"
          value={x}
          onChange={(e) => {
            setX(e.target.value)
            setHint(null)
          }}
          onKeyDown={onKeyDown}
          placeholder="X"
          aria-label="World X coordinate"
          className={inputClass}
          data-testid="worldeditor-goto-x"
        />
        <input
          type="number"
          inputMode="numeric"
          value={y}
          onChange={(e) => {
            setY(e.target.value)
            setHint(null)
          }}
          onKeyDown={onKeyDown}
          placeholder="Y"
          aria-label="World Y coordinate"
          className={inputClass}
          data-testid="worldeditor-goto-y"
        />
        <button
          type="button"
          onClick={submit}
          className="shrink-0 rounded-lg border border-edge bg-surface-2 px-3 py-1 text-sm text-ink hover:bg-accent-soft"
          data-testid="worldeditor-goto-submit"
        >
          Go
        </button>
      </div>
      {hint ? (
        <p className="mt-1.5 text-xs text-danger" data-testid="worldeditor-goto-hint">
          {hint}
        </p>
      ) : (
        <p className="mt-1.5 text-xs text-ink-faint">
          Frames the camera on a raw world point (±{WORLD_MAX}). Navigation only — nothing is written.
        </p>
      )}
    </section>
  )
}
