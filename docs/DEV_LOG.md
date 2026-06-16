# Byeharu — Dev Log

Running record of **requests**, **work done**, **bugs**, and **fixes**.
Newest entries at the top. Dates are absolute (YYYY-MM-DD).

---

## 2026-06-17 — M4 combat overhaul: pacing + per-unit HP (verified 27/27)

**Request**
Browser feedback: waves one-shot (HP 195 vs 385 dmg), no visible wave progress,
only total fleet HP, unclear feed. Make combat readable + per-unit correct.

**Root cause**
Wave HP and wave damage were the SAME number → a 385-attack fleet one-shot a
195-HP wave. Fixed by decoupling: wave **HP** scales large with danger; wave
**attack** is a separate, smaller danger-scaled value.

**Backend (migrations 0023–0025)**
- `0023`: tick 2s→**4s**; config knobs `enemy_hp_base`(6), `enemy_hp_danger_scale`(0.6),
  `enemy_attack_base`(1.0), `enemy_attack_danger_scale`(0.25), `wave_transition_seconds`(3).
  New table **`combat_units`** (per-unit-type combat HP: ship_hp, initial/alive count,
  hp_max/current, carries over between waves). `combat_create_encounter` snapshots it;
  `process_combat_ticks` rewritten: decoupled HP/attack, **server-side damage
  distribution across unit groups by ship count**, deterministic ship loss
  (alive = ceil(hp/ship_hp)), `next_wave_at` transition, richer event payloads,
  `fleet_sync_quantities` to write survivors back to Fleet. encounter `wave_number`;
  ticks `wave_number` + `unit_snapshot_json`.
- `0024`: re-lock execute (also block anon/authenticated default).
- `0025`: `fleet_sync_quantities` → **SECURITY INVOKER** (Supabase re-grants execute to
  authenticated on new fns and resists revoke; invoker means a client call runs as
  authenticated with no fleet_units UPDATE grant → denied; internal caller runs as
  owner → works). Grant-independent lockdown.

**Frontend**
- `combatTypes`/`combatApi`/`useCombat`: `CombatUnit` + fetch combat_units; encounter
  wave fields. `ActiveCombatPanel`: total + **per-unit-type integrity bars**
  (alive/initial ships, HP, %), wave-incoming display, "latest exchange", richer debug.
- `CombatEventLayer`: meaningful text ("Missile salvo hit the pirate wave for N
  damage", "Pirates damaged Corvette group for N hull", "N Scout destroyed",
  "Wave N cleared. +M metal pending", "Wave N incoming").

**Verification — `verify:m4`: 27/27**
- Lockdown: process_combat_ticks / fleet_sync_quantities / base_add_resources denied.
- A: multi-tick wave (HP 252→37, dealt 215; not one-shot), per-unit HP present +
  decreasing via distribution, metal accrued, retreat→escaped, reward once, +metal,
  return via M3.
- B defeat: 0 rewards, base unchanged, no return, destroyed. C retreat-death: same.

**Remaining:** wave pacing is multi-tick but on the short side (~2 ticks for a strong
fleet at low danger); deeper balance deferred per request — tunable via game_config
(`enemy_hp_base`, `enemy_hp_danger_scale`).

---

## 2026-06-16 — M4 fixes from browser feedback (verified 26/26)

**Request**
Browser testing surfaced issues. Fix before M4 complete.

**Fixes**
1. **Reward-on-defeat bug (critical, backend):** defeat kept accrued
   `total_rewards_json`, so the report/pending looked rewarded. Migration `0022`:
   on defeat (both paths) `total_rewards_json = '{}'`, no `reward_grant`, no
   `base_add_resources`, no return. reward_grant only ever called on escaped/completed.
2. **Integrity model (backend):** added `player_integrity_max/current`,
   `enemy_integrity_max/current` on encounters and `*_integrity_before/after` on
   ticks. Persistent integrity pool decreases each tick (visible HP), unit losses
   incremental-proportional → explains "hull damaged, no ships destroyed". Frontend:
   Fleet/Pirate-wave HP bars + "Latest exchange" (you dealt / they dealt / losses).
3. **Retreat reward-locking (backend):** while `retreating`, fleet takes damage but
   deals none, clears no waves, accrues no rewards (locked at retreat). `0022` adds
   `retreat_started_at`; frontend shows "Retreating — escaping in Ns" countdown.
4. **Completed history:** collapsed into "Completed history: N previous run(s)".
5. **Wording:** "use the Retreat button in the combat panel" (non-positional).
6. **Balance:** left as-is per request (combat still easy; tune later).

