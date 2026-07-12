import { supabase } from '../../lib/supabase'
import type { GroupRow } from './teamRoster'
import type { PreviewMember } from './teamSkillset'

// TEAM-COMMAND Slice A — owner-scoped reads for team/group data (DARK).
//
// These run ONLY from the TeamRosterPanel, which is mounted behind the compile-time TEAM_COMMAND_ENABLED gate
// (false) — so while dark the panel is never mounted and NEITHER read below ever executes in production.
// That is deliberate: `group_id` does not exist on main_ship_instances until migration 0160 deploys, and these
// reads must not run against a DB that predates it. They read the tables DIRECTLY via owner-select RLS (the
// same pattern as useMainShipSelection) — the roster's ship LIST + selection still come from the ONE shell
// selection (shellState.selection); this only supplies the group metadata + membership the shell doesn't carry.

// The player's teams (backend: ship_groups rows), owner-read, ordered by the deterministic slot.
export async function fetchMyShipGroups(): Promise<GroupRow[]> {
  const { data, error } = await supabase
    .from('ship_groups')
    .select('group_id, group_index, name')
    .order('group_index', { ascending: true })
  if (error || !data) return []
  return data as GroupRow[]
}

// Per-ship membership + capacity read: main_ship_id → { group_id, captain_slots }. Owner-read; merged onto
// the shell's ship list (which carries neither) so the shell stays the single selection source. Slice C1
// widened the SELECT with `captain_slots` (an existing owner-RLS column — the mainshipApi SHIP_COLS read
// already selects it; zero server change) so the captain sub-surface can feed captainAssignAvailability a
// SERVER-reported slot count instead of a hardcoded 2/6.
export interface ShipGroupMapEntry {
  group_id: string | null // null = ungrouped
  captain_slots: number | null // null = unexpectedly absent → callers skip the client slot precheck
}

export async function fetchMyShipGroupMap(): Promise<Record<string, ShipGroupMapEntry>> {
  const { data, error } = await supabase
    .from('main_ship_instances')
    .select('main_ship_id, group_id, captain_slots')
  if (error || !data) return {}
  const map: Record<string, ShipGroupMapEntry> = {}
  for (const r of data as { main_ship_id: string; group_id: string | null; captain_slots: number | null }[]) {
    map[r.main_ship_id] = { group_id: r.group_id ?? null, captain_slots: r.captain_slots ?? null }
  }
  return map
}

// ── TEAMMAP-0 — the docked-location read for the team rollup. ──
// A docked ship's fleet is 'present' with a current_location_id (the resolveMainShipMarker §D
// coherence source; written by fleet_set_present at arrival, 0153) — this owner-RLS read is the
// docked-location truth the pure deriveDockedTeamRollups fold consumes. Normalize-don't-throw (the
// file's read style): transport error → [] → no rollup line / no dock badge, never a crash.
export interface PresentShipFleetLite {
  main_ship_id: string
  current_location_id: string | null
}

export async function fetchMyPresentShipFleets(): Promise<PresentShipFleetLite[]> {
  const { data, error } = await supabase
    .from('fleets')
    .select('main_ship_id, current_location_id')
    .eq('status', 'present')
    .not('main_ship_id', 'is', null)
  if (error || !data) return []
  return data as PresentShipFleetLite[]
}

// ── Slice B1 — owner-scoped group WRITE wrappers over the B0/B1 SECURITY DEFINER RPCs (DARK). ──
// Thin: send only ids/values; the server derives the player from auth.uid(), re-checks the gate + ownership,
// and is the SOLE authority. {ok:false} is a NORMAL (dark) outcome → normalized, never thrown (the
// mainshipApi dark-RPC style). These run ONLY from TeamRosterPanel (mounted behind TEAM_COMMAND_ENABLED=false),
// so they never execute in production.

export type TeamRpcResult = { ok: true; [k: string]: unknown } | { ok: false; reason: string }

