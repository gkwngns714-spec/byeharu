import { useCallback, useEffect, useState } from 'react'
import { isServerLit, runGuardedCommand, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { getCaptainRecipes, getMyCaptainInstances, recruitCaptain } from './captainsApi'
import {
  recruitCaptainErrorMessage,
  type CaptainRecipe,
  type GetMyCaptainInstancesResult,
} from './captainsTypes'

// CAPTAIN-P16 (post-audit UI, panel 4 of 4) — the dark Captain Progression (recruit) surface: the
// recruitable captain types with their ingredient costs + a per-type Recruit action. Recruit is
// inventory→captain (non-spatial), so no ship id is needed.
//
// THE VISIBILITY-GATE DECISION (documented honestly). `captain_progression_enabled` (0124) is gated
// ONLY inside the recruit COMMAND (recruit_captain, 0126) — there is NO existing read RPC gated on it,
// and item (4) forbids adding new server authority/RPCs. So this panel derives its VISIBILITY from the
// captain system's existing gated roster read get_my_captain_instances (gated on
// captain_assignment_enabled) — progression is the recruitment face of the captain system — while the
// recruit COMMAND remains the AUTHORITATIVE captain_progression_enabled gate (it returns feature_disabled
// while progression is dark, surfaced inline on attempt). The server is the sole control: no client flag
// enables recruiting. CAVEAT of this reuse: if captain_assignment_enabled is lit but
// captain_progression_enabled is NOT, this panel would show the recipes with a Recruit affordance that
// the server rejects feature_disabled on click (never a false success). A dedicated
// progression-gated read surface — which would let the panel also HIDE the affordance on the progression
// flag — is the clean future follow-up, out of this fix pass's no-new-authority scope.
//
// Recipes are read by DIRECT public-read select over the shipped catalogs (getCaptainRecipes) — no RPC.
// Affordability (have/need) is NOT annotated: the only inventory-balance function (inventory_get_balance,
// 0039) is service_role-only (no client grant) and item (4) forbids adding a client read RPC — so the
// panel shows recipe COSTS and relies on the server's insufficient_items {item_id, have, need} payload on
// attempt (surfaced by recruitCaptainErrorMessage).

export function RecruitCaptainPanel({
  // Re-reads roster + recipes whenever the main-ship lifecycle changes (the sibling-panel idiom).
  lifecycleKey,
}: {
  lifecycleKey: string
}) {
  const [roster, setRoster] = useState<GetMyCaptainInstancesResult | null>(null)
  const [recipes, setRecipes] = useState<CaptainRecipe[]>([])
  // Per-captain-type (id-keyed) pending + note Records — the ModulesPanel per-row guarded idiom.
  const [pending, setPending] = useState<Record<string, boolean>>({})
  const [rowNote, setRowNote] = useState<Record<string, string | null>>({})

  // Mounted + synchronous in-flight guards — the shared home of the idiom (useActivityPanelGuards).
  const guards = useActivityPanelGuards()
  const { activeRef } = guards

  const refresh = useCallback(async () => {
    // Roster gates visibility (fail-closed); recipes are public-read catalog data (empty on error).
    const [rosterRes, recipeList] = await Promise.all([getMyCaptainInstances(), getCaptainRecipes()])
    if (!activeRef.current) return
    setRoster(rosterRes)
    setRecipes(recipeList)
  }, [activeRef]) // ref identity is stable — dep satisfies the lint rule without changing identity

  // lifecycleKey is a deliberate re-fetch trigger (the sibling-panel dep idiom).
  useEffect(() => {
    void refresh()
  }, [refresh, lifecycleKey])

  // One intentional Recruit per captain type — the shared guarded-submit body over the per-type key; the
  // server dedups on (player, request_id) and is the AUTHORITATIVE progression gate (feature_disabled
  // while dark) + spend/mint authority. request_id is a fresh crypto.randomUUID() STRING (TEXT param).
  async function recruit(rec: CaptainRecipe) {
    await runGuardedCommand({
      key: rec.captain_type_id,
      guards,
      setPending: (on) => setPending((p) => ({ ...p, [rec.captain_type_id]: on })),
      setNote: (note) => setRowNote((n) => ({ ...n, [rec.captain_type_id]: note })),
      exec: () => recruitCaptain(crypto.randomUUID(), rec.captain_type_id),
      successNote: () => `Recruited ${rec.name}.`,
      errorNote: (res) => recruitCaptainErrorMessage(res),
      refresh,
    })
  }

  // FAIL CLOSED: render nothing unless the server affirmatively lit the captain-system roster read. This
  // is the dark path in production today (captain_assignment_disabled → not server-lit); transport errors
  // collapse to null the same way. The client is never the control.
  if (!isServerLit(roster)) return null

  return (
    <div
      data-testid="recruit-captain-panel"
      // Bottom-left row, continuing after CaptainsPanel (left-[50rem]); non-spatial like its siblings, so
      // it coexists with every other overlay without overlap (each w-64, ~0.5rem gaps).
      className="pointer-events-auto absolute bottom-2 left-[66.5rem] z-10 w-64 rounded-lg border border-fuchsia-500/30 bg-slate-900/90 p-2 text-slate-100"
    >
      <p className="text-[11px] font-medium text-fuchsia-300">Recruit Captains</p>
      {recipes.length === 0 ? (
        <p data-testid="recruit-recipes-none" className="mt-2 border-t border-slate-700/60 pt-2 text-[10px] text-slate-400">
          No captain recipes available.
        </p>
      ) : (
        <ul data-testid="recruit-recipes" className="mt-2 space-y-1 border-t border-slate-700/60 pt-2">
          {recipes.map((rec) => {
            const isPending = pending[rec.captain_type_id] ?? false
            const note = rowNote[rec.captain_type_id]
            const cost = rec.ingredients.map((i) => `${i.item_name} ×${i.qty}`).join(' · ')
            return (
              <li key={rec.captain_type_id} data-testid={`recruit-recipe-${rec.captain_type_id}`} className="text-[10px]">
                <div className="flex items-center justify-between gap-2">
                  <span className="truncate text-slate-200">{rec.name}</span>
                  <span className="shrink-0 rounded bg-slate-800/80 px-1.5 py-0.5 text-[9px] text-slate-300">
                    {rec.specialization}
                  </span>
                </div>
                <p className="text-slate-500">{cost || '—'}</p>
                <div className="mt-1">
                  <button
                    type="button"
                    data-testid={`recruit-button-${rec.captain_type_id}`}
                    disabled={isPending}
                    onClick={() => void recruit(rec)}
                    className="rounded bg-fuchsia-600/90 px-2 py-0.5 text-[10px] font-medium text-white hover:bg-fuchsia-500 disabled:opacity-50"
                  >
                    {isPending ? 'Recruiting…' : 'Recruit'}
                  </button>
                </div>
                {note && (
                  <p data-testid={`recruit-note-${rec.captain_type_id}`} className="mt-0.5 text-[10px] text-fuchsia-200/90">
                    {note}
                  </p>
                )}
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}