**Verification — `verify:m4`: 26/26 PASSED**
- Anti-cheat lockdown (4 fns denied).
- A escape: integrity exposed, pending accrued, retreat → escaped, rewards locked
  (no farming), reward_grants ×1, base metal +once, return created.
- B defeat (1 scout): defeat, destroyed, report 0 rewards, 0 reward_grants, base
  unchanged, no return.
- C retreat-death (6 scouts): defeat, 0 rewards, base unchanged, no return.
- (verify script bug fixed: `.catch` on supabase builder → plain await.)

Deploy: GitHub Action ✅ (migration 0022). Frontend build green (88 modules).

---

## 2026-06-16 — M4 frontend (active combat UI, display-only)

**Request**
Build the M4 frontend only (no backend changes): ActiveCombatPanel, CombatEventLayer,
combat reports view, ~1–2s combat polling, SendFleetPanel allows pirate_hunt. Client
display-only; combat_events cosmetic; combat_ticks truth/log; keep boundaries.

**Work done (files)**
- `src/features/combat/` — `combatTypes.ts`, `combatApi.ts` (read encounters/events/
  ticks/reports + `request_retreat`), `useCombat.ts` (1.5s poll), `CombatEventLayer.tsx`
  (cosmetic missile/laser/explosion feed), `ActiveCombatPanel.tsx` (danger/waves/
  survivors/pending rewards/Retreat + combat_ticks debug log), `CombatReportsView.tsx`.
- `SendFleetPanel.tsx` — dispatch to safe **and** pirate_hunt locations (danger label
  + combat warning).
- `FleetStatusPanel.tsx` — present hunt fleets show "in combat" (retreat via combat panel).
- `Dashboard.tsx` — renders ActiveCombatPanel per active encounter + CombatReportsView,
  using a separate faster `useCombat` poll. `index.css` — `bh-fade-in` for event feed.

**Boundaries:** client display-only; only action is `request_retreat`; no client math;
events cosmetic, ticks read-only. No backend changes.

**Verification:** `npm run build` green (88 modules, no type errors); dev server HTTP 200
at http://localhost:5173/. Visual click-through handed to user.

---

## 2026-06-16 — M4 backend: server-authoritative pirate combat (verified)

**Request**
Build M4 backend: active-feeling combat (2s server ticks), 20s retreat, single-resource
metal rewards, 30-min forced auto-extract safety cap. Server owns all outcomes; client
animates cosmetic events later. Strict boundaries; backend first.

**Security finding (fixed in this milestone)**
Probed the live DB: M1–M3 internal `SECURITY DEFINER` functions (e.g.
`base_reserve_units`, `fleet_set_present`, `process_fleet_movements`) were
**client-callable** — Postgres grants `EXECUTE` to `PUBLIC` by default and PostgREST
exposes the whole `public` schema. That's an anti-cheat hole (client could mutate
units/fleet state). Fixed in `0021_lock_function_execute`: revoke execute on all
public functions from public/anon/authenticated, `alter default privileges` to block
future leaks, and grant execute only on the 6 client RPCs (`get_world_map`,
`bootstrap_me`, `send_fleet_to_location`, `request_leave_location`, `request_retreat`,
`get_combat_reports`). Verified denied post-deploy.

**Work done (migrations 0012–0021)**
- Base `base_add_resources`; Fleet `fleet_combat_stats` + `fleet_apply_losses`.
- Combat tables `combat_encounters` / `combat_ticks` (truth log) / `combat_events`
  (cosmetic stream); Reward `reward_grants` + idempotent `reward_grant`; Report
  `combat_reports` + `report_create` + `get_combat_reports`.
- `combat_create_encounter`, `combat_set_retreating`, **`process_combat_ticks()`**
  (2s, FOR UPDATE SKIP LOCKED, idempotent; one tick row + several event rows; wave
  scaling, power combat, losses, rewards, defeat/escaped/completed).
- Presence `activity_start` routes hunt_pirates→Combat; `presence_request_leave`
  combat-retreat branch. Player RPCs: allow hunt sends (+min_power), `request_retreat`.
- Config: combat_tick_seconds 12→2, retreat_delay 30→20, max_presence_seconds 1800,
  reward_metal_base 10. Cron `process-combat-ticks` every 2s.

**Deploy:** GitHub Action run 27623526054 ✅ — 0012–0021 applied (incl. 2s cron + lockdown).

**Verification — `verify:m4`: 20/20 PASSED**
- Lockdown: 4 internal fns denied to client.
- Success: dispatch hunt → arrival → encounter active → ticks/waves/events accrue
  (danger rising) → retreat → escaped → fleet returning + return movement → reward
  granted exactly once (315 metal in base). `verify:m3` still 13/13 (lockdown safe).
