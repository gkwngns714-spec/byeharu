# Byeolharu

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

1. **Scaffold + auth** ✅ — Vite/React/TS/Tailwind/Zustand, Supabase client, auth.
2. Living base — data model + RLS + lazy resource accrual.
3. Buildings + build queue.
4. Fleets + movement.
5. Galaxy map + pirate pressure (co-op PvE layer).
6. Combat + reports.
7. Balance + polish + deploy.
