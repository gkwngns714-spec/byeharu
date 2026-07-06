import { useCallback, useEffect, useMemo, useState } from 'react'
import { isServerLit, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { getUiAssetCatalog } from '../assets/assetsApi'
import { assetGlyphs } from '../assets/assetGlyphs'
import type { GetUiAssetCatalogResult, UiAsset } from '../assets/assetsTypes'
import { getWorldEvents } from './eventsApi'
import type { GetWorldEventsResult, WorldEventSeverity } from './eventsTypes'

// PHASE20-POLISH — the dark World Events display: a compact, read-only overlay of currently-live world
// events. SERVER-DRIVEN visibility (no client flag constant): the panel reads get_world_events (0141)
// on mount / lifecycle change and renders NOTHING unless the server affirmatively lit the feature AND
// returned live events. While phase20_polish_enabled is false the server empties the feed
// ({ok:true, events:[]}), so this renders null — today's production UI is byte-unchanged; when the human
// later lights the flag AND publishes events, they appear. The server (flag gate + live-window filter)
// is the SOLE control; the client never decides visibility. Purely presentational — no actions/buttons.

// Severity → badge color classes (the ExplorationPanel badge idiom: a small static class map).
const SEVERITY_BADGE: Record<WorldEventSeverity, string> = {
  info: 'bg-sky-600/30 text-sky-300',
  warning: 'bg-amber-600/30 text-amber-300',
  critical: 'bg-rose-600/30 text-rose-300',
}

export function WorldEventsPanel({
  // Re-reads the feed whenever the main-ship lifecycle changes (the ExplorationPanel/MiningPanel idiom).
  lifecycleKey,
}: {
  lifecycleKey: string
}) {
  const [result, setResult] = useState<GetWorldEventsResult | null>(null)
  const [icons, setIcons] = useState<GetUiAssetCatalogResult | null>(null)

  // Mounted guard — the shared home of the idiom (useActivityPanelGuards).
  const guards = useActivityPanelGuards()
  const { activeRef } = guards

  const refresh = useCallback(async () => {
    // Fetch the feed and the icon vocabulary together; both empty server-side while dark (fail-closed).
    const [events, iconCatalog] = await Promise.all([getWorldEvents(), getUiAssetCatalog('icon')])
    if (!activeRef.current) return
    setResult(events)
    setIcons(iconCatalog)
  }, [activeRef]) // ref identity is stable — dep satisfies the lint rule without changing refresh's identity

  // asset_key → UiAsset lookup from the returned 'icon' rows (empty while dark / on a failed read →
  // no glyph resolves, which the render below tolerates without breaking the feed).
  const iconByKey = useMemo(() => {
    const map = new Map<string, UiAsset>()
    if (isServerLit(icons)) for (const a of icons.assets ?? []) map.set(a.asset_key, a)
    return map
  }, [icons])

  // lifecycleKey is a deliberate re-fetch trigger (the ExplorationPanel dep idiom).
  useEffect(() => {
    void refresh()
  }, [refresh, lifecycleKey])

  // FAIL CLOSED: render nothing unless the server affirmatively lit the surface AND there are live
  // events. This is the dark path in production today (empty feed while the flag is false); transport
  // errors collapse to null the same way. The client is never the control.
  if (!isServerLit(result) || (result.events?.length ?? 0) === 0) return null

  return (
    <div
      data-testid="world-events-panel"
      // Top-center; deliberately clear of the four existing overlays (PortNav top-left, DockServices
      // top-right, Exploration/Mining bottom-left, Stop bottom-right) so all can coexist without overlap.
      className="pointer-events-auto absolute left-1/2 top-2 z-10 w-72 -translate-x-1/2 rounded-lg border border-indigo-500/30 bg-slate-900/90 p-2 text-slate-100"
    >
      <p className="text-[11px] font-medium text-indigo-300">World Events</p>
      <ul data-testid="world-events-list" className="mt-2 space-y-1 border-t border-slate-700/60 pt-2">
        {result.events?.map((e) => {
          // Resolve the server-owned severity icon vocabulary → the client-owned glyph. Any miss
          // (dark/empty catalog, unseeded key, unregistered asset_ref) resolves to no glyph — the
          // event still renders with its severity badge (never break the feed).
          const icon = iconByKey.get(`severity_${e.severity}`)
          const glyph = icon ? assetGlyphs[icon.asset_ref] : undefined
          return (
            <li key={e.id} data-testid={`world-event-${e.id}`} className="text-[10px]">
              <div className="flex items-center justify-between gap-2">
                <span className="flex min-w-0 items-center gap-1">
                  {glyph && (
                    <span
                      data-testid={`world-event-icon-${e.id}`}
                      aria-label={icon?.display_name}
                      title={icon?.display_name}
                      className="shrink-0"
                    >
                      {glyph}
                    </span>
                  )}
                  <span className="truncate text-slate-200">{e.title}</span>
                </span>
                <span
                  data-testid={`world-event-badge-${e.id}`}
                  className={`shrink-0 rounded px-1.5 py-0.5 text-[9px] uppercase ${SEVERITY_BADGE[e.severity]}`}
                >
                  {e.severity}
                </span>
              </div>
              {e.body && <p className="text-slate-400">{e.body}</p>}
            </li>
          )
        })}
      </ul>
    </div>
  )
}