- Defeat: 1 scout vs Pirate Den → wiped → defeat → fleet destroyed → defeat report →
  no return, no reward.

**Next:** M4 frontend (ActiveCombatPanel + cosmetic CombatEventLayer) — awaiting go.

---

## 2026-06-16 — ✅ M3 COMPLETE

Browser click-through passed; M3 accepted. Criteria met: units return correctly,
fleets complete correctly, no duplicate fleets, no console errors, no backend
errors. One UI wording bug found + fixed (`arriving in arriving…` →
`awaiting server confirmation…` once the client clock hits zero, while the cron
resolves; backend untouched).

**M4 requirement captured (user):** combat must feel MORE active than movement.
Movement stays slow (cron ~30s OK). Combat needs **faster server combat steps**
(tune `game_config.combat_tick_seconds`) and **client-side `combat_events` for
missile/laser visuals** — cosmetic, driven by server-authoritative results, never
client authority. Do NOT optimize movement's zero-countdown gap.

M4 not started — awaiting go-ahead.

---

## 2026-06-16 — M3 frontend (Command Center)

**Request**
Build the M3 frontend to click the live loop: base → send fleet → countdown →
present → leave → return → units restored. Keep modules separated; client only
requests + renders; M2 map read-only.

**Work done (files)**
- `src/game/movement/travelPreview.ts` — client ETA PREVIEW math only (mirrors
  server formula; not authoritative).
- `src/lib/catalog.ts` — shared `unit_types` read.
- `src/features/base/` — `baseTypes.ts`, `baseApi.ts` (ensureBase/fetch*),
  `BasePanel.tsx` (base + resources + units at base).
- `src/features/fleets/` — `fleetTypes.ts`, `fleetApi.ts` (send/leave + reads),
  `SendFleetPanel.tsx` (pick safe location + quantities, preview ETA),
  `FleetStatusPanel.tsx` (status/dest/countdown + leave button).
- `src/features/dashboard/useGameState.ts` — single 3s poll loop; panels stay
  presentational. `Dashboard.tsx` composes the panels (Command Center).

**Boundaries:** base UI in features/base, fleet UI in features/fleets, preview-only
math in game/movement; M2 map untouched/read-only; no client-side game authority
(all mutations via RPCs); reusable for future combat/trading/captains.

**Verification**
- `npm run build` green (tsc + vite, 83 modules, no type errors).
- Dev server serving HTTP 200 at http://localhost:5173/.
- Backend loop already proven by `verify:m3` (13/13) — frontend calls the same RPCs.
- Visual/console click-through: handed to user (browser).

**Bugs / fixes**
- _(none in build)_

---

## 2026-06-16 — M3 backend built, deployed, and verified live

**Request**
Build M3 (movement + presence spine, no combat), deploy via GitHub Action, verify
the full backend loop. Keep systems separated; server authoritative.

**Work done**
- M3a migrations `0003`–`0005`: game_config, unit_catalog, base_system
  (bases/units/resources + initialize_new_player + signup bootstrap + backfill).
- M3b migrations `0006`–`0011`: fleet_system, movement_system, presence_system,
  movement_processor, player_rpcs, cron_movement (pg_cron 30s).
- Switched deploy to the free GitHub Action (3 secrets in GitHub UI). First run
  failed at *Link project* — invalid `SUPABASE_ACCESS_TOKEN` secret; after user
  re-added a valid `sbp_` token, re-run succeeded.
- Wrote `scripts/verify-m3.mjs` (throwaway-user integration test) + `verify:m3`.

**Deploy result — GitHub Action run 27619768482: ✅ success**
- Migrations `0003`–`0011` all applied to remote, incl. `0011` (pg_cron enabled,
  job `process-fleet-movements` scheduled every 30s, no permission error).

**Verification — `verify:m3`: 13/13 PASSED**
bootstrap → base → starting units(100/20/5)+resources → dispatch to "Safe Rally
Point" → movement row (5.0s, dist 12.1) → units reserved 100→90 → processor resolves
arrival → fleet present + presence active(none) → leave → return movement
(return_home) → processor resolves → fleet completed → survivors merged 90→100.

**Bugs / fixes**
- Deploy 1 failed: bad `SUPABASE_ACCESS_TOKEN` secret (JWT could not be decoded) →
  user re-added valid token → re-run green.
