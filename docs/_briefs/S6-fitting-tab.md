# S6 Ship tab → FITTING tab — grounded brief (banked 2026-07-18)

Serializes behind S1 (needs `place:'berthed'` in the one location read). Frontend-only.

## Retire these two
- `src/features/ship/ShipScreen.tsx` (route `/ship`, App.tsx:37; tab AppShell.tsx:23-28) mounts
  `ShipStatusCard` (:62-70) + `ShipDossier` (:78-83). ShipScreen is the ONLY importer of both.
- Delete `ShipStatusCard.tsx` + `ShipDossier.tsx`; rebuild ShipScreen as the Fitting screen.
- KEEP (pure/shared, spec-covered): `shipLocation.ts`, `meterPair.ts`, `MeterPairBars.tsx`,
  `shipName.ts`, `shipDossierView.ts` selectors, `shipTraits.ts`, `commandBuff*.ts`.

## RE-HOME (NO-SOFTLOCK)
- REPAIR (mandatory): `repairMainShip` (mainshipApi.ts:374-378, RPC repair_main_ship). RepairPanel
  defers destroyed ships to this FREE path (RepairPanel.tsx:32,220) — if the roster doesn't host it a
  destroyed ship soft-locks. Render an UNGATED Repair button on any row/detail where status==='destroyed'.
- Rename (inline form, pure guards shipName.ts) → fitting detail header.
- Room config (configure_ship_room, ShipDossier:222-234) → moves with the detail panel.
- ShipSwitcher → retire (superseded by roster-row selection via shell `selection.selectShip`).
- CommissionShipPanel → Command (acquisition = composition; teaser already says "from Command").
- Inventory/Captains panels → stay on the Fitting aside (per-ship loadout, inside the boundary).

## Fitting read + commands + gate
- `getMyShipFittings()` → get_my_ship_fittings (no args, modulesApi.ts:66-70) returns ALL ships'
  fittings in ONE call; filter per-ship via `fittingsForShip` (shipDossierView.ts:12).
- `fitModuleToShip(moduleInstanceId, mainShipId, requestId)` / `unfitModuleFromShip(moduleInstanceId,
  requestId)` (modulesApi.ts:73-98). Envelope FittingCommandResult (modulesTypes.ts:99-138, has
  ship_not_settled copy).
- 0114 SETTLED-SAFE gate: fitting_execute_command step 6 (0114:107-142) requires validated
  `state in ('home','at_location')` (:131-132). 'home' IS in the set → berthed IS fit-eligible IF S1's
  berthed ships validate to 'home'/'at_location'. `legacy_home` is NOT in the set (0114:26-28) — VERIFY
  S1's shipped berthed state before wiring "editable when berthed".
- UI enable: derive from the SAME get_my_fleet_positions row (place==='docked' or 'berthed'), never a
  2nd dockedness query. Server stays enforcer.

## Roster + location (ONE read per fact)
- LOCATION = `get_my_fleet_positions` (head 0212:58-213), client `map.fleetPositions` from
  `useShellState()` — ALREADY polled every 4s (useGalaxyMapData.ts:164-178). S6 reads it, ZERO new fetch.
  S1 adds place:'berthed' to the union (mainshipApi.ts:125).
- Label adapter: `fleetPositionLocationLabel(pos, locations)` (teamRoster.ts:98-118) — extend with the
  'berthed' branch (berthed→berth port name). The ONE place location strings fold for rows.
- GROUPING: pure `buildTeamRoster(groups, ships)` → {teams, ungrouped} (teamRoster.ts:42-63).
  `ungrouped` IS the "Berthed — not in a fleet" bucket post-S1 (XOR: group_id NULL ⇔ berth set). Reuse
  it — do NOT write a 2nd grouping fold. Ships list = shell `useMainShipSelection`; condition cols =
  fetchMyMainShips; membership = fetchMyShipGroups + fetchMyShipGroupMap.

## UI kit (compose, no parallel design system)
components/ui: Button, Card/CardHeader, Badge, Meter, Notice, SectionLabel, PageHeader, StatRow,
Screen, EmptyState, Skeleton, OverlayPanel, Icon (icons.ts ICON_PATHS — add glyphs, tested by
uiPrimitives.spec). MeterPairBars (hull/shield, meterPair.ts:29-43). chip() idiom (ShipDossier:210-215).
shipTraitCards + shipCommandBuffCard (fail-closed fetchers). components/items: ItemChip/ItemTile/
ItemGlyph. Status pill: mainShipInstanceStatusLabel/Tone. Selected-row: TeamRosterPanel role="button"
idiom (:241-256).

## Tab rename
AppShell.tsx:23-28 label 'Ship'→'Fitting'; keep /ship path or redirect (App.tsx:41-45 /galaxy→/map
idiom). nav testid = `nav-${label.toLowerCase()}` — Playwright specs on nav-ship must follow. Command
tab (CommandScreen.tsx:81, TeamRosterPanel, TEAM_COMMAND_ENABLED=true) is LIVE.

## Data fan-out (measured — NO new RPC v1)
Shared roster facts = ~6 requests total regardless of N (fetchMyMainShips 1 + fetchMyShipGroups 1 +
fetchMyShipGroupMap 2 + getMyShipFittings 1 + getMyCaptainInstances 1 + location 0). Per-ship 3×N
surfaces (fetchShipSoul/fetchShipCommandBuff/fetchMyExpeditionPreview) load ONLY in the selected ship's
detail (trimmed dossier wave ≤9 reads). Worst case 8-ship cap = 6+9 = 15/visit — fine. Mint
get_my_ships_dossier only if owner later demands per-ROW traits/buffs.

## Spaghetti risks
1. 2nd location source: DELETE ShipScreen.tsx:40-44 (sole-ship legacy derivation); use map.fleetPositions
   only. Note `fleetDisplayStatus` (shipLocation.ts:59-64) is a documented mirror of deriveMainShipStatus
   — after S6, deriveMainShipStatus's last UI consumer dies; flag for cleanup, don't add a 3rd.
2. Fitting rendered twice → could be thrice: read-only view (ShipDossier:394-420, retires) + edit
   surface in ModulesPanel Workshop (ModulesPanel.tsx:145-166,285-333, mounted PortScreen:114). DECIDE
   ONE: move the fitting section OUT of ModulesPanel into the new fitting detail (ModulesPanel keeps
   crafting only, non-spatial); the detail composes getMyShipFittings + fit/unfit with the ship
   pre-selected (row IS the ship, no <select>), enabled only when place docked/berthed. Retire Workshop
   fitting rows SAME PR.
3. Roster boundary: Command owns COMPOSITION (create/rename/delete fleet, add/remove ship, command-ship
   toggle). Fitting owns per-ship EQUIPMENT+CONDITION (modules, rename, repair, rooms, captains, cargo,
   traits/buffs). Fitting renders grouping READ-ONLY via same buildTeamRoster — zero membership controls,
   zero movement controls.
4. Selection: use shell `selection` (row click → selection.selectShip) — no local selected-ship state.
5. Dark honesty: map.fleetPositions is [] when both movement gates dark — show "Location unavailable".
6. No-ship: replace starter teaser with EmptyState → Command.
