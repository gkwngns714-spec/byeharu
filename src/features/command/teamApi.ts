import { supabase } from '../../lib/supabase'
import { buildShipGroupMap, type GroupRow, type ShipGroupMapEntry, type ShipMembershipRow } from './teamRoster'
import { buildCommandShipGroupGoArgs, type GroupGoTarget } from './teamMove'
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
// ShipGroupMapEntry moved to teamRoster.ts (the pure buildShipGroupMap home); re-exported here so every
// existing importer (TeamRosterPanel / TeamMapSend / useGalaxyMapData) is unchanged.
export type { ShipGroupMapEntry }

export async function fetchMyShipGroupMap(): Promise<Record<string, ShipGroupMapEntry>> {
  // The BASE membership read selects ONLY pre-existing columns (main_ship_id / group_id / captain_slots),
  // so it can NEVER error against a DB that predates a later-added column. This is load-bearing: this read
  // drives the LIVE roster/map membership, and the client (Pages) auto-deploys AHEAD of the approval-gated
  // migration — if a widened select errored, every live team-command player would briefly see all fleets
  // dissolved. FLEET-CONTROL (0204) therefore reads is_command_ship in a SEPARATE query that fail-closes to
  // "no command-ship data" (every ship false) — the pure buildShipGroupMap folds them, membership-first.
  const { data, error } = await supabase
    .from('main_ship_instances')
    .select('main_ship_id, group_id, captain_slots')
  if (error || !data) return {}
  // FLEET-CONTROL (0204): the command-ship designation, read SEPARATELY so a missing column (pre-0204 DB)
  // or any transport error can NEVER nuke membership above — buildShipGroupMap treats null as "no command
  // data" and keeps every ship's fleet. Harmless while dark (the client renders no command-ship surface).
  const { data: cmd, error: cmdErr } = await supabase
    .from('main_ship_instances')
    .select('main_ship_id, is_command_ship')
  return buildShipGroupMap(
    data as ShipMembershipRow[],
    cmdErr || !cmd ? null : (cmd as { main_ship_id: string; is_command_ship: boolean | null }[]),
  )
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

// ── FLEET-GO 4a-1 — the UNIFIED-fleet read (the fetchMyPresentShipFleets SIBLING, deliberately not a
// widening of it): the live rollup input above is untouched (its `.not('main_ship_id','is',null)`
// filter is exactly why a unified fleet is invisible to it), and this read answers the question the
// old one cannot: the group's ONE fleet — main_ship_id IS NULL + group_id set, the hunt's proven
// shape that 0207 reuses — with its own position (status/location_mode/current_location_id/space_x/y,
// the 0208 columns; live in prod since the 0211 deploy). Owner-select RLS on `fleets` is the same
// grant the present-fleet read already exercises. Live rows only (0207's own live-set predicate).
//
// ⚠ THE SHAPE IS NOT UNIQUELY THE UNIFIED MOVER'S: the live team hunt (send_ship_group_hunt, 0168 —
// team_command_enabled is ON in prod) mints EXACTLY this shape for its sortie fleet, TODAY, while
// fleet_movement_unified_enabled is false. So "no unified fleet row can exist while the server gate
// is false" is FALSE and this read is NOT dark-inert by construction. Callers therefore (a) gate the
// FETCH on the runtime unified flag (dark → zero reads, zero behavior change — the hard invariant),
// and (b) when lit, exclude rows 'present' at a COMBAT location before folding them as docks: the
// unified mover refuses combat destinations (0208 combat_destination), so a group-shaped fleet
// present at a hunt site can only be a sortie, never a dock.
export interface UnifiedGroupFleetLite {
  group_id: string
  status: string
  location_mode: string
  current_location_id: string | null
  space_x: number | null
  space_y: number | null
}

export async function fetchMyUnifiedGroupFleets(): Promise<UnifiedGroupFleetLite[]> {
  const { data, error } = await supabase
    .from('fleets')
    .select('group_id, status, location_mode, current_location_id, space_x, space_y')
    .is('main_ship_id', null)
    .not('group_id', 'is', null)
    .in('status', ['idle', 'moving', 'present', 'returning'])
  if (error || !data) return []
  return data as UnifiedGroupFleetLite[]
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

// set_fleet_command_ship (0204) — toggle a ship's command-ship designation. Owner-scoped, NOT flag-gated
// (the designation is additive data, inert until fleet_control_enabled lights the movement requirement);
// setting to true requires the ship be in a fleet (server rejects ship_not_in_fleet otherwise). Thin,
// normalize-don't-throw (the file's write style). A fleet needs ≥1 command ship to be ACTIVE (able to
// move/send/hunt) once fleet_control_enabled is lit.
export async function setFleetCommandShip(mainShipId: string, isCommand: boolean): Promise<TeamRpcResult> {
  const { data, error } = await supabase.rpc('set_fleet_command_ship', {
    p_main_ship_id: mainShipId,
    p_is_command: isCommand,
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

// move_ship_group_to_location (0190) — all-or-nothing ONWARD move of a fully-DOCKED team to another
// active, non-combat location (the other half of "docked or move as a whole"). Server-side it composes
// the live per-ship move_main_ship_to_location (0156) once per member; success carries { sent: [...] }
// (one per-ship envelope per member, each with fleet_id/movement_id/arrive_at). Rejects arrive as the
// 0163-family vocabulary plus member_not_ready (the team is not docked together — the 0168 phrasing);
// a per-member failure (bad destination, already there, …) surfaces as member_send_failed.
export async function moveShipGroup(groupId: string, locationId: string): Promise<TeamRpcResult> {
  const { data, error } = await supabase.rpc('move_ship_group_to_location', {
    p_group_id: groupId,
    p_location_id: locationId,
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

// ── FLEET-GO 4a-1 — the UNIFIED mover/brake wrappers (charter §2: the fleet is the ONLY mover). ──
// Thin, normalize-don't-throw (the file's write style, verbatim). Both RPCs are DARK behind
// fleet_movement_unified_enabled (false in prod) and reject-before-read while dark, so wiring these
// wrappers changes nothing until 4b flips the flag. NEITHER goes through the fleet-control
// (cmd.active) gate: fleet_control_enabled imposes a command-ship requirement (0204
// fleet_inactive_no_command) that the unified mover deliberately does NOT have — gating these on it
// would make the client forbid what the server accepts.

// command_ship_group_go (0207/0208) — the ONE fleet-level mover: the whole group moves as ONE fleet
// to a port XOR a world coordinate, from wherever it is (docked, split-docked, parked in space, or
// mid-flight — a re-issue is a redirect from the interpolated point). The exclusive target shape is
// enforced by the pure builder (teamMove.ts): a location target NEVER carries coords, and coordinate
// targets go RAW (0208 rounds to the integer grid server-side; the client must not pre-round).
// Success carries { fleet_id, movement_id, arrive_at, member_count, redirected, … }.
export async function commandShipGroupGo(groupId: string, target: GroupGoTarget): Promise<TeamRpcResult> {
  const { data, error } = await supabase.rpc('command_ship_group_go', buildCommandShipGroupGoArgs(groupId, target))
  if (error) return { ok: false, reason: 'unavailable' }
  return data as TeamRpcResult
}

// command_ship_group_dock (0219 — S4 TIMED DOCKING) — the DOCK verb: from a fleet PARKED in open
// space inside a dockable port's territory, mint a normal 45s fleet_movements leg (mission 'dock');
// the arrival settles into the docked state through the untouched settle. Server-derived
// everything: the port comes from fleet_in_territory, never from the client. DARK behind
// timed_docking_enabled (reject-before-read: timed_docking_disabled) — the FleetCommandPanel's
// dock row only routes here when the runtime flag is lit, and falls back to the instant
// commandShipGroupGo otherwise. Success carries { fleet_id, movement_id, port_id, arrive_at }.
// Rejects: not_parked / not_in_territory / not_dockable / group_on_sortie / … (teamReasonMessage).
export async function commandShipGroupDock(groupId: string): Promise<TeamRpcResult> {
  const { data, error } = await supabase.rpc('command_ship_group_dock', { p_group_id: groupId })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as TeamRpcResult
}

// command_ship_group_stop (0209) — the ONE fleet-level brake: cancels the group fleet's live leg and
// HOLDS it in open space at the interpolated point (immediately re-commandable). Idempotent —
// pressing it on a parked fleet returns ok:true with stopped:false + a reason_code, never an error.
// ⚠ ENVELOPE TRAP: `stopped` here is a BOOLEAN; the legacy 0164 stop returns a COUNT under the same
// key. Outcome copy MUST go through teamStop.ts's unifiedStopOutcomeMessage, never the 0164 parser.
export async function commandShipGroupStop(groupId: string): Promise<TeamRpcResult> {
  const { data, error } = await supabase.rpc('command_ship_group_stop', { p_group_id: groupId })
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
// NO-HOME (0199): the widened hunt takes an optional return port (p_return_location_id) — the port a
// DOCKED team docks at after combat (a non-dockable hunt site has no dock of its own). Omitted (the
// dark/home path) → the third arg defaults NULL server-side and the RPC behaves exactly as the 0168
// head. Passing it is inert until launch_from_dock_enabled is lit.
export async function sendShipGroupHunt(
  groupId: string,
  locationId: string,
  returnLocationId?: string | null,
): Promise<TeamRpcResult> {
  const { data, error } = await supabase.rpc('send_ship_group_hunt', {
    p_group_id: groupId,
    p_location: locationId,
    ...(returnLocationId ? { p_return_location_id: returnLocationId } : {}),
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