- verify:m3 v1: Supabase rejected `.test` email domain + a Node/libuv exit crash
  (auth auto-refresh timer). Fixed: use `@example.com`, `autoRefreshToken:false`,
  clean exit via `process.exitCode`.
- Email confirmation was ON → signup rate-limited; user disabled "Confirm email".

**Follow-ups**
- A few throwaway `m3test.*@example.com` users exist in auth (each with a base);
  harmless, can prune later.
- M3 frontend (base view, send-fleet panel, fleet status) is next.

---

## 2026-06-16 — M2 verified live against real Supabase

**Request**
Verify M2 against a real database before M3. Apply migrations (no manual SQL paste,
no secrets in chat).

**Setup**
- Supabase project created (ref `dlkbwztrdvnnjlvaydut`, Free plan, Asia-Pacific).
- GitHub repo `gkwngns714-spec/byeharu` (private) created; full project pushed.
- User chose Supabase's **native GitHub integration** + connected the repo.

**Work done**
- `.env.local` written with Project URL + **publishable** key (`sb_publishable_…`);
  git-ignored. Frontend uses publishable key only (never secret/service_role).
- Secrets handled via local git-ignored `supabase/.secrets.env` (access token +
  db password), loaded into transient env vars, **never** printed or committed;
  file deleted immediately after `db push`.
- Applied migrations via `npx supabase link` + `npx supabase db push`
  (`20260616000001_init_profiles`, `20260616000002_world_map`).

**Result — `npm run verify:m2`: 11/11 PASSED**
- Data: 2 sectors / 2 zones / 5 locations; nested sectors→zones→locations;
  3 pirate_hunt + 2 safe_zone.
- RLS read: anon can read sectors/zones/locations.
- RLS write-denial: insert blocked (42501 insufficient_privilege — SELECT-only grant),
  update/delete affect 0 rows.
- Frontend: dev server up at http://localhost:5173/ for click-through.

**Bugs / fixes**
- Native GitHub integration did **not** auto-deploy on Free plan (first verify found
  no tables). Applied via CLI instead. Future migrations need a deploy decision
  (upgrade for native, or use the free GitHub Action with secrets in GitHub UI).
- The redundant custom Action `deploy-migrations.yml` fails on push (no secrets set);
  left in place pending the deploy-mechanism decision.

**Follow-ups**
- Rotate/revoke the temporary Supabase access token (it lived only in the deleted
  local file, but rotate as good hygiene).
- Decide future migration deploy mechanism before/at M3.

---

## 2026-06-16 — System boundaries approved; M2 (read-only world map)

**Request**
Before coding, define strict system boundaries (sole writer per table, acyclic
cross-system call graph via exposed functions only). Approve and persist, then build
M2 as a **read-only** world map: `sectors`/`zones`/`locations` + seed +
`get_world_map()` + map screen. No movement/fleets/presence/combat/rewards/resources.

**Decisions made**
- Approved all 5 beyond-spec ownership additions: **Fleet**, **Base**, **World State**
  systems as sole owners of their shared tables; **`reward_grants`** ledger as the only
  reward-application path; **Activity** table-less router. _Why:_ enforces every
  separation law with a single-writer-per-table rule and prevents hidden coupling.
- M2 scope locked to the 3 static Map tables only; `zone_state`/`location_state`
  deferred (they belong to World State, built later) so Map stays pure.

**Work done**
- Wrote `docs/SYSTEM_BOUNDARIES.md` (table→sole-writer matrix, per-system
  owns/exposes/forbidden, the 5 allowed call-edges, forbidden edges, invariant
  checklist).
- **M2 migration** `20260616000002_world_map.sql`: `sectors`/`zones`/`locations`
  (static, Map-owned) with CHECK constraints + FKs + unique(sector,name)/(zone,name);
  public-read RLS, no write policies (no client writes); `get_world_map()` (nested
  jsonb, `stable`, granted to anon/authenticated); seed = 2 sectors / 2 zones /
  5 locations (mix of `safe_zone` + `pirate_hunt`).
- **M2 frontend**: `features/map/` (`mapTypes.ts`, `mapApi.ts`, `MapPage.tsx`);
  `/map` route (auth-guarded); "Open galaxy map" link on Dashboard.
- Verified: `npm run build` green (tsc + vite, 75 modules). SQL not run locally
  (no psql/docker/supabase CLI on this machine) — reviewed by hand; first live run
  on migration apply.

**Bugs / fixes**
- _(none)_

**Follow-ups for user**
- Apply migrations + set `.env.local`, then the map screen loads live data.
- M2 shows Map-owned fields only (name/type/danger/reward). Distance & travel-time
  need a base + movement formula → arrive in M3.

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