// upsert_ship_group (0161) — create OR rename the slot group_index (1..3). Rename = pass an existing team's
// group_index; the (player_id, group_index) upsert updates its name. group_id is server-assigned.
export async function upsertShipGroup(groupIndex: number, name: string): Promise<TeamRpcResult> {
  const { data, error } = await supabase.rpc('upsert_ship_group', {
    p_group_index: groupIndex,
    p_name: name,
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as TeamRpcResult
}

// assign_ship_to_group (0161) — assign an owned ship to an owned team, or UNASSIGN (groupId null).
export async function assignShipToGroup(
  mainShipId: string,
  groupId: string | null,
): Promise<TeamRpcResult> {
  const { data, error } = await supabase.rpc('assign_ship_to_group', {
    p_main_ship_id: mainShipId,
    p_group_id: groupId,
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as TeamRpcResult
}

// delete_ship_group (0162) — delete an owned team; its ships are un-grouped by ON DELETE SET NULL server-side.
export async function deleteShipGroup(groupId: string): Promise<TeamRpcResult> {
  const { data, error } = await supabase.rpc('delete_ship_group', { p_group_id: groupId })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as TeamRpcResult
}

// send_ship_group_expedition (0163) — all-or-nothing team send to an active, non-combat location.
// Success carries { sent: [...] }; the server re-validates the destination and each member.
export async function sendShipGroup(groupId: string, locationId: string): Promise<TeamRpcResult> {
  const { data, error } = await supabase.rpc('send_ship_group_expedition', {
    p_group_id: groupId,
    p_location: locationId,
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as TeamRpcResult
}

// stop_ship_group_transit (0164) — best-effort halt of every in-flight member. Success carries the aggregate
// { stopped, skipped, failed }.
export async function stopShipGroup(groupId: string): Promise<TeamRpcResult> {
  const { data, error } = await supabase.rpc('stop_ship_group_transit', { p_group_id: groupId })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as TeamRpcResult
}

// ── Slice C1 — the ONE group-preview READ wrapper over C0's dark RPC (0165). ──
// Read-only; the captain assign/unassign commands are NOT wrapped here — captainsApi.ts owns them
// (one captain API, one envelope, one error map).

// get_my_group_expedition_preview's envelope (0165): lit → the group id + activity echoed back with
// per-member results (each member delegated to the ONE stat adapter; a member's validation raise
// arrives as { valid:false, error }); dark → { ok:false, reason:'team_command_disabled' } (and the
// rest of the 0165 reject vocab). PreviewMember is the teamSkillset.ts structural shape.
export type GroupPreviewResult =
  | { ok: true; group_id: string; activity_type: string; member_count: number; members: PreviewMember[] }
  | { ok: false; reason: string }

// get_my_group_expedition_preview (0165) — DARK, read-only per-member stats preview for a team.
// Normalize-don't-throw (the file's dark-RPC style): transport error → { ok:false, reason:'unavailable' }.
export async function fetchGroupExpeditionPreview(
  groupId: string,
  activityType: string,
): Promise<GroupPreviewResult> {
  const { data, error } = await supabase.rpc('get_my_group_expedition_preview', {
    p_group_id: groupId,
    p_activity_type: activityType,
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as GroupPreviewResult
}

// ── Slice D4 — team COMBAT wrappers over the D0/D2 dark RPCs. ──
// Same posture as everything above: thin, normalize-don't-throw, server is the SOLE authority, and
// callers exist only inside TeamRosterPanel (mounted behind TEAM_COMMAND_ENABLED=false) — never
// executed in production while dark.

// send_ship_group_hunt (0168) — the combat twin of sendShipGroup: ONE fleet for the whole team to an
// active hunt_pirates location. Success carries { fleet_id, movement_id, arrive_at, member_count };
// rejects arrive as the 0168 envelope vocabulary (see teamCombat.ts for the mirrored prefix + the
// server-only tail).
export async function sendShipGroupHunt(groupId: string, locationId: string): Promise<TeamRpcResult> {
  const { data, error } = await supabase.rpc('send_ship_group_hunt', {
    p_group_id: groupId,
    p_location: locationId,
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as TeamRpcResult
}

// get_my_group_expedition_totals's envelope (0166): the AUTHORITATIVE team totals — the D0 strict
// authority's folding (Σ the additive 0122 keys, speed = min member speed), opaque on ANY member
// raise (reason:'stats_invalid'; the C0 preview is the friendly per-member diagnosing surface).
// totals carries `speed` + the eight additive stat keys; members[] echoes the per-member stats.
export type GroupTotalsResult =
  | {
      ok: true
      group_id: string
      activity_type: string
      member_count: number
      members: { main_ship_id: string; stats?: Record<string, number> }[]
      totals: Record<string, number>
    }
  | { ok: false; reason: string }

// get_my_group_expedition_totals (0166) — DARK, read-only authoritative team totals.
export async function fetchGroupExpeditionTotals(
  groupId: string,
  activityType: string,
): Promise<GroupTotalsResult> {
  const { data, error } = await supabase.rpc('get_my_group_expedition_totals', {
    p_group_id: groupId,
    p_activity_type: activityType,
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as GroupTotalsResult
}
