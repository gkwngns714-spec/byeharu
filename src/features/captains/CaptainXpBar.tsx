import { Meter } from '../../components/ui'
import { captainProgress, captainProgressVisible } from './captainProgress'

// C2-3 — the captain XP bar + level chip (dark UI), shared by CaptainsPanel and
// TeamMemberCaptains. PURE presentation over the get_my_captain_instances projection (0181 added
// xp/level): renders NOTHING unless captainProgressVisible — i.e. the projection carries finite
// xp/level AND there is progression to show (xp > 0 or level > 1). THE DARK STORY: while
// captain_growth_enabled is false the accrual has never moved xp/level, so every captain is
// level-1/0-xp → this component is null everywhere and today's UI is byte-identical. Design
// tokens + the Meter primitive only; mono/tabular numerics.

export function CaptainXpBar({ xp, level, instanceId }: { xp?: number; level?: number; instanceId: string }) {
  if (!captainProgressVisible({ xp, level })) return null
  const p = captainProgress(xp ?? 0, level ?? 1)
  return (
    <div data-testid={`captain-xp-${instanceId}`} className="mt-1 flex items-center gap-1.5">
      <span className="shrink-0 rounded bg-surface-2 px-1.5 py-0.5 font-mono text-[9px] tabular-nums text-ink-muted">
        Lv {p.level}
      </span>
      <span className="w-16 shrink-0">
        <Meter pct={p.fraction * 100} tone="accent" />
      </span>
      <span className="min-w-0 truncate font-mono text-[9px] tabular-nums text-ink-faint">
        {Math.round(p.intoLevel)}/{p.span} xp
      </span>
    </div>
  )
}
