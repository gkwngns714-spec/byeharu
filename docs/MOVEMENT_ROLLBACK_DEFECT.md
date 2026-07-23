# ⚠ DEFECT — the documented unified-movement rollback is BROKEN (recorded 2026-07-23)

> Docs-only record. Nothing here changes code, migrations, flags, or production.
> Companion to `MOVEMENT_UNIFICATION_CHARTER.md` and `HANDOFF.md`.

## The claim that is no longer true

Two places promise a **one-command, reversible** rollback of the 2026-07-18 unified-movement flip:

- `scripts/activate-unified-movement.sql:310-319` — a commented `begin; …four set_game_config writes…; commit;`
  block that re-lights `mainship_send_enabled`, `mainship_space_movement_enabled`,
  `mainship_coordinate_travel_enabled` and darkens `fleet_movement_unified_enabled`.
- `MOVEMENT_UNIFICATION_CHARTER.md:20-24` — "**ROLLBACK (one command, reversible)**".

**That escape hatch no longer exists.** It is documentation debt, not a live capability.

## Why it is broken

The post-flip cleanup that shipped after the flip removed the machinery those three flags gate:

| Migration | What it did | Effect on rollback |
|---|---|---|
| `20260618000231_movement_schema_drop.sql` | drops `main_ship_instances.spatial_state` / `space_x` / `space_y` (`:1559-1562`); unschedules the dead `process-mainship-space-arrivals` cron (`:1580-1586`) | the per-ship movement **columns are gone** |
| `20260618000232_movement_function_drop.sql` | hard-drops **20** functions (`:231-264`) — the legacy expedition RPCs, the whole OSN coordinate command surface + internal engine, the legacy settle pair, the dead cron processor, and the two orphaned team-group RPCs | the per-ship movement **functions are gone** |

Re-lighting a flag cannot resurrect a dropped function or a dropped column. The per-ship travel path is
**not merely gated — it is physically dropped.**

## The concrete failure mode (worse than "no-op")

`public.command_main_ship_stop_transit(uuid)` **survives** `0232` (it is not in the drop list). Its TRUE
head is `20260618000155_mainship_legacy_stop_holds_in_space.sql:60`.

- It gates on `mainship_send_enabled` as its first statement and today returns a clean
  `{ok:false, code:'feature_disabled'}` (`:81-82`).
- But its body **reads `main_ship_instances.spatial_state`** (`:102-103`) and **writes `spatial_state`,
  `space_x`, `space_y`** (`:152-154`) — all three columns dropped by `0231`.

So re-lighting `mainship_send_enabled` would **convert a clean, harmless reject into a runtime
`column … does not exist` raise** for any player who presses stop. The rollback does not merely fail to
restore the old behaviour; it replaces a safe refusal with an error.

## What a real rollback would now require

New **forward** migrations that re-create the dropped columns, re-create the dropped functions at their
true heads, backfill per-ship spatial state from the fleet layer, and re-schedule the removed cron — i.e.
a rebuild slice with its own CI apply-proof and its own production gate. There is no flag-only path back.

The pre-existing caveat in `activate-unified-movement.sql:303-309` (members of a group that already ran a
unified go read `contradictory_state`/hidden after a rollback and need manual reconciliation) still stands
**on top of** this — it was never the whole story.

## Status

- Recorded as a defect. **No fix is proposed or applied here** — the remedy is the owner's call.
- The rollback text in `scripts/activate-unified-movement.sql` and in the charter has NOT been edited by
  this docs change (the script is out of scope for a docs-only PR); the charter now carries a superseded
  marker pointing here.
