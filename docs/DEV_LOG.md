# Byeharu — Dev Log

Running record of **requests**, **work done**, **bugs**, and **fixes**.
Newest entries at the top. Dates are absolute (YYYY-MM-DD).

---

## 2026-06-16 — Foundation architecture & milestone plan (no code)

**Request**
User supplied a detailed server-authoritative PvE design spec (map → location →
movement → presence → activity → combat → retreat → return → report) and asked to
**plan only, no code yet**, then persist the design as living docs.

**Decisions made**
- **Economy = combat-reward only (Option 1).** Seed a starter base + starter units;
  resources come solely from pirate-combat rewards landing in `base_resources` at
  encounter end. _Why:_ the priority is proving the core world/loop foundation, not
  the economy. Adding production/buildings/training now would build too many systems
  at once and make bugs hard to isolate. Deferred: buildings, build queues, passive
  production, lazy resource accrual, unit training, research, trade/market, cargo.
- **Sequencing = movement+presence spine first (M3), combat second (M4).** _Why:_
  spec keeps movement and combat as separate systems bridged by presence; proving the
  movement→presence→return spine on a harmless `safe_zone` first isolates any later
  combat bugs to the combat system (which the `combat_rounds` table is built to debug).
- **Write architecture docs before any game code.** _Why:_ the spec is large and
  prescriptive; capturing it as `docs/ARCHITECTURE.md` makes it the source of truth so
  every milestone (and future session) follows the same modular, anti-cheat,
  server-authoritative rules instead of re-deriving them.

**Gap resolutions agreed (added beyond original spec)**
- `base_resources` table — rewards need somewhere to land (not an economy system).
- `initialize_new_player()` — seeds starter base + units + resources (no training in MVP).
- `game_config` table — tunable balance (travel_scale, max_active_fleets, tick/retreat
  seconds, reward multipliers, random variance) without code redeploys.

**Work done**
- Verified Supabase Cron supports sub-minute (seconds) schedules on Postgres
  15.1.1.61+ → 30s movement / 10–15s combat / 60s location-state ticks are feasible.
- Wrote `docs/ARCHITECTURE.md` (core principle, world hierarchy, all systems, combat
  formulas, anti-cheat, RLS/RPC, state machines, constraints/locking/idempotency,
  cron timing, MVP table list, milestone roadmap M1–M6, deferred list).
- No game code or migrations written yet (next step: M2 world map, after review).

**Bugs / fixes**
- _(none — planning only)_

---

## 2026-06-16 — Rename to Byeharu

**Request**
Change the game name to **Byeharu** (the initial scaffold used "Byeolharu"; user
confirmed the shorter spelling).

**Work done**
- Renamed project folder `byeolharu` → `byeharu`.
- Updated `package.json` / `package-lock.json` name, `index.html` title, README,
  the migration comment, the Supabase client warning tag, and the AuthPage /
  Dashboard headings from "Byeolharu" to "Byeharu".
- Updated saved project memory.

**Bugs / fixes**
- _(none)_

---

## 2026-06-16 — Milestone 1: Scaffold + auth

**Request**
Rebuild the PvE space-strategy game from scratch as a clean web-first project named
**Byeolharu**. Stack: React + TypeScript + Vite, Tailwind, Zustand, Supabase
(Postgres + Auth + RLS + RPC + pg_cron). Server-authoritative, modular systems,
milestone-by-milestone. First milestone: scaffold + basic auth structure.

**Work done**
- Created Vite React+TS project at `C:\Users\디폴리스\byeharu`.
- Installed `zustand`, `@supabase/supabase-js`, `react-router-dom`, and
  `tailwindcss` + `@tailwindcss/vite` (Tailwind v4).
- Wired Tailwind via the Vite plugin (`vite.config.ts`) and `@import 'tailwindcss'`
  in `src/index.css`.
- Supabase client at `src/lib/supabase.ts`; env typing in `src/vite-env.d.ts`;
  `.env.example` with `VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY`.
- Auth: Zustand store `src/store/authStore.ts` (session, signIn/signUp/signOut,
  `init()` listener); `src/features/auth/AuthPage.tsx` (login/signup);
  `src/app/RequireAuth.tsx` route guard; routing in `src/app/App.tsx`.
- Placeholder `src/features/dashboard/Dashboard.tsx`.
- DB: migration `supabase/migrations/20260616000001_init_profiles.sql` —
  `profiles` table, RLS (own-row read/update), auto-create-profile trigger on
  `auth.users` (SECURITY DEFINER).
- CI: `.github/workflows/deploy-migrations.yml` to `supabase db push` on push to
  `main`.
- Removed default Vite demo files (`App.tsx`/`App.css`/sample assets); updated
  `index.html` title and `.gitignore` for env files.

**Bugs / fixes**
- _(none yet)_

**Open follow-ups**
- User must create a Supabase project and fill `.env.local`.
- For CI: add repo secrets `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_ID`,
  `SUPABASE_DB_PASSWORD`.
- Run `npm run build` / typecheck once `.env.local` exists to confirm green.

---
