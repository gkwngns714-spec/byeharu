# Byeharu

A PvE space-strategy game (no PvP for now) — build bases, gather resources, move
fleets, fight pirates, explore sectors. Inspired by OGame / Tribal Wars / Travian
and EVE-style living-world ideas. Clean web-first rebuild.

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

> Authoritative roadmap — see `docs/ARCHITECTURE.md` §16. The MVP proves one loop:
> `map → location → movement → presence → combat → retreat → return → report`.
> Economy is **combat-reward-only** for now (buildings/production/training deferred — §17).

1. **Scaffold + auth** ✅ — Vite/React/TS/Tailwind/Zustand, Supabase client, `profiles`.
2. **World map** ✅ — `sectors`/`zones`/`locations` + seed + `get_world_map()` + read-only map screen.
3. **Movement + presence spine** ✅ — bases/units/config, fleets, `send_fleet_to_location()`,
   `process_fleet_movements()`, return; send → travel → present at a safe zone → return (no combat).
4. **Pirate combat** ✅ — `combat_encounters`/`ticks`/`reports`, `process_combat_ticks()`, wave
   scaling, per-unit HP, retreat, metal rewards on home-arrival; full pirate-hunt loop.
5. **Living world** ⬜ — `process_location_state_ticks()` + zone/location dynamics (pirate
   pressure / danger drift), wire all cron jobs together, balance.
6. **Frontend depth** ⬜ — location panel, send-fleet preview math, fleet status, active-combat
   panel, round log, report page — polished playable loop.
