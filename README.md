# Byeharu

A PvE **main-ship expedition game** (no PvP for now). You command **one main ship** —
captains, modules, support craft, cargo — and send **expeditions** to pirate / trade /
exploration / mining locations, then return home to secure loot, profit, resources, and
ranking points and grow stronger. Server-authoritative, web-first.

> Core fantasy: *my ship and crew go on dangerous expeditions, return with rewards, and
> become stronger.* The current engine (movement → combat → retreat → return → reward)
> is the **expedition engine**; the forward direction is in **`docs/ROADMAP.md`**.

## Current status (2026-06-29)

- **Production migration head: `0070`.** Three starter ports (Haven, Slagworks, Driftmarch) are
  **active/public**. *(Renamed 2026-07-05 by forward-only migration `0148` — UX cleanup item 4, one-word
  display names; formerly Haven Reach / Slagworks Anchorage / Driftmarch Waypost. Fixed UUIDs unchanged.)*
- **OSN port-to-port travel is enabled** — a ship docked at a port can travel port-to-port. **Free
  arbitrary-coordinate travel is server-disabled by default** (`mainship_coordinate_travel_enabled = false`).
- **Phase 9 is live:** a read-only **docked-port surface** (`get_my_current_dock_services()` + `DockServicesPanel`)
  shows the current port + its active services when the ship is docked (today: **Docking**).
- **Phase 10 Trading V1 is designed but not built.** Its prerequisite is **main-ship provisioning** (a brand-new
  player has no ship yet) + a canonical port-entry transition. See `docs/DEV_LOG.md` (2026-06-29 entry) for the
  authoritative state and the **forward plan**, and `docs/ROADMAP.md` for the phase plan.

## Stack

- **Frontend:** React + TypeScript + Vite
- **Styling:** Tailwind CSS (v4)
- **State:** Zustand
- **Backend:** Supabase — Postgres, Auth, RLS, RPC functions, pg_cron

## Architecture principles

1. **Server-authoritative.** The client requests actions; the server validates and
   decides the result. Never trust the client for important game state.
2. **Modular systems.** Resources, buildings, fleets, map, movement, combat,
   pirates, captains, trading, research, and reports are kept as separate systems —
   not tightly coupled.
3. **All important mutations go through Supabase RPC functions.**
4. **Lazy resource accrual** for resources; **scheduled event processing** (pg_cron)
   for timers, fleet arrivals, combat resolution, pirate pressure, and build-queue
   completions.
5. Clean, simple, maintainable code over clever code.

## Folder structure

```
src/
  app/        routing + app-level providers (App, RequireAuth)
  features/   one folder per game system (auth, dashboard, …)
  components/ shared UI (added when needed)
  lib/        supabase client, shared hooks/types
  store/      zustand stores
  game/       shared game math/constants mirrored with the server (added when needed)
supabase/
  migrations/ SQL: tables, RLS, RPC functions, pg_cron
docs/
  DEV_LOG.md  running record of requests, work, bugs, and fixes
```

## Setup

```bash
npm install
cp .env.example .env.local   # then fill in your Supabase URL + anon key
npm run dev
```

Apply the database migrations to your Supabase project (via the Supabase CLI
`supabase db push`, or by pasting `supabase/migrations/*.sql` into the SQL editor).

## Milestones

> The forward direction (Main Ship + Support Craft + Activities + Ranking) lives in
> **`docs/ROADMAP.md`**; engine design in `docs/ARCHITECTURE.md`; ownership law in
> `docs/SYSTEM_BOUNDARIES.md`; running history in `docs/DEV_LOG.md`.

### Foundation — built & verified (KEEP; reclassified, not rewritten)
- **M1** ✅ Scaffold + auth.
- **M2–M4 = the Expedition Engine** ✅ — world map · bases/fleets/movement · pirate combat
  (3s ticks, waves, per-unit HP, retreat) · return · **reward deposit only on home arrival** ·
  combat report. *(Verified: M2 11/11 · M3 13/13 · M4 40/40.)* Reused by every future activity.
- **M5** ✅ Living world — `location_state`/`zone_state`, 60s cron, pressure decay to baseline.
- **M6** ✅ Frontend depth — location panel, round log, `/reports`, friendly UI.
- **M7** ✅ Metal-spend ship training.
- **M4.5 = the Serial Build Queue Foundation** ✅ — serial queue · one active slot · cancel +
  refund/penalty · per-ship + total time · history fold · friendly labels. *(Verified
  27/27 + a Playwright browser-acceptance test.)* Future meaning: **support craft / module /
  drone / equipment production** (same queue).

### Forward direction
Byeharu is a **main-ship expedition game**: one main ship + captains + modules + support
craft → expedition → activity (`pirate_hunt` / `trade_run` / `exploration` / `mining`) →
return → secured loot → craft/upgrade. **Support craft are capacity-limited loadout choices,
not additive power.** Phased plan (incremental, M2–M4.5 green throughout) in
**`docs/ROADMAP.md`**.
