# Byeharu — Dev Log

Running record of **requests**, **work done**, **bugs**, and **fixes**.
Newest entries at the top. Dates are absolute (YYYY-MM-DD).

---

## 2026-07-04 — FITTING-P14 SLICE F — dark frontend: the fitting section EXTENDS `src/features/modules/` (fit/unfit controls inside ModulesPanel; renders nothing while either flag is dark). Frontend only — no migration

**Request.** Implement slice F: the dark fitting UI as a minimal extension of the existing
`src/features/modules/` feature. NO migration (head stays **0116**), no config, no verify script.
Read end-to-end first: `modulesTypes.ts` / `modulesApi.ts` / `ModulesPanel.tsx`, the shared
`src/lib/useActivityPanelGuards.ts`, the `GalaxyMapScreen.tsx` mounting, the `mainshipApi.ts`
ship-reading convention, and the twins' `crypto.randomUUID()` request-id idiom.

**DECISION — EXTEND, don't duplicate (locked):** the fitting UI extends `ModulesPanel` rather than
adding a parallel panel, because the panel already lists the player's module instances and a second
panel would duplicate that list (the no-duplication rule). **CONSEQUENCE (recorded honestly): the
fitting section is server-gated TWICE** — it renders only when the CRAFTING read surface is lit
(the panel's existing `isServerLit` gate on `get_my_module_instances`, `module_crafting_enabled`)
AND `get_my_ship_fittings` answers ok (`module_fitting_enabled`) — it fails closed both ways and
renders NOTHING today. With both flags `'false'` the fittings RPC is not even called (it rides the
lit branch); with crafting lit and fitting dark, every fitting element is behind a
`litFittings &&` gate, so the rendered output is exactly the pre-slice-F markup.

**Work done (4 files, all existing modules — no new feature dir, no GalaxyMapScreen change):**
- **`modulesTypes.ts`** — added the fitting types: `ShipFittingRow` (the seven 0116 fields) +
  `GetMyShipFittingsResult`; `FittingCommandResult` (the 0113/0114 wrapper envelopes — success
  passes the writer's fitted/unfitted + slot facts through with the replay flag; failure carries
  code/message with the real `insufficient_slots` `{used, cost, limit}` and `already_fitted`
  `{main_ship_id}` context); and the `FITTING_ERROR_COPY` map + `fittingErrorMessage()` covering
  `feature_disabled` / `invalid_request` / `ship_not_settled` / `module_not_owned` /
  `ship_not_owned` / `already_fitted` / `not_fitted` / `insufficient_slots` /
  `not_authenticated` / `unavailable`. The read reason `module_fitting_disabled` is handled by
  fail-closed rendering, not copy (stated in the section header).
- **`modulesApi.ts`** — three thin wrappers in the existing envelope idiom (transport error →
  normalized failure, never a throw into the render path): `getMyShipFittings()`,
  `fitModuleToShip(moduleInstanceId, mainShipId, requestId)`,
  `unfitModuleFromShip(moduleInstanceId, requestId)`.
- **`mainshipApi.ts`** — minimal extension INSIDE the existing module (never a second ship-select
  elsewhere): the ship column list was extracted to `SHIP_COLS` (now used by both selects) and
  `fetchMyMainShips()` added — the multi-ship-ready LIST variant of `fetchMyMainShip` (same
  owner-read RLS, same columns incl. `module_slots`; `[]` on error, non-fatal).
- **`ModulesPanel.tsx`** — the fitting section: `getMyShipFittings()` rides the existing lit-branch
  read batch (mount + `lifecycleKey`); ships fetched only once fitting is lit. Per instance row
  (all double-gated): fitted state joined from the fittings result by `module_instance_id`
  ("Fitted → <ship name>" + an Unfit control), or a fit control — ship picker over the player's
  ships labeled `name (Σ slot_cost used / module_slots)` computed from the already-loaded fittings
  data (**display-only arithmetic; `fitting_apply`'s hard cap + the 0114 settled-SAFE rule remain
  the enforcer**, commented in place) + a Fit button. Each command generates a fresh
  `crypto.randomUUID()` request id (the twins' idiom; the server dedups on (player_id,
  request_id)), claims the row synchronously via the shared `tryClaim(instance_id)` (craft rows
  key by catalog slug, fitting rows by instance uuid — the key spaces cannot collide, noted),
  disables the row while in flight, renders the server's message (falling back to the copy map,
  with the real `{used, cost, limit}` suffix on `insufficient_slots` — the insufficient_items
  idiom), and refetches instances + fittings on success. One shared `runFitting()` executes both
  commands (no duplicated submit block).

**Doc-sync note.** `docs/SYSTEM_BOUNDARIES.md` needs NO change — confirmed and stated (the
MODULES-P13 SLICE E precedent): frontend-only; no table, no writer, no cross-system edge; the
client reads/commands only through the shipped RPCs (0113/0114/0116) and the existing owner-read
selects.

**State.** `npm run build` green (tsc -b + vite, exit 0 — this slice DOES touch src; one TS error
was caught and fixed during the slice: a double-wrapped `Promise<ReturnType<…>>` in the shared
submit helper's type). Targeted eslint on all four touched files: exit 0. **Dark-render trace
(manual, per the request):** with both flags `'false'` the panel's first read returns
`module_crafting_disabled` → `isServerLit` false → the panel renders `null`, byte-identical to
before this slice (the fittings RPC is never called); with crafting lit + fitting dark every added
element is behind `litFittings &&` → the instances list renders the exact pre-slice markup.
Migration head stays **0116**; `module_fitting_enabled='false'`; nothing flipped, no live DB
write, no workflow touched. PR-ready on `autopilot/20260703-064048`, `main` untouched. Next:
slice G (`scripts/verify-fitting.mjs` + the `verify:fitting` package.json entry).

---

## 2026-07-04 — FITTING-P14 SLICE E — the dark read surface `0116` (`get_my_ship_fittings()`). **Server side of Phase 14 complete, fully dark**

**Request.** Implement slice E: ONE new forward-only migration with the read surface, mirroring the
modules read surface (0110, the 0101/0106 family) — re-read end-to-end first. NO write path, NO new
table, NO frontend, NO verify script this slice; flag stays `'false'`.

**Work done — NEW `supabase/migrations/20260618000116_fitting_p14_read_surface.sql`** (migration
head moves **0115 → 0116**; `0001–0115` unedited):
- **`get_my_ship_fittings()`** — the 0110 body idiom (jsonb envelope · `stable` ·
  `security definer` · `set search_path = public` · jsonb_agg row shape + coalesce-to-`[]` ·
  `{ok:true, fittings:[…]}` plural envelope), with ONE deliberate divergence recorded in the
  header: **the dark gate runs FIRST, then auth** (0110 checks auth first) per the slice spec —
  `{ok:false, reason:'module_fitting_disabled'}` identically for every caller while dark (the
  frontend's server-driven visibility signal; anon has no execute grant anyway), then the 0110
  `not_authenticated` posture. Per row: `module_instance_id`, `main_ship_id`, `fitted_at`,
  `module_type_id`, plus the catalog display fields the future panel needs (`name`, `slot_type`,
  `slot_cost`), joined DOWNWARD via `module_instances` to `module_types`; ordered `fitted_at` desc
  **then `module_instance_id`** (determinism — the 0110 ordering idiom + a uuid tiebreak since
  several fittings can share a timestamp). Rows are scoped `player_id = auth.uid()` IN THE QUERY
  (defense in depth over the 0112 own-row RLS, as 0110 does).
- **NO catalog RPC** (the 0110 stance restated in the header): `module_types` (incl. the 0111
  `slot_cost`/`stats_json`) is a public-read Reference/Config catalog read by direct client
  select — an RPC would duplicate an already-public surface.
- **DECISION — deliberately NO ship `module_slots` in this RPC** (recorded so the omission is
  never read as forgotten): the slot LIMIT belongs to the ship, not the fitting rows — the client
  reads its own `main_ship_instances` rows (the 0043 own-row grant covers `module_slots`) or
  `get_my_expedition_preview` (whose stats carry `module_slots_used`/`module_slots_limit` since
  0115). The surface stays dumb — fitting rows only.
- **ACL (0110:72–75 verbatim):** execute revoked from public/anon, granted to authenticated only —
  and dark today: the gate rejects every call while `module_fitting_enabled='false'`. Table RLS
  unchanged.

**Doc-sync (same step).** `docs/SYSTEM_BOUNDARIES.md`: the §2 Fitting row gained
`get_my_ship_fittings()` with its gate-first semantics, the no-catalog-RPC stance, and the
no-ship-limit decision. The **§1 matrix is UNCHANGED — confirmed and stated**: no new table, no new
writer (the 0101/0106/0110 precedent: read surfaces are recorded in the §2 system row, not the
matrix).

**State.** `npm run build` green (no `src/` change was made — confirmed). Migration head **0116**;
`module_fitting_enabled='false'` everywhere. **The server side of Phase 14 Module fitting is
COMPLETE (slices A–E) and fully dark end-to-end:** the flag + stats catalog (0111), the fittings
table + THE ONE writer (0112), the two-layer fit/unfit command + receipts (0113, settled-SAFE rule
0114), the adapter integration (0115), and the read surface (0116) — every client-reachable
surface server-rejects while the flag is false; the writer/command internals are
service_role-only. No flag flipped, no live DB write, no workflow touched. **DB-apply posture
(honest, unchanged):** no psql/docker/supabase CLI in this sandbox — the migration was
hand-verified line-by-line against 0110 at the idioms cited above; live assertions run in the
owner's environment and will be covered by the slice-G `verify:fitting` dark-posture script.
PR-ready on `autopilot/20260703-064048`, `main` untouched. Next: slice F (dark frontend
`src/features/fitting/` or a minimal `src/features/modules/` extension), then slice G
(`scripts/verify-fitting.mjs` + the `verify:fitting` entry).

---

## 2026-07-04 — FITTING-P14 SLICE D — stats integration `0115` (fitted modules feed `calculate_expedition_stats` under the `module_slots` hard cap; re-create of the 0044 adapter)

**Request.** Implement slice D: ONE new forward-only migration re-creating the stat adapter so
fitted modules feed expedition stats via capacity/tradeoff — ROADMAP law 4's "replace the SOURCE
of stats … capacity + tradeoffs, never a plain sum", now real for modules. NO frontend, NO verify
script, NO wrapper/writer/receipts change this slice. Read first, end-to-end: `0044` (the function
being re-created), `0049` (its only live caller), and BOTH pinning scripts.

**What the pinning scripts actually assert (checked, not assumed):**
- `verify-phase8.mjs` asserts specific field VALUES (empty loadout → `support_capacity_used 0`,
  `limit 10`, `combat_power 0`, `speed 1`, `cargo_capacity` = ship's; per-craft deltas;
  rejection/exception cases; determinism = two identical calls compared to each other; ship +
  inventory not mutated) and LIST-membership finiteness over its `NUM_FIELDS` array (`:38–39`,
  `.every(...)`) — it never asserts an exact key SET, so ADDING keys is safe.
- `verify-mainship-preview.mjs` (reported per the request): asserts envelope/value checks only —
  `has_ship`/`valid` flags, `stats.support_capacity_limit === 10`/`used === 0`/`combat_power === 0`
  (`:52–54`), `used === 3` + `combat_power > 0` for one missile_boat (`:56–58`), over-capacity →
  `valid:false` with an error message matching `/capacity/i` (`:60–62` — the support-capacity
  exception text is unchanged, so this still matches), unknown craft → `valid:false`, no-ship →
  hull-teaser fields, preview-writes-nothing, and the adapter still denied to clients. It also
  never asserts an exact key set — additive keys are safe here too.

**Work done — NEW `supabase/migrations/20260618000115_fitting_p14_stats_adapter.sql`**
(migration head moves **0114 → 0115**; `0001–0114` unedited): `create or replace
calculate_expedition_stats` — SAME signature, support-craft path byte-identical, and the module
feed ADDED between the loadout capacity check and the final jsonb build:
1. **Read** the ship's fit set: `ship_module_fittings` (for `v_ship.main_ship_id`) →
   `module_instances` → `module_types` (`slot_cost`/`slot_type`/`stats_json` — the 0111 columns'
   FIRST code consumer). Pure downward read; no player filter needed — the existing owned-ship
   read plus `fitting_apply`'s owner-consistency invariant (0112) guarantee the fit set is the
   player's (commented in place).
2. **Capacity** — 0044:112–115 verbatim: `Σ slot_cost > v_ship.module_slots` → `raise exception`.
   Defense-in-depth: fit-time enforcement in `fitting_apply` is primary; the adapter still refuses
   to compute from an over-capacity state rather than clamp or trust it.
3. **Contributions** into the SAME accumulators the loadout loop uses
   (a_combat/a_survival/a_repair/a_cargo/a_scout/a_mining/a_retreat), exact key list
   attack/defense/repair/cargo/scan/mining/evasion, coalesced to 0 — one stat pipeline, no
   parallel module pipeline.
4. **Speed** — Σ `speed_mult_bonus` applied BEFORE penalties (the slice-A locked model):
   `round(greatest(0.2, v_speed * (1 + v_mod_speed_bonus) * (1 - a_spd_pen)), 3)` — floor and
   rounding untouched; zero modules reduces the expression to 0044's exactly.
5. **Tradeoffs (numbers + rationale, recorded):** slot_type CASE × `slot_cost` (the module
   analogue of ×qty) — **weapon** → attention +2·cost, speed_pen +0.03·cost; **cargo** →
   attention +2·cost, speed_pen +0.04·cost; **sensor** → attention +1·cost; **engine** → no
   tradeoff. Rationale: weapons/cargo mirror the 0044 combat_damage/cargo role tradeoffs — more
   firepower / a bigger hold draws pirates and slows the burn; active sensors emit (attention
   only); the engine's cost is the slot itself. Unknown/future slot_types contribute stats but no
   tradeoff (CASE else 0 — 0044's permissive unmatched-role posture). No activity-tag warning for
   modules — `module_types` has no `activity_tags` column.
6. **Output** — exactly two added keys, `module_slots_used`/`module_slots_limit`, mirroring the
   support-capacity pair. **THE COMPATIBILITY CONTRACT:** a ship with no fitted modules returns
   today's values for every pre-existing key — which is what keeps verify:phase8 /
   verify:mainship-preview green; and no fitted module can exist anywhere until the owner flips
   the dark flag.
- **ACL** re-asserted with the targeted idiom (0084/0113/0114 posture; same end state 0044
  established: service_role only, never clients — `get_my_expedition_preview` (0049) remains the
  one client path and needs no change: it passes the adapter's jsonb through, so the two new keys
  simply appear in previews).

**Doc-sync (same step).** `docs/SYSTEM_BOUNDARIES.md`: §4 item 8 (stat adapter) now records the
0115 extension — reads `ship_module_fittings`+`module_instances`+`module_types` downward
read-only, enforces BOTH hard caps (raise, never clamp), same accumulators + speed bonus, the two
added keys, the zero-module compatibility contract; the §2 Fitting row's "future adapter edge"
note became the real shipped edge (Expedition-stats → Fitting is a READ by the adapter; nothing
writes through Fitting but its own command). Still acyclic; the adapter owns no table.

**State.** `npm run build` green (no `src/` change was made — confirmed). Migration head **0115**;
`module_fitting_enabled='false'` — the adapter change is inert today (no fitting rows can exist
while the command surface is dark, so every caller sees pre-0115 values plus `module_slots_used:0`
/`module_slots_limit`). No flag flipped, no live DB write, no workflow touched. **DB-apply posture
(honest, unchanged):** no psql/docker/supabase CLI in this sandbox — the re-created function was
mechanically diffed against 0044 (only the stated additions: declares, the module block, the two
speed-line/output changes) and the pinning scripts were read end-to-end as reported above; live
assertions run in the owner's environment (`verify:phase8` + `verify:mainship-preview` must stay
green there) and the later `verify:fitting` covers the dark posture. PR-ready on
`autopilot/20260703-064048`, `main` untouched. Next: the read surface + frontend + `verify:fitting`.

---

## 2026-07-04 — FITTING-P14 SLICE C2 — settled-SAFE ship-state rule `0114` (corrects the 0113 `'home'` literal; `ship_not_home` → `ship_not_settled`)

**Request.** Forward-only correction of the slice-C game rule, while everything is still dark: the
strict `spatial_state = 'home'` literal was confirmed dead-on-arrival (NO shipped writer ever
produces `'home'` — commissions land `at_location`, OSN writers produce
in_transit/in_space/at_location, destruction/repair leave NULL), so even a flag flip would strand
the feature behind another migration. **Rationale (one line): intent preserved, literal fixed,
precedent reused** — the rule's INTENT ("loadout never changes mid-transit/in-space/mid-combat")
stands; only the accepted-state literal was wrong; the codebase's authoritative "settled and safe
to act on" definition is reused. No flag touched, nothing activated — a design correction within
the loop's authority.

**The shipped gating, as read first (transcribed in `FITTING_P14_RECON.local.md` §6b):** the
scan/extract COMMANDS (0099:151–167 / 0104:124–140) gate IDENTICALLY to each other — no
stricter-of-two choice was needed: `mainship_space_validate_context` must be ok, its validated
state must be `'in_space'` exactly, then `mainship_space_assert_cross_domain_exclusion` (no active
legacy movement / coordinate-pointer mismatch / presence conflict) must be ok. Their `'in_space'`
state exists because scan/extract ARE open-space actions — transcribing that literal into fitting
would contradict the recorded intent, so it deliberately does NOT transfer. The settled-SAFE STATE
SET is the securing processors' (0100:231 / 0105:69): `spatial_state in ('home','at_location')`.
**What ships: the processors' state set verbatim + the commands' companion machinery verbatim** —
`validate_context` ok AND state in `('home','at_location')`, then `cross_domain_exclusion` ok — so
fitting is gated AT LEAST as strictly as the shipped activity commands. Every non-settled outcome
(legacy NULL, in_space, in_transit, destroyed, incoherent context, busy in either movement domain)
collapses to ONE truthful reject **`ship_not_settled`** (the 0099:159 "one truthful reason" idiom).
Satisfiable today: commissioned ships sit `at_location` in the canonical coherent shape.

**Work done — NEW `supabase/migrations/20260618000114_fitting_p14_settled_safe_rule.sql`**
(migration head moves **0113 → 0114**; `0001–0113` unedited; 0113 stays as history):
- **`fitting_execute_command` re-created** (the 0044-style `create or replace` forward-only idiom)
  changing ONLY the step-6 game rule: the affected ship is resolved per action first (fit → the
  owner-checked target, `ship_not_owned` unchanged; unfit → the currently-fitted ship, rule
  skipped when no fitting row exists so the writer still answers `module_not_owned`/`not_fitted`
  truthfully), then ONE shared settled-SAFE check block runs. Dark-gate order, request_id
  validation, per-player lock, verbatim replay, action-shape validation, delegation to
  `fitting_apply`, and failure-writes-no-receipt semantics are byte-identical to 0113 (the only
  other diff: the declare block swaps `v_state` for `v_check_ship`/`v_val`/`v_excl`).
  **NO-DUPLICATION NOTE (explicit, per the review):** the settled-SAFE mechanism appears ONCE
  (resolve-then-check), so no shared-helper extraction is needed — and the membership check itself
  is one line.
- **`fitting_command_client_envelope` re-created** only because it embeds the renamed code + copy:
  `ship_not_settled` with the message "The ship must be settled at home or docked at a location to
  change its module loadout." (matching the existing copy tone); every other line identical.
  Repo grep confirms NO other site references `ship_not_home` (0113 itself is history; no
  frontend/verify script exists yet).
- **ACL re-asserted** for both re-created functions exactly as 0113 (revoke public/anon/
  authenticated + grant service_role — `create or replace` preserves grants, but the shipped
  re-create precedents re-assert explicitly). `fitting_apply`, `module_fitting_receipts`, both
  wrappers, and every exploration/mining object are NOT touched.

**Doc-sync (same step).** `docs/SYSTEM_BOUNDARIES.md` §2 Fitting row: the ⚠ unsatisfiable-rule
note is replaced by the settled-SAFE rule as now shipped (citing the 0099/0104 machinery +
0100/0105 state-set precedents), and the edges line now records the OSN-context-helper reads
(`mainship_space_validate_context` + `mainship_space_assert_cross_domain_exclusion` — read-only,
downward, the exact 0099/0104 reuse-never-reinvent posture; still acyclic, still nothing depends
on Fitting).

**State.** `npm run build` green (no `src/` change was made — confirmed). Migration head **0114**;
`module_fitting_enabled='false'` — the surface stays server-rejected at every layer; no flag
flipped, no live DB write, no workflow touched. **DB-apply posture (honest, unchanged):** no
psql/docker/supabase CLI in this sandbox — the re-created functions were diffed line-by-line
against 0113 (single-rule change + declares + the two mapper lines) and the new rule block against
0099:151–167/0104:124–140 (machinery) and 0100:231/0105:69 (state set); live assertions run in the
owner's environment and will be covered by the later `verify:fitting` dark-posture script.
PR-ready on `autopilot/20260703-064048`, `main` untouched. Next: the adapter slice and/or the read
surface, then frontend + `verify:fitting`.

---

## 2026-07-04 — FITTING-P14 SLICE C — the dark two-layer fit/unfit command `0113` (`module_fitting_receipts` + `fit_module_to_ship`/`unfit_module_from_ship` → ONE private `fitting_execute_command`)

**Request.** Implement slice C of Phase 14: ONE new forward-only migration with the player-scoped
fitting-receipt ledger and the dark two-layer fit/unfit command, delegating every mutation to the
0112 writer. NO frontend, NO adapter change, NO verify script this slice. Idioms matched by
re-reading the shipped sources end-to-end first: `0109` (the two-layer craft command this slice
mirrors verbatim — receipts posture, gate order, lock-before-replay, trade-semantics replay,
failure-writes-no-receipt, envelopes, relock), `0112` (the writer being wired), `0054`/`0055`
(the exact `spatial_state` values + constraints).

**Work done — NEW `supabase/migrations/20260618000113_fitting_p14_fit_command.sql`**
(migration head moves **0112 → 0113**; `0001–0112` unedited):
- **`module_fitting_receipts`** — Fitting-owned per-player idempotency ledger: **PK
  (player_id, request_id)** (the locked keying — the idempotency key IS the row identity; 0109
  used a surrogate receipt_id + a UNIQUE on the same pair, same semantics), `action` check in
  ('fit','unfit'), the request fingerprint (`module_instance_id` FK cascade, `main_ship_id` FK
  cascade nullable — as-requested, NULL on unfit; the 0088/0109 order-safe-cascade lesson), and
  **`result_json`** — the writer's success envelope stored VERBATIM. RLS = the 0109 posture
  verbatim: owner-read select only, no write path. No extra index (the PK leads on player_id —
  the 0086/0109 comment idiom).
- **DECISION — ONE private command for BOTH actions:**
  `fitting_execute_command(p_player, p_action, p_module_instance_id, p_main_ship_id, p_request_id)`
  (service_role-only) handles 'fit' AND 'unfit' precisely so the receipts table keeps **ONE sole
  writer** — a fit-command and an unfit-command each inserting receipts would be TWO writers on
  one table. Order of operations mirrors 0109 exactly: **dark gate FIRST**
  (`module_fitting_enabled` via `cfg_bool`, reject-before-any-read, `feature_disabled`) →
  request_id validation (text, non-empty, ≤200) → **per-player advisory lock BEFORE the replay
  check** using the SAME `('module_fitting', player)` key as `fitting_apply` (documented:
  `pg_advisory_xact_lock` is reentrant within a transaction, so the writer's nested acquisition is
  safe and the replay check is serialized with ALL fitting mutations — a same-request_id race
  resolves to one mutation + one verbatim replay) → **verbatim replay** (an existing
  (player, request_id) receipt returns its stored `result_json` + `idempotent_replay:true`; NO
  payload-conflict check — the 0089/0095/0109 trade semantics: a reused request_id replays the
  original result even if the call names a different action/module/ship) → action-shape validation
  ('fit' requires a ship, 'unfit' forbids one → `invalid_request`) → **the GAME RULE this layer
  owns** (below) → delegate to `fitting_apply` (NEVER touching `ship_module_fittings` directly —
  the sole-writer law; writer reasons `module_not_owned`/`ship_not_owned`/`already_fitted`/
  `not_fitted`/`insufficient_slots` pass through) → **only a SUCCESSFUL mutation writes a receipt**
  (failures write nothing — the 0109 law).
- **THE HOME-ONLY GAME RULE (`ship_not_home`).** The affected ship — `p_main_ship_id` on fit; the
  currently-fitted ship (read from `ship_module_fittings`, owner-scoped) on unfit — must have
  `spatial_state = 'home'`. RATIONALE (recorded per the locked spec): constrained state
  transitions — a loadout must never change mid-transit / in-space / mid-combat; expedition stats
  are frozen for the duration of an expedition; refitting happens at home before departure.
  Fail-closed (`is distinct from 'home'`): NULL (legacy) and every other state reject. ⚠ **AS-SHIPPED
  HONESTY NOTE (for the human activation review):** grep of all migrations shows NO shipped writer
  ever sets `spatial_state = 'home'` — commissions insert ships `at_location` (0072/0077/0078/0080),
  OSN writers produce `in_transit`/`in_space`/`at_location`, destruction/repair leave NULL (0059) —
  so with current writers EVERY existing ship answers `ship_not_home` even once the flag flips.
  Implemented as the strict locked reading; relaxing to the 0100/0105 settled-SAFE set
  (`in ('home','at_location')`) or adding a `'home'` writer is a forward-only HUMAN decision.
- **TWO thin authenticated wrappers** (0109 wrapper idiom; named per ROADMAP `:89`):
  `fit_module_to_ship(p_module_instance_id, p_main_ship_id, p_request_id)` and
  `unfit_module_from_ship(p_module_instance_id, p_request_id)` — each does auth resolution + the
  anti-probe dark-gate-first check exactly like `craft_module`, then calls the private command with
  its fixed action. **Adaptation (the no-duplication hard rule):** 0109 inlined its reason→
  code/message map in its single wrapper; two wrappers would duplicate that block, so it is
  extracted ONCE as `fitting_command_client_envelope(jsonb)` (pure jsonb→jsonb; service_role-only
  surface) and both wrappers call it. Codes covered: `feature_disabled`, `not_authenticated`,
  `invalid_request`, `ship_not_home`, `module_not_owned`, `ship_not_owned`, `already_fitted`
  (+`main_ship_id` context), `not_fitted`, `insufficient_slots` (+`{used, cost, limit}` context),
  `unavailable` fallback, and the `idempotent_replay` marker on replays.
- **ACL (0109:265–273 verbatim posture):** private command + shared mapper revoked from
  public/anon/authenticated + granted to service_role; both wrappers revoked from public/anon +
  granted to authenticated (dark: every layer's gate rejects today).

**Doc-sync (same step).** `docs/SYSTEM_BOUNDARIES.md`: §1 gained the `module_fitting_receipts` row
(**Fitting**; sole writer = `fitting_execute_command` via the two wrappers; one-command-for-both-
actions rationale; DARK, no row can exist today) and the `ship_module_fittings` row's "called by
NOTHING yet" became "called today ONLY by Fitting's own command `fitting_execute_command` (0113)";
the §2 Fitting row now records the full command layer (wrappers → private command → `fitting_apply`),
the home-only rule with its rationale and the as-shipped ⚠ note, the new DOWNWARD reads
(Reference/Config flag · Main Ship `spatial_state`), and the expanded forbidden column (no second
receipt writer, no client exposure of command/writer/mapper, no fit/unfit while the gate is off).
Still nothing depends on Fitting.

**State.** `npm run build` green (no `src/` change was made — confirmed). Migration head **0113**;
`module_fitting_enabled='false'` — the entire command surface is server-rejected at every layer
(both wrappers gate, the private command gates first, the writer stays service_role-only); no flag
flipped, no live DB write, no workflow touched. **DB-apply posture (honest, unchanged from
P11–P13):** no psql/docker/supabase CLI in this sandbox — the migration was hand-verified
line-by-line against 0109 (order, replay, receipts, ACL), 0112 (delegation contract), and
0054/0055 (state values); live assertions run in the owner's environment and will be covered by
the later `verify:fitting` dark-posture script. PR-ready on `autopilot/20260703-064048`, `main`
untouched. Next: the adapter slice (modules feeding `calculate_expedition_stats` under the slot
cap) and/or the read surface, then frontend + `verify:fitting`.

---

## 2026-07-04 — FITTING-P14 SLICE B — `ship_module_fittings` + the single Fitting writer `0112` (`fitting_apply`; FIT and UNFIT through THE ONE writer)

**Request.** Implement slice B of Phase 14: ONE new forward-only migration with the fitting-state
table and THE ONE Fitting writer. NO RPC wrapper, NO receipts table, NO adapter change, NO
frontend, NO verify script this slice. Idioms matched by re-reading the shipped sources first:
`0108` (module_instances schema + mint writer — the slice this one mirrors), `0109` (the
per-player advisory-lock key derivation), `0043` (main-ship ownership shape + `module_slots`).

**Work done — NEW `supabase/migrations/20260618000112_fitting_p14_fittings_schema.sql`**
(migration head moves **0111 → 0112**; `0001–0111` unedited):
- **`ship_module_fittings`** — Fitting-owned junction state:
  **`module_instance_id uuid PRIMARY KEY`** FK → `module_instances` on delete cascade (**the PK IS
  the invariant**: one module instance is fitted to at most one ship, ever — a schema fact, not
  writer discipline), `main_ship_id` FK → `main_ship_instances` on delete cascade, `player_id` FK →
  `auth.users` on delete cascade, `fitted_at timestamptz`, plus a `(main_ship_id)` index (the
  capacity sum + the future adapter read). RLS posture = 0108 verbatim: own-row SELECT only
  (`player_id = auth.uid()`), select granted to authenticated, NO write policy/grant — no client
  write path exists.
- **`fitting_apply(p_player uuid, p_module_instance_id uuid, p_main_ship_id uuid) returns jsonb`**
  — THE sole writer of `ship_module_fittings` (SECURITY DEFINER; service_role-only via the 0108
  relock idiom). **DECISION — fit/unfit in ONE writer:** `p_main_ship_id` NOT NULL = FIT, NULL =
  UNFIT; one sole writer per table covers ALL mutations of that table (insert AND delete) — two
  writer functions would be two writers. The writer enforces the STRUCTURAL invariants itself so no
  future caller can violate them, in order: (1) per-player
  `pg_advisory_xact_lock(hashtext('module_fitting'), hashtext(player))` FIRST (the exact 0109
  key-derivation idiom — serializes all of a player's fitting mutations; since every fitting on a
  ship belongs to the ship's owner, per-player IS per-ship-fit-set, so the capacity read cannot be
  raced); (2) module instance exists AND `module_instances.player_id = p_player`
  (`module_not_owned` — another player's instance answers like a nonexistent one); on FIT: (3) ship
  exists AND owned (`ship_not_owned`; also fixes owner-consistency — row.player = module owner =
  ship owner); (4) `already_fitted` reject NAMING the current ship — an already-fitted module is
  never silently re-homed (explicit unfit first; the PK backstops); (5) the CAPACITY HARD CAP —
  Σ `module_types.slot_cost` currently fitted to the ship + the new module's `slot_cost` ≤
  `main_ship_instances.module_slots`, else `insufficient_slots` + `{used, cost, limit}` — a hard
  rejection mirroring 0044:112–115, NEVER a clamp; (6) the one insert. UNFIT of a non-fitted
  module → distinct `not_fitted` (idempotency ENVELOPES are the slice-C command's receipt-replay
  job, not the writer's). Envelopes are the 0104/0109 private-writer family (`{ok, reason, …}` —
  the slice-C wrapper maps reasons to client codes); validation failures write nothing.
  **GAME-RULE checks deliberately live in the slice-C command layer, NOT here:** the
  `module_fitting_enabled` dark gate, the ship-must-be-home spatial rule, and receipt-keyed
  idempotency — this writer owns only table invariants and is unreachable by clients
  (service_role-only) until that gated command exists, so the feature stays fully dark.
- **ACL (0108:108–113 relock idiom verbatim):** execute revoked from public/anon/authenticated,
  granted to service_role only. No existing grant touched.

**Doc-sync (same step).** `docs/SYSTEM_BOUNDARIES.md`: §1 gained the `ship_module_fittings` row
(**Fitting**, owner; sole writer = `fitting_apply`, service_role-only, FIT+UNFIT through the one
writer, called by nothing yet); §2 gained the new **Fitting** leaf-system row (owns
`ship_module_fittings`; the full writer semantics; edges all DOWNWARD — Fitting → Modules (read
`module_instances`) · Main Ship (read ownership + `module_slots`) · Reference/Config (read
`module_types.slot_cost`); no system depends on Fitting yet — the Phase-14 adapter slice will later
add the Expedition-stats → Fitting downward READ edge; forbidden column bans a second mutation
path, clamping, silent re-homing, client exposure, and gating game rules in the writer).

**State.** `npm run build` green (no `src/` change was made — confirmed). Migration head **0112**;
`module_fitting_enabled='false'` — still fully dark: the ONE writer is service_role-only with ZERO
callers (dead-until-slice-C by design, documented as such), the table has no client write path, and
no flag was flipped, no live DB write, no workflow touched. **DB-apply posture (honest, unchanged
from P11–P13):** no psql/docker/supabase CLI in this sandbox — the migration was hand-verified
line-by-line against the shipped idioms it copies (0108 table+RLS+ACL posture, 0109 advisory-lock
key derivation, 0043 ownership reads, 0044 hard-cap semantics); live assertions run in the owner's
environment and will be covered by the later `verify:fitting` dark-posture script. PR-ready on
`autopilot/20260703-064048`, `main` untouched. Next: slice C (the dark two-layer fit/unfit command
— `module_fitting_enabled` gate, player-scoped receipts, ship-must-be-home rule, delegating to this
writer).

---

## 2026-07-04 — FITTING-P14 SLICE A — locked design decisions + dark flag/stats-catalog migration `0111` (`module_fitting_enabled` + `module_types.slot_cost`/`stats_json`)

**Request.** Begin Phase 14 "Module fitting" (ROADMAP `:89` — "`fit_module_to_ship` |
server-validated; feeds stats") with slice A: record the planner-approved LOCKED design decisions,
then ONE new forward-only migration seeding the dark flag + the module stats/slot-cost catalog
wiring. NO fittings table, NO RPC, NO adapter change, NO frontend, NO verify script this slice.
Recon: `FITTING_P14_RECON.local.md` (scope locked 2026-07-04). Template: the 0107 slice-A idiom.

**LOCKED DESIGN DECISIONS (planner-approved 2026-07-04):**
1. **SYSTEM SHAPE** — Phase 14 creates a NEW leaf system **Fitting** per ROADMAP law 5
   ("Fitting=modules"); fitting state will live in a NEW Fitting-owned junction table
   `ship_module_fittings` (arrives slice B — NOT this slice) with its own sole writer, never a
   second writer or new columns on `module_instances`; Fitting depends one-directionally DOWNWARD
   on Modules (read instances), Main Ship (read `module_slots`), and Reference/Config.
2. **CAPACITY/TRADEOFF MODEL** — mirrors the proven support-craft mechanism in 0044: each module
   type has an integer `slot_cost ≥ 1`; the adapter (extended in a later slice via
   `create or replace` in a new migration) will hard-REJECT when Σ slot_cost of fitted modules >
   `main_ship_instances.module_slots` (exception, never a clamp — the 0044:112–115 idiom), and
   slot_type-based tradeoff rules (pirate_attention / speed penalty) will apply exactly like
   0044's role-based rules — so module power is capacity-limited with tradeoffs, never a raw sum.
3. **STATS ENCODING** — reuse the `support_craft_types.base_stats_json` idiom: add a
   `stats_json jsonb not null default '{}'` column to `module_types`, using the SAME physical stat
   keys the adapter already reads (attack/defense/repair/cargo/scan/mining/evasion) plus one new
   key `speed_mult_bonus` (numeric fraction of hull base speed, applied before penalties — the
   engine archetype's positive effect; the adapter clamps total speed exactly as today:
   `round(greatest(0.2, …), 3)` — 0044:117–118).
4. **FLAG** — `module_fitting_enabled` seeded `'false'`, the exact 0097/0102/0107 idiom; every
   Phase 14 RPC must check it FIRST and reject-before-any-read; this migration flips nothing.

**Work done — NEW `supabase/migrations/20260618000111_fitting_p14_config_and_stats.sql`**
(migration head moves **0110 → 0111**; `0001–0110` unedited):
- **(a)** `game_config` seed `module_fitting_enabled='false'` (`on conflict (key) do nothing`, the
  exact 0097/0102/0107 dark-gate idiom + description stating the reject-before-any-read law).
- **(b)** `alter table module_types add column slot_cost integer not null default 1 check
  (slot_cost >= 1), add column stats_json jsonb not null default '{}'::jsonb` — Reference/Config
  CATALOG data exactly like `support_craft_types.capacity_cost`/`base_stats_json` (0042). Posture
  unchanged: the existing 0107 public-read policy + grants cover new columns (the 0075/0076
  add-column precedent); still no client write path; no function created → no execute relock
  (0054 precedent). First code consumer arrives with the Phase 14 adapter slice — nothing reads
  them today.
- **(c)** Write-once per-id UPDATEs seeding the four shipped archetypes, guarded on
  `stats_json = '{}'::jsonb` (the update analogue of the seeds' `on conflict do nothing` — a
  re-run or later owner rebalance is never clobbered). Magnitudes were read against the 0042
  `base_stats_json` band (missile_boat cap 3 → attack 12 · cargo_drone cap 2 → cargo 20 ·
  survey_drone cap 2 → scan 8 · decoy_drone cap 1 → evasion 6) so a full 3-slot fit is comparable
  to a similarly-sized support loadout: `autocannon_battery` (weapon) slot 1 → `{"attack":10}` ·
  `vector_thruster_kit` (engine) slot 1 → `{"evasion":3,"speed_mult_bonus":0.1}` ·
  `expanded_cargo_lattice` (cargo) **slot 2** (deliberately multi-slot so the Σ slot_cost cap math
  is exercised) → `{"cargo":25}` · `deep_scan_sensor_array` (sensor) slot 1 → `{"scan":8}`.

**Doc-sync (same step).** `docs/SYSTEM_BOUNDARIES.md`: the §1 `module_types` row now records
`slot_cost` + `stats_json` (still migration-seeded only, NO runtime writer; consumer = the Phase 14
fitting adapter, later slice). Deliberately NO Fitting system row yet — `ship_module_fittings`
does not exist until slice B, and a doc must never describe state that isn't real.

**State.** `npm run build` green (no `src/` change was made — confirmed). Migration head **0111**;
`module_fitting_enabled='false'` and `module_crafting_enabled='false'` — nothing client-writable
was added (one dark flag + two inert catalog columns + write-once seeds; no RPC, no writer, no
reader). No flag flipped, no live DB write, no workflow touched. **DB-apply posture (honest,
unchanged from P11–P13):** no psql/docker/supabase CLI in this sandbox — the migration was
hand-verified line-by-line against the idioms it copies (0107 flag seed, 0042 catalog stats shape,
0075/0076 add-column posture); live assertions run in the owner's environment and will be covered
by the later `verify:fitting` dark-posture script. PR-ready on `autopilot/20260703-064048`,
`main` untouched. Next: slice B (`ship_module_fittings` + the Fitting sole writer).

---

## 2026-07-04 — MODULES-P13 SLICE F (final) — `verify:modules` dark-posture script. **Phase 13 Module crafting — dark implementation complete (slices A–F)**

**Request.** Implement slice F, the last Phase 13 slice: the dark-posture verify script + its
`package.json` entry, mirroring the exploration/mining verifier twins (read end-to-end first:
`verify-exploration.mjs`, `verify-mining.mjs`, `scripts/lib/verify-harness.mjs`,
`scripts/lib/verifier-teardown.mjs`). Touches ONLY `scripts/verify-modules.mjs`, `package.json`,
this file, and the recon scratch file. No migrations (head stays **0110**), no CI/workflow edits,
no flags.

**Flag-handling mechanism — the twins', stated and followed exactly.** `verify-mining.mjs:16–20`
records the mechanism verbatim: the twins **NEVER write `game_config` and NEVER flip their flag**
— they exercise NO lit path at all (the `set_game_config` flip in `verify-mainship-send.mjs` is
the explicitly-NOT-copied alternative; the self-rolling-back mechanism exists only in the
separate `trade-economy-bootstrap-proof` psql/CI harness, which is workflow-wired and out of this
loop's scope). So `verify-modules.mjs` proves the DARK contracts only, and the requested lit-path
behaviors are recorded in the HUMAN ACTIVATION CHECKLIST below — run on a DEV database by the
owner, never by this script. Teardown guarantee: the shared `teardownVerifier` deletes the
throwaway user (the 0108/0109 player FKs cascade any of its rows away); no flag entry is passed
because the script touches NO flag — nothing to restore, `module_crafting_enabled` stays exactly
as found (`'false'`).

**Work done:**
- **NEW `scripts/verify-modules.mjs`** — imports the shared harness from day one
  (`Abort`/`createReporter`/`createUserFactory`/`resolveEnv` from `scripts/lib/verify-harness.mjs`
  + `teardownVerifier` from `scripts/lib/verifier-teardown.mjs`) — ZERO inline harness copies (the
  harness header's law). Same posture as the twins: dark contracts only; NEVER writes
  `game_config`; service key OPTIONAL (teardown only); one throwaway signup. Asserts, in the
  twins' order/idioms:
  (1) **dark rejection** — `craft_module` → `{ok:false, code:'feature_disabled'}` (0109 gates
  before any validation — anti-probe) and `get_my_module_instances` →
  `{ok:false, reason:'module_crafting_disabled'}` (0110), both authenticated;
  (2) **catalog seeds (0107, exact contract)** — `module_types` = the 4 seeded archetypes with
  their slot types; `module_recipe_ingredients` = exactly 12 rows, all `qty > 0`, per-type
  ingredient maps equal to the seed verbatim, and every ingredient id present in `item_types`
  (the client-checkable form of FK validity). NOTE the deliberate inversion vs mining's
  "no field leak": these catalogs are PUBLIC-READ by design (the item_types posture), so reading
  them back exactly IS the posture assertion;
  (3) **player-state RLS + no client write path** — `module_instances` + `module_craft_receipts`
  own-row RLS (fresh user sees 0 rows) AND inserts denied to the authenticated client on all four
  Modules/Production tables (both state tables + both catalogs);
  (4) **internal surfaces locked** — `production_craft_module` + `modules_mint_instance` denied
  to the authenticated client; both public RPCs denied to anon;
  (5) **config presence (read-only)** — `module_crafting_enabled` = false, via the same
  jsonb-storage-tolerant comparison.
- **`package.json`** — `"verify:modules": "node scripts/verify-modules.mjs"` added in the verify
  cluster, directly after `verify:mining`, same command shape.
- **CI note:** grep confirms the exploration/mining verifiers are wired into NO workflow file —
  there is nothing to mirror, and no workflow was created or modified (dispatching/enabling
  workflows is outside this loop). Wiring `verify:modules` into CI, if desired, is a human /
  PR-review step.
- **Verify posture run honestly:** `node --check scripts/verify-modules.mjs` parses clean;
  `npm run build` green. `node scripts/verify-modules.mjs` in this sandbox aborts at the
  throwaway SIGNUP step with the environmental TLS failure ("signup failed: fetch failed") —
  `node scripts/verify-mining.mjs` aborts at the IDENTICAL point in the same run, so this is the
  known environmental-fail-only posture (the Phase 12 slice-G precedent), and reaching that
  identical abort point proves the harness wiring. The assertions themselves run against a real
  DB in the owner's environment.
- `docs/SYSTEM_BOUNDARIES.md` needs NO change this slice (checked the twins' verify slices: the
  Phase 12 slice-G entry recorded the same) — no table, writer, or cross-system edge (a read-only
  verifier script + one npm alias).

---

### Phase 13 Module crafting — dark implementation complete (slices A–F) — closing summary

- **Migrations `0107–0110`** (head **0106 → 0110**; all forward-only; `0001–0106` never edited):
  `0107` config/flag + catalogs (`module_crafting_enabled='false'` + `module_types` +
  `module_recipe_ingredients` + 4 seeded archetypes whose recipes reuse EXISTING `item_types`
  rows) · `0108` instances schema + the ONE mint writer (`module_instances` with the
  `mint_key` idempotency spine + `modules_mint_instance`, service_role-only) · `0109` the craft
  command (`module_craft_receipts` + `craft_module` wrapper → private `production_craft_module`;
  dark-gate-first, per-player advisory lock, trade-semantics verbatim replay, items-only cost via
  `inventory_spend`, one craft = one instance via the namespaced `craft:` mint key) · `0110` the
  read surface (`get_my_module_instances`; the 0101/0106 idiom; no catalog RPC — public-read
  catalogs are direct client selects).
- **Frontend:** dark `src/features/modules/` (types/api/panel — the twins' structure; server-driven
  visibility, fails closed to null; MarketPanel per-row claims; direct catalog + own-inventory
  selects) wired beside `MiningPanel` in `GalaxyMapScreen.tsx`.
- **Verify:** `scripts/verify-modules.mjs` + `npm run verify:modules` (dark posture only, shared
  harness, never flips flags).
- **Design decisions (owner-directed, slice A):** Modules leaf system + Production-owned craft
  command; instant idempotent craft (player-scoped receipts; `build_orders` integration deferred
  with the mint-helper retirement note); normalized items-only recipes; one craft = one instance;
  `module_crafting_enabled` flag.
- **Ownership/laws:** SYSTEM_BOUNDARIES §1 rows (`module_types`/`module_recipe_ingredients`,
  `module_instances`, `module_craft_receipts`) + §2 Modules and Production rows — every doc synced
  in the SAME step as its fact; edges all DOWNWARD/acyclic (Production → Inventory · Modules ·
  Reference/Config); sole writers: catalogs none (migration-seeded), `module_instances` =
  `modules_mint_instance` (called only by 0109), `module_craft_receipts` =
  `production_craft_module`.
- **HUMAN ACTIVATION CHECKLIST (the owner's gate — never this loop):** (1) apply migrations
  0107–0110 to the target DB; (2) run `npm run verify:modules` there — expect ALL dark-posture
  checks green; (3) optionally flip `module_crafting_enabled='true'` on a DEV database and run the
  lit path there: seed a test player's inventory (e.g. via secured mining/exploration deposits or
  a dev grant), then `craft_module` with sufficient balances → expect success AND (a) exactly the
  recipe quantities spent from `player_inventory` with matching negative `inventory_ledger` rows,
  (b) exactly ONE `module_instances` row minted with the namespaced `craft:<player>:<request_id>`
  key, (c) exactly one `module_craft_receipts` row; REPLAY the same (player, request_id) → same
  `instance_id` + `idempotent_replay:true`, and provably NO double-spend/double-mint; a shortfall
  craft → `insufficient_items` with `{item_id, have, need}`, nothing spent, no receipt;
  `unknown_module` and `no_recipe` codes fire; `modules_mint_instance` twice with the same key
  (service_role) → one row; `get_my_module_instances` returns the crafted instance newest-first
  for the owner and NOT for a second test player; then flip the flag back and decide production
  activation separately. The loop ships everything server-rejected; activation is exclusively the
  human's.

**State.** `npm run build` green; `node --check` clean on the new script. Migration head **0110**;
`module_crafting_enabled='false'` everywhere; no flag flipped, no live DB write, no workflow
touched. **Phase 13 Module crafting is implemented DARK end-to-end and PR-ready on
`autopilot/20260703-064048`** — SAFE FOR HUMAN MERGE REVIEW; `main` untouched.

---

## 2026-07-04 — MODULES-P13 SLICE E — dark frontend `src/features/modules/` (catalog + craft + instances panel; renders nothing while the server says dark). Frontend only — no migration

**Request.** Implement slice E: the dark module-crafting frontend mirroring the post-cleanup
exploration/mining twins exactly (read end-to-end first: both panels + api/types modules, the
shared `src/lib/useActivityPanelGuards.ts`, the GalaxyMapScreen mounting, MarketPanel's per-row
state shapes, and the `mainshipApi.ts` direct-select convention). NO migration (head stays
**0110**), NO verify script, no config.

**Work done — NEW `src/features/modules/` (the twins' structure, adapted where crafting differs):**
- **`modulesTypes.ts`** — pure types + copy (the miningTypes.ts idiom): `ModuleInstance` (the 0110
  row), `GetMyModuleInstancesResult`, `CraftModuleResult` (0109 wrapper shape; `item_id`/`have`/
  `need` are REAL server data on the `insufficient_items` code), the public catalog row types, and
  the craft error-copy map (`module_crafting_disabled` read reason is handled by the fail-closed
  render, not copy; command codes covered: `feature_disabled`, `invalid_request`,
  `unknown_module`, `no_recipe`, `insufficient_items`, `not_authenticated`, `unavailable`) +
  `craftModuleErrorMessage`.
- **`modulesApi.ts`** — thin `supabase.rpc` wrappers for `craft_module` +
  `get_my_module_instances` (identical envelope-handling idiom: transport error → normalized
  failure, never a throw into the render path), PLUS two direct selects per the shipped
  conventions: `fetchModuleCatalog()` reads the PUBLIC-READ `module_types` +
  `module_recipe_ingredients` (0107) by direct table select — the `mainshipApi.ts` hull-types
  convention; deliberately NO catalog RPC exists (0110 header) — and `fetchMyItemBalances()` reads
  the caller's own `player_inventory` rows through the EXISTING 0039 own-row grant (the existing
  Inventory read path; no new server surface, no new cross-system edge).
- **`ModulesPanel.tsx`** — server-driven visibility: reads the instances on mount/lifecycle change
  and **fails closed to null on ANY non-ok envelope** — the Exploration/Mining twins' posture via
  `isServerLit` (the hook documents this server-lit stance as distinct from MarketPanel's
  shell-with-`unavailableNote`, which is reserved for client-flag-mounted shells — the twins ARE
  the match here; while the server returns `module_crafting_disabled` the panel renders nothing,
  so production is unchanged; the panel never pretends the feature is on). Catalog + balances are
  fetched only after the server lights the surface. **Per-module-type claim keys**
  (`tryClaim(entry.id)` — the MarketPanel per-row granularity, with its
  `pending`/`rowNote: Record<string, …>` state shapes) since the catalog lists multiple craftable
  types; fresh `crypto.randomUUID()` request id per submit (the twins' idiom; the server dedups on
  (player_id, request_id)); craft buttons disable while in flight and on a client-side shortfall
  preview (server stays authoritative — `insufficient_items`); ingredient lines show
  `item ×qty (have N)` with shortfalls flagged rose; the `insufficient_items` failure note appends
  the server's real `item_id: have/need` (the mining cooldown-suffix idiom); crafted-instances
  list (name, slot badge, timestamp), newest first. **Crafting is NON-SPATIAL** (player-scoped,
  0109) — no ship/settled precondition, so unlike the twins the panel takes only `lifecycleKey`
  (no ship props; a deliberate, documented deviation). Sky styling vs violet/amber; positioned
  bottom-left BESIDE MiningPanel (`left-[33.5rem]` — the w-64 row continues; all three activity
  panels are server-lit, so overlap only ever involves lit surfaces).
- **Wiring:** `GalaxyMapScreen.tsx` — `ModulesPanel` imported and rendered directly adjacent to
  `MiningPanel`, same container, same comment convention, same `lifecycleKey` expression.

**Doc-sync note.** `docs/SYSTEM_BOUNDARIES.md` needs NO change (the MINING-P12 SLICE F precedent,
stated explicitly per the request): frontend-only — no table, no writer, no cross-system edge;
the server contracts the new files mirror (0107/0109/0110, the 0039 grant) are unchanged.

**State.** `npm run build` green (tsc -b + vite, exit 0). `npm run lint`: the 4 touched files
(`modulesTypes.ts`, `modulesApi.ts`, `ModulesPanel.tsx`, `GalaxyMapScreen.tsx`) lint CLEAN
(targeted eslint exit 0, incl. exhaustive-deps via the stable-ref dep); full-repo lint still FAILS
with exactly the same 14 pre-existing out-of-scope errors recorded in MINING-CLEANUP SLICE 1
(`MainShipMarker.tsx`, `SpaceRouteLine.tsx`, `useSpaceMoveCommand.ts`, tests harnesses/spec —
no new problems). Migration head stays **0110** (no migrations, no flags); everything still dark
and server-rejected — the panel is wired but renders nothing while
`module_crafting_enabled='false'`. PR-ready on `autopilot/20260703-064048`, `main` untouched.
Next: slice F (`scripts/verify-modules.mjs` + the `verify:modules` entry).

---

## 2026-07-04 — MODULES-P13 SLICE D — the dark read surface `0110` (`get_my_module_instances()`). **Server side of Phase 13 complete, fully dark**

**Request.** Implement slice D: ONE new forward-only migration with the read surface, mirroring
the exploration/mining read surfaces (0101/0106) exactly — re-read end-to-end first. NO frontend,
NO verify script this slice.

**Work done — NEW `supabase/migrations/20260618000110_modules_p13_read_surface.sql`** (migration
head moves **0109 → 0110**; `0001–0109` unedited):
- **`get_my_module_instances()`** — the 0101/0106 body step-for-step (line-level sources:
  envelope + auth + dark-gate order **0101:36–44 / 0106:38–46**; jsonb_agg row shape + desc
  ordering + coalesce-to-`[]` **0101:49–63 / 0106:51–65**; `stable`/`security definer`/
  `set search_path = public` posture **0101:26–29**): `auth.uid()` → `not_authenticated`
  envelope; then the dark gate BEFORE any instance read — `{ok:false,
  reason:'module_crafting_disabled'}` (the 0101 `exploration_disabled` / 0106 `mining_disabled`
  envelope shape), identical regardless of caller state (no probing while dark); then the
  caller's OWN `module_instances` joined to their `module_types` catalog identity. Per row:
  `instance_id`, `module_type_id`, `name`, `slot_type`, `created_at` — newest first
  (`created_at desc`); response `{ok:true, instances:[…]}` mirroring
  `{ok:true, discoveries/extractions:[…]}`.
- **Catalog surface decision — the precedent points AGAINST a catalog RPC, and was followed:**
  0101/0106 exist because `exploration_sites`/`mining_fields` are HIDDEN (RLS, no client
  policy — reveal only through the player's own rows). The module catalog/recipe tables are the
  opposite posture by design (0107): public-read Reference/Config catalogs exactly like
  `item_types` (0039:23–25) / `support_craft_types` (0042:32–36) / `trade_goods`, which the
  client reads by DIRECT table select (the shipped convention — e.g. the hull-type selects in
  `src/features/map/mainshipApi.ts`). A `get_module_catalog` RPC would duplicate an
  already-public surface — NOT added.
- **No inventory-balance join:** no shipped read surface joins another system's balances
  (`inventory_get_balance` is an internal service_role-only leaf, 0039:156). The surface stays
  dumb; the client reads its own `player_inventory` through the existing Inventory read path
  (the 0039:50–52 own-row select policy + grant). No new cross-system read edge without
  precedent.
- **ACL verbatim from 0101:69–70 / 0106:71–72:** execute revoked from public/anon, granted to
  authenticated only — and dark today: the gate rejects every call while
  `module_crafting_enabled='false'`.

**Doc-sync (same step).** `docs/SYSTEM_BOUNDARIES.md`: the §2 Modules row gained
`get_my_module_instances()` with its dark-gate semantics + the two recorded non-additions (no
catalog RPC, no balance join, with the precedent reasons). The §1 matrix is UNCHANGED — mirroring
the 0101/0106 precedent exactly: read surfaces add no writer and are recorded in the §2 system
row, not the matrix (the mining slice-E entry did the same).

**State.** `npm run build` green. Migration head **0110**. **The server side of Phase 13 Module
crafting is COMPLETE (slices A–D) and fully dark end-to-end:** the craft command (both layers)
and the read surface all server-reject while `module_crafting_enabled='false'`; the mint writer
is service_role-only; the catalogs are inert public-read reference data. No flag flipped, no live
DB write, no workflow touched. **DB-apply posture (honest, unchanged from slices A–C):** no
psql/docker/supabase CLI in this sandbox and npx cannot fetch (`UNABLE_TO_VERIFY_LEAF_SIGNATURE`)
— the migration was hand-verified line-by-line against 0101/0106 at the sources cited above; live
assertions run in the owner's environment and will be covered by the slice-F `verify:modules`
dark-posture script. PR-ready on `autopilot/20260703-064048`, `main` untouched. Next: slice E
(dark frontend `src/features/modules/`, consuming `useActivityPanelGuards`), then slice F
(`verify:modules`).

---

## 2026-07-04 — MODULES-P13 SLICE C — the dark craft command `0109` (`module_craft_receipts` + `craft_module` → private `production_craft_module`)

**Request.** Implement slice C of Phase 13: ONE new forward-only migration with the player-scoped
craft-receipt ledger and the two-layer craft command. NO read surface, NO frontend this slice.
Idioms matched by re-reading the shipped sources end-to-end first: `0099` (scan command) + `0104`
(extract command) for the two-layer/envelope/ACL shape, `0089` (`market_buy`) + `0095`
(`market_claim_relief`) for the trade replay + insufficient-balance envelope, `0086`/`0094` for
the receipts-table RLS posture, `0078`/`0080` for the per-player advisory lock.

**Work done — NEW `supabase/migrations/20260618000109_modules_p13_craft_command.sql`**
(migration head moves **0108 → 0109**; `0001–0108` unedited):
- **`module_craft_receipts`** — Production-owned per-player idempotency ledger:
  `receipt_id uuid pk`, `player_id` (the 0108 `auth.users on delete cascade` FK shape),
  `request_id text not null`, `module_type_id` FK → `module_types`, `instance_id` FK →
  `module_instances` (`on delete cascade` — the instance only ever disappears via the auth.users
  cascade today; cascading the receipt keeps account deletion order-safe across the multi-path
  cascade graph, the 0088 child-FK lesson), `created_at`, **unique (player_id, request_id)**.
  RLS posture copied from the player-scoped receipts precedent `trade_relief_claims`
  (**0094:24–43**): owner-read select policy + `grant select to authenticated`, NO write
  policy/grant. No extra index — the unique index leads on player_id and covers idempotency
  probes + owner lookups (the 0086:53–55 comment idiom).
- **`craft_module(p_request_id text, p_module_type text)`** *(authenticated wrapper — the
  0099:221–300 wrapper idiom: auth check → anti-probe flag gate FIRST → delegate → reason→
  code/message map; the `insufficient_items` failure passes its `{item_id, have, need}` context
  through, the 0104 `retry_after_seconds` pass-through idiom)* → private
  **`production_craft_module(p_player, p_module_type, p_request_id)`** *(service_role)*:
  1. **Dark gate FIRST** (0107 law; **0099:108–113**): `module_crafting_enabled` false →
     `feature_disabled` before ANY other read.
  2. request_id validation — TEXT per the locked signature (the shipped receipt columns are uuid;
     text is validated non-empty + length-capped at 200 since it lacks uuid's intrinsic bound).
  3. **Per-player advisory lock BEFORE the replay check** —
     `pg_advisory_xact_lock(hashtext('module_craft'), hashtext(player))`, the shipped commission
     idiom (**0078:43/79**): the player-scoped analogue of market_buy's per-ship lock
     (0089:104–106) and relief's wallet FOR UPDATE (0095:53–57), both taken before their
     idempotency checks for the same race-safety reason (a same-request_id race resolves to one
     craft + one verbatim replay; the pre-check→spend window can't be raced by another craft of
     the same player).
  4. **REPLAY — matched to the TRADE receipts semantics (0089:108–116 / 0095:60–66), stated
     explicitly:** an existing (player, request_id) receipt returns the ORIGINAL success envelope
     rebuilt verbatim from the receipt row, flagged `idempotent_replay` — **NO payload-conflict
     check** (a same-key-different-module_type replay returns the original receipt's data, exactly
     as market_buy replays a same-key-different-good call). The `request_id_payload_conflict` hash
     check (0099:140–148) belongs to the ship-scoped space receipts, which this player-scoped
     command does not use.
  5. Catalog validation: `unknown_module` (bad id) vs **`no_recipe`** (catalog row with zero
     `module_recipe_ingredients` rows — a distinct truthful reason so a seed gap is diagnosable).
  6. **Ingredient pre-check** via `inventory_get_balance` — shortfall returns
     `{ok:false, reason:'insufficient_items', item_id, have, need}` (the **0089:150–153**
     `insufficient_credits` + context shape) WITHOUT spending anything.
  7. **One transaction:** loop the recipe rows → `inventory_spend(player, item, qty)` each (its
     exceptions — 0039:113–121 — roll back everything; a failed craft writes NO receipt, the
     0099/0104 law) → mint exactly ONE instance via
     `modules_mint_instance(player, module_type, 'craft:'||player||':'||request_id)` (the
     namespaced key per 0108's producer contract) → insert the receipt → success envelope with
     `instance_id`/`receipt_id`/`module_type_id`/`crafted_at`. Crafting never touches
     `player_inventory`/`inventory_ledger`/`module_instances` directly — only the two leaf
     functions. This is `inventory_spend`'s FIRST live caller.
- **ACL (0099:302–311 / 0104:291–299 verbatim):** private writer revoked from
  public/anon/authenticated + granted to service_role; wrapper revoked from public/anon + granted
  to authenticated (dark: both its gate and the writer's first check reject today).

**Doc-sync (same step).** `docs/SYSTEM_BOUNDARIES.md`: §1 gained the `module_craft_receipts` row
(**Production**, owner; sole writer = `production_craft_module` via the `craft_module` wrapper;
DARK) and the `module_instances` row's "NOTHING calls it yet" became "called today ONLY by
Production's craft command (0109)"; §2 Production row gained `module_craft_receipts` in its owns
column, the full `craft_module` semantics in its functions column (dark-gated, idempotent by
player+request_id with verbatim replay, items-only cost, downward `inventory_spend` +
`modules_mint_instance` fan-out, one craft = one instance), and the direct-write bans in its
forbidden column; §2 Modules row's "will belong to Production" note went present-tense
("SHIPPED as `craft_module` (0109)") and its "NOTHING calls it yet" was replaced by the caller
fact. New edges all DOWNWARD (Production → Inventory · Modules · Reference/Config) — acyclic, no
second writer anywhere.

**State.** `npm run build` green. Migration head **0109**; still fully dark — the wrapper and
writer both server-reject while `module_crafting_enabled='false'`; no flag flipped, no live DB
write, no workflow touched. **DB-apply posture (honest, unchanged from slices A/B):** no
psql/docker/supabase CLI in this sandbox and npx cannot fetch (`UNABLE_TO_VERIFY_LEAF_SIGNATURE`)
— the migration was hand-verified line-by-line against the named idiom sources above; live
assertions run in the owner's environment and will be covered by the slice-G `verify:modules`
dark-posture script. PR-ready on `autopilot/20260703-064048`, `main` untouched. Next: slice D
(the read surface, e.g. `get_my_module_instances()` — the 0101/0106 idiom).

---

## 2026-07-04 — MODULES-P13 SLICE B — `module_instances` schema + the single Modules mint writer `0108` (`modules_mint_instance`; idempotent by `mint_key`)

**Request.** Implement slice B of Phase 13: ONE new forward-only migration with the
`module_instances` table and the ONE Modules mint writer. NO craft command, NO receipts table, NO
read surface, NO frontend this slice. Idioms matched by re-reading the shipped sources first:
`0098` (exploration_discoveries) + `0103` (mining_extractions) for the player-state schema/RLS
posture, `0039` (Inventory) for the SECURITY DEFINER internal-writer + idempotency-key pattern,
and `0104:291–299` for the function-ACL relock wording.

**Work done — NEW `supabase/migrations/20260618000108_modules_p13_instances_schema.sql`**
(migration head moves **0107 → 0108**; `0001–0107` unedited):
- **`module_instances`** — `id uuid primary key default gen_random_uuid()`;
  `player_id uuid not null references auth.users (id) on delete cascade` (the exact 0098/0103
  player-FK shape); `module_type_id text not null references module_types (id)`;
  **`mint_key text not null unique`** — the idempotency spine; `created_at timestamptz not null
  default now()`; plus the `(player_id, created_at desc)` player index (0098/0103 idiom).
  Instances are INDIVIDUAL rows, never counts (the Phase-13 law) — no quantity column by design.
  **NO fitting columns** (`fitted_ship_id`/slots/stats are Phase 14, forward-only).
- **RLS posture copied from the P11/P12 player-state tables exactly** (verified, not assumed —
  both 0098 `exploration_discoveries` and 0103 `mining_extractions` DO expose an owner-select
  policy): RLS enabled + `module_instances_select_own` (`player_id = auth.uid()`) +
  `grant select to authenticated`; NO insert/update/delete policy, NO write grant — no client
  write path exists.
- **`modules_mint_instance(p_player uuid, p_module_type text, p_key text) returns uuid`** — THE
  ONE writer of `module_instances`: plpgsql SECURITY DEFINER, `set search_path = public`;
  exception-style errors matching Inventory's internal-leaf idiom (`raise exception` on missing
  key / unknown module type — not a player envelope RPC); then
  `insert … on conflict (mint_key) do nothing`, and on conflict returns the EXISTING instance id
  for that key — true idempotent replay mirroring `inventory_deposit(p_key)`'s
  ledger-insert-is-the-guard semantics (0039:85–90): the same key can NEVER mint twice. Key
  namespacing is the producer's contract (the slice-C craft command derives keys from its own
  player-scoped receipts). Header states the **sole-writer law**: every future producer — the
  Phase-13 craft command AND any future `build_orders` queue completion (the recorded M4.5
  retirement path) — must mint through this function and nothing else.
- **ACL (0099/0104 relock idiom verbatim):** execute revoked from public/anon/authenticated,
  granted to service_role only. No existing grant touched.

**Doc-sync (same step).** `docs/SYSTEM_BOUNDARIES.md`: §1 gained the `module_instances` row
(**Modules**, owner-read; sole writer = `modules_mint_instance` (0108), idempotent by `mint_key`,
service_role-only, nothing calls it yet) and the catalog row dropped its now-stale "mint writer
arrives with `module_instances`" note; the §2 Modules row's function list gained the mint
signature + semantics (replacing "*none yet — no function exists*") — the
Production-will-own-the-craft-command note, the M4.5 retirement note, and the forbidden column
are unchanged and still accurate. No new cross-system edge: the helper reads only Modules' own
catalog (`module_types`), and nothing calls it yet — the graph stays acyclic.

**State.** `npm run build` green (tsc -b + vite, exit 0). Migration head **0108**;
`module_crafting_enabled='false'` — still fully dark: the mint writer is service_role-only with
ZERO callers (dead-until-slice-C by design, documented as such), the table has no client write
path, and no flag was flipped, no live DB write, no workflow touched. **DB-apply posture
(honest, unchanged from slice A):** no psql/docker/supabase CLI in this sandbox and npx cannot
fetch (`UNABLE_TO_VERIFY_LEAF_SIGNATURE`) — the migration was hand-verified line-by-line against
the shipped idioms it copies (0098/0103 table+RLS posture, 0039 writer/idempotency pattern,
0104 ACL block); live assertions run in the owner's environment and will be covered by the
slice-G `verify:modules` dark-posture script. PR-ready on `autopilot/20260703-064048`, `main`
untouched. Next: slice C (the craft command — Production system, player-scoped receipts,
`inventory_spend` fan-out + this mint helper).

---

## 2026-07-04 — MODULES-P13 SLICE A — locked design decisions + dark flag/catalog migration `0107` (`module_types` + `module_recipe_ingredients`)

**Request.** Begin Phase 13 "Module instances + crafting" (ROADMAP `:88` — "instances, not
stack-only") with slice A: record the owner's LOCKED design decisions, then ONE new forward-only
migration seeding the dark flag + the module catalog/recipe config tables + starter seeds. NO
instances table, NO command, NO read surface, NO frontend this slice. Recon:
`MODULES_P13_RECON.local.md` (scope locked 2026-07-04).

**LOCKED DESIGN DECISIONS (owner-directed 2026-07-04 — not self-approved):**
1. **System shape** (ROADMAP law 5: "Production=support craft/crafting · Fitting=modules"): a NEW
   leaf system **Modules** owns the module state tables (`module_types` catalog,
   `module_recipe_ingredients` config, and — in later slices — `module_instances` + a mint
   writer), while the craft COMMAND itself will belong to the existing **Production** system,
   depending DOWNWARD on Inventory (`inventory_spend`) and Modules (mint) — acyclic, one
   sole-writer per table.
2. **Crafting is INSTANT in Phase 13**: an idempotent dark command in the 0099/0104 two-layer
   idiom with a PLAYER-scoped receipts table (crafting is non-spatial, so
   `trade_relief_claims`-style (player, request_id) keying, NOT ship-scoped space receipts). The
   M4.5 "same queue" note is FUTURE meaning — integrating with `build_orders` would touch the
   shipped Production queue and risk the green M4.5 tests, so it is explicitly deferred with this
   RETIREMENT NOTE: when module production later moves onto the serial queue, the queued
   completion path must call the SAME Modules mint helper this phase creates.
3. **Recipe encoding is a normalized table, NOT jsonb**: `module_recipe_ingredients
   (module_type_id, item_id, qty)` with FKs to `module_types` and `item_types` and a `qty > 0`
   check — referential integrity over blob parsing; one implicit recipe per module type (its
   ingredient rows); costs are ITEMS-ONLY in Phase 13 (no metal/credits — the pipeline law says
   crafting consumes INVENTORY; metal would drag in a Base edge the phase doesn't need and can be
   added forward-only later).
4. **One craft = one instance** (no batching), keeping idempotency trivial.
5. **Flag name `module_crafting_enabled`**, seeded `'false'`, following the exact 0097/0102
   config+flag idiom including the server-side `feature_disabled` rejection posture for every
   future RPC.

**Work done — NEW `supabase/migrations/20260618000107_modules_p13_catalog_and_flag.sql`**
(migration head moves **0106 → 0107**; `0001–0106` unedited):
- **(a)** `game_config` seed `module_crafting_enabled='false'` (`on conflict (key) do nothing`,
  the exact 0097/0102 dark-gate idiom + description stating the reject-before-any-read law).
- **(b)** **`module_types`** — minimal intrinsic catalog identity ONLY: `id text primary key`,
  `name text not null`, `slot_type text not null` (intrinsic archetype; display now, fitting
  validation in Phase 14; unconstrained text like `item_types.category`/`support_craft_types.role`
  — no code consumer yet), `description text not null`, `created_at`. **NO stats columns** —
  stats wiring is Phase 14's job, added forward-only there.
- **(c)** **`module_recipe_ingredients`** per decision 3: FKs to both catalogs,
  `qty integer not null check (qty > 0)`, PK `(module_type_id, item_id)`.
- **(d)** Seeds (`on conflict do nothing`): 4 starter module types spanning distinct slot
  archetypes, copy matching the 0042 catalog tone — `autocannon_battery` (weapon: weapon_parts ×4
  + pirate_alloy ×2 + scrap ×6), `vector_thruster_kit` (engine: engine_parts ×4 + crystal ×2 +
  scrap ×4), `expanded_cargo_lattice` (cargo: scrap ×10 + pirate_alloy ×3 + repair_parts ×2),
  `deep_scan_sensor_array` (sensor: scan_data ×5 + anomaly_shard ×2 + blueprint_fragment ×1).
  Recipes consume ONLY EXISTING `item_types` rows (0039/0097 seeds REUSED — `item_types` is NOT
  touched; the 0097 reuse law).
- **(e)** RLS/grants — verified against the sources, not assumed: both tables copy the
  Reference/Config catalog posture verbatim (`item_types` 0039:23–25 / `support_craft_types`
  0042:32–36): RLS enabled, ONE public-read select policy, `grant select to anon, authenticated`,
  NO write policy/grant. No function created → no execute-surface relock needed (0054 precedent).

**Doc-sync (same step).** `docs/SYSTEM_BOUNDARIES.md`: §1 matrix gained the row
`module_types`, `module_recipe_ingredients` → **Modules** (catalog/config — seeded by migration
only, NO runtime writer yet; the mint writer arrives with `module_instances` in a later Phase-13
slice; public read-only); §2 gained the **Modules** system row recording the dark gate, the
Production-will-own-the-craft-command note (with the downward Inventory+Modules fan-out, the
player-scoped receipt keying, one-craft-one-instance, and the M4.5 retirement note) and the
forbidden column (never write player_inventory/inventory_ledger/base_resources; never mint outside
the ONE mint helper; fitting/`module_slots` is Phase 14).

**State.** `npm run build` green (tsc -b + vite). Migration head **0107**;
`module_crafting_enabled='false'` — nothing client-writable exists (two public-read catalogs + one
dark flag; no RPC, no writer, no reader). No flag flipped, no live DB write, no workflow touched.
**DB-apply posture (honest):** this sandbox has no psql/docker/supabase CLI and npx cannot fetch
(the recorded `UNABLE_TO_VERIFY_LEAF_SIGNATURE` environmental posture) — the migration was
hand-verified line-by-line against the shipped idioms it copies (0039/0042 table+RLS posture,
0097/0102 seed idiom, 0098 same-step boundaries sync), exactly the P11/P12 slice-B/C verification
posture; the seeds/flag assertions run against a real DB in the owner's environment (and will be
covered by the slice-G `verify:modules` dark-posture script). PR-ready on
`autopilot/20260703-064048`, `main` untouched. Next: slice B (`module_instances` + the mint
helper).

---

## 2026-07-04 — MINING-CLEANUP SLICE 2 (final) — MarketPanel migrated onto `useActivityPanelGuards`. **Guard-hook extraction complete — no local copies remain**

**Request.** Final slice of the mining-milestone cleanup: migrate `MarketPanel.tsx` (the idiom's
original reference copy) onto the shared hook, byte-equivalent behavior, and close the doc trail.

**Work done — `src/features/map/MarketPanel.tsx` only:**
- Local mounted-guard block + per-row `inFlightRef` Set replaced by
  `const { activeRef, tryClaim, release } = useActivityPanelGuards()` — the per-row granularity
  maps directly onto the hook's Set-of-string keys (`tryClaim(goodId)` / `release(goodId)`).
- Submit handler: `!shipId` first, then `tryClaim(goodId)` early-return; the qty validation now
  sits AFTER the claim with `release(goodId)` before its early return. **Behavior-equivalent
  reordering (claim→validate→release vs check→validate→claim):** the whole sequence is
  synchronous with NO await in between, so a duplicate in-flight click still returns before any
  validation side effect, and an invalid qty still leaves no lasting claim. `finally` now calls
  `release(goodId)`; the `activeRef`-guarded pending reset is untouched.
- Idiom comments repointed: the guard scaffold's home is `src/lib/useActivityPanelGuards.ts`;
  MarketPanel is now a consumer like Exploration/Mining, not the reference copy.
- `refresh` deps: `[shipId]` → `[shipId, activeRef]` (the SLICE 1 exhaustive-deps posture; ref
  identity is stable so `refresh`'s identity is unchanged). NOT touched: `pending`/`qty`/`rowError`
  state shapes, `refresh()`'s Promise.all body, the `!selectedShip → null` check, the
  shell-with-`unavailableNote` posture (still NOT `isServerLit` — documented in the hook), error
  copy via `tradeReasonMessage`, render output.

**Extraction promised in the SLICE F note is COMPLETE:** all three activity panels
(Market/Exploration/Mining) consume `useActivityPanelGuards`; grep confirms no file under `src/`
declares a local `activeRef`/`inFlightRef` guard outside the hook itself.

**Doc-sync note.** `docs/SYSTEM_BOUNDARIES.md` needs NO change (frontend-only, SLICE F precedent).

**State.** `npm run build` green (tsc -b + vite). `npm run lint`: the 2 touched files lint clean;
full-repo lint still FAILS with exactly the same 14 pre-existing out-of-scope errors recorded in
SLICE 1 (no new problems). Migration head stays **0106** (no migrations, no flags); everything
still dark and server-rejected. Diff = exactly 2 files (MarketPanel.tsx, this file).

---

## 2026-07-04 — MINING-CLEANUP SLICE 1 — panel guard scaffold extracted to `src/lib/useActivityPanelGuards.ts`; Exploration + Mining migrated

**Request.** Extract the duplicated activity-panel guard pattern (the documented cross-panel
"MarketPanel idiom") into ONE shared hook and migrate the two twin panels, byte-equivalent
behavior. This is the sanctioned **"adopt-on-next-real-change"** the SLICE F entry recorded when
it deliberately did NOT extract the scaffold (third copy landed → the change is now real).

**Work done — NEW `src/lib/useActivityPanelGuards.ts`** (frontend-only; `src/lib/` is the
established shared home, concern-per-file):
- **`useActivityPanelGuards()`** → `{ activeRef, tryClaim, release }`. The mounted guard is the
  MarketPanel block verbatim (`useRef(true)` + one empty-deps effect; StrictMode re-arms). The
  in-flight guard is a `useRef<Set<string>>` with stable callbacks: `tryClaim(key)` claims
  synchronously BEFORE any await (false if already claimed — the same-tick double-submit killer),
  `release(key)` drops it in the caller's `finally`. A Set-of-string serves BOTH granularities —
  MarketPanel's per-row `good_id` keys and Exploration/Mining's fixed `'scan'`/`'extract'` key —
  so one hook covers all three panels with zero behavior change.
- **`isServerLit(result)`** — the shared form of the `!result || !result.ok` fail-closed check,
  ONLY for server-lit panels that render nothing until the server affirms (Exploration/Mining
  style); explicitly NOT for MarketPanel's shell-with-unavailable-note posture. Typed
  `result is Extract<T, { ok: true }>` so the discriminated-union narrowing the inline checks
  gave callers is preserved (`result.discoveries`/`result.extractions` stay type-safe).

**Migrated (behavior byte-equivalent):** `ExplorationPanel.tsx` + `MiningPanel.tsx` — the local
`activeRef` block and boolean `inFlightRef` replaced by the hook; guard ORDER preserved
(`!mainShipId` first, then `tryClaim`); `finally` now calls `release(...)`; fail-closed render
check now `if (!isServerLit(result)) return null` under the same FAIL CLOSED comments; the
"MarketPanel idiom" comments repointed to the shared hook. NOT touched: `refresh()`, effect deps,
`lifecycleKey`, state shapes, error/success copy (incl. the mining cooldown suffix), MarketPanel.

**Doc-sync note.** `docs/SYSTEM_BOUNDARIES.md` needs NO change (SLICE F precedent): frontend-only,
no table, no writer, no cross-system edge; server contracts unchanged.

**State.** `npm run build` green (tsc -b + vite). `npm run lint`: the 4 touched files lint clean
(0 problems, incl. exhaustive-deps via the stable-ref dep); full-repo lint FAILS with 14
pre-existing errors in out-of-scope files (`MainShipMarker.tsx`, `SpaceRouteLine.tsx`,
`useSpaceMoveCommand.ts`, `tests/` harnesses/spec) that predate this slice and sit outside the
locked scope — NOT fixed here (scope law), left for their own cleanup step. Migration head stays
**0106** (no migrations, no flags); everything still dark and server-rejected. Diff = exactly
4 files (new hook, two panels, this file). Next slice: migrate MarketPanel's per-row guards onto
the same hook and retire its local copy.

---

## 2026-07-04 — MINING-P12 SLICE G (final) — `verify:mining` dark-posture script. **Phase 12 Mining — dark implementation complete (slices A–G)**

**Request.** Implement slice G, the last Phase 12 slice: the dark-posture verify script + its
`package.json` entry, mirroring the exploration slice-H precedent (the post-cleanup,
harness-importing form). Touches ONLY `scripts/verify-mining.mjs`, `package.json`, this file, and
the recon scratch file. No migrations (head stays **0106**), no CI/workflow edits, no flags.

**Work done:**
- **NEW `scripts/verify-mining.mjs`** — imports the shared harness from day one
  (`Abort`/`createReporter`/`createUserFactory`/`resolveEnv` from `scripts/lib/verify-harness.mjs`
  + `teardownVerifier` from `scripts/lib/verifier-teardown.mjs`) — ZERO inline harness copies (the
  harness header's law). Same posture as `verify-exploration.mjs`: proves the DARK contracts only;
  NEVER writes `game_config`, NEVER flips `mining_enabled`; service key OPTIONAL (teardown only);
  one throwaway signup. Asserts, in the exploration script's order/idioms:
  (1) **dark rejection** — `command_mining_extract(ZERO, ZERO)` →
  `{ok:false, code:'feature_disabled'}` (0104 gates before ship resolution — anti-probe) and
  `get_my_mining_extractions()` → `{ok:false, reason:'mining_disabled'}` (0106), both
  authenticated; (2) **no field leak** — authenticated select on `mining_fields` → denied/0 rows
  (0103 posture) and `mining_extractions` → 0 rows for a fresh user (own-row RLS);
  (3) **internal surfaces locked** — `mining_extract` + `process_mining_securing` denied to the
  authenticated client, both public RPCs denied to anon (`osn_distance` deliberately NOT
  re-asserted — `verify:exploration` owns that slice's surface, no duplicate assertion);
  (4) **config presence (read-only)** — `mining_enabled` = false, `mining_extract_radius` = 750,
  `mining_extract_cooldown_seconds` = 300, via the same jsonb-storage-tolerant comparison.
- **`package.json`** — `"verify:mining": "node scripts/verify-mining.mjs"` added in the verify
  cluster, directly after `verify:exploration`. No CI/workflow edits.
- **Verify posture run honestly:** `node --check scripts/verify-mining.mjs` parses clean.
  `node scripts/verify-mining.mjs` in this sandbox aborts at the throwaway SIGNUP step with the
  environmental TLS failure (`UNABLE_TO_VERIFY_LEAF_SIGNATURE` → "signup failed: fetch failed") —
  `node scripts/verify-exploration.mjs` aborts at the IDENTICAL point in the same run, so this is
  the known environmental-fail-only posture (DEV_LOG 2026-07-03 precedent), and reaching that
  identical abort point proves the harness wiring. The assertions themselves run against a real
  DB in the owner's environment.
- `docs/SYSTEM_BOUNDARIES.md` needs NO change this slice — no table, writer, or cross-system edge
  (a read-only verifier script + one npm alias).

---

### Phase 12 Mining — dark implementation complete (slices A–G) — closing summary

- **Migrations `0102–0106`** (head **0101 → 0106**; all forward-only; `0001–0101` never edited):
  `0102` config/flag (`mining_enabled='false'` + `mining_extract_radius='750'` +
  `mining_extract_cooldown_seconds='300'`; NO new item_types rows) · `0103` schema
  (`mining_fields` hidden/server-only + repeatable `mining_extractions` with own-row RLS +
  cooldown/player indexes; 5 seeded fields, items-only bundles from the existing
  `ore`/`crystal`/`artifact_core`) · `0104` the extract command (`command_mining_extract` wrapper →
  private `mining_extract`; dark-gate-first, S2 lock, receipts idempotency, `osn_distance` radius,
  per-(player, field) cooldown with `retry_after_seconds`) · `0105` the securing processor
  (`process_mining_securing` + pg_cron `process-mining-securing` @60s; flag-ignoring in-flight
  safety; deposits via `reward_grant('mining', extraction_id, …)` — the sole depositor — on safe
  settle) · `0106` the read surface (`get_my_mining_extractions`; reveal-after-extraction only).
- **Frontend:** dark `src/features/mining/` (types/api/panel twins of the post-cleanup exploration
  files; server-driven visibility, fails closed to null) wired beside `ExplorationPanel` in
  `GalaxyMapScreen.tsx`; **shared-lib extractions** `src/lib/rewardBundle.ts` (`PendingBundle`) +
  `src/lib/osnState.ts` (`isSettledInSpace`) with exploration repointed same-step (no second copy).
- **Verify:** `scripts/verify-mining.mjs` + `npm run verify:mining` (dark posture only, shared
  harness, never flips flags).
- **Design decisions** (recon §8, self-approved 2026-07-04): exploration-template OSN-native
  extract command; repeatable extraction + server-enforced cooldown (no unique pair); rewards land
  in item inventory ONLY via `reward_grant('mining', …)` reusing existing catalog rows (never
  `base_resources`; `trade_goods` `'ore'` untouched); hidden fields + reveal-after-extraction;
  forfeiture deferred (0100 posture); cooldown per-ship serialization accepted while multi-ship is
  dark (0105 header note).
- **Ownership/laws:** SYSTEM_BOUNDARIES §1/§2 rows + ARCHITECTURE §7-adjacent §14 processor row +
  ACTIVITIES/ROADMAP untouched where already accurate — every doc synced in the SAME step as its
  fact; edges all DOWNWARD/acyclic; sole writers: `mining_fields` none (Reference/Config),
  `mining_extractions` = Mining (0104 inserts · 0105 secures); `reward_grant` the only depositor.
- **HUMAN ACTIVATION CHECKLIST (the owner's gate — never this loop):** (1) apply migrations
  0102–0106 to the target DB; (2) run `npm run verify:mining` there — expect ALL dark-posture
  checks green; (3) optionally flip `mining_enabled='true'` on a DEV database and run the lit
  path (settle in space near a seeded field → `command_mining_extract` → pending row → repeat →
  `cooldown` with `retry_after_seconds` → dock/return home → `process_mining_securing` deposits
  ore/crystal/core items via `reward_grant('mining', …)` → `get_my_mining_extractions` shows
  Secured) — then decide production activation separately. The loop ships everything
  server-rejected; activation is exclusively the human's.

**State.** `npm run build` green; `node --check` clean on the new script. Migration head **0106**;
`mining_enabled='false'` everywhere; no flag flipped, no live DB write, no workflow touched.
**Phase 12 Mining is implemented DARK end-to-end and PR-ready on `autopilot/20260703-064048`** —
SAFE FOR HUMAN MERGE REVIEW; `main` untouched.

---

## 2026-07-04 — MINING-P12 SLICE F — dark frontend `src/features/mining/` + shared `src/lib/rewardBundle.ts`/`osnState.ts` extraction (exploration repointed same-step)

**Request.** Implement slice F of the Phase 12 plan (recon §9): the dark mining frontend mirroring
the post-cleanup exploration frontend exactly, with the HARD-RULE duplication check. No server
changes, no migrations, no config — migration head STAYS **0106**.

**Duplication check first (the hard rule) — TWO extractions, exploration repointed in this same step:**
- **NEW `src/lib/rewardBundle.ts`** — `PendingBundleItem` + `PendingBundle` (the 0040/0041 server
  bundle contract). Mining needed the identical types verbatim; the one copy moved out of
  `explorationTypes.ts` (which now imports it) and `miningTypes.ts` imports it from day one.
- **NEW `src/lib/osnState.ts`** — `isSettledInSpace()` (the 0055 settled-in-space predicate that
  drives the action button's enabled state; server stays authoritative). Same story: moved out of
  `explorationTypes.ts`; `ExplorationPanel.tsx` and `MiningPanel.tsx` both import it from here.
  `src/lib/` is the established shared home (catalog/location/time idiom, concern-per-file).
- **NOT extracted (below the bar, stated per the request):** the panel scaffold
  (mounted-guard `activeRef` + synchronous `inFlightRef` + `refresh` callback) is the documented
  cross-panel "MarketPanel idiom" already present in several panels — the exploration cleanup pass
  reviewed these exact files and did not extract it; a shared-hook refactor would touch MarketPanel
  and siblings, out of this slice's scope (adopt-on-next-real-change precedent). The API wrappers
  (2-line rpc calls with per-feature names/types), the per-feature error-copy maps (different
  strings), and the inline `toLocaleString()` one-liner are trivial per-feature glue.

**Work done — NEW `src/features/mining/` (the exploration twins, post-cleanup state — NO
speculative disabled-reason constant, exactly what the cleanup pass deleted from exploration):**
- **`miningTypes.ts`** — `MiningExtraction` (the 0106 row: field_name, space_x/space_y,
  extracted_at, secured_at, bundle), `GetMyMiningExtractionsResult`,
  `CommandMiningExtractResult` (0104 wrapper success shape; failure envelope includes optional
  `retry_after_seconds` — REAL server data on the `cooldown` code), and the extract error-copy
  map (the 0104 code set) + `miningExtractErrorMessage`.
- **`miningApi.ts`** — thin `supabase.rpc` wrappers for `command_mining_extract` +
  `get_my_mining_extractions`, identical envelope-handling idiom (transport error → normalized
  failure, never a throw into the render path).
- **`MiningPanel.tsx`** — the `ExplorationPanel` structure verbatim: server-driven visibility
  (reads the extractions on mount/lifecycle change and **fails closed to null on ANY non-ok
  envelope without inspecting reason** — the documented deliberate posture; while the server
  returns `mining_disabled` the panel renders nothing, so production is unchanged); extract
  enabled only when settled in space; fresh `crypto.randomUUID()` request id per submit with the
  synchronous in-flight guard; extraction history list (field name, Pending/Secured badge, bundle
  contents as `item ×qty`, coords + timestamp). Mining-specific glue: the cooldown failure note
  appends the server's `retry_after_seconds`; amber styling vs exploration's violet; positioned
  bottom-left BESIDE ExplorationPanel (`left-[17rem]`; both are server-lit so overlap only ever
  involves lit surfaces).
- **Wiring:** `GalaxyMapScreen.tsx` — `MiningPanel` imported and rendered directly adjacent to
  `ExplorationPanel`, same import style, same props (`lifecycleKey`/`mainShipId`/`shipStatus`/
  `shipSpatialState`), same comment convention.

**Doc-sync note.** `docs/SYSTEM_BOUNDARIES.md` needs NO change: the extractions are client-side
display types/predicates (no table, no writer, no cross-system edge); the server contracts they
mirror are unchanged.

**State.** `npm run build` green (`tsc -b` typecheck + vite; standalone `tsc --noEmit` also clean).
Migration head stays **0106**; everything still dark — the panel is wired but renders nothing
(every mining RPC server-rejects while `mining_enabled='false'`), and the repointed exploration
surface is behavior-identical. PR-ready on `autopilot/20260703-064048`, `main` untouched. Next:
slice G (`scripts/verify-mining.mjs` + the `verify:mining` entry).

---

## 2026-07-04 — MINING-P12 SLICE E — the dark read surface `0106` (`get_my_mining_extractions()`). **Server side of Phase 12 complete, fully dark**

**Request.** Implement slice E of the Phase 12 plan (recon §9): ONE new forward-only migration with
the read surface, mirroring the exploration read surface 0101 exactly (function shape, dark-gate
behavior, reveal semantics, envelope, ACL). No frontend, no config changes, no other functions.

**Work done — NEW `supabase/migrations/20260618000106_mining_p12_read_surface.sql`** (migration
head moves **0105 → 0106**; `0001–0105` unedited):
- **`get_my_mining_extractions()`** — the 0101 body step-for-step: `auth.uid()` resolution
  (`not_authenticated` envelope), then the dark gate BEFORE any extraction/field read —
  `{ok:false, reason:'mining_disabled'}` (the 0101 `exploration_disabled` envelope shape),
  identical regardless of caller state (no probing while dark) — then the caller's OWN
  `mining_extractions` joined to the hidden `mining_fields` rows. Per row it reveals exactly the
  0101 attribute classes: field `name` + `space_x`/`space_y` (as 0101 reveals sites), the
  extraction's lifecycle fields (`extracted_at` = the row's `created_at`, `secured_at`), and
  `bundle` = the row's `pending_bundle_json` snapshot — 0101 exposes the discovery's pending
  bundle, so mining mirrors it; the field's own `reward_bundle_json` is never exposed directly.
  Ordering (`created_at desc`), response shape (`{ok:true, extractions:[…]}` mirroring
  `{ok:true, discoveries:[…]}`), and posture (`stable`, `security definer`,
  `set search_path = public`) all verbatim from 0101. Repeatability nuance (header-documented):
  the history legitimately contains multiple rows per field — one per extraction — and
  extracted-then-disabled fields stay visible (the 0101 posture: the player's own history).
- **Reveal rule (header):** a field is revealed ONLY through the player's own extraction rows —
  no browse-all surface; the 0103 no-client-policy posture on `mining_fields` is untouched, so an
  un-extracted field stays unreachable by construction (identical anti-probe stance to
  exploration).
- **ACL verbatim from 0101:** execute revoked from public/anon, granted to authenticated only —
  and dark today: the gate rejects every call while `mining_enabled='false'`.

**Doc-sync (same step).** `docs/SYSTEM_BOUNDARIES.md`: the §2 Mining row dropped its last
FORTHCOMING — the read surface is now named LIVE (read-only, dark-gated `mining_disabled`, the
only client path to field data, strictly post-extraction). The §1 matrix rows need NO change —
slice E adds no writer (`get_my_mining_extractions` is read-only; `mining_fields` still has no
runtime writer, `mining_extractions` still has exactly the two 0104/0105 writer fns).

**State.** `npm run build` green. Migration head **0106**. **The server side of Phase 12 Mining is
COMPLETE (slices A–E) and fully dark end-to-end:** the command wrapper + writer and the read
surface all server-reject while `mining_enabled='false'`; the securing processor correctly ignores
the flag but is inert (no extraction row can exist). No flag flipped, no live DB write; PR-ready on
`autopilot/20260703-064048`, `main` untouched. Next: slice F (dark frontend
`src/features/mining/`), then slice G (`verify:mining`).

---

## 2026-07-04 — MINING-P12 SLICE D — the securing processor `0105` (`process_mining_securing` + pg_cron; deposits via `reward_grant('mining', …)`)

**Request.** Implement slice D of the Phase 12 plan (recon §9): ONE new forward-only migration with
Mining's own securing processor, mirroring the exploration securing processor 0100 exactly —
mining's as-built extraction rows already model the lifecycle the same way (`secured_at` NULL =
pending, 0103), so the processor shape carries over verbatim with no structural deviation. No read
surface, no frontend, no config changes.

**Work done — NEW `supabase/migrations/20260618000105_mining_p12_securing_processor.sql`**
(migration head moves **0104 → 0105**; `0001–0104` unedited):
- **`process_mining_securing()`** — the 0100 body step-for-step: `FOR UPDATE SKIP LOCKED` sweep of
  `mining_extractions where secured_at is null`; carrying ship = the row's `main_ship_id`, else
  the player's canonical main ship via `mainship_resolve_owned_ship` (the 0100 NULL-fallback
  verbatim; unresolvable → the row waits); settled SAFE = `spatial_state in ('home','at_location')`
  per the 0055 state model (anything else waits); deposit target = the player's active home base
  (0050 idiom; null base → the row waits — guard kept verbatim from 0100 even though mining
  bundles are items-only, one pattern not two); then
  `reward_grant('mining', extraction_id, player, base, pending_bundle_json)` + `secured_at = now()`
  in the same transaction. Like 0100 there is NO per-row exception wrapper — skips are `continue`
  branches, and idempotency is DOUBLE-guarded (`secured_at` NULL filter + the `reward_grants`
  UNIQUE (source_type, source_id) law), so a re-run can never double-deposit.
- **Flag posture (0100 wording convention):** the processor deliberately IGNORES `mining_enabled`
  — in-flight safety: accrued pending value must never be stranded by an emergency flag-off.
  Naturally inert today: the 0104 writer rejects while the flag is false, so no extraction rows
  can exist and the processor sweeps an empty set.
- **Slice-C review note recorded in the header:** the 0104 cooldown is serialized per SHIP via the
  S2 lock, not per player — acceptable because the canonical model is one main ship per player
  (multi-ship stays DARK behind `mainship_additional_commission_enabled=false`) and no
  double-deposit is possible regardless (receipts + the `reward_grants` unique key); revisit if
  multi-main-ship ever activates.
- **ACL + cron verbatim from 0100:** execute revoked from public/anon/authenticated, granted to
  service_role; `create extension if not exists pg_cron`; idempotent unschedule guard
  (`undefined_table` swallowed); `cron.schedule('process-mining-securing', '* * * * *', …)` —
  every 60s (pg_cron's seconds form caps at 59s, so every-minute standard cron, the 0100 comment).
- NO forfeiture: a pending extraction simply WAITS (destroyed ships secure after recovery lands
  them home) — the 0100 posture, recon decision 4.

**Doc-sync (same step).**
- `docs/SYSTEM_BOUNDARIES.md`: the `mining_extractions` §1 row now reads "ONE owner system, two
  writer fns: `mining_extract` (0104) inserts · `process_mining_securing` (0105) sets
  `secured_at`" (both LIVE); the §2 Mining row's securing paragraph rewritten to present tense
  (0105 shipped — safe-settle definition, double-guarded idempotency, flag-ignoring in-flight
  safety) with only the slice-E read surface still FORTHCOMING; the Mining → Bases (deposit-target
  read) and Mining → Reward (grant) edges are now live and the edge list stays all-DOWNWARD,
  exactly the Exploration shape.
- `docs/ARCHITECTURE.md` §14 processors table: added the `process_mining_securing()` row exactly
  parallel to the exploration row (every 60s; deposits via `reward_grant('mining',
  extraction_id, …)` once the ship settles safe; deliberately ignores `mining_enabled`; pg_cron
  job `process-mining-securing`; migration 0105).

**State.** `npm run build` green. Migration head **0105**; still dark END-TO-END — the command
rejects while `mining_enabled='false'`, so the processor (which correctly ignores the flag) has
nothing to sweep; no flag flipped, no live DB write; PR-ready on `autopilot/20260703-064048`,
`main` untouched. Next: slice E (the read surface).

---

## 2026-07-04 — MINING-P12 SLICE C — the dark extraction command `0104` (`command_mining_extract` → private `mining_extract`)

**Request.** Implement slice C of the Phase 12 plan (recon §9): ONE new forward-only migration with
the two-layer extraction command, mirroring the exploration scan command's AS-BUILT form (0099 body
+ the 0100 changes) — same shape, envelopes, locking, and ACL — deviating only where the recon §8
decisions require (repeatability/cooldown instead of unique-discovery). No processor, no read
surface, no frontend, no `game_config` changes.

**Work done — NEW `supabase/migrations/20260618000104_mining_p12_extract_command.sql`** (migration
head moves **0103 → 0104**; `0001–0103` unedited):
- **Private `mining_extract(p_player, p_main_ship_id, p_request_id)`** — the 0099/0100 writer
  step-for-step: dark gate FIRST (`cfg_bool('mining_enabled')` → `feature_disabled` before ANY
  read/lock/write) → request-id validation → S2 canonical lock context →
  ownership-from-locked-snapshot → canonical payload hash → receipt lookup
  (`main_ship_space_command_receipts`; replay returns the first committed result;
  `request_id_payload_conflict` on hash mismatch — the EXACT 0099 mechanism, no new receipt
  system) → `mainship_space_validate_context` (settled `in_space` required; `destroyed` /
  `not_in_space` reasons) → `mainship_space_assert_cross_domain_exclusion` → live position under
  lock → NEAREST active `mining_fields` row within `cfg_num('mining_extract_radius')` via
  `osn_distance` (deterministic tie-break distance-then-name; none → `no_field_in_range`).
  **Deviations (recon decisions 2/4, all header-documented):** no discovered-filter and no
  ON CONFLICT race guard (repeatable; the S2 ship lock serializes concurrency, receipts dedupe
  replays); NEW cooldown step — the latest `mining_extractions.created_at` for (player, field)
  (the 0103 `(player_id, field_id, created_at desc)` index) must be older than
  `cfg_num('mining_extract_cooldown_seconds')`, else `{ok:false, reason:'cooldown',
  retry_after_seconds}` (failure writes NO receipt — 0064 posture — so the same request_id
  retries cleanly after the cooldown). On success: ONE extraction row inserted with
  `pending_bundle_json` = the field's `reward_bundle_json` verbatim + the resolved
  `main_ship_id`; success envelope in 0099's shape; receipt finalised atomically.
- **Public wrapper `command_mining_extract(p_main_ship_id, p_request_id)`** — the 0099 wrapper
  verbatim: auth check → `mining_enabled` gate BEFORE any ship/argument resolution (anti-probe;
  `{ok:false, code:'feature_disabled'}`) → `mainship_resolve_owned_ship` → delegate → the same
  reason→code/message map with `no_field_in_range`/`cooldown` replacing
  `no_site_in_range`/`already_discovered`; the `cooldown` failure passes `retry_after_seconds`
  through.
- **ACL verbatim from 0099:** `mining_extract` revoked from public/anon/authenticated, granted to
  service_role; `command_mining_extract` revoked from public/anon, granted to authenticated.
- DARK today: both gates reject every call; a successful extraction would only sit pending anyway —
  the securing processor arrives in slice D (unreachable today).

**Doc-sync (same step).** `docs/SYSTEM_BOUNDARIES.md`: the `mining_extractions` §1 row now names
`mining_extract` (0104) as the LIVE sole insert path (insert-only) with `process_mining_securing`
still FORTHCOMING; the §2 Mining row rewritten to present tense for the shipped command (wrapper →
private writer, receipts/S2/validate/exclusion reuse, cooldown + nearest-field rule) with slices
D/E still marked forthcoming — edge list stays all-DOWNWARD (Mining → OSN geometry/locks · Main
Ship read · Reference/Config reads · Bases/Reward deferred to slice D), exactly the Exploration
shape.

**State.** `npm run build` green. Migration head **0104**; still fully dark — the wrapper and
writer both server-reject while `mining_enabled='false'`; no flag flipped, no live DB write;
PR-ready on `autopilot/20260703-064048`, `main` untouched. Next: slice D
(`process_mining_securing`).

---

## 2026-07-04 — MINING-P12 SLICE B — mining schema migration `0103` (`mining_fields` + `mining_extractions`, dark, no writer exists)

**Request.** Implement slice B of the Phase 12 plan (recon §9): ONE new forward-only migration with
the two mining tables + seeds + RLS, mirroring the exploration schema slice 0098 and deviating only
where the recon §8 decisions require it. No functions, no cron, no `game_config` changes, no
frontend.

**Work done — NEW `supabase/migrations/20260618000103_mining_p12_fields_schema.sql`** (0098
structure/idioms; migration head moves **0102 → 0103**; `0001–0102` unedited):
- **`mining_fields`** — hidden static resource-field catalog, the 0098 `exploration_sites` shape
  verbatim: name-unique seed key; `space_x`/`space_y` with the finite-only CHECK idiom + the
  `[-10000,10000]²` envelope; deterministic `reward_bundle_json` (jsonb-object CHECK); `is_active`
  soft-disable. **RLS enabled with NO client policy and NO client grant** (anti-probe posture
  identical to 0098 — field coordinates/composition are never client-readable before extraction).
  Seeds 5 fields on the integer grid, near/far spread, distinct from the exploration sites, with
  ITEMS-ONLY bundles (decision 3) drawn from the EXISTING catalog rows: `ore` in every field
  (qty 2–3), `crystal` in three (qty 1–2), `artifact_core` in exactly one (qty 1) — per-item
  quantities in the 0098 magnitude; no metal scalar, so nothing can ever land in `base_resources`.
- **`mining_extractions`** — per-extraction state row: player + field FKs, `main_ship_id`
  (`on delete set null`, the 0100 resolver-fallback idiom), `pending_bundle_json` snapshot +
  `secured_at` (NULL = pending — the exploration as-built lifecycle verbatim; no `'{}'` default
  needed on a fresh table, unlike the 0099 migration-validity shim), `created_at` as the cooldown
  anchor. **THE deliberate deviation from 0098 (decision 2): NO `unique (player_id, field_id)`** —
  extraction is repeatable; one row per extraction; idempotency = the slice-C receipt convention;
  pacing = the per-(player, field) cooldown. Indexes: `(player_id, field_id, created_at desc)`
  (cooldown lookup) + `(player_id, created_at desc)` (the 0098 player-index idiom, serves the
  slice-E read surface). Own-row SELECT policy + `grant select to authenticated` only — NO write
  policy/grant; writers are the forthcoming slice-C command and slice-D processor.
- Forfeiture of pending bundles: DEFERRED with the documented 0100 posture (pending rows wait;
  destruction semantics are a future product decision) — stated in the migration header.

**Doc-sync (same step).** `docs/SYSTEM_BOUNDARIES.md`: §1 matrix gained the two rows —
`mining_fields` = Reference/Config (static hidden world data, NO runtime writer, server-only read);
`mining_extractions` = **Mining** (ONE owner system, two FORTHCOMING writer fns: slice-C
`mining_extract` inserts · slice-D `process_mining_securing` sets `secured_at`; DARK behind
`mining_enabled=false`, schema-only today) — and §2 gained the Mining system row (forthcoming
surfaces named; bundles items-only; deposits ONLY via `Reward.grant('mining', extraction_id, …)` —
`reward_grant` remains the sole depositor; edges all DOWNWARD in the Exploration shape; forbidden
column includes writing `base_resources` at all). No other section contradicts the new tables (the
"OSN geometry leaf" note already anticipated Mining as a later downward consumer).

**State.** `npm run build` green. Migration head **0103**; both tables exist DARK with NO writer
anywhere (nothing can insert until slice C ships); no flag flipped, no live DB write; PR-ready on
`autopilot/20260703-064048`, `main` untouched. Next: slice C (`command_mining_extract`).

---

## 2026-07-04 — MINING-P12 SLICE A — design decisions (self-approved) + dark config/flag migration `0102`

**Request.** Record the Phase 12 Mining design decisions and implement slice A: ONE new forward-only
migration seeding the dark gate + tunables. Nothing else — no tables, no functions, no grants, no
catalog rows, no frontend, no flag flipped.

**Design decisions (self-approved; full text + rationale in `MINING_P12_RECON.local.md` §8):**
1. **Extract shape:** mirror the exploration OSN-native template as a single
   `command_mining_extract` (prospect+extract in one command) — settled `in_space` under the S2
   lock + cross-domain exclusion, proximity via the existing `osn_distance` leaf against
   `mining_extract_radius`, pending extraction row secured later by a flag-ignoring securing
   processor when the ship settles safe (the 0099→0100 shape). Maximal reuse; no new engine surface.
2. **Repeatability:** mining is repeatable (no `unique(player_id, field_id)`); one extraction row
   per extraction, receipts idempotency, plus a server-enforced per-(player, field) cooldown from
   the latest extraction's `created_at` against `mining_extract_cooldown_seconds`.
3. **Reward landing zone:** item inventory via `reward_grant('mining', extraction_id, …)` reusing
   the EXISTING `item_types` rows `ore`/`crystal`/`artifact_core`; NO new catalog rows, NO writes to
   `base_resources` (that would add a second landing path to the Base-owned economy scalars). The
   `trade_goods` `'ore'` is a separate Trade Market catalog and is not touched.
4. **Field visibility:** hidden like `exploration_sites` (RLS, no client policy/grant);
   deterministic `reward_bundle_json` per field; the read surface reveals only fields the player
   has extracted from. Forfeiture of in-flight pending bundles DEFERRED with the exploration 0100
   posture (pending rows wait; destruction semantics are a future product decision).

**Slice plan** (recon §9): A=config/flag (this step) → B=`mining_fields`+`mining_extractions`
schema+seeds → C=`command_mining_extract` → D=securing processor → E=read surface → F=dark frontend
`src/features/mining/` → G=`verify:mining` script (must import `scripts/lib/verify-harness.mjs`).

**Work done — NEW `supabase/migrations/20260618000102_mining_p12_config_and_flag.sql`** (0097
structure/idioms; migration head moves **0101 → 0102**; `0001–0101` unedited):
- `game_config` seeds (established `on conflict (key) do nothing` upsert idiom):
  `mining_enabled='false'` (the dark gate — every later mining RPC must check it FIRST and
  reject-before-any-read), `mining_extract_radius='750'` (matches the exploration radius default;
  retune via config, no redeploy), `mining_extract_cooldown_seconds='300'`.
- Deliberately NO `item_types` rows (decision 3 — unlike 0097, which needed two new item classes).
- No table, no function, no grant, no cron; the keys are inert until slice C reads them.

**Doc-sync note:** `docs/SYSTEM_BOUNDARIES.md` needs NO change this slice — no new table, writer, or
cross-system edge exists yet (`game_config` stays Reference/Config, admin/migration sole writer);
the Mining ownership rows + §2 system row land with the slice-B schema, same-step (the 0097/0098
precedent).

**State.** `npm run build` green. Migration head **0102**; no flag flipped, no live DB write —
everything dark and server-rejected (`mining_enabled='false'`); PR-ready on
`autopilot/20260703-064048`, `main` untouched.

---

## 2026-07-04 — EXPLORATION CLEANUP step 4 (final) — delete dead `EXPLORATION_DISABLED_REASON` export; closes recon finding #3. **Exploration cleanup complete (findings 1–3 all fixed)**

**Request.** Fix finding #3 and close out the exploration cleanup pass. Repo-wide grep re-confirmed
`EXPLORATION_DISABLED_REASON` (`explorationTypes.ts:48`) had zero references outside the recon
scratch file; deleted the constant + its doc comment (2 lines) and nothing else. Rationale: the
panel deliberately collapses ALL failure envelopes without inspecting `reason`
(`ExplorationPanel.tsx:86`), so the constant was speculative dead code with no consumer and no
planned consumer — the dark surface stays server-driven either way.

**Cleanup pass summary (the trade-milestone-style audit of Phase 11, slices A–H / 0096–0101):**
- **Audit verdict:** boundaries acyclic and all edges downward; sole writers hold everywhere
  (`exploration_discoveries` = one owner system, two writer fns; `exploration_sites` = no runtime
  writer; `reward_grant` the sole depositor; `osn_distance` a pure IMMUTABLE leaf); dark gates
  consistent (all three client-callable surfaces reject-before-any-read while
  `exploration_enabled='false'`; the securing processor's flag exception documented as in-flight
  safety); every shim carries its retirement condition. Three cleanup-class findings, none severe.
- **Finding #1 (step 2):** `docs/ARCHITECTURE.md` doc-sync — §14 processors table gained the
  `process_exploration_securing()` row; §7 gained the OSN-native as-built clarification (narrow
  self-approved scope amendment, recorded in the recon §3).
- **Finding #2 (step 3):** shared verify harness extracted to `scripts/lib/verify-harness.mjs`;
  `verify-exploration.mjs` repointed (pure extraction, identical environmental abort point);
  retirement plan: the 31 sibling verifiers adopt on next meaningful touch (`osn_distance`
  precedent, `SYSTEM_BOUNDARIES.md:75–78`).
- **Finding #3 (this step):** dead `EXPLORATION_DISABLED_REASON` export deleted.

**State.** `npm run build` green; `node --check scripts/verify-exploration.mjs` parses clean.
Migration head remains **0101**; no migration edited, no flag touched, `game_config` seeds
untouched; every exploration surface still dark/server-rejected; everything PR-ready on
`autopilot/20260703-064048`, `main` untouched. The exploration cleanup audit is **CLOSED**
(recon: `CLEANUP_EXPLORATION_RECON.local.md`, findings 1–3 all FIXED).

---

## 2026-07-04 — EXPLORATION CLEANUP step 3 — extract shared verify harness (`scripts/lib/verify-harness.mjs`); closes recon finding #2

**Request.** Fix finding #2 of the exploration cleanup recon: `scripts/verify-exploration.mjs` had
added the 32nd verbatim inline copy of the verify-script harness (the `loadEnv()` env loader +
URL/key resolution, the `ok/bad/Abort/die` reporting harness, and the throwaway-signup `newUser()`)
instead of extracting it to `scripts/lib/`. Touches ONLY the new module, the exploration verifier,
this file, and the recon scratch file — no migrations, no flags, no sibling scripts, no `package.json`.

**Work done — pure extraction, no behavior change:**
- **NEW `scripts/lib/verify-harness.mjs`** (next to the existing `verifier-teardown.mjs`, same
  module style): exports `loadEnv()` + `resolveEnv()` (anon key required → exit 2; service key
  OPTIONAL at this layer — a verifier that requires it asserts that itself), `Abort`/`die`,
  `createReporter()` (ok/bad + shared pass/fail counts), and `createUserFactory({url, anonKey,
  emailPrefix, createdUserIds})` → `newUser(tag)` (ids pushed immediately after creation for
  finally-teardown). Parameterized ONLY where the sibling comparison showed a variation point the
  exploration script actually relies on (email prefix, optional service key, caller-owned
  createdUserIds); no speculative knobs for sibling quirks it doesn't use.
- **`scripts/verify-exploration.mjs`** repointed at the module; its inline copies deleted. Every
  assertion, ordering, envelope check, and the teardown behavior are semantically identical.
- **RETIREMENT PLAN for the remaining duplication (stated in the module header):** the **31 sibling
  `verify-*.mjs` scripts still carry inline copies** and MUST adopt `verify-harness.mjs` the next
  time each is meaningfully touched — the documented `osn_distance` adopt-on-next-real-change
  precedent (`docs/SYSTEM_BOUNDARIES.md:75–78`). New verifiers import from the harness from day one.

**Verification.** `node --check` parses both files clean. `node scripts/verify-exploration.mjs`
reaches the IDENTICAL sandbox environmental abort as before the extraction (`✗ ABORTED — signup
failed: fetch failed`, exit 1 — the same no-reachable-Supabase blocker the slice-H entry records),
proving the harness wires up identically: `resolveEnv` resolved the keys, the shared `newUser`'s
`die` threw `Abort` through the script's `instanceof Abort` catch, and the shared reporter printed
the summary. `npm run build` green. Finding #2 of `CLEANUP_EXPLORATION_RECON.local.md` is FIXED
(marked in the recon; finding #3 remains).

---

## 2026-07-04 — EXPLORATION CLEANUP step 2 — ARCHITECTURE.md doc-sync (docs-only; closes recon finding #1)

**Request.** Fix finding #1 of the exploration cleanup recon: `docs/ARCHITECTURE.md` contradicted the
as-built Phase 11 code — §14's processors/cron table omitted `process_exploration_securing()` (a live
60s pg_cron job since 0100), and §7 still implied no exploration processor exists ("Later:
`process_exploration_ticks()`"). Docs-only: no code, no migrations, no flags.

**Scope amendment (self-approved, recorded in the recon §3).** The cleanup's locked scope is amended to
also allow `docs/ARCHITECTURE.md`, restricted to exactly these two out-of-sync spots — a law doc
contradicting as-built code is a defect under the doc-sync principle; ARCHITECTURE.md's exclusion from
the original MAY-touch list was an oversight in the scope lock itself.

**Work done — two surgical edits in `docs/ARCHITECTURE.md`:**
- **§14 processors table:** added one row — `process_exploration_securing()` · every 60s · deposits
  pending exploration discovery bundles via `reward_grant('exploration', discovery_id, …)` once the
  carrying main ship settles safe (home / `at_location`); deliberately ignores `exploration_enabled`
  (in-flight safety); pg_cron job `process-exploration-securing`, migration 0100.
- **§7 activity list:** added an as-built bullet — Phase 11 shipped exploration OSN-native, outside the
  presence dispatch, with its own securing processor (dark behind `exploration_enabled='false'`;
  mirrors the `docs/ACTIVITIES.md` §2 as-built clarification); the `explore_derelict` presence branch
  stays deliberately unwired. The "Later" line now names `process_mining_ticks()` /
  `process_trade_ticks()` and a *presence-domain* `process_exploration_ticks()` only as a hypothetical
  future form — it no longer implies the exploration processor is unbuilt.

**State.** `npm run build` green (docs-only sanity check). Migration head remains **0101**; no flag
touched; finding #1 of `CLEANUP_EXPLORATION_RECON.local.md` is FIXED (marked in the recon; findings
#2–#3 remain for the next steps).

---

## 2026-07-04 — EXPLORATION-P11 SLICE H (final): `verify:exploration` dark-posture script + wiring. **Phase 11 Exploration: dark implementation complete (slices A–H)**

**Request.** The exploration verify script + `package.json` wiring + this closing entry. Touches ONLY
`scripts/verify-exploration.mjs`, `package.json`, and this file; migrations `0001–0101` unedited; no
CI/workflow files; no flags flipped.

**Design decisions (self-approved).**
1. **`verify:exploration` wired in `package.json` exactly like the `verify:mainship-*` entries** (one
   `node scripts/…` line in the verify cluster). **No CI/workflow edits** — the narrowest compliant wiring;
   the human can extend the existing CI pattern later; this loop does not touch workflows.
2. **The script proves the DARK POSTURE and contracts only — it activates nothing.** It never writes
   `game_config`, never sets `exploration_enabled`, and creates nothing beyond the sibling scripts'
   throwaway-test-player convention (one signup, tracked and deleted by the shared
   `scripts/lib/verifier-teardown.mjs` when a service key is present; without one, teardown is skipped with
   a note — the `verify-m3/m4` precedent). The sibling `verify-mainship-send.mjs` DOES flip its own flag via
   `set_game_config` (its lines 49/98/105) — that part was **deliberately not copied**, and the script says
   so in its header: lit-path verification is deferred to the activation checklist below. `SUPABASE_SERVICE_
   ROLE_KEY` is OPTIONAL (teardown only); every assertion runs with anon/authenticated clients.

**The script asserts, in order** (idioms: env loader + ok/bad + Abort + exit codes from `verify-m45.mjs:12–41,
147–149`; throwaway `newUser` from `verify-m45.mjs:49–57`; client-role ACL-denial loop from
`verify-m45.mjs:135–137`; read-only `cfgVal` query shape from `verify-mainship-send.mjs:50`, run as the client
role; teardown from `verify-mainship-send.mjs:206–224` minus the flag entry):
- **(a) dark rejection** — `command_exploration_scan(ZERO, ZERO)` → `{ok:false, code:'feature_disabled'}`
  (0099/0100 wrapper envelope; the wrapper gates before ship resolution, so a zero id gets the same
  anti-probe answer) and `get_my_exploration_discoveries()` → `{ok:false, reason:'exploration_disabled'}`
  (0101), both for an authenticated throwaway user.
- **(b) no site leak** — authenticated `select` on `exploration_sites` → denial or 0 rows (0098 posture);
  `exploration_discoveries` → 0 rows for a fresh user (own-row RLS).
- **(c) internal surfaces locked** — client-role rpc calls to `exploration_scan`,
  `process_exploration_securing`, `osn_distance` all denied; plus anon denied on both public RPCs.
- **(d) config presence (read-only)** — `exploration_enabled` reads `false`, `exploration_scan_radius`
  reads `750`, compared tolerantly of the jsonb storage form (see Bugs below).

---

### Phase 11 Exploration — dark implementation complete (slices A–H)

**The six migrations (`0096–0101`; head `0095 → 0101`, all forward-only, nothing shipped edited):**
- **0096** — engine carrier made activity-agnostic: `fleet_movements.reward_source_type` (+ closed CHECK) and
  `movement_attach_cargo(…, source_type default 'combat')`; `process_fleet_movements` deposits under the
  carried type. Combat behavior unchanged.
- **0097** — the four-item exploration reward set (`scan_data` + `anomaly_shard` seeded; `blueprint_fragment`
  + `artifact_core` reused from 0039) + the `exploration_enabled='false'` dark gate.
- **0098** — hidden `exploration_sites` (RLS, NO client policy/grant; OSN coordinate convention; deterministic
  `reward_bundle_json`; 5 seeds) + own-row `exploration_discoveries` with `unique (player_id, site_id)`.
- **0099** — dark write path: `osn_distance` leaf + `exploration_scan` private writer (S2 locks, 0055
  receipts idempotency, reject-before-any-read) + `command_exploration_scan` wrapper +
  `exploration_scan_radius='750'`; pending-bundle accrual columns.
- **0100** — securing: `exploration_discoveries.main_ship_id`, the race-guarded re-created writer, and
  `process_exploration_securing()` (60s cron) → `reward_grant('exploration', discovery_id, …)` when the
  carrying ship settles safe (home / `at_location`); in-flight-safe (no flag check); double-guarded
  idempotency.
- **0101** — dark read surface `get_my_exploration_discoveries()` (reveal-after-discovery; the ONLY client
  path to site data).

**Frontend surface (Slice G):** `src/features/exploration/` (types + api + `ExplorationPanel`), mounted in
`GalaxyMapScreen`'s OSN overlay stack; server-driven visibility — renders nothing while the server answers
`exploration_disabled`.

**The corrected securing law (Slice E re-decision):** OSN-native activities never traverse `fleet_movements`,
so Exploration secures via its OWN processor calling `reward_grant` directly — the same sole depositor the
fleet return branch uses; `movement_attach_cargo` remains the fleet-domain carrier only (combat today).
`docs/SYSTEM_BOUNDARIES.md` + `docs/ACTIVITIES.md` carry the as-built law.

**ACTIVATION CHECKLIST — for the human owner only (nothing below is done by this loop):**
1. **Flip `exploration_enabled` → `'true'` — that is the ONLY switch.** The cron
   (`process-exploration-securing`), both RPCs, the read surface, and the panel are already in place and
   fail closed until the flip; the securing processor deliberately ignores the flag (in-flight safety) and
   is inert while no discoveries exist.
2. **Reposition the `GalaxyMap.tsx:390` bottom-left legend** ("N locations · M moving · drag to pan …") —
   the ExplorationPanel also renders bottom-left when lit and will cover it. Cosmetic; deferred because a
   dark panel covers nothing today.
3. **Decide destruction-forfeiture semantics for pending exploration data BEFORE OSN main-ship combat
   ships.** v1 never forfeits: a pending discovery waits and secures after recovery. Fine while destruction
   is rare/dev-only; a real combat loop needs an explicit forfeit-or-keep rule (ACTIVITIES.md §2 note).
4. **`activity_start`/`explore_derelict` is deliberately unwired in v1** (OSN-native-only scope decision,
   Slice F). Do not "finish" that dispatch branch without a product decision.
5. **Before any flip: run `verify:exploration` (dark posture) against a dev DB, then the lit-path checks
   there** — flip the flag ON THE DEV DB only, scan from a settled in-space ship near a seeded site, watch
   the discovery appear pending, dock/return home, confirm the cron deposits (metal → base, items →
   inventory, `secured_at` set, `reward_grants` row `('exploration', discovery_id)`), and re-run
   `verify:exploration` after re-darkening. Production flips remain a human production-gate action
   (PROD_GATE_APPROVAL_POLICY).

**Nothing in slices A–H flipped a flag, merged anything, deployed anything, or touched production.** All
work sits PR-ready on `autopilot/20260703-064048`; every exploration surface is server-rejected while
`exploration_enabled='false'`; `main` untouched.

**State (this slice).** `npm run build` green; `node --check scripts/verify-exploration.mjs` parses clean;
`node scripts/verify-exploration.mjs` in this sandbox aborts at signup with `fetch failed` (no reachable
Supabase) — the identical ENVIRONMENT blocker `verify:m3/m4` record, not a syntax/logic failure. Migration
head remains **0101**.

**Bugs / fixes**
- **jsonb type mismatch in the step-4 config assertions (reviewer-caught; fixed).** `game_config.value` is
  **jsonb** (`0003:8`), so the seeded literals `'false'` (0097) / `'750'` (0099) store as JSON boolean/number
  and supabase-js returns JS `false` / `750` — the original string comparisons (`v === 'false'` /
  `v === '750'`) would have false-failed step 4 on exactly the healthy dev DB the activation checklist
  targets (masked here because the sandbox aborts at signup, before step 4; no sibling script string-compares
  a `cfgVal` result — they only capture-and-restore — so there was no precedent to copy). Fixed to
  storage-form-tolerant comparisons (`String(v) === 'false'` / `Number(v) === 750`), mirroring how the
  server's `cfg_bool`/`cfg_num` (`0046:23` idiom) are storage-form-agnostic; noted in-line in the script.

---

## 2026-07-04 — EXPLORATION-P11 SLICE G: dark frontend surface `src/features/exploration/` (scan control + discoveries panel; renders nothing while the server says dark). Frontend only — no migration

**Request.** The exploration client surface: scan control + discoveries panel in a new feature folder,
integrated with the OSN in-space controls. NO new migration; nothing outside the feature folder + one
integration point + docs.

**Design decisions (self-approved).**
1. **Server-driven visibility, no client flag constant.** The panel calls `get_my_exploration_discoveries()`
   on mount/lifecycle change and renders **nothing unless the server affirmatively answers `{ok:true}`** —
   the `exploration_disabled` dark envelope (and any transport failure) fails closed to `null`. This follows
   the fail-closed side of the trade client idiom (all `{ok:false, reason}` shapes collapse quietly; nothing
   throws into the render path — `tradeApi.ts`/`MarketPanel.tsx`) while deliberately NOT copying trade's
   compile-time `TRADE_MARKET_ENABLED` constant: visibility is the SERVER's answer alone. The UI is not the
   control anyway — the server rejects every exploration RPC while dark (fail-closed law, both sides).
2. **Placement with the OSN in-space controls.** The panel mounts in `GalaxyMapScreen`'s map-overlay stack
   (where the OSN command surfaces live: PortNavPanel top-left, DockServicesPanel top-right, SpaceStopControls
   bottom-right) at **bottom-left**, receiving the ship id + `status`/`spatial_state` the screen already
   threads to its OSN siblings. Single feature folder `src/features/exploration/`; no new route (matches how
   the trade/dock surfaces integrate — overlay panels, not routes).
3. **request_id idiom copied from the existing command clients:** one `crypto.randomUUID()` per intentional
   submit (the `MarketPanel` idiom; the server dedups on `(main_ship_id, request_id)`), a synchronous
   in-flight ref so a same-tick double-click can't mint a second id, and disabled buttons while in flight.

**Work done** — three new files + one integration point; no migration, `0001–0101` unedited:
- **`src/features/exploration/explorationTypes.ts`** — framework-free types mirroring the server contracts
  exactly (`CommandExplorationScanResult` from 0099/0100's wrapper; `ExplorationDiscovery` /
  `GetMyExplorationDiscoveriesResult` from 0101: discovery_id, site_name, space_x, space_y, discovered_at,
  secured_at, bundle), the `isSettledInSpace` predicate (0055 model: `in_space` ⇔ `stationary`; drives only
  the button — the server stays authoritative), and the scan reason→message copy map in the
  `spaceStopCommand.ts` style (`feature_disabled`, `invalid_request`, `request_conflict`, `no_ship`,
  `ship_destroyed`, `not_in_space`, `busy_legacy`, `no_site_in_range`, `already_discovered`,
  `not_authenticated`, `unavailable`).
- **`src/features/exploration/explorationApi.ts`** — two thin `supabase.rpc` wrappers
  (`commandExplorationScan(mainShipId, requestId)`, `getMyExplorationDiscoveries()`); transport/DB errors
  normalize to `{ok:false, code/reason:'unavailable'}` (tradeApi idiom — never throw into render).
- **`src/features/exploration/ExplorationPanel.tsx`** — reads discoveries on mount + lifecycleKey change
  (the `useDockServices` re-fetch idiom); early-returns `null` unless `result.ok`; Scan button enabled only
  when settled in space (disabled with the truthful hint "Stop in open space to scan." otherwise); on
  success shows "Discovered <name>." and refreshes; failures show the server message (fallback: copy map).
  Discovery rows: name, rounded coordinates, local discovery time, and a Pending/Secured badge from
  `secured_at`. Styling/testids match the neighboring OSN overlay panels.
- **Integration (the ONE point):** `src/features/map/GalaxyMapScreen.tsx` — `ExplorationPanel` mounted
  directly after `DockServicesPanel` in the map-area overlay block, passing
  `mainShipId`/`shipStatus`/`shipSpatialState` + the lifecycle key the siblings already use.

**Panel renders nothing in production today because the server returns `exploration_disabled` — no flag was
touched.** `docs/SYSTEM_BOUNDARIES.md` NOT edited: verified it does not document client surfaces per system
(the Trade Market row lists RPCs/flags only; trade's UI is not listed), so exploration's UI is not added
either.

**State.** Frontend-only; migration head remains **0101**. `npm run build` green (`tsc -b && vite build`,
**144 modules** — up from 141 with the three new files); `npx eslint` on the new folder + the integration
file: clean. `verify:m3`/`verify:m4` fail only on `fetch failed` (no reachable Supabase from this sandbox)
and `verify:m45` needs `SUPABASE_SERVICE_ROLE_KEY` — the recorded environmental posture; no code/assertion
failure. `main` untouched.

**Bugs / fixes**
- _(none — additive dark UI; server rejects everything while dark, and the panel renders nothing on that
  answer.)_

---

## 2026-07-04 — EXPLORATION-P11 SLICE F: dark read surface `get_my_exploration_discoveries()` (reveal-after-discovery) + ACTIVITIES.md as-built reconciliation

**Request.** The exploration read surface: one server RPC exposing the caller's own discoveries (with the joined
site data), dark-gated; plus the reviewer-flagged ACTIVITIES.md lifecycle reconciliation. No frontend yet.

**Design decisions (self-approved).**
1. **The client never reads `exploration_sites` directly.** Reveal-after-discovery goes through ONE server read
   RPC that joins the player's OWN `exploration_discoveries` to the site rows and returns only discovered sites.
   The 0098 no-client-policy posture on sites is untouched: an undiscovered site's existence/name/coordinates
   stay unreachable **by construction** (a site row is reachable exclusively through one of the caller's own
   discovery rows; `where d.player_id = auth.uid()`). Same spirit as the `get_my_current_dock_services` (0069)
   read surface — already-authoritative, player-scoped, everything derived server-side.
2. **Dark-gated FIRST, copying the 0087 `get_market_offers` read idiom exactly** (`0087:46–50`): auth check,
   then `if not cfg_bool('exploration_enabled') → {ok:false, reason:'exploration_disabled'}` BEFORE any
   discovery/site read — the identical envelope regardless of caller state, so nothing can be probed while
   dark (matches the `trade_market_disabled`/`trade_relief_disabled` reason-token style).
3. **Exploration v1 is OSN-native ONLY (explicit scope decision).** The `activity_start`/`explore_derelict`
   location-presence dispatch is deliberately NOT wired in Phase 11 (ROADMAP: "scan in OSN proximity … where
   applicable"); `activity_start` still raises on `explore_derelict` — intended behavior, recorded in
   ACTIVITIES.md so nobody "finishes" the branch by accident.

**Work done** — one new migration `20260618000101_exploration_p11_read_surface.sql` (head **0100 → 0101**):
`get_my_exploration_discoveries()` — `language plpgsql stable security definer`; no arguments (player =
`auth.uid()`); flag gate first; then one read-only aggregate: the caller's discoveries joined to
`exploration_sites`, each as `{discovery_id, site_name, space_x, space_y, discovered_at, secured_at, bundle}`
(bundle = the row's `pending_bundle_json` snapshot; `secured_at` null = pending, non-null = deposited), ordered
`discovered_at desc`, `[]`-coalesced; envelope `{ok:true, discoveries:[…]}`. **No write anywhere** (single
SELECT aggregate). Discovered-then-disabled sites stay visible — the discovery is the player's own history.
ACL (0087 idiom): revoke from public/anon; grant execute to authenticated only. Dark today because the gate
rejects while `exploration_enabled='false'`.

**Doc sync (same step).** (a) `docs/SYSTEM_BOUNDARIES.md` — the Exploration row's surface list now names
`get_my_exploration_discoveries()` (read-only, dark-gated, the ONLY client path to site data, strictly
post-discovery). (b) `docs/ACTIVITIES.md` — the reviewer-flagged reconciliation as a marked **"Phase 11
as-built clarification (not a new design)"** note in §2: OSN-native activities secure pending rewards when the
carrying ship next settles SAFE (home or docked `at_location`, 0055 model) via the activity's own processor +
`reward_grant`; the "home arrival" wording is the fleet_movements-domain form (combat); destruction-forfeiture
deferred; Exploration v1 OSN-native-only dispatch decision recorded.

**State.** Forward-only; migration head **0101**; `0001–0100` unedited. No flag flipped; no frontend (next
slice). `main` untouched. `npm run build` green; `verify:m3`/`verify:m4` fail only on `fetch failed` (no
reachable Supabase from this sandbox) and `verify:m45` needs `SUPABASE_SERVICE_ROLE_KEY` — the recorded
environmental posture; no code/assertion failure.

**Bugs / fixes**
- _(none — additive read-only surface; the ACTIVITIES.md fleet-domain wording ambiguity is reconciled by the
  marked as-built note.)_

---

## 2026-07-04 — EXPLORATION-P11 SLICE E: dark securing/deposit path — `process_exploration_securing` cron → `reward_grant('exploration', …)` on safe settlement. ⚠ DESIGN RE-DECISION: corrects the Slice-C carrier law

**Request.** Secure pending exploration discoveries into real rewards when the scanning ship next settles safe,
via Exploration's OWN cron processor (the ACTIVITIES.md "own cron per activity" template). Everything stays dark.

**⚠ DESIGN RE-DECISION (self-approved) — the Slice-C carrier law was wrong for OSN-native scanning.**
Slice C's SYSTEM_BOUNDARIES row said exploration deposits ride `movement_attach_cargo(…, 'exploration')`. That
path is **UNREACHABLE** for OSN scanning: an OSN in-space ship never traverses `fleet_movements` — the S2
posture never locks legacy movements, `mainship_space_assert_cross_domain_exclusion` rejects a ship claimed by
one, and OSN has no HOME leg (`origin_not_anchored` fails closed) — so the fleet carrier can never fire for it.
The engine contract Exploration actually reuses is one level down: **`reward_grant` is THE sole secured-deposit
owner and idempotency owner (`reward_grants UNIQUE (source_type, source_id)`), and the activity accrues pending
value on its own state until a safe arrival.** Exploration's own processor therefore calls
`reward_grant('exploration', discovery_id, player, base, bundle)` directly — exactly as
`process_fleet_movements` calls it for fleet returns. `movement_attach_cargo` remains the carrier for
fleet_movements-domain activities ONLY (Slice A stays correct and is used by combat today). Dependency direction
stays acyclic and DOWNWARD: Exploration → {OSN geometry/locks (read), Main Ship (read), Bases (read: deposit
target), Reward (grant)}; OSN and the arrival processors are NOT edited and never call into Exploration.
SYSTEM_BOUNDARIES corrected in the SAME step (matrix + Exploration row).

**Work done** — one new migration `20260618000100_exploration_p11_securing_processor.sql` (head **0099 → 0100**):
- **`exploration_discoveries.main_ship_id`** — FK → `main_ship_instances` `on delete set null`; records WHICH
  ship holds the unsecured scan data. NULL only possible for legacy/deleted-ship rows; securing falls back to
  the player's canonical main ship (`mainship_resolve_owned_ship(player, null)`, the 0081 shared resolver).
- **`exploration_scan` re-created from the 0099 body with EXACTLY TWO changes** (diff-proven; ACL re-asserted
  verbatim): (a) the discovery insert records `main_ship_id`; (b) **race-guard fix** — the insert is now
  `on conflict (player_id, site_id) do nothing` and 0 rows inserted returns a truthful `already_discovered`
  instead of a raw unique-violation exception on a same-player concurrent scan (failure reasons write no
  receipt — the 0064 posture — so retries stay deterministic).
- **`process_exploration_securing()`** — Exploration's OWN cron processor (security definer;
  internal/service_role only, 0033 ACL idiom). `secured_at is null` rows via `FOR UPDATE SKIP LOCKED`; resolves
  the carrying ship (row's `main_ship_id`, else canonical); secures ONLY if settled **SAFE** per the 0055 state
  model — `spatial_state in ('home','at_location')` (constraints tie these to `status='home'` /
  `status='stationary'`, 0055:151–153 / 0055:145–147) — never in_transit/in_space/destroyed/legacy-NULL;
  resolves the deposit base with the 0050 idiom (`from bases where player_id=… and status='active' order by
  created_at limit 1`) and SKIPS (row stays pending) rather than granting with a null base — `reward_grant`
  would silently drop the metal half; then `reward_grant('exploration', d.id, …)` + `secured_at = now()`.
  **Idempotency double-guarded:** the `secured_at` filter (fast path) + `reward_grants` UNIQUE
  (source_type, source_id) (the law — can never double-deposit). **No forfeiture in this slice:** pending rows
  simply wait (a destroyed ship secures after recovery lands it home); destruction semantics for pending scan
  data are a future product decision, deliberately not invented here.
- **IN-FLIGHT SAFETY (0064 precedent, stated in the header):** the processor does NOT check
  `exploration_enabled` — accrued pending value must never be stranded by an emergency flag-off. Naturally
  inert today: no discovery rows can exist while scan is dark.
- **Cron:** `process-exploration-securing` every 60s via the 0033 idiom (guarded `cron.unschedule` DO-block +
  `'* * * * *'` — pg_cron rejects `'60 seconds'`). Cadence rationale: securing is not latency-sensitive;
  matches the location-state tick's order of magnitude. Cadence summary: movement 30s · combat 3s ·
  worldstate 60s · space arrivals (0058) · **exploration securing 60s**.

**State.** Forward-only; migration head **0100**; `0001–0099` unedited. No flag flipped (`exploration_enabled`
stays `'false'`; the scan writer + wrapper still dark-reject first). No frontend. `docs/SYSTEM_BOUNDARIES.md`
corrected in the SAME step: the Exploration row now carries the securing law (own processor →
`Reward.grant('exploration', discovery_id)`; `movement_attach_cargo` = fleet-domain carrier ONLY, with the
unreachability rationale; edges listed, all downward, acyclic), and the matrix row records the writer SET
(`exploration_scan` inserts · `process_exploration_securing` sets `secured_at`) under the ONE Exploration
owner system. `main` untouched. `npm run build` green; `verify:m3`/`verify:m4` fail only on `fetch failed`
(no reachable Supabase from this sandbox) and `verify:m45` needs `SUPABASE_SERVICE_ROLE_KEY` — the recorded
environmental posture; no code/assertion failure.

**Bugs / fixes**
- **Slice-C carrier law unreachable for OSN scanning (doc/design defect).** Fixed by the re-decision above —
  corrected in SYSTEM_BOUNDARIES the same step; no shipped code implemented the wrong law (the deposit path
  did not exist until this slice), so this is a doc/design correction, not a behavior change.
- **Same-player concurrent-scan race (0099).** Two concurrent scans of the same site could raise a raw unique
  violation instead of a clean reason. Fixed in the re-created writer via `on conflict … do nothing` +
  `already_discovered`.

---

## 2026-07-04 — EXPLORATION-P11 SLICE D: dark `command_exploration_scan` — OSN-proximity scan → pending discovery bundle (server-rejected while `exploration_enabled=false`; nothing deposits yet)

**Request.** The exploration write path: an OSN-proximity scan that records a per-player discovery with a
PENDING (not yet deposited) reward bundle. Deposit wiring is deliberately NOT in this slice.

**Design decisions (self-approved).**
1. **Geometry is OSN's concern; Exploration depends on it DOWNWARD.** New pure IMMUTABLE leaf
   `osn_distance(ax,ay,bx,by) → double precision` — the exact euclidean formula the movement writers already
   use inline (`sqrt(power(bx-ax,2)+power(by-ay,2))`, verified at `0007:105`, `0057:179`, `0067:319`). The
   shipped movement-writer bodies were NOT re-created just to swap their one-line inline sqrt: a single
   arithmetic expression is below the duplication bar, and re-creating proven critical writers for a cosmetic
   swap adds regression risk with zero behavior gain. **Future re-definitions of those writers should adopt
   the helper when next touched for real changes** (also recorded in SYSTEM_BOUNDARIES).
2. **Accrual law (ACTIVITIES.md):** the activity accrues pending rewards on ITS OWN state. The discovery row
   snapshots the site's bundle at scan time — new columns `pending_bundle_json jsonb not null default '{}'`
   (CHECK object; the default is a migration-validity shim only — retirement is behavioral: the sole writer
   ALWAYS snapshots a real bundle, so no row ever relies on it) and `secured_at timestamptz` (NULL = pending;
   set ONLY by the deposit slice's securing path). **This slice mints nothing into inventory** — no
   inventory/base/reward/movement write anywhere in the scan path.
3. **Scan preconditions:** ship settled OSN in-space (`mainship_space_validate_context` state = `in_space`,
   which the 0055 constraints tie to `status='stationary'`; in transit / docked / home / legacy all reject),
   not claimed by another domain (`mainship_space_assert_cross_domain_exclusion` — the 0064
   arrival-processor posture, reused not re-derived), within `exploration_scan_radius` (new `game_config`
   tunable, default **750** — same order as the world's port/proximity scales, tunable without redeploy) of an
   `is_active` site the player has not discovered. Nearest-first, deterministic tie-break (distance, then name).

**Work done** — one new migration `20260618000099_exploration_p11_scan_command.sql` (head bump **0098 → 0099**):
- **`osn_distance`** — `language sql immutable strict`; internal posture (no client grant; service_role for CI
  parity with the S2 helpers).
- **`exploration_discoveries` + pending columns** (decision 2 above).
- **`exploration_scan(p_player, p_main_ship_id, p_request_id)`** — PRIVATE service-role/internal writer; the
  **sole writer** of `exploration_discoveries`. Ordered body: (1) **DARK GATE FIRST** —
  `if not cfg_bool('exploration_enabled') → feature_disabled` BEFORE any other read/lock/write (0097
  reject-before-any-read law, 0070 idiom); (2) null request_id → `invalid_request_id`; (3) S2 canonical
  blocking lock (ship → fleet → coordinate movement → presence) — `missing_ship` / lock status; (4) ownership
  from the LOCKED snapshot → `not_owned`; (5) canonical payload hash (no coordinate body — 0064 stop idiom);
  (6) **receipts idempotency REUSED EXACTLY** — `main_ship_space_command_receipts` (0055), lookup AFTER ship
  lock + ownership (0064 order): verbatim replay of the first committed `result_json`, or
  `request_id_payload_conflict`; (7) `validate_context` → `destroyed` / `not_in_space` unless settled
  `in_space`; (8) cross-domain exclusion → forwarded reason; (9) ship coords under lock; (10) nearest
  undiscovered active site within radius via `osn_distance` — else `already_discovered` (an in-range active
  site exists but all are this player's discoveries) or `no_site_in_range`; (11) insert the discovery with the
  bundle snapshot (`secured_at` NULL); (12) receipt insert atomic with the discovery (movement_id null).
- **`command_exploration_scan(p_main_ship_id, p_request_id)`** — authenticated public wrapper (0083 idiom):
  auth → **anti-probe flag gate** (while dark, identical answer regardless of input — no hidden-site probing) →
  `mainship_resolve_owned_ship` (selected owned ship or sole-ship shim; UI never trusted) → delegate →
  narrow reason→code/message map. Reason set: `feature_disabled`, `invalid_request_id`,
  `request_id_payload_conflict`, `missing_ship`/`not_owned`→`no_ship`, `destroyed`, `not_in_space`,
  `active_legacy_movement`→`busy_legacy`, `no_site_in_range`, `already_discovered`, else `unavailable`.
- **`exploration_scan_radius` = `'750'`** seeded `on conflict (key) do nothing`.
- **ACL (targeted 0083/0095 idiom):** `osn_distance` + `exploration_scan` revoked from public/anon/
  authenticated, granted to service_role only; `command_exploration_scan` revoked from public/anon, granted to
  authenticated — dark today because both the wrapper gate and the writer's first check reject.

**Nothing deposits yet — pending bundles only.** The deposit-on-arrival wiring through the Slice-A
activity-agnostic carrier (`movement_attach_cargo(…, 'exploration')`) is the NEXT slice.

**State.** Forward-only; migration head **0099**; `0001–0098` unedited. No flag flipped
(`exploration_enabled` stays `'false'`; it is read, never written). No frontend change.
`docs/SYSTEM_BOUNDARIES.md` synced in the SAME step: matrix + Exploration row now name `exploration_scan` as
sole writer via the dark `command_exploration_scan`, enumerate the reused OSN machinery, and a new note records
the `osn_distance` leaf ("pure/immutable, consumed downward by activities; movement writers adopt it when next
re-defined for real changes"). `main` untouched. `npm run build` green; `verify:m3`/`verify:m4` fail only on
`fetch failed` (no reachable Supabase from this sandbox) and `verify:m45` needs `SUPABASE_SERVICE_ROLE_KEY` —
the recorded environmental posture; no code/assertion failure.

**Bugs / fixes**
- _(none — additive dark write path; reuses the proven receipts/lock/validation machinery unchanged.)_

---

## 2026-07-04 — EXPLORATION-P11 SLICE C: hidden `exploration_sites` + per-player `exploration_discoveries` (tables + seed + RLS only; no RPC, no client path, fully dark)

**Request.** Exploration domain schema: the hidden static site table and the per-player discovery ledger —
tables + seed + RLS only; no RPCs, no processors, no client paths; everything stays dark.

**Design decisions (self-approved).**
1. **Sites are hidden — server-only read, fail-closed by construction.** `exploration_sites` is migration-seeded
   static world data with NO runtime writer and — unlike `locations`/`item_types` — NO public read: a hidden
   site's coordinates must never be client-readable before discovery. RLS is ENABLED with **no client policies
   at all and no anon/authenticated grant**; future SECURITY DEFINER exploration functions reach it as owner.
   There is nothing for the UI to hide — the client simply cannot see the table.
2. **Per-player discovery state in its own table** `exploration_discoveries` with `unique (player_id, site_id)`
   (+ a `(player_id, discovered_at desc)` index). **Sole writer = the Exploration system** (its future
   RPC/processor — nothing writes it yet). Own-row select only, copying the `reward_grants_select_own` idiom
   (`0015:18–21`); no insert/update/delete policy, no write grant; `grant select` to authenticated only.
3. **v1 reward semantics: deterministic `reward_bundle_json` per site** in the EXACT pending-bundle shape the
   carrier already transports (`{ "metal": N, "items": [{item_id, quantity}] }`, the 0040/0041 shape; CHECK
   `jsonb_typeof = 'object'`) — reuses the Slice-A activity-agnostic deposit path byte-for-byte with zero new
   roll logic. Weighted "discovery rolls" are an additive later change and, if they come, must reuse/extract the
   combat loot-roll helper as ONE shared leaf, never a copy. `is_active boolean not null default true` lets a
   bad seed be disabled without deleting world data (no destructive cleanup).

**Coordinate representation — copied from OSN, no second convention.** Column names `space_x`/`space_y` from
`main_ship_instances` (`0054:33–36`); `double precision`; finite-only CHECKs via the
`<> 'NaN'::double precision` idiom and the immutable world envelope `[-10000,10000]^2`, both verbatim from
`main_ship_space_movements` (`0055:56–63`), matching the movement writer's inclusive bounds gate
(`0057:58–59, 95–96`). Seeds use integer-grid values (the 0070 command canonicalizes targets to the integer
grid) well inside the envelope — every site is a legal open-space target.

**Work done** — one new migration `20260618000098_exploration_p11_sites_schema.sql` (head bump **0097 → 0098**):
the two tables above + five idempotent seeds (natural `name` unique key + `on conflict (name) do nothing` —
the 0002 world-seed idiom; NOT fixed uuids, matching how sectors/zones/locations seed). Seed inventory
(bundles draw ONLY from the Slice-B reward set; metal calibrated to the 0041 combat scale of ~10–40/wave):
- `Derelict Listening Post` (−1200, 850) — 25 metal, scan_data ×3 (common)
- `Shattered Survey Buoy` (2100, −1400) — 30 metal, scan_data ×2 + anomaly_shard ×1 (common)
- `Anomalous Debris Field` (−2600, −1900) — 40 metal, anomaly_shard ×2 (uncommon)
- `Silent Foundry Wreck` (3300, 2500) — 60 metal, scan_data ×2 + blueprint_fragment ×1 (rare)
- `Precursor Vault Signal` (−4100, 3600) — 100 metal, anomaly_shard ×1 + artifact_core ×1 (epic)

**State.** Forward-only; migration head **0098**; `0001–0097` unedited. No function created → no execute-surface
relock needed (0054 precedent). No flag added/read/flipped — the feature stays server-rejected behind
`exploration_enabled=false` (0097) with no RPC even existing. `docs/SYSTEM_BOUNDARIES.md` synced in the SAME
step: §1 matrix gains `exploration_sites` (Reference/Config; NO runtime writer; **server-only** read) and
`exploration_discoveries` (Exploration future writer; owner-read); §2 gains the **Exploration** system row with
the dark gate inline (like Trade Market) and the carrier-reuse law (`movement_attach_cargo(…, 'exploration')`,
never a parallel deposit path). `main` untouched; no frontend, no workflow, no verifier change.
`npm run build` green; `verify:m3`/`verify:m4` fail only on `fetch failed` (no reachable Supabase from this
sandbox) and `verify:m45` needs `SUPABASE_SERVICE_ROLE_KEY` — the recorded environmental posture; no
code/assertion failure.

**Bugs / fixes**
- _(none — additive schema + seed; no writer, no reader, no behavior.)_

---

## 2026-07-04 — EXPLORATION-P11 SLICE B: reward-item catalog entries + `exploration_enabled=false` dark flag (foundations only; nothing client-reachable, no behavior change)

**Request.** Exploration foundations: the reward item catalog entries and the dark capability flag. No gameplay
logic, no RPC, no table, nothing reachable by clients.

**Design decisions (self-approved).**
1. **Reuse the existing item-catalog + `player_inventory` path** that pirate loot uses (0039/0040/0041) — no new
   inventory table, no new depositor. `reward_grant` stays the sole depositor; its item validation is
   catalog-driven (`exists (select 1 from item_types where item_id = …)`, `0040:78`; same guard in
   `inventory_deposit`, `0039:81`), so it recognizes the new ids with **zero code change** — seeding the catalog
   row IS the enablement.
2. **The ACTIVITIES.md §3 exploration reward classes** ("data / shards / blueprint fragments / artifact cores")
   **become exactly four catalog items** — the smallest closed set covering the documented classes; more variants
   are additive later. Two classes already had exact catalog matches seeded in 0039 and reserved by
   ACTIVITIES.md §5 for precisely these later progression drops — `blueprint_fragment` (progression, rare) and
   `artifact_core` (progression, epic) — so they are **REUSED, not re-added** (re-adding them under
   exploration-specific ids would duplicate catalog concepts — forbidden). Only the two missing classes are
   seeded: **`scan_data`** ('Scan Data', category `data`, common — the bulk "data" class; the category value is
   the class name the ACTIVITIES.md row uses; `category` is unconstrained Reference/Config metadata with no code
   consumer, grep-verified) and **`anomaly_shard`** ('Anomaly Shard', `material`, uncommon — the "shards" class,
   named from the exploration ownership row's "anomalies"; deliberately NOT `captain_memory_shard`, which is
   captain-progression material, a different concept). Exploration reward set =
   `{ scan_data, anomaly_shard, blueprint_fragment, artifact_core }`.
3. **Capability flag `exploration_enabled = 'false'`** — the standard server-authoritative dark gate, copying the
   0070/0071 reject-before-any-read idiom verbatim (same posture as `trade_market_enabled`/`trade_relief_enabled`).
   No RPC exists yet; the flag simply exists dark. The migration header states the law: every exploration RPC
   added in later slices MUST check it FIRST and reject-before-any-read while false — UI hiding is never the only
   control.

**Work done** — one new migration `20260618000097_exploration_p11_catalog_and_flag.sql` (head bump **0096 → 0097**):
two idempotent `item_types` rows + one idempotent `game_config` row, both via the established
`on conflict … do nothing` seeding idiom (0039 / 0070). No table, no function, no RPC, no frontend, no index —
nothing else.

**RLS/grants — verified, not assumed.** New `item_types` rows inherit the table-wide public-read posture
(`item_types_public_read` for select using (true) + `grant select to anon, authenticated`, `0039:23–25`); the
`game_config` row likewise (`game_config_public_read`, `0003:13–15`). The items are inert without any exploration
RPC. No function created → no execute-surface relock needed (0054 precedent). Also grep-verified: `item_types` is
seeded ONLY in 0039 (no later migration adds items or a category constraint), and `0041` produces only
0039-seeded ids — so nothing can mint the new items yet; no loot source references them.

**Flag seeded false, nothing client-reachable, no behavior change.** No flag set true anywhere; no existing flag
value touched. `docs/SYSTEM_BOUNDARIES.md` NOT edited — verified it enumerates dark gates only inline within
per-system rows (Trade Market / Main Ship), and no Exploration system row exists yet (it arrives with the
exploration tables in a later slice, which will add the matrix row + gate in the same step); `item_types` /
`game_config` ownership (Reference/Config, §1) is unchanged by adding rows. `docs/ACTIVITIES.md` untouched.
`main` untouched; migration head is now **0097**; `0001–0096` unedited.
`npm run build` green; `verify:m3`/`verify:m4` fail only on `fetch failed` (no reachable Supabase from this
sandbox) and `verify:m45` needs `SUPABASE_SERVICE_ROLE_KEY` — the recorded environmental posture; no
code/assertion failure.

**Bugs / fixes**
- _(none — additive Reference/Config seed + dark flag; no writer, no reader, no behavior.)_

---

## 2026-07-04 — EXPLORATION-P11 SLICE A: activity-agnostic deposit-on-arrival carrier (`reward_source_type`; refactor only, combat behavior unchanged, everything dark)

**Request.** Prerequisite refactor for Phase 11 Exploration: make the pending-bundle → attach →
deposit-on-arrival carrier activity-agnostic. No new feature, no behavior change, nothing activated.

**Design decision (self-approved).** `reward_grant(source_type, …)` has been generic since 0015/0040 — the only
combat coupling in the engine path (docs/ACTIVITIES.md §2) was at the CARRIER layer: `fleet_movements` had no
source-type column and `process_fleet_movements`' return branch (latest shipped body: `0030:36`) hard-coded
`reward_grant('combat', …)`. **Why:** Exploration (and later Mining) must reuse the exact same
pending-bundle → `movement_attach_cargo` → deposit-on-arrival path — one shared engine carrier, never a parallel
deposit system — so the movement row now transports its reward source type instead of the engine assuming combat.

**Work done** — one new migration `20260618000096_engine_reward_source_type.sql` (head bump **0095 → 0096**):
- **`fleet_movements.reward_source_type`** — `text not null default 'combat'` (existing rows backfill to
  `'combat'`: every payload-carrying return in flight today IS combat's) + closed domain CHECK
  `('combat','exploration','mining','trade')` matching the docs/ACTIVITIES.md §3 activity ownership table
  (closed set now; a future activity is an additive constraint change in a new forward-only migration).
- **`movement_attach_cargo(movement, source, bundle, source_type default 'combat')`** — the old 3-arg signature
  is DROPPED first (the 0038/0081–0084 signature-evolution idiom; keeping both overloads would make existing
  3-arg calls ambiguous), then re-created with the defaulted 4th param that writes the column. Every existing
  caller — `process_combat_ticks`, latest `0046:185`, a 3-arg call bound by name at runtime — keeps working
  verbatim via the default; combat callers are untouched.
- **`process_fleet_movements`** — re-created from its latest shipped body (`0030:36`, grep-confirmed: no later
  migration re-defines it or `movement_attach_cargo`; `0032/0041/0046` only re-define the CALLER
  `process_combat_ticks`) **byte-identical except** the deposit call — `reward_grant(m.reward_source_type, …)`
  instead of the literal `'combat'` — and that call's two-line comment, which claimed combat-specificity and
  would otherwise contradict the code it annotates.
- **ACL preserved (anti-cheat; no new client execute grants):** the re-created 4-arg `movement_attach_cargo`
  gets the explicit internal revoke (`from public, anon, authenticated` — 0093 idiom; the DROP discarded the old
  signature's ACL); `process_fleet_movements` keeps its ACL through CREATE OR REPLACE with a defense-in-depth
  re-assert (0070 idiom). Neither had — nor gains — any client or service_role grant (grep: no `src/`, no
  client RPC, no verify-runner grant; cron + SECURITY DEFINER orchestrators invoke them as owner).

**Combat behavior unchanged.** Same column default, same attach default, same deposit semantics and timing law
(pending while out, secured once on home arrival, forfeited on destruction), same idempotency
(`reward_grants UNIQUE (source_type, source_id)`, 0040). No flag added, read, or flipped; no activity enabled;
exploration remains entirely unbuilt/dark after this slice.

**State.** Forward-only. Migration `0096` is now the highest-numbered file; `0001–0095` unedited.
`docs/SYSTEM_BOUNDARIES.md` synced in the SAME step: the Movement row now names `movement_attach_cargo(…,
source_type='combat')` as the internal shared carrier, and the §3 return-arrival edge now reads
`Reward.grant(reward_source_type, bundle)` (activity-agnostic; today always `'combat'`). Sole writers unchanged:
Movement remains the sole `fleet_movements` writer (`movement_attach_cargo` is Movement-owned;
`process_fleet_movements` remains the only return-branch writer) and `reward_grant` remains the only depositor —
no new cross-system edge, call graph unchanged and acyclic. `docs/ACTIVITIES.md` untouched (it already describes
this target state). `main` untouched; no frontend, no workflow, no verifier change.
`npm run build` green (`tsc -b && vite build`, 141 modules); `verify:m3`/`verify:m4` fail only on
`fetch failed` (no reachable Supabase from this sandbox) and `verify:m45` needs `SUPABASE_SERVICE_ROLE_KEY` —
the same environmental posture recorded by the 2026-07-03 entries; no code/assertion failure.

**Bugs / fixes**
- _(none — pure carrier refactor; the deposit path's combat literal was a latent Phase-11 blocker, removed
  before any exploration code exists.)_

---

## 2026-07-03 — Trade-economy cleanup audit: ROADMAP Phase-10 doc-sync (docs-only; one stale figure fixed)

**Request.** Final auto-cleanup/audit pass for the trade-economy milestone: verify the branch is in the clean
end-state the milestone claims (boundaries doc, single docked-location helper, dark-both-sides flags, CI proof
wiring, law-doc sync) and fix — narrowly — anything that is not.

**Audit result** (full evidence trail in the untracked scratch file `TRADE_ECONOMY_CLEANUP_RECON.local.md`):
claims (a)–(d) — SYSTEM_BOUNDARIES coverage + sole-writers/acyclicity, single `mainship_resolve_docked_location`
(defined once in `0092`, no surviving inline copy in `0093–0095` or the proof SQL), dark both sides
(`trade_market_enabled`/`trade_relief_enabled` seeded false + RPC dark-rejects + `TRADE_MARKET_ENABLED=false`
client gate; relief has NO client UI — N/A by evidence), and the `trade-v1-proof.yml` posture (feature-branch
triggers only, no `environment:`, `permissions: contents: read`, `if: always()` teardown, proof SQL one
begin…ROLLBACK txn, no COMMIT) — all ✅ CLEAN. ONE defect: claim (e) — `docs/ROADMAP.md` (Phase-10 cell, line 85)
still said "migration head `0092`" and omitted the economy-bootstrap phase entirely, contradicting this log's own
"migration head remains **0095**" (CI-wiring entry below).

**Work done** — exactly one doc-sync edit to the Phase-10 status sentence in `docs/ROADMAP.md`, nothing else:
- Stale "migration head `0092`" → "`0095`".
- The pipeline enumeration now includes the previously-missing 2026-07-03 work: cleanup helper `0092`,
  ECONOMY-BOOTSTRAP `0093–0095` (seed capital via `wallet_ensure` + no-softlock relief `market_claim_relief`),
  and the disposable proof `scripts/trade-economy-bootstrap-proof.{sql,sh}` wired into `trade-v1-proof.yml`.
  The historical `0073–0084` / `0085–0091` ranges and the "implemented DARK & PR-ready … all trade flags/gates
  OFF" meaning are unchanged.

**State.** Docs-only, forward-only. No code, migration, RPC, frontend, workflow, proof, flag default, or behavior
changed — nothing activated; `main` untouched; migration head remains **0095** on `autopilot/20260703-064048`.
No `SYSTEM_BOUNDARIES.md` change (no architectural fact changed; §1/§2 already document the 0092–0095 surface —
re-verified in this audit). `npm run build` green (`tsc -b && vite build`, 141 modules); the remote-DB
`verify:m2/m3/m4` runs fail only on `fetch failed` (no reachable Supabase from this sandbox) and `verify:m45/m5`
need `SUPABASE_SERVICE_ROLE_KEY` — environmental, no code/assertion failure;
`scripts/trade-economy-bootstrap-proof.sh selftest` passes in-sandbox.

**Bugs / fixes**
- **ROADMAP Phase-10 status stale (doc/law mismatch).** The 0093–0095 + proof + CI slices updated this log but
  not the ROADMAP status figure written back at head-0092 time. Fixed by the doc-sync above; no other
  contradiction found.

---

## 2026-07-03 — TRADE-ECONOMY-BOOTSTRAP proof wired into existing `trade-v1-proof.yml` (disposable-only; no new workflow)

**Request.** Wire the economy-bootstrap proof into CI by EXTENDING the existing `trade-v1-proof.yml` — which
already spins up ONE disposable stack for all Trading-V1 proofs — rather than adding a parallel workflow that would
redundantly start a second throwaway stack. This resolves the "CI wiring is a separate follow-up" note from the
prior entry.

**Work done** — additive edits to `.github/workflows/trade-v1-proof.yml` only (no new workflow file):
- **`selftest` job** — added a third step `- run: bash scripts/trade-economy-bootstrap-proof.sh selftest` after the
  trade-market-1 selftest (DB-free static check).
- **`disposable-matrix` job** — added a `TRADE-ECONOMY-BOOTSTRAP real-chain matrix` step mirroring the
  trade-market-1 step's exact shape (`set -a; . /tmp/sbenv; set +a; bash scripts/trade-economy-bootstrap-proof.sh
  local`), placed AFTER the trade-market-1 matrix and BEFORE the `if: always()` "Stop disposable stack" teardown so
  the single throwaway stack is still up when it runs. The new proof is self-rolling-back and order-independent;
  ordering just keeps the file readable.
- **Truthful references** — the `supabase start` step name "applies migrations 0001..0092" → "0001..0095"; the
  top-of-file comment + workflow `name:` now enumerate the economy-bootstrap proof (seed capital + no-softlock
  relief floor, 0093..0095) alongside the existing two, keeping the "NEVER production / no `environment:` / flips no
  committed flag / disposable local Supabase only" language intact.

**Preserved:** `permissions: contents: read`, the `concurrency` block, the `on:` triggers (feature branches only —
NOT `main`/any release branch), no `environment:` on any job, and the `if: always()` teardown. Reuses the single
disposable stack — no second stack started.

**State.** CI-config only. No migration, no `src/`, no committed flag changed; dispatches no production/deploy/
verifier/sensitive workflow (dispatching this workflow is a human/CI action, not taken here). No
`SYSTEM_BOUNDARIES.md` change — a CI workflow is not an architectural fact. `main` untouched; migration head remains
**0095**. `selftest` re-run in-sandbox (DB-free) and passes; the `disposable-matrix` job needs GitHub-hosted
Docker/Supabase (same limitation as the sibling matrix) and was not run here.

**Bugs / fixes**
- _(none — additive CI wiring; runs existing disposable proofs, changes no product code.)_

---

## 2026-07-03 — TRADE-ECONOMY-BOOTSTRAP proof: disposable, self-rolling-back seed + relief exercise (no CI yet)

**Request.** Add a disposable proof that actually exercises the seed-capital + no-softlock-relief SQL end-to-end —
the only way this logic runs, since `verify:m*` can't reach a live DB in-sandbox. Mirror the
`trade-market-1-proof.{sh,sql}` idiom. Touch no `src/` and no migrations.

**Work done** — two new files under `scripts/` (no migration, no committed flag change):
- **`trade-economy-bootstrap-proof.sql`** — one `begin;`…`rollback;` transaction that persists NOTHING (no COMMIT
  anywhere). Same idiom as the sibling: `\set ON_ERROR_STOP on`, the `pg_temp.call_as(sub, fn)` JWT-subject helper,
  a `teb` temp fixture table, `teb.`-prefixed fixture users, the "mirror production config a fresh chain lacks"
  setup (`reveal_starter_ports()` + transient `mainship_space_movement_enabled='true'`), real-RPC provisioning
  (`commission_first_main_ship()`), and owner-level `insert into public.player_wallet (player_id, balance)` /
  `insert into public.ship_cargo_lots …` for state setup (harness runs as DB owner, bypassing RLS; all reverted by
  ROLLBACK). Both dark flags (`trade_market_enabled`, `trade_relief_enabled`) are toggled ONLY inside the txn.
  Asserts, each ending in a `raise notice` PASS marker:
  - **SEED**: `SEED_PASS_DARK` (wallet-less buy while trade dark → `trade_market_disabled`, no wallet seeded),
    `SEED_PASS_APPLIED` (first buy seeds `starting_credits`=1000 once then debits → balance 1000−T),
    `SEED_PASS_ONCE` (2nd buy debits further; balance never returns to 1000 — `wallet_ensure`'s `on conflict do
    nothing` is unfarmable).
  - **RELIEF anti-farm matrix**: `RELIEF_PASS_DARK` (rock-bottom claim while relief dark → `trade_relief_disabled`,
    no claim, wallet 0), `RELIEF_PASS_NO_WALLET` (wallet-less → `no_wallet`, still no wallet — proves relief never
    calls `wallet_ensure`, closing the seed+relief double-grant hole), `RELIEF_PASS_WALLET_NOT_EMPTY`,
    `RELIEF_PASS_CARGO_NOT_EMPTY`, `RELIEF_PASS_GRANT` (0 → `relief_credits`=250, exactly one claim @ 250),
    `RELIEF_PASS_IDEMPOTENT` (replay → `idempotent_replay`, no 2nd claim/credit), `RELIEF_PASS_COOLDOWN`
    (`relief_cooldown_active` + `next_eligible_at`), `RELIEF_PASS_CAP` (cooldown transiently 0; 3 grants then 4th →
    `relief_cap_reached`). Ends with the `TRADE-ECONOMY-BOOTSTRAP PROOF PASSED` line, then `rollback;`.
- **`trade-economy-bootstrap-proof.sh`** — mirrors the sibling's two modes. `selftest` (DB-free): verifies the
  `.sql` is self-rolling-back (opens a txn, last verb is `rollback;`, no COMMIT), toggles both dark flags strictly
  inside the txn, provisions via the real RPCs (`commission_first_main_ship`/`market_buy`/`market_claim_relief`),
  sets up a wallet via an owner insert, contains every PASS marker, asserts the key reason tokens
  (`trade_market_disabled`/`trade_relief_disabled`/`no_wallet`/`wallet_not_empty`/`cargo_not_empty`/
  `idempotent_replay`/`relief_cooldown_active`/`relief_cap_reached`), and references neither `src/` nor
  `migrations/`; prints an ALL-PASSED line. `local` (against a disposable `DB_URL`): `psql -X -v ON_ERROR_STOP=1
  -f` the `.sql`, require the final PASS line + every marker, print `OVERALL_PASS`.

**Self-rolling-back; persists nothing; flips no committed flag.** The whole proof runs inside one rolled-back
transaction — no wallet, lot, claim, ship, fixture user, or flag flip survives. The dark flags are enabled only
transiently inside the txn to exercise the capabilities; production/committed defaults stay false. Relief credits
are never injected directly — the GRANT case drives the real `market_claim_relief` RPC.

**State.** No migration added/edited; no `src/`; no committed flag changed. **CI wiring is a separate follow-up**
(would mirror the existing `trade-*-proof` CI idiom). No `SYSTEM_BOUNDARIES.md` change — a proof script is not an
architectural fact. `main` untouched. `selftest` was run in-sandbox (DB-free) and passes; `local` needs a
disposable Supabase (same environmental limitation as `verify:m*`) and was not run here.

**Bugs / fixes**
- _(none — new disposable proof; exercises existing DARK logic, changes no product code.)_

---

## 2026-07-03 — TRADE-MARKET-1 no-softlock floor: relief claim RPC `market_claim_relief` (DARK; server-rejected)

**Request.** The relief floor's writer: a Trade-Market orchestrator that grants `relief_credits` to a genuinely
softlocked player and records the claim. Forward-only; ships DARK; no flag flipped true.

**Work done** — one new migration `20260618000095_trade_market_1_claim_relief.sql` (head bump **0094 → 0095**):
`public.market_claim_relief(p_request_id uuid) returns jsonb` (`plpgsql` / `security definer` / `search_path =
public`; market_buy idiom + ACL: `revoke … from public, anon; grant … to authenticated`). It is the **sole writer**
of `trade_relief_claims`. Ordered body: (1) `auth.uid()` → not_authenticated; (2) **DARK reject before any read**
`if not cfg_bool('trade_relief_enabled')` → trade_relief_disabled; (3) `p_request_id is null` → invalid_request;
(4) **account lock + rock-bottom read** `select balance … for update` on the EXISTING wallet row, NOT FOUND →
no_wallet; (5) idempotency on (player, request_id) → verbatim replay, no re-grant; (6) `balance <> 0` →
wallet_not_empty; (7) cargo sum across ALL the player's ships (`ship_cargo_lots ⋈ main_ship_instances`) `<> 0` →
cargo_not_empty; (8) lifetime cap `count >= cfg_num('relief_max_lifetime_claims')` → relief_cap_reached;
(9) cooldown `last > now() - cfg_num('relief_cooldown_seconds')` → relief_cooldown_active (+ next_eligible_at);
(10) grant `cfg_num('relief_credits')` **through `wallet_credit`**; (11) insert the claim, return
{ok, claim_id, amount, claimed_at}.

**Anti-farm design (the "no `wallet_ensure` in relief" rule).** `wallet_credit` now routes through `wallet_ensure`,
which seeds `starting_credits` (1000). If relief ensured a wallet, a rock-bottom player with NO wallet row would be
seeded 1000 **plus** granted 250 relief — a farming hole. So relief **requires an EXISTING `player_wallet` row**
(reason `no_wallet` when absent) and **never calls `wallet_ensure`**: a player with no row hasn't entered the
economy and gets the normal seed on first trade, not relief. The rock-bottom read is `SELECT balance … FOR UPDATE`
on that existing row, giving a natural **per-account lock** — every check and the ledger write run under it, so
distinct-`request_id` races cannot bypass the cap/cooldown. Relief fires only at exact rock-bottom (balance = 0 AND
zero cargo across all ships), bounded by the lifetime cap and cooldown.

**Boundaries.** Trade Market is the sole `trade_relief_claims` writer; the balance write flows only through
`wallet_credit`, preserving `player_wallet`'s sole-writer invariant. All of `player_wallet` (FOR UPDATE),
`ship_cargo_lots`, `main_ship_instances` are DOWNWARD reads — no new cross-system edge, no cycle, Wallet stays a
downward leaf.

**State.** Forward-only. Migration `0095` is the highest-numbered file; `0001–0094` unedited. Ships
**DARK/server-rejected** (`trade_relief_enabled=false`) — no flag default flipped. `docs/SYSTEM_BOUNDARIES.md`
synced in the SAME step (Trade Market row names `market_claim_relief` as sole `trade_relief_claims` writer +
records the downward reads; acyclic-invariant note updated). `main` untouched. No frontend, no workflow, no
verifier, no engine (M2/M3/M4/M4.5) change.

**Bugs / fixes**
- _(none — additive DARK RPC; the seed+relief double-grant hole is closed by design via the existing-wallet-row
  requirement, not patched after the fact.)_

---

## 2026-07-03 — TRADE-MARKET-1 no-softlock floor: relief ledger + tunables + dark flag (schema slice; NO RPC)

**Request.** Schema/config/flag slice of the no-softlock relief floor: add the relief ledger table, its tunables,
and a dark gate — no RPC and no writer yet. Forward-only; ships DARK; no flag flipped true.

**Ownership decision (planner authority).** The relief ledger + orchestrator belong to **Trade Market**, not
Wallet (overriding the scope-lock's tentative "Wallet-owned ledger" phrasing — table ownership is a design detail
within scope). Trade Market is the economy orchestrator that ALREADY fans out downward to Wallet (credit), Trade
Cargo (lots), and Main Ship (read); siting relief there introduces **zero new cross-system edges** and keeps Wallet
a pure downward leaf. Making Wallet orchestrate relief would force Wallet to read Trade Cargo + Main Ship and stop
being a leaf. Mirrors the existing `trade_receipts` table + `market_buy`/`market_sell` RPCs. The relief credit is
granted THROUGH `wallet_credit`, so Wallet stays the sole `player_wallet` writer — Trade Market never writes
`player_wallet` directly.

**Work done** — one new migration `20260618000094_trade_market_1_relief_claims.sql` (head bump **0093 → 0094**):
- **`public.trade_relief_claims`** — Trade-Market-owned, per-player idempotent relief ledger: `claim_id` (pk),
  `player_id` (fk → auth.users, on delete cascade), `request_id`, `amount` (`check >= 0`), `claimed_at`,
  `unique (player_id, request_id)` idempotency key, and a `(player_id, claimed_at)` index for the cooldown /
  lifetime-cap lookups the RPC will do. RLS enabled; owner-read policy `player_id = auth.uid()`; `grant select` to
  authenticated (NOT anon); **no** insert/update/delete policy and **no** write grant → Trade Market will be the
  sole writer via the forthcoming SECURITY DEFINER RPC. Account-scoped (keyed by player_id, not ship) because
  relief is account-level softlock recovery; RLS/comment idiom matches `trade_receipts` (0086).
- **Three tunables** (placeholders) via `on conflict (key) do nothing`: `relief_credits`=`250` (grant per claim),
  `relief_cooldown_seconds`=`86400` (24h minimum spacing — prevents rapid re-farming),
  `relief_max_lifetime_claims`=`3` (lifetime cap per player — bounds total relief while still guaranteeing
  genuine-softlock recovery).
- **Dark flag** `trade_relief_enabled`=`'false'` via `on conflict (key) do nothing`. The relief RPC (next step) is
  server-rejected until this flips; it stays false here — no flag set true.

**No writer exists yet.** The table starts DARK with no writer — exactly as `player_wallet`/`trade_receipts` did in
0086. Nothing reads or writes `trade_relief_claims` yet; the sole writer arrives with the relief RPC in the next
slice, itself gated by `trade_relief_enabled=false`.

**State.** Forward-only. Migration `0094` is the highest-numbered file; `0001–0093` unedited. No new cross-system
edge, no cycle — Wallet remains a downward leaf and `player_wallet`'s sole-writer invariant is preserved (relief
credits flow through `wallet_credit`). `docs/SYSTEM_BOUNDARIES.md` synced in the SAME step (ownership matrix +
Trade Market section + acyclic-invariant note). `main` untouched. No frontend, no workflow, no verifier, no engine
(M2/M3/M4/M4.5) change. No flag default flipped true.

**Bugs / fixes**
- _(none — additive schema/config/flag slice; no writer, no behavior change.)_

---

## 2026-07-03 — TRADE-MARKET-1 seed capital: `starting_credits` tunable + single shared `wallet_ensure` (DARK)

**Request.** Seed-capital slice of the Trading V1 economy bootstrap: add a `starting_credits` tunable seeded into a
wallet on first creation, and collapse the two copies of the Wallet "lazy ensure" block (inline in `wallet_debit`
0089 and `wallet_credit` 0090) into ONE shared helper. Forward-only; ships DARK; no flag default flipped.

**Work done** — one new migration `20260618000093_trade_market_1_wallet_seed_capital.sql` (head bump **0092 → 0093**):
- **`starting_credits` = `'1000'`** added to `game_config` via the `on conflict (key) do nothing` numeric-seed idiom
  (0003). Placeholder economy value; an inert tunable until a wallet is actually created.
- **`wallet_ensure(player)`** — the ONE shared lazy-ensure + seed:
  `insert into public.player_wallet (player_id, balance) values (p_player, coalesce(cfg_num('starting_credits'),0)::numeric) on conflict (player_id) do nothing`.
  Seeds the starting balance exactly once on first creation; idempotent + **unfarmable** by the `player_id`
  primary-key conflict (a re-call is a no-op — the row is only ever inserted once). Internal (`revoke execute …
  from public, anon, authenticated`), `security definer`, `set search_path = public`.
- **`wallet_debit` de-duplicated:** former inline `insert … on conflict do nothing` → `perform wallet_ensure(...)`;
  the existing atomic conditional `update … where balance >= p_amount` and `return found` are left exactly as-is.
  Behavior preserved: seed on first touch, then race-safe conditional debit that can never overdraw.
- **`wallet_credit` de-duplicated:** reworked from its upsert-add into **ensure-then-add** — `perform
  wallet_ensure(...)` then an unconditional `update … set balance = balance + p_amount`. The ensure guarantees the
  row exists (seeded on first creation), then the amount adds on top — credit semantics preserved, second copy of
  the ensure logic removed. This is the de-duplication target: the ensure block now lives in exactly one place.

**Ships DARK — no flag flipped.** The seed only ever fires when a wallet is first created, and every
wallet-creation path is already server-rejected: `market_buy`/`market_sell` under `trade_market_enabled=false`, and
the additional-ship commission debit under `mainship_additional_commission_enabled=false`. So no wallet — and thus
no seed — occurs while trade/commission stay dark. No flag default changed.

**State.** Forward-only. Migration `0093` is now the highest-numbered file; `0001–0092` unedited. Wallet stays a
**downward leaf** (reads `cfg_num('starting_credits')` from Reference/Config — a DOWNWARD read; no new cycle, no new
writer to any non-Wallet table). `docs/SYSTEM_BOUNDARIES.md` Wallet row synced in the SAME step (names
`wallet_ensure` as the shared lazy-ensure+seed, records the config read, drops the stale `wallet_credit` "lazy
ensure" phrasing). `main` untouched. No frontend, no workflow, no verifier, no engine (M2/M3/M4/M4.5) change.

**Bugs / fixes**
- _(none — clean de-duplication + additive tunable; behavior preserved on both wallet writers.)_

---

## 2026-07-03 — Docs-only roadmap reconciliation: Phase-10 label + live migration head (no code/flag change)

**Request.** Reconcile the Phase-10 (row `10 ⏳`) cell in `docs/ROADMAP.md` (line 85) with its own appended
status: replace the stale leading label `**designed, NOT built.**` and bump the stale live "migration head"
figure. Docs-only; touch nothing else.

**Work done** — exactly two edits to the Phase-10 cell, nothing else in it:
- **Label `designed, NOT built` → `implemented DARK, NOT activated`.** The cell's own appended note already reads
  "**implemented DARK & PR-ready** … all trade flags/gates OFF", so the leading "NOT built" clause was factually
  wrong (the pipeline IS built, only un-activated). The new label preserves the "not live" meaning while removing
  the contradiction.
- **Live "migration head `0091`" → "migration head `0092`".** The docked-location-helper migration
  `20260618000092_trade_market_1_resolve_docked_location.sql` was added after that status note was written, so the
  live head figure was stale. The historical `TRADE-MARKET-1 `0085–0091`` range is **left untouched** — it
  correctly describes TRADE-MARKET-1's original migration set; `0092` is the later cleanup helper and only the live
  head figure was stale.

**State.** Docs-only, forward-only. No code, migration, RPC, frontend, workflow, test, verifier, flag default, or
behavior changed — nothing activated. Locked scope was `docs/ROADMAP.md` + this `docs/DEV_LOG.md` entry only. No
`SYSTEM_BOUNDARIES.md` sync needed (no architectural fact changed — no table/writer/constraint/call-graph change).
Migration head remains **0092** on `autopilot/20260703-064048`; `main` untouched. No build/test run is required
(no runtime surface); the M2/M3/M4/M4.5 engine tests are unaffected.

**Bugs / fixes**
- _(none — docs reconciliation only.)_

---

## 2026-07-03 — Trading V1 cleanup: CI proof workflow `trade-v1-proof.yml` (disposable DB only; no production)

**Request.** Wire the two already-existing Trading-V1 proofs into CI. Add ONE workflow that runs both against a
throwaway/disposable Supabase only — never production, flipping no flag. Reuse the `port-entry-1-proof.yml` idiom.

**Work done**
- **New workflow `.github/workflows/trade-v1-proof.yml`** (modeled on `port-entry-1-proof.yml`). One workflow, one
  disposable stack for both proofs:
  - `selftest` job — DB-free static checks: `bash scripts/trade-fleet-0c-proof.sh selftest` +
    `bash scripts/trade-market-1-proof.sh selftest`.
  - `disposable-matrix` job — `supabase start` (applies the full local chain 0001..0092, incl. the new shared
    docked-location helper), exports the disposable `DB_URL` via `supabase status -o env` into a tmp env file (no
    secrets), then runs `trade-fleet-0c-proof.sh local` then `trade-market-1-proof.sh local`, and an
    `if: always()` `supabase stop --no-backup || true`.
  - `on: workflow_dispatch` + `push` to `autopilot/**`, `trade-**`, `trade-market-**`, `trade-fleet-**` — **not**
    `main` / any release branch. `permissions: contents: read`; `concurrency` on `github.ref` with
    `cancel-in-progress: true`. **No `environment:` on any job** → no job can read production secrets.
- **Flips NO committed flag.** Both proofs are self-rolling-back: they enable the dark trade capabilities ONLY
  inside a txn that ends in ROLLBACK (no COMMIT), so the committed flag defaults (`trade_market_enabled`,
  `mainship_additional_commission_enabled` = false) are untouched. Disposable local Supabase only — never prod.

**State.** Additive CI wiring only. No proof `.sql`/`.sh`, migration, flag default, `MarketPanel`, or boundary-doc
change (a CI workflow is not an architectural fact, so `SYSTEM_BOUNDARIES.md` needs none). Migration head unchanged
at **0092**. Not dispatched/triggered (a human/CI action); `main` untouched. Both `selftest` invocations pass
locally (DB-free); the `disposable-matrix` job needs GitHub-hosted Docker/Supabase and was **not** run in-sandbox.

**Bugs / fixes**
- _(none — additive CI wiring around existing proofs.)_

---

## 2026-07-03 — Trading V1 cleanup: extract shared docked-location helper (migration 0092; behavior-identical)

**Request.** The identical ~10-line "resolve docked location" block was copy-pasted verbatim into
`get_market_offers` (0087), `market_buy` (0089), and `market_sell` (0090). Extract ONE shared helper and repoint
the three RPCs, in a NEW forward-only migration — never editing 0087/0089/0090; behavior-identical; DARK.

**Work done**
- **New migration `20260618000092_trade_market_1_resolve_docked_location.sql`.** Adds
  `public.mainship_resolve_docked_location(uuid) returns uuid` (`security definer`, `set search_path`, `stable`,
  read-only): calls `mainship_space_validate_context`, requires `ok` + `state='at_location'`, then reads the
  present/location fleet's `current_location_id` — returns that id or NULL. Both original "not docked" null paths
  collapse to one NULL, which each caller maps to the same `{ok:false, reason:'not_docked'}` → behavior-identical.
- **Repointed all three RPCs** via `create or replace` (supersedes 0087/0089/0090 forward-only; those files are
  untouched). Each body is byte-for-byte its original except (a) the inline block → the helper call, and (b) the
  now-unused `v_ctx jsonb;` local dropped (dead after extraction). Flag gate, `mainship_resolve_owned_ship`
  ownership assert, per-ship lock, request-id idempotency, offer/volume/cargo checks, and all wallet/cargo/receipt
  writes are unchanged.
- **ACL — INTERNAL (deviation from the step's suggested `grant authenticated`, on security grounds).** The helper
  is revoked from public/anon/authenticated (no client grant), matching its true siblings
  `mainship_space_validate_context` / `mainship_resolve_owned_ship`. It does NOT assert ownership (the
  orchestrators do, before calling it); granting it to `authenticated` would create a new client-callable
  SECURITY DEFINER read that leaks any ship's dock. It is called only inside the SECURITY DEFINER trade RPCs
  (which run as owner), so the internal ACL changes no call path.
- **Law-doc sync (same step).** `SYSTEM_BOUNDARIES.md`: named the helper in the Main Ship §2 row (shared
  read-only docked-location helper, internal, called DOWNWARD by Trade Market) and in the Trade Market row's
  docked-context read; extended the acyclic-fan-out note with the (pre-existing) Trade Market → Main-Ship-read
  edge, now a single named function.

**State.** Migration head now **0092**. No flag/behavior change; feature stays **DARK** (`trade_market_enabled`,
`TRADE_MARKET_ENABLED`, `mainship_additional_commission_enabled`, `MAINSHIP_ADDITIONAL_ENABLED` all OFF). No
migration ≤ 0091 edited; `main` untouched; not applied to production.

**Bugs / fixes**
- _(none — pure de-duplication; three verbatim copies → one helper, behavior-identical.)_

---

## 2026-07-03 — Trading V1 cleanup pass: SYSTEM_BOUNDARIES doc-sync (docs-only; no behavior/flag change)

**Request.** Bring `docs/SYSTEM_BOUNDARIES.md` back in sync with the actual schema after the TRADE-FLEET-0C /
TRADE-MARKET-1 migrations (0073–0091). Docs-only; touch no code, migration, RPC, workflow, or flag.

**Work done**
- **Corrected the stale one-ship-per-player claim.** §4 item 7 (and the §2 Main Ship row) asserted
  `main_ship_instances` had one row per player via a `player_id` UNIQUE. That UNIQUE
  (`main_ship_instances_player_id_key`) was **dropped in migration 0079** — a player MAY now own multiple ships.
  Both spots now state multi-ship is structurally allowed but stays **DARK**: sole-ship is a runtime shim / dark
  gate (`mainship_additional_commission_enabled=false`), not a schema constraint.
- **Documented the four new tables in the §1 ownership matrix** with their real sole-writers:
  `trade_goods` = **Reference/Config** (Trade Market static catalog; admin/migration, seed-only),
  `ship_cargo_lots` = **Trade Cargo**, `player_wallet` = **Wallet**, `trade_receipts` = **Trade Market**.
- **Added the three new systems to the §2 contract:** **Wallet** (downward leaf; `wallet_debit`/`wallet_credit`
  — both Main Ship (add-ship `main_ship_price` debit) and Trade Market (buy debit / sell credit) depend DOWNWARD
  on it, Wallet depends on nothing above → acyclic, no mutual dependency); **Trade Cargo**
  (`trade_cargo_add_lot`/`trade_cargo_consume` — per-ship volume-keyed lots; a leaf Trade Market depends on);
  **Trade Market** (`trade_receipts`; orchestrates buy/sell fanning out DOWNWARD to Wallet + Trade Cargo,
  reads `trade_goods` + docked context; DARK while `trade_market_enabled=false`). Added an acyclic-fan-out note
  confirming exactly one sole-writer per table and no second writer anywhere.

**State.** Docs-only. **No** migration/RPC/`MarketPanel`/workflow/flag change; migration head unchanged at **0091**.
The trade feature stays **DARK** (`trade_market_enabled`, `TRADE_MARKET_ENABLED`,
`mainship_additional_commission_enabled`, `MAINSHIP_ADDITIONAL_ENABLED` all OFF); `main` untouched.

**Bugs / fixes**
- _(none — a law-doc that contradicted the schema was corrected; no behavior path changed.)_

---

## 2026-07-03 — TRADE-UI-1 landed DARK + PR-ready (ship-switcher + buy/sell + §2.5 sole-ship shim retirement)

**Request.** Complete **TRADE-UI-1** on `autopilot/20260703-064048`: the client trading surface (ship switcher,
market buy/sell) and the **§2.5 sole-ship shim retirement** (the UI passes an explicit `p_main_ship_id`). Additive,
gated **OFF**, behavior-preserving; no migration/DB/verifier/workflow/flag change; `main` untouched.

**Work done**
- **Client trade surface (DARK).** Selected-ship model `useMainShipSelection` (owner-reads `main_ship_instances`,
  auto-selects the sole ship, N-ship-ready); `ShipSwitcher` (selection-only; a single ship renders as a
  non-interactive sole entry); `MarketPanel` read view (wallet, occupied cargo m³ vs capacity, station offers)
  **plus per-offer buy/sell** wired to `market_buy` / `market_sell` — each intentional click is one idempotent
  command keyed by a fresh `crypto.randomUUID()`, a **synchronous in-flight ref** guards against double-submit, and
  a success re-reads wallet/cargo/offers via `refresh()`. Fail-closed server reasons map through the pure
  `tradeReasonMessage`. Everything mounts only behind `TRADE_MARKET_ENABLED = false` and is **double fail-closed**
  against the server `trade_market_enabled` flag (also false — the trade RPCs reject before any ship read).
- **§2.5 sole-ship shim retirement.** The client now sends an explicit `p_main_ship_id` at ⑤ port
  move-to-location, ④ space-stop, ③ movement-readiness, ② dock-services, ① repair, and ⑦ normalize-dock. Each is
  behavior-preserving: with one ship the sourced id equals the shim-derived sole ship; a transitional `null` still
  resolves via the server `count = 1` shim; ownership is server-asserted, so an explicit id can only ever act on the
  caller's own ship. ⑥ `command_main_ship_space_move` is **deferred by design** — its RPC intentionally never took
  `p_main_ship_id` in TRADE-FLEET-0C (it rejects at the coordinate gate before any ship read).
- Delivered as six small, independently-reviewable commits (map hooks/panels; plus `dashboard/MainShipPanel.tsx`
  for repair and `portentry/` for normalize under a deliberately-widened frontend scope, id-threading only).

**State.** Migration head **unchanged at `0091`** — TRADE-UI-1 touched **no** migration/DB/verifier/workflow. The
feature is **DARK and PR-ready** on `autopilot/20260703-064048`: buildable, **not deployed, not verified in
production**. All trade / add-ship gates + flags remain **OFF**: `TRADE_MARKET_ENABLED`,
`MAINSHIP_ADDITIONAL_ENABLED`, `trade_market_enabled`, `mainship_additional_commission_enabled`,
`mainship_coordinate_travel_enabled`.

**Human-gated follow-ups (NOT done, by design)**
- **Activate trading:** flip `trade_market_enabled` + `TRADE_MARKET_ENABLED` (and, for the multi-ship add-ship
  path, `mainship_additional_commission_enabled` + `MAINSHIP_ADDITIONAL_ENABLED`).
- **Server-side removal of the sole-ship shim** — a future migration, only once the UI-explicit-id path is merged.
- **Run the rendered `.uispec.ts` suites in CI** — this sandbox lacks the browser binary (`chrome-headless-shell`).
- **Small `react-hooks` lint-debt cleanup** — documented pre-existing suppressions in `usePortEntry.ts` and
  `useDockServices.ts` (a `useState`-initializer refactor; out of scope for the id-threading commits).

**Bugs / fixes**
- _(none — additive dark UI + behavior-preserving id threading; no production code path changed.)_

---

## 2026-07-03 — Repo/docs sync + PORT-ENTRY player UI landing recorded (no new build)

**Request.** Pull `main` current on the local machine and bring the project docs (log, guide, PDFs) up to date.

**Work done**
- Synced local `main` (fast-forward **22 commits → `f48bc53`**). No code written this session.
- Recorded that the **PORT-ENTRY player UI** (PR #65, `cb0d4fe`) is **merged** — the player-facing **Claim First
  Ship** + **Finish Docking (normalize)** panel (`src/features/portentry/PortEntryPanel.tsx` + hooks) now exists,
  **frontend-only**, calling the migration-`0072` RPCs; no new migration.
- Refreshed the guide **Current project snapshot** with a 2026-07-03 note (`main` head → `f48bc53`, PORT-ENTRY UI
  merged, Trading V1 FIXED to volume-only, TRADE-FLEET-0A audit recorded via PR #66).

**State.** Migration head **unchanged at `0072`**; coordinate travel stays **DARK**
(`mainship_coordinate_travel_enabled = false`). Next planned: **TRADE-FLEET-0B** (user-approved multi-ship +
volume-cargo contract — design/approval only). Trading V1 not started.

**Bugs / fixes**
- _(none — docs/sync only; no code path touched.)_

---

## 2026-07-02 — Trading V1 design record — FIXED product direction (volume-only per-ship cargo + multi-ship foundation) + TRADE-FLEET-0A read-only audit (DESIGN RECORD ONLY; nothing built)

**Request.** Do **not** begin Trading implementation. Fix the Trading V1 product direction (below) as binding for
design, and produce **TRADE-FLEET-0A** — a strict read-only impact audit for introducing **multiple persistent main
ships** and **ship-bound, volume-based cargo**. No branch, PR, migration, code, seed, workflow, deployment, or
production-state change; PORT-ENTRY, coordinate-travel, flags, and movement are untouched
(`mainship_coordinate_travel_enabled` stays **false**). Migration head remains **`0072`**.

> **Supersession note.** This direction **replaces** the earlier same-day draft that used **kilograms + cubic
> metres (dual mass+volume caps)** and allowed **same-port ship-to-ship transfer**. The FIXED model is
> **volume-only (m³)**, and **cargo transfer between ships is OUT of Trading V1 scope.** Mass / density / fuel /
> acceleration / handling are **future-only**, not part of this foundation.

**Fixed direction (binding for design):**

1. **Multi-ship from the start.** Multiple persistent main ships are a **Trading foundation**, not a later
   module/captain feature. A player may eventually own and operate several main ships **concurrently** (one docked
   & trading while another travels or docks elsewhere).
2. **Cargo is ship-bound.** Trade cargo is physically assigned to **one** ship; it moves only when that ship moves;
   it is **never pooled** across a player's ships. **No** account-level trade inventory. **No** remote buy/sell and
   **no** cargo teleportation.
3. **Volume-only capacity (m³).** Canonical storage + validation unit is **cubic metres**. Player-facing display may
   use m³ (and litres for small amounts). **No** abstract cargo units. **No** kilograms / mass / density / dual
   mass+volume in Trading V1 (those are explicitly future-only).
4. **Commodities have a defined physical volume.** Trade denominations (crate / pallet / tank / container / bundle…)
   each resolve to a **fixed canonical m³**; the capacity rule is **occupied volume only**.
5. **Every market action targets one selected ship** — owned by the player, physically **docked** at the relevant
   port, in an eligible state; buy/sell operate only on **that ship's** cargo.
6. **Coordinate travel stays dark.** Existing **port-to-port** travel is sufficient for the first economy; no
   coordinate-travel activation, change, or dependency is recommended.
7. **Out of V1 scope:** pooled fleet cargo; account-level trade inventory; remote market actions; **cargo transfer
   between ships**; port warehouses; automated trade routes; player-to-player trading; dynamic supply/demand;
   cargo loss / piracy / insurance / destruction economics; mass / density / fuel / acceleration / handling.

**Implementation sequence (design-level; unchanged ordering, cargo model corrected to volume-only):**

```
PORT-ENTRY (complete, mig 0072)
  → TRADE-FLEET-0A  read-only impact audit (this entry — design record only)
  → TRADE-FLEET-0B  explicit user-approved multi-ship + volume-cargo contract (design/approval only)
  → TRADE-FLEET-0C  coherent implementation slice (multi-ship + ship-bound volume-only m³ cargo, one slice)
  → TRADE-MARKET-1  server-authoritative market (offers, wallet, atomic volume-checked buy/sell vs a selected ship)
  → TRADE-UI-1      selected-ship market + fleet interface
```

**TRADE-FLEET-0A audit (read-only).** The full impact audit — every current one-main-ship assumption
(DB / backend / frontend / verifier / onboarding) classified mandatory / compatibility-sensitive / optional /
not-affected; cargo-locality guarantees; a minimal design-level data boundary; multi-ship concurrency & safety;
compatibility/migration risks across all ship states; affected frontend surfaces; verifier implications; blockers;
open decisions; and a recommended slice order — is recorded in
[`docs/TRADE_FLEET_0A_IMPACT_AUDIT.md`](TRADE_FLEET_0A_IMPACT_AUDIT.md). Key finding: the locking/idempotency
substrate is **already ship-scoped** (`mainship_space_lock_context(main_ship_id)`, no advisory/player lock;
idempotency keyed `(main_ship_id, request_id)`); the only hard single-ship blockers are the
`main_ship_instances.player_id UNIQUE` constraint and the uniform `where player_id = v_player` ship derivation.

**Work done**
- DEV_LOG (this entry) + ROADMAP Phase 10 row and Standing Law #1 annotated with the FIXED (volume-only) direction.
- New read-only audit doc `docs/TRADE_FLEET_0A_IMPACT_AUDIT.md` (replaces the superseded kg+m³ draft audit).

**Bugs / fixes**
- _(none — design record only; no code path touched)_

---

## 2026-06-30 — OSN-COORD-ENABLE (dark) → PORT-ENTRY-1 first-ship commission/normalize → production verifier (head `0070` → `0072`)

Since the entry below (head `0070`, OSN port-to-port live, coordinate travel server-disabled) the project built the
coordinate-travel capability **end-to-end and left it DARK**, then shipped the **first-ship / port-entry** backend
(the Trading prerequisite), then added a dedicated production verifier for it. **Net production change:** migration
head **`0070` → `0072`**; **no flag flipped** — `mainship_coordinate_travel_enabled` stays **false**, coordinate UI
hidden, raw coordinate command server-rejected, port-to-port unchanged/enabled. `main` head `a947c8d`.

**Work done (in order):**

- **OSN-COORD-ENABLE-1B (migration `0071`, PR #57, deployed DARK).** Extended the authenticated read-model
  `get_osn_movement_readiness()` with one additive boolean `coordinate_travel_available = osn_available AND
  cfg_bool('mainship_coordinate_travel_enabled')` — derived from the existing anchored-origin decision, false for
  every caller while the gate is false. Disposable 2×2 truth-table proof; gated deploy.
- **OSN-COORD-ENABLE-1B-VERIFY (PR #58).** Repinned the read-only post-enable verifier to head `0071` + a
  single-RPC readiness-capability contract probe. Production read-only run: `OVERALL_PASS=true`.
- **OSN-COORD-ENABLE-1C (PR #59, Pages-deployed).** The frontend empty-space coordinate UI is now driven SOLELY by
  the server-derived `coordinate_travel_available` (strict fail-closed parser + `isCoordinateTargetingActionable`);
  the compile-time `OSN_COORDINATE_TRAVEL_ENABLED` constant is retired as the UI authority. **Effect:** when the
  server flag is later flipped true, the coordinate UI lights up with no redeploy; until then it stays dark.
  Live bundle independently verified dark.
- **PORT-ENTRY-1 (migration `0072`, PR #61, deployed).** First-ship commissioning + same-location dock
  normalization — the Trading prerequisite. `port_entry_commission_writer(uuid)` (service-role-only) inserts a new
  player's ship DIRECTLY into canonical `at_location` at Haven Reach; `commission_first_main_ship()` (authenticated,
  zero-arg) outcome matrix A–F; `normalize_main_ship_dock()` (authenticated) upgrades a coherent `legacy_present`
  ship in place. Two-phase lock protocol; proven with a real two-session concurrency race (B blocks on the
  `player_id` unique conflict until A commits). Additive function-only; no flag/data/coordinate change. **No
  player-facing UI yet.**
- **PORT-ENTRY-1-VERIFY-1 (PR #62, merged — tooling only).** A dedicated, dispatch-only, production-gated
  read-only verifier proving production contains exactly the three PORT-ENTRY functions (signatures, bodies via raw
  `pg_proc.prosrc` md5, `SECURITY DEFINER`, `search_path`, ACLs) AND the **complete** authenticated client-RPC
  inventory (exact 20-RPC set by OID). Disposable proof passes + fails closed for 8 mutation cases. **Not yet run
  against production** (the gated run is the next human-approved checkpoint).

**Current authoritative state (HELD):** head `0072`; `mainship_send_enabled=true`, `mainship_space_movement_enabled=true`
(port-to-port enabled), `mainship_coordinate_travel_enabled=false`, `coordinate_travel_available=false`. Coordinate
travel and Trading V1 are **not** started; PORT-ENTRY player UI is the next active development.

---

## 2026-06-29 — OSN enabled → Phase 9 docked-port surface → coordinate-gate hardening → Phase 10 Trading design (head `0068` → `0070`)

Since the PORT-LAUNCH entry below (head `0068`, ports public, OSN still dark) the project advanced through OSN
enablement, a first player-facing port surface, a coordinate-travel security fix, and a full Trading V1 design
pass. **Net production change:** migration head **`0068` → `0070`**; **OSN port-to-port travel is now ENABLED**;
**free arbitrary-coordinate travel is server-disabled by default.** Current live flags: `mainship_send_enabled =
true`, `mainship_space_movement_enabled = true` (port-to-port ON), `OSN_COORDINATE_TRAVEL_ENABLED = false`
(frontend) + `mainship_coordinate_travel_enabled = false` (server, new in `0070`). `main` head `6e2a091`.

**Work done (in order):**

- **OSN enablement (config-only; head stays `0068`).** The dark OSN port-to-port path was turned on via the
  controlled one-shot enable operation (`mainship_space_movement_enabled` false→true), independently read-only
  verified against production, and a disposable authenticated port-to-port journey (depart → arrive → dock
  `at_location`) confirmed live behavior. A ship docked at a port can now travel port-to-port; arbitrary
  coordinate travel stayed off.

- **Phase 9 — docked-port read surface (PR #49 → migration `0069`, deployed).** `get_my_current_dock_services()`
  (authenticated, read-only, zero-arg, `SECURITY DEFINER`): derives player → own ship → validated dock, and
  ONLY for the `at_location` state returns the port + its ACTIVE `location_services` (today: Docking). Frontend
  `DockServicesPanel` shows "Main ship docked at &lt;port&gt;" + service chips only when docked. No buy/sell/market.
  Proven (disposable RPC matrix + rendered UI), deployed `0068`→`0069`, read-only verified live (`OVERALL_PASS=true`).

- **Phase 9 closeout (PR #50, frontend/tooling only — no migration).** Dock-context hardening (stale-data
  protection on a lifecycle change, safe-failure, mobile width cap), the one stale player-facing string fixed,
  and the current-state verifier `osn-postenable-verify` repinned head `0068`→`0069` + dock-surface ACL
  assertions; the historical pre-enable verifiers were left untouched.

- **OSN-COORD-GATE-1 (PR #51 → migration `0070`, deployed).** Closed a real gap: the public raw coordinate
  command `command_main_ship_space_move` was guarded only by `mainship_space_movement_enabled` (true for the
  enabled port-to-port path), while the "free coordinate travel OFF" control was **frontend-only** — so a direct
  authenticated API caller could request arbitrary coordinates. Fix: a server-owned key
  `mainship_coordinate_travel_enabled` (default **false**); the raw command now returns `coordinate_travel_disabled`
  BEFORE any ship read / lock / writer call (no side effect) while the key is false. The location-target command
  `command_main_ship_space_move_to_location` is **unchanged** (still governed by `mainship_space_movement_enabled`;
  port-to-port unaffected). Disposable matrix `ok[1..7]` green; deployed `0069`→`0070`. Gate ships **false**.

- **Phase 10 Trading V1 — design & calibration (DESIGN ONLY; nothing built).** A full pass produced the Trading
  V1 contract: free-port model (trade eligibility = own ship's validated current dock + active `market`
  capability), a **HYBRID cargo** model (account loot stays in `player_inventory`; a per-ship trade-hold carries
  trade goods), a **lazy player wallet** (currency separate from items), server-owned **`market_offers`**
  (price/availability, never in `location_services`), **`trade_receipts`** whole-trade idempotency, a per-offer
  **purchase-allowance** throttle, 7 proposed original commodities + a capacity-accurate 3-port matrix, and a
  route/balance simulation (no same-port profit; no unbounded reinvestment). Two hard findings: (1) a brand-new
  player has **no main ship** today (`bootstrap_me` makes only a base; `ensure_main_ship_for_player` is
  service-role-only with no player path) — so **main-ship provisioning** is the gating prerequisite; (2) trading
  needs the OSN `at_location` state, which neither `repair_main_ship` (→`home`) nor the legacy
  `send_main_ship_expedition` (→`legacy_present`) produces, while `command_main_ship_space_move_to_location`
  refuses a `home` origin by design — so a canonical **port-entry transition** is needed. Cargo-loss-on-destruction
  is deferred (free instant repair makes any recovery grant farmable). **No migration / seed / RPC / wallet /
  market / UI was created.**

**Bugs / fixes**
- Phase-9 dock proof: the in_transit fixture inserted the movement before its fleet (FK order) — fixed.
- Coord-gate proof: the disposable chain defaults `mainship_space_movement_enabled=false` (production's `true`
  is runtime, not a migration), so the first gate fired before the new gate — the proof now enables the
  movement domain on the disposable stack.

**FORWARD PLAN (approved direction; not started):**
1. **Main-ship provisioning — the prerequisite that gates all of Trading.** A one-time authenticated "Commission
   Your First Ship" claim that atomically creates ship + fleet + presence + an `at_location` dock at one
   designated **starting port** (a spawn placement, **not** a home port; `player_home_port` stays unused), plus
   a canonical OSN **port-entry transition** so existing `home`/`legacy_present` ships can reach a tradeable
   `at_location` state.
2. **Trading V1 implementation** (only after the open decisions below are approved): read model
   (`trade_goods` / `market_offers` / `player_wallet` / `ship_trade_cargo` / `trade_receipts` / allowance) →
   market capability + catalog seed → atomic idempotent buy/sell write path → Market UI from the Phase-9 dock
   seam → disposable proofs → gated deploy → read-only verifier.
3. **Then** Exploration (Phase 11) → Mining (Phase 12) → Modules/Captains (13–16) → Ranking (17) → economy/polish (18–20).
4. **Cross-cutting, deferred:** the `world_sites` canonical identity layer (build only when its F2 trigger
   fires), Online Presence & Visibility, main-ship combat, and a cargo-loss / repair-cost redesign.

**Open product decisions (need user approval before any Trading build):** cargo model (hybrid), currency (lazy
wallet, start 0), first commodities + price matrix, per-offer allowance + reset window, starting spawn port,
first-voyage starter cargo, and credit purpose (proof loop accumulating toward a future ship/captain/module sink).

---

## 2026-06-27 — PORT-LAUNCH: public port launch (foundation → reveal → independent verification)

The OSN-HUB-1A line (head `0067`, prior entry) advanced through the full **PORT-LAUNCH** epic: the dark
public-launch back end + front end were built and production-verified, then the three starter ports were
**revealed** in a single controlled, human-gated operation, and the result was **independently, read-only
verified** against production. Net production change: migration head **`0067` → `0068`**; authenticated
client-RPC surface **16 → 17**; the three starter ports **hidden → active/public**. **OSN port-to-port
movement stays dark** — `mainship_send_enabled = true`, `mainship_space_movement_enabled = false`,
`OSN_COORDINATE_TRAVEL_ENABLED = false` (frontend) — all unchanged by this epic.

**Requests / work done (in order):**
- **ENABLEMENT-1 (PR #36 → `3b5e6ce`).** Re-pinned `scripts/osn-enablement-preflight.sql` to head `0067` /
  surface `16`, widened space|location target checks, mirrored the function inventory into the DOCK-0 / HUB-1A
  allowlists. Tooling/gate only — no gameplay, no flag flip.
- **Fixture maintenance (PR #37 → `83d44e6`).** Replaced a global "anchors empty" assumption with an exact
  identity baseline (the three 0066 starter-port anchors). Housekeeping; depended on #36 landing first.
- **Enablement preflight (run `28253259301`).** Read-only production check → `OVERALL_PASS=true` at 0067/16.
- **PORT-LAUNCH-1A (PR #38 → `122374f`, migration `20260618000068`).** Added `reveal_starter_ports()`
  (service-role-only, one-way, all-or-nothing, never auto-invoked; locks the full sector→zone→location→anchor
  →service hierarchy before validating) and `get_osn_movement_readiness()` (authenticated, read-only; reports
  `osn_available=false` while the flag is off). Surface 16→17.
- **Deploy 0068 (run `28281667811`).** Human-gated deploy; head `0067`→`0068`; functions + surface re-lock
  only, **zero data change** (no reveal, no flag, no row touched).
- **Catalog-verifier refresh (PR #39 → `27df8e8`) + production verify (run `28288983383`, `OVERALL_PASS=true`).**
  Re-aimed the read-only catalog verifier at 0068/17; proved production still dark (ports hidden, flags off).
- **PORT-LAUNCH-1B (PR #40 → `ab07f14`).** Dark port-to-port travel UI (PortNavPanel / osnReadiness /
  portMoveCommand / osnReleaseGates); shows nothing while the flag is off; in-transit keeps route/ETA/Stop.
- **PORT-LAUNCH-2A (assessment) + 2B (PR #41 → `589abb9`).** Read-only onboarding-readiness recon, then a
  disposable full-chain proof: reveal → real `send_main_ship_expedition` accepts Haven Reach → real arrival
  settles → resolver returns anchored → readiness `anchored` (flag off) → world reverted. Added the verifier's
  A9 `STP_*` fail-closed pre-reveal checks.
- **PORT-LAUNCH-2C (PR #42 → `33af7e8`).** The controlled one-shot reveal workflow: `workflow_dispatch` only,
  `main`-only, typed `REVEAL_THREE_STARTER_PORTS` confirmation before any DB connection, `production`
  environment gate, pinned-CA verify-full, one transaction (lock → preconditions → reveal ×1 → postconditions
  incl. an **identity-level non-canonical digest** → commit-only-on-pass), rerun/uncertain fail-closed, no
  retry. Disposable proof `ok[1..6]`.
- **PORT-LAUNCH-2D (run `28294311791`).** Dispatched + approved; reveal executed once:
  `REVEAL_FUNCTION_CALLS=1 · STARTER_PORTS_ACTIVE_AFTER=3 · FLAGS_UNCHANGED=true · REVEAL_OPERATION_PASS=true`.
  Three ports hidden → active. One-way.
- **PORT-LAUNCH-2E (PR #43 → `00dfdd2`, run `28295627367`).** New independent read-only post-reveal verifier
  (`scripts/postreveal-verify.{sql,sh}` + `.github/workflows/postreveal-verify*.yml`) — leaves the dark-state
  verifier untouched; checks the server catalog **and** the authenticated `get_world_map()` boundary. Live run
  returned `MIGRATION_HEAD=0068 · CANONICAL_PORTS_ACTIVE=3 · CANONICAL_PORTS_HIDDEN=0 ·
  UNEXPECTED_PORT_STATE_CHANGES=0 · AUTHENTICATED_MAP_PORTS_VISIBLE=3 · MAINSHIP_SEND_ENABLED=true ·
  MAINSHIP_SPACE_MOVEMENT_ENABLED=false · OVERALL_PASS=true`.

**Bugs / fixes:**
- **1A lock-order TOCTOU** — reveal first locked only the three port rows; hardened to lock the full hierarchy
  (sector→zone→location→anchor→service) in a fixed order before validating; proven with concurrent psql sessions.
- **1A duplicate-insert proof premise** — the real block is a synchronous unique-constraint violation, not an
  FK lock-wait; proof corrected to assert the actual mechanism.
- **2B forced arrival** — back-dating only `arrive_at` violated `fleet_movements (arrive_at > depart_at)`;
  fixed by moving the whole travel window into the past.
- **2C postcondition** — net "+3 active" could be fooled by an offsetting change; added an `md5` digest of every
  non-canonical `(id,status)` to prove identity-level invariance.
- **2E test-harness** — a `emit_markers | grep -qx` happy-path assertion was fragile under `pipefail`; switched
  to reconcile + direct `mval` spot-checks (verifier logic itself was correct on first run).

**State after this epic (all on `main`, head `00dfdd2`):** production head **`0068`**, surface **17**, three
starter ports **active/public** (independently verified), flags unchanged (send `true`, space `false`). The
in-game OSN travel panel is built but dark. The only remaining arc item is the separate, optional, future OSN
flag-enable decision (`mainship_space_movement_enabled = true`) — **not started, not needed, not urgent.**

---

## 2026-06-26 — Session wrap-up + FORWARD PLAN (notes/design only; nothing started)

Closing-session record. **No product code / migration / workflow / verifier / flag / production change** in
this entry. Captures where things stand after OSN-HUB-1A and the deliberately-gated next steps, so the next
session can resume without re-deriving.

**State at this wrap (all on `main`):** product/production migration head **`0067`**; `main` is the
OSN-HUB-1A closure + verifier-tooling line (PRs #31 product, #32/#33 read-only verifier tooling, #34 closure
record). **OSN is DARK** and stays dark: `mainship_send_enabled = true` (legacy named-location travel LIVE),
`mainship_space_movement_enabled = false`. Hidden starter ports remain hidden/ineligible/unassigned; no
home-port assigned; no base anchor; no public OSN enablement. OSN-HUB-1A was merged → deployed (`0067`) →
read-only verified (production catalog verifier run `28229418325` = `OVERALL_PASS=true`) → formally closed
(prior entry). The legacy `bases.x/y` / `locations.x/y` coordinate path is frozen; the OSN coordinate domain
resolves origins/targets through canonical `space_anchors`.

**Reusable asset created this line of work:** a dispatch-only, production-`environment`-gated, **strictly
read-only** production catalog/ACL/configuration verifier (`scripts/osn-hub1a-production-catalog-verify.{sql,sh}`
+ `.github/workflows/osn-hub1a-production-catalog-verify.yml`, disposable proof `…-proof.yml`). It answers
"does production still match the approved dark state at head 0067?" via one `REPEATABLE READ READ ONLY`
snapshot + rollback (pinned CA / `verify-full` / session-pooler). Model future "is prod still in the approved
known state?" checks on it. **Lesson encoded in it:** Supabase hosted **default privileges** grant
`EXECUTE`-to-`service_role` on `public` functions that a migration doesn't explicitly revoke for `service_role`
— so a public RPC granted only `to authenticated` still has `service_role` EXECUTE on prod but not on the
disposable local stack; assert such platform-default ACLs as an **explicit production policy**, not
reference-vs-local parity (this was PR #33 "correction A").

**FORWARD PLAN — NOT STARTED. Each item needs its own separately-approved owner charter; do not begin on your
own. No flag flip / port reveal / home-port assignment / anchor seed as a side effect.** Ordered by readiness:

1. **ENABLEMENT-1 (tooling/gate maintenance — no gameplay, no flag flip).** Re-pin
   `scripts/osn-enablement-preflight.sql` from migration head `0064`→`0067` and the authenticated client-RPC
   surface `15`→`16` (it currently fails-closed on the new head/surface — *that is why it was deferred*).
   Update the **DOCK-0 perm allowlist** (`scripts/osn3-dock0-realchain-perm.sql`, exact-15 client-RPC list) to
   add `command_main_ship_space_move_to_location` (the same maintenance OSN-4 did for its Stop wrapper).
   Preserve the read-only / fail-closed / `verify-full` / pinned-CA contract. This unblocks a *green*
   enablement preflight; it does NOT enable anything.
2. **OSN flag-enable go/no-go (the first player-facing OSN change).** Only after ENABLEMENT-1 + a green
   production enablement preflight + an explicit owner decision: flip `mainship_space_movement_enabled=true`
   via the controlled `dev-mainship-space-movement-flag.yml` workflow. Reversible (single config key).
3. **Port-centric world build-out (heavy, charter-gated).** Reveal/seed real ports; seed canonical
   `space_anchors` for reachable locations; assign home-ports (`assign_home_port`); per the **F2 Option C**
   packet add the canonical `world_sites` identity layer (G1+) with the strict 1:1 immutable `locations`
   bridge; geographic-zones layer; possibly the **World Workbench** authoring plane first
   (`PORTCENTRIC_DECISION_PACKET.md` / `F2_COMPATIBILITY_MODEL_DECISION_PACKET.md` are the approved sources).
4. **Baseline activities & beyond (depend on OSN live + ports).** Exploration / Mining / Trading → Online
   Presence v1 → player interaction; Repair & Recovery (replace the instant-Home safelock); main-ship combat;
   captains / modules / rankings. Long-order rationale: `docs/BYEHARU_PROJECT_GUIDE.md` §10–11 and
   `docs/ROADMAP.md`.

**Ship discipline that produced this line (keep using it):** one owner-authorized step per message
(build → disposable CI proof → PR → pre-merge integrity review → admin-override no-ff merge → deploy →
read-only verify); the human owner approves every `environment: production` gate; never flip a flag / reveal a
port / dispatch or approve a workflow as a side effect; work in a throwaway worktree off `origin/main` and
never touch the stale `osn3-dock0-location-arrival` checkout.

---

## 2026-06-26 — OSN-HUB-1A FORMALLY CLOSED — dark canonical location-target navigation, deployed + verified (flag OFF)

Administrative closure record (notes only; **no product code / migration / workflow / verifier / flag /
production change** in this entry). **OSN-HUB-1A is formally closed.**

- **What shipped (PR #31, merge `09f8ba6`, migration `0067`).** The dark, additive **canonical location-target
  navigation** foundation: the OSN coordinate domain now resolves a docked **origin** and a named-location
  **target** through canonical `space_anchors` (NOT legacy `locations.x/y` / `bases.x/y`). One discriminated
  core writer `mainship_space_begin_move_core` (the deployed 5-arg `mainship_space_begin_move` preserved as a
  space-only delegate); the single canonical target-legality rule `mainship_space_location_target_legal`
  (active sector/zone/location + role city|port + `activity_type='none'` + one active docking service + one
  active in-bounds anchor); anchored origin resolution (HOME stays fail-closed `origin_not_anchored`, no base
  anchor); Dock-0 (`mainship_space_dock_at_location`) re-pointed from `locations.x/y` to the canonical anchor
  with **full arrival-time revalidation** under target-hierarchy `FOR SHARE` locks and a `clock_timestamp()`
  settlement time (`resolved_at >= arrive_at`); OSN-4 **Stop compatibility** for location routes (mid-flight
  interpolated stop / at-or-after-arrival settles via the SAME Dock-0 decision; `mainship_space_settle_space_arrival`
  stays strict space-only); and the one new public authenticated wrapper
  `command_main_ship_space_move_to_location(uuid, uuid)` (flag-gated before target resolution; hidden-port
  UUID ≡ nonexistent → generic `invalid_target`; **authenticated surface stays exactly 16**). Frontend is
  read-only/dark (`target_location_id` read-model; location routes render only to VISIBLE destinations).

- **Deployed.** Production migration head **`0067`** (`Deploy Supabase migrations` run `28219980298`, approved
  production gate). OSN remains **DARK**: `mainship_send_enabled = true`, `mainship_space_movement_enabled =
  false`. **No port reveal, no home-port assignment, no base anchor, no flag flip, no player/world mutation.**

- **Verified (read-only).** Final corrected production catalog/ACL/configuration verifier run **`28229418325`**
  → **`OVERALL_PASS=true`** at verified main **`30e5a36`** (verifier tooling commits; product head `0067`
  unchanged). One `REPEATABLE READ READ ONLY` snapshot + `ROLLBACK`; **no production write**. All assertions
  passed: dark-state (head 0067, flags dark, zero active coordinate movement, no incoherent pointer, empty
  `player_home_port`, no base anchor); hidden-world (3 hidden ports hidden/ineligible/absent from
  `get_world_map`, one anchor + one docking service each, original five intact); RPC surface **exactly 16** +
  anon limited to `get_world_map`; the **13 internals service_role-only** + catalog tables locked down; **6/7
  function bodies + descriptors byte-identical** ref↔prod; and the public wrapper's explicit hosted-production
  **`service_role EXECUTE = true`** policy.

- **Verifier tooling PRs.** **PR #32** (merge `09f8ba6`→… on `main`) added the dispatch-only, production-gated,
  strictly read-only verifier. **PR #33** (merge `30e5a36`) was a **verifier-only correction**: the public
  wrapper is granted only `TO authenticated` in `0067`, so its `service_role EXECUTE` is governed by Supabase
  hosted DEFAULT PRIVILEGES (allowed) which the disposable reference does not reproduce; PR #33 replaced that
  accidental local-reference dependence with an **explicit, testable hosted-production `service_role EXECUTE =
  true` contract** (strict parity preserved for the body hash + args + lang + owner + SECDEF + search_path +
  anon/authenticated/PUBLIC, and full SRVX parity for the six internals). Both PRs were **verifier tooling
  only** — no migration, no production data/ACL change.

**NEXT:** the next product step (e.g. ENABLEMENT-1 / the OSN enablement preflight re-pin to head `0067` +
surface 16, the DOCK-0 perm allowlist update, then any controlled OSN flag-enable go/no-go) requires a
**separately approved charter**. None is started. OSN remains dark.

---

## 2026-06-23 — ANCHOR-2 P0-A census closed + PORT-CENTRIC direction (durable handoff; design/ops only)

Cross-computer handoff record. **No code/schema/migration/anchor/resolver/flag/production change** — this entry
makes the current direction recoverable from `main`.

**1. ANCHOR-2 P0-A census — CLOSED.** One authorized, production-Environment-gated, **read-only** count-only
census ran and succeeded — workflow `osn3-anchor2-p0a-homebase-census.yml`, **run `28061856879`**, source commit
**`a12743f4829782530fc05015af509135886f8bf3`**, one `BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY`
snapshot then **`ROLLBACK`** (no write). Result: `TOTAL_SHIPS=72`, `ELIGIBLE=72`, `UNRESOLVED=0`; the
one-ship-per-owner invariant held (`72 = DISTINCT_NON_NULL_SHIP_OWNER_IDS`); zero null-owner/orphan/no-base/
inactive-only/multi-base anomalies. This closes **only** the old-data ambiguity prerequisite (legacy base records
are clean). **The census must not be rerun without explicit authorization.**

**2. PORT-CENTRIC direction (supersedes the home-base P0 plan).** Byeharu is a **multi-port navigation world**,
not a permanent-main-base game. A ship's meaningful normal location is its **current docked port**. Normal loop:
`Dock at Port A → depart → travel/act → dock at Port B → depart from Port B`. The permanent
`main_ship_instances.home_base_id` / ship-to-owner-base P0 plan is **CANCELLED** (no FK / NOT NULL / backfill /
creation-path change). Legacy `bases` are **bootstrap / starter / registration / possible-recovery records only**,
never operational homes. "Return home" is **not** ordinary navigation; emergency recovery is separate future work.

**3. Technical boundary.** The existing dark `at_location` state (ship `spatial_state='at_location'` + the fleet's
`current_location_id` + an active `location_presence`) is the **proto current-dock model**. `space_anchors`
(migration 0063, empty/dark) remains the **future fixed-coordinate foundation**. Future port docking/departure must
resolve through **location identity + the eligible port's canonical `space_anchors` (kind='location') coordinate** —
not legacy `locations.x/y`. The current dark DOCK-0 exact-match against `locations.x/y` (migration 0061) is proto
behavior only and **remains unchanged**.

**4. Map-growth policy.** The open-space boundary stays **≈ `[-10000, 10000]²`** — a **temporary technical
frontier**, not a permanent world/lore edge; no final map size is chosen. Future expansion grows **outward** and
**preserves all existing coordinates** (do not remap/move existing ports, anchors, ships, or players); keep the
initial central region **dense** and reserve outer space for later. **No map-size expansion is authorized now.**

**5. Exact next project gate.** *Next work is a **port-centric product-decision packet**: port eligibility, dock
identity, legacy-base/recovery role, recovery model, anchor-seeding scope, and initial central-region layout
policy. No ANCHOR-2 implementation, anchor seeding, resolver change, map work, coordinate command work, migration,
or flag change is authorized before those decisions.*

Live baseline unchanged at this handoff: production migrations end at **0063**; `mainship_send_enabled=true`,
`mainship_space_movement_enabled=false`; OSN paused.

---

## 2026-06-23 — MSP-0: Main Ship Progression ↔ Movement integration contract (design only)

Read-only reconnaissance + integration contract answering where future main-ship progression stats must live
so the current named-location route and future OSN movement consume **one** server-calculated result. **No
code/migration/workflow/flag/branch change — design packet only.**

- **Speed-truth trace.** Both routes derive main-ship speed solely from `main_ship_hull_types.base_speed`
  (`starter_frigate=1.0`): legacy `send_main_ship_expedition`/`move_main_ship_to_location`/
  `request_main_ship_return` → `resolve_fleet_movement_speed` → `movement_create` (LIVE); OSN
  `mainship_space_begin_move` reads the hull inline + computes duration inline, with `resolve_fleet_movement_speed`
  only as an equality assert (DARK). Speed + `arrive_at` are snapshotted once at departure, never recomputed at
  arrival. Frontend submits **intent only** (no client speed/duration math; the one `previewTravelSeconds` is
  dead code).
- **Divergence to prevent (already nascent):** `calculate_expedition_stats` computes a support-craft speed
  penalty that live movement ignores.
- **Recommendation (Option B):** one private main-ship-keyed `mainship_effective_stats` resolver
  (`effective_travel_speed` first; empty loadout ≡ raw hull base ⇒ current behavior byte-for-byte unchanged)
  that both movement adapters consume. First slice = **module-first**, first effect = travel speed on the live
  named-location route. Phases MSP-0..MSP-4 defined; module/captain schema is greenfield (only integer
  `module_slots`/`captain_slots` counts exist today).

**No implementation started.** Flags unchanged (`mainship_send_enabled=true`, `mainship_space_movement_enabled=false`);
migrations end at **0063**. NEXT (needs approval): Option-B decision + **MSP-1** (additive, dark module-ownership
schema only). ANCHOR-2 / seeding / resolver extension / S6B-PRES / coordinate enablement remain deferred.

---

## 2026-06-23 — OSN-ANCHOR-1B: empty canonical-anchor schema (`space_anchors`) — DEPLOYED & CLOSED (flag OFF)

Additive, EMPTY, server-only canonical-anchor foundation (branch `osn3-anchor1b-space-anchors`, PR #18 merge
**`7264f12`**, migration **`0063`**). `public.space_anchors`: closed `kind ∈ {base,location}` with **exactly
one real typed owner FK** (`base_id`→`bases` ON DELETE CASCADE, `location_id`→`locations` ON DELETE RESTRICT;
no ownerless / all-null / polymorphic `(kind, owner_uuid)`); coords NOT NULL + finite + within `[-10000,10000]²`
(rejects NULL/NaN/±Inf/oob); partial-unique **one active anchor per base & per location** (no `(space_x,space_y)`
unique — intentional co-location stays possible); BEFORE-UPDATE immutability guard (SECURITY INVOKER,
`search_path=public`: active→retired only; kind/owner/x/y/created_at immutable; retired terminal; DELETE
unguarded so base CASCADE works); private RLS (no policy) + explicit revoke from public/anon/authenticated +
grant **service_role-only**.

**Seeds NOTHING; copies nothing from `bases.x/y`/`locations.x/y`; NOT read by `mainship_space_resolve_origin`
(resolver UNCHANGED → `home`/`at_location`/`legacy_*` still resolve `origin_not_anchored`); no flag/resolver/
docking/movement/UI change.** Proof: disposable real-chain `osn3-anchor1b-realchain-proof.yml` (all 17 points —
shape/types/RLS/indexes/checks/trigger, kinds/owners/coords/uniqueness/immutability, base-cascade, location-
restrict, ACL, resolver-unchanged; asserts table empty) + S1–S6A / DOCK-0 / ANCHOR-1A non-regression + Build,
all GREEN. (Three proofs first failed on a transient Docker-pull `502` at `supabase start` — proof step skipped,
not a defect — and reran green with no code change.)

**Deploy:** production-Environment-gated run **`28025760972`** (approved) applied exactly `0063` ("Finished
supabase db push"); remote migration history now ends **`20260618000063`** (no `0064+`). Live confirm: anon REST
`GET /space_anchors` → HTTP `401` `42501` permission-denied (table **exists** in prod, clients **denied**); flags
`mainship_send_enabled=true`, `mainship_space_movement_enabled=false`. **OSN is now PAUSED at this boundary.**
NEXT: **Main Ship Progression (MSP)** — not ANCHOR-2.

---

## 2026-06-23 — OSN-ANCHOR-1A: production catalog-parity verification — CLOSED

Verified the deployed truthful-origin resolver `mainship_space_resolve_origin` (migration `0062`) is
**byte-identical + semantically identical to source** in production, via a dedicated, strictly read-only
catalog-parity spotcheck. Built across two PRs: **#16 (`2b11f28`)** added the `osn3-anchor1a-catalog-spotcheck`
workflow + script capability; **#17 (`cb0219a`)** a CA-trust remediation after the first production run failed
`sslmode=verify-full` against the shared IPv4 pooler — pinned the official **Supabase Root 2021 CA**
(`scripts/supabase-prod-ca.crt`, cert SHA-256 `807025ad50d4ed219d2c9c7d299c004f824eb00cf7f65afef607d07b72e6cafa`)
+ used the **session pooler (port 5432)**; kept `verify-full`, **no TLS downgrade**.

Production verification run **`28022976137`** (workflow_dispatch on `main`, production gate approved) PASSED: raw
stored-body `prosrc` SHA-256 `7d4548e64e2fca60a944fe2875c0b8e3e381c85bb0960f14bb8670d71d6038b0` identical
reference-vs-production (exact, no normalization); 17-field descriptor parity identical; invariants OK
(plpgsql / owner=postgres / SECURITY DEFINER / `search_path=public` / service_role-only; anon/authenticated/PUBLIC
denied); remote migration history ends exactly `0062`; read-only gate proven before any catalog query; **no
production write**. Equality source = raw `p.prosrc` (version-stable), NOT `pg_get_functiondef`. Flags unchanged
(send=true, space=false). No resolver/data/flag change.

---

## 2026-06-22 — OSN-ANCHOR-1A: truthful-origin guard (dark) — DEPLOYED & CLOSED (flag OFF)

Migration **`0062`** (branch `osn3-anchor1a-truthful-origin`, PR #15 merge **`fb28481`**) re-creates
`mainship_space_resolve_origin(uuid)` (CREATE OR REPLACE; signature / SECURITY DEFINER / `search_path=public` /
service_role-only all preserved) so `home` / `legacy_home` / `at_location` / `legacy_present` now resolve
**`{ok:false, reason:'origin_not_anchored'}`** instead of reading legacy `bases.x/y` / `locations.x/y` as a
movement origin; `in_space` unchanged (origin = ship `space_x/space_y`); `in_transit`→`must_stop`;
`destroyed`→`destroyed`. Closes the proven defect of legacy dynamic-map coordinates leaking into OSN movement
origins. **NO anchor table, NO bases/locations column, NO seed/backfill, NO legacy fallback; both flags
untouched** (send=true, space=false).

Proof: real chain `0001..0062` (`osn3-anchor1a-realchain-proof.yml`) — the four legacy/home states →
`origin_not_anchored` (no movement / receipt / legacy-origin written); `in_space` success with origin == ship
coord; rejected-request idempotency; resolver ACL/security/signature parity; cross-domain / destruction / DOCK-0
non-regression. Deployed via production-gated run **`27988863386`**; production catalog-parity verification
followed separately (see the 2026-06-23 catalog-parity entry). Coordinate movement stays dark.

---

## 2026-06-22 — OSN-3 S6C: flag-dark empty-space coordinate command surface — CLOSED (flag OFF)

Frontend-only coordinate-move command path (branch `osn3-s6c-empty-space-coordinate-command`, PR #14 merge
**`9ce5567`**, **no migration / RPC / flag / server change**). Empty-space map tap → `screenToWorld` →
canonicalized target → existing S6A wrapper `command_main_ship_space_move(p_target_x, p_target_y, p_request_id)`.
Layered gating (feature flag `mainship_space_movement_enabled` read once; eligibility; controls/crosshair mount
only when enabled + within bounds; tap qualifies only on empty SVG) → **production-dark**: flag false ⇒ wrapper
returns `feature_disabled` and writes nothing. The client submits **intent only** (target coords + `request_id`);
never a speed/duration/stat/ship-id. Build green; flags unchanged (send=true, space=false). NEXT then was the
S6B presentation foundation + ANCHOR truthful-origin work.

---

## 2026-06-22 — OSN-3 S6B: fixed-space frontend coordinate foundation — CLOSED (flag OFF, read-only)

S6B closes the **read-only frontend coordinate-rendering foundation** for open space across four merged
sub-slices. It is **not** a player-enabled movement feature: coordinate movement remains **production-dark**
(`mainship_space_movement_enabled=false`; `mainship_send_enabled=true`), there is **no player command path,
tap selection, selected-target persistence, or coordinate-movement enablement**, and **no migration / RPC /
flag / server change** in any S6B slice (migrations remain through **0060**).

- **S6B1** (merge `586d67c`) — `src/features/map/openSpaceTransform.ts`: a **pure** fixed-domain transform —
  `worldToViewBox`/`viewBoxToWorld` over `[-10000,10000]→[0,1000]` (explicit Y-inversion), `worldToScreen`/
  `screenToWorld` (camera + `preserveAspectRatio` letterbox), and a **separate** `isWithinOpenSpaceBounds`
  predicate (no hidden clamping; conversions never validate). Verifier `verify:osn:s6b`.
- **S6B2** (merge `f7974ac`) — a **mandatory discriminated** `coordinateSpace: 'legacy_dynamic' |
  'open_space_fixed'` on the resolved `ShipMarker`; the ship's open-space states (`in_space`, coordinate
  `in_transit`) route through the fixed transform while legacy/named states keep `buildNormalizer`.
  Exhaustive switch + `never` guard, no silent legacy fallback. Verifier `verify:osn:resolver`.
- **S6B3** (merge `e2de473`) — a **development-only**, non-interactive fixed-space preview
  (`DevFixedSpacePreview`), gated **solely** by `import.meta.env.DEV` and **compile-time eliminated** from
  the production bundle — proven by `vite build` + a `dist/` grep showing the `s6b3-dev-preview` sentinel
  and the component are **absent** (true removal, not runtime hiding). `pointerEvents:none`, `aria-hidden`,
  minimal hollow ring/crosshair. Verifier `verify-s6b3`.
- **S6B4** (merge `adc7009`) — behavior-preserving extraction of `MainShipMarker`'s routing into a pure
  exported `markerViewBoxPoint(marker, norm)` that **the component and the tests both call** (no duplicate);
  proves a **resolved** `open_space_fixed` marker is projected through `worldToViewBox` (the dynamic `norm`
  is **never** called) and that the preview + a distinct fixed-space ship point **co-move** under the camera
  (screen Δ = letterbox·zoom × viewBox Δ across zoom 0.4/1/2/8 × zero/nonzero pan × square/wide/tall/mobile
  viewports; pure geometry, no comparison to dynamic named-location coords). Verifiers `verify:osn:resolver`
  + `verify:osn:s6b`.

**Acceptance (all green):** `verify:osn:s6b` (transform) · `verify:osn:resolver` (provenance + S6B4 routing)
· `verify-s6b3` (dev preview + production-elimination) · `build` (tsc -b + vite build) · post-merge **Build +
Pages** deploy. On production data the ship marker is always `legacy_dynamic` (open-space states are dark)
and the dev preview is absent → **zero production visual change**.

**Explicitly NOT done / still pending.** Fixed-space markers and legacy named locations are **not yet an
approved co-registered presentation**. **S6B-PRES is mandatory before any S6D enablement** — it must
charter, implement, and prove **either** named locations rendered through a verified fixed-domain transform
**or** a distinct coordinate-navigation map mode where legacy dynamic markers are hidden/non-spatial. No
tap/`mapToWorld` wiring (S6C), no command/CTA/RPC, no flag flip.

**NEXT:** OSN-3 **S6B-PRES** reconnaissance — the fixed-space ↔ named-location presentation decision (the
mandatory pre-S6D gate). S6C input wiring must **not** precede that decision.

---

## 2026-06-21 — OSN-3 S6A: public coordinate-command boundary (flag-dark) — CLOSED (flag OFF)

First **player-facing** coordinate-movement command surface (branch `osn3-s6a-public-space-move-command`,
no-ff merge **`ac9230a`**, code commit `581dea9`, migration **`0060`**). A narrow, **authenticated**,
SECURITY DEFINER wrapper **`command_main_ship_space_move(p_target_x, p_target_y, p_request_id)`** that
derives the caller from `auth.uid()`, derives the caller's **own** main ship server-side (**no client
player/ship id**), defense-in-depth flag-gates, **canonicalizes** the target to the integer world-unit
grid (`round(numeric)` — half **away from zero**, deterministic; non-finite rejected before the cast;
bounds remain the writer's authority, so a raw value with `|canonical| ≤ 10000` snaps inward and is
accepted), **DELEGATES** to the existing private writer `mainship_space_begin_move`, and **maps** the
result to a narrow player-safe payload. Canonicalization is a discrete-grid concern only — **`p_request_id`
remains the idempotency key**. The private writer stays the **final authority** on flag/ownership/bounds/
state/exclusion/travel-cap/locking/idempotency/movement-creation and remains **service_role-only** (the
client never gains it; the definer-owner `postgres` invokes it). **NO writer/processor/S2/S5 change, NO
new table/cron, NO flag flip, NO UI/CTA.**

**Dark in production:** `mainship_space_movement_enabled` stays **false**, so the wrapper returns
`feature_disabled` and writes nothing → **net player-visible effect: none**. `mainship_send_enabled` stays
**true**; legacy named-location travel is untouched and **mutually exclusive** with coordinate movement
(proven both directions: a coordinate-domain ship rejects legacy send/move by precondition; a legacy-busy
ship rejects the coordinate command via cross-domain exclusion; the fleet `active_movement_id` XOR
`active_space_movement_id` holds).

Also: sibling dev flag tool **`dev-mainship-space-movement-flag.mjs`** (+ workflow) for the coordinate flag
(legacy send-flag tool untouched; **not** run against prod in S6A); **`fetchMainshipSpaceMovementEnabled()`**
typed read in `src/lib/catalog.ts` (no UI wiring — an S6B seed). The migration re-locks the execute surface
(canonical client RPCs **+ the new wrapper**; writer/processor/destruction/S2 helpers stay service_role-only).

**Authoritative proof (real chain `0001..0060`, disposable Supabase; `osn3-s6a-realchain-proof.yml`).**
GREEN: permission/boundary (wrapper authenticated-only, owner postgres / SECURITY DEFINER / search_path
public / no dynamic SQL / no player-or-ship param; private writer + S4 + S5 + four S2 helpers
service_role-only; canonical client-RPC inventory = prior 13 **+** the wrapper); runtime **SET ROLE** (anon
denied / authenticated allowed on the wrapper; writer client-denied, service_role-allowed); fixture matrix
(dark→`feature_disabled` + no write; success from home/in_space/at_location; canonicalization
half-away-from-zero + near-edge inward snap + `out_of_bounds`/non-finite reject; `zero_distance`;
idempotency exact **and** equivalent-canonical replay + `request_conflict` + no duplicate; state matrix
`in_transit→must_stop_first` / `destroyed→ship_destroyed` / legacy-busy`→busy_legacy`; legacy↔coordinate
mutual exclusion both directions + fleet pointer XOR); REST boundary (private writer rejected for anon **and**
authenticated; wrapper reachable for authenticated but dark → `feature_disabled`, no movement). Flags
restored `if: always()`.

**Gates (all green):** S6A real-chain proof; **S1–S5 real-chain regression**; Build (`tsc -b` + `vite
build`); `deploy-migrations` (live `db push` of 0060); post-deploy integration **Verify**; live legacy
regressions `verify-mainship-send` (send **+ return/recall**), `verify-mainship-move`,
`verify-mainship-repair`. **Live read-only spot check** (`osn3-s6a-live-spotcheck.yml`): 0060 applied;
wrapper present **authenticated-only**; private engine **service_role-only**; canonical inventory intact;
one S4 arrival cron @30s; `mainship_send_enabled=true`, `mainship_space_movement_enabled=false`, cap=86400;
`main_ship_space_movements=0`, `command_receipts=0` — **no game-state mutation by the deploy**. (An earlier
batch of live runs was **cancelled** by the shared `live-db-tests` concurrency group — a workflow-concurrency
incident, not a test failure; each was re-run serially to a real `success`.)

**NEXT (not started, needs approval):** OSN-3 **S6B** — the fixed-domain paired coordinate transform
(`worldToMap`/`mapToWorld` over `[-10000,10000]`, Y-inverting, pan/zoom-aware) **+ a read-only target
preview**, still flag-off. No map tap/CTA until S6C; no enablement until S6D; OSN-4 Stop remains deferred.

---

## 2026-06-21 — OSN-3 S5: coordinate-complete trusted destruction primitive — CLOSED (flag OFF)

Fifth **OSN-3** slice (branch `osn3-s5-destruction-hardening`, approved head `a7ab585`, normal **no-ff**
merge **`0d84256`**, migration **`0059`**; final `main == origin/main == fda8778` after a read-only
live-spot-check tooling commit). **Narrow hardening only — NO public RPC, NO UI, NO new processor/cron,
NO Return/Stop, NO generic reconciliation, NO flag change.** Both flags untouched (`mainship_send_enabled`
stays **true**, `mainship_space_movement_enabled` stays **false**).

**The defect S5 fixes.** `dev_set_main_ship_destroyed(p_player uuid)` — the **unique** trusted main-ship
destruction writer (audited: the only fn that sets `main_ship_instances.status='destroyed'`/`hp=0`;
combat destroys legacy unit-fleets via `fleet_destroy`, never main ships; `repair_main_ship` only
recovers) — predated the coordinate domain and therefore could **not** destroy a ship in a valid
coordinate state without violating a coordinate constraint (`in_transit` left
`fleets.active_space_movement_id` set → violates `fleets_active_space_movement_requires_moving`;
`in_space`/`at_location` left a non-null `spatial_state` → violates the `…_ss_*_status` CHECKs). Latent
(service_role-only path; coordinate movement dark), but closed before coordinate movement is ever enabled.

**Migration 0059** re-creates **only** `dev_set_main_ship_destroyed` (same signature, `SECURITY DEFINER`,
owner `postgres`, `search_path=public`, **service_role-only**, no player wrapper, no new cron). It:
acquires `mainship_space_lock_context(id,false)` first (canonical order; never locks `fleet_movements`);
requires `validate_context` ok — **any generic contradiction ABORTS atomically with all rows unchanged**;
for a coherent `in_transit` cancels the active coordinate movement → `status='cancelled'`,
`terminal_reason='ship_destroyed'`, `resolved_at` (history preserved); clears `active_space_movement_id`;
preserves the existing legacy cleanup; and sets the ship `destroyed`/`hp=0`/**`spatial_state=NULL`**/
`space_x`/`space_y` NULL (NULL — not `'destroyed'` — so `repair_main_ship`, which sets `status='home'`
without resetting `spatial_state`, stays valid → a repaired ship is a clean `legacy_home`). The S3 command
receipt is immutable; no history deletion. `repair_main_ship`, the S4 processor, the S3 writer, the S2
helpers, and all legacy writers are untouched; migrations `0052/0055/0056/0057/0058` are untouched.

**Authoritative proof (real chain `0001..0059`, disposable Supabase; `osn3-s5-realchain-proof.yml`).**
GREEN at `a7ab585`: coherent destruction of `in_transit` (movement→cancelled/ship_destroyed, receipt
immutable), `in_space`, `at_location`, and preserved `legacy_present`; idempotent repeated destruction;
**real `repair_main_ship` after destruction → clean `legacy_home`** with no coordinate residue; the full
contradiction-abort matrix (active legacy movement, unexpected presence, pointer/ownership mismatch,
multiple fleets, in_transit-without-movement, destroyed-plus-moving) each non-mutating; real
concurrent-session races (arrival-wins-then-destroy-clears-`in_space`; destruction-wins-arrival-never-
settles-cancelled; two destructions race → one terminal, second idempotent); runtime ACL + SET ROLE
denial; REST/RPC denial of the primitive + processor + writer + S2 helpers for anon and a real
authenticated JWT. *Root-cause note:* the first run was red only on a **proof-harness** transaction
defect (concurrency sessB ran destruction in autocommit, never observed idle-in-transaction); fixed by
holding sessB's destruction in a txn — **the migration/primitive needed no change** (no `0060`).

**Gates (all green at `a7ab585`):** S5 real-chain proof; S1/S2/S3/S4 real-chain regression; the Build
gate via draft PR #3 (`npm ci`, lint, `tsc -b`, `vite build`); `verify:osn:resolver`; the legacy-send
read-only verifier. **Live read-only spot check** (`osn3-s5-live-spotcheck.yml`, post-deploy): 0059
applied; primitive present with the approved signature (`p_player uuid`), owner=postgres, SECURITY
DEFINER, search_path=public, no dynamic SQL, no player wrapper, service_role-only; canonical client-RPC
inventory unchanged; `repair_main_ship` still authenticated-executable; S2 helpers + S3 writer + S4
processor non-client-executable; exactly one S4 arrival cron @ `30 seconds` (cadence unchanged);
`mainship_send_enabled=true`, `mainship_space_movement_enabled=false`, `max_coordinate_travel_seconds=86400`;
`main_ship_space_movements=0`, `main_ship_space_command_receipts=0` — no game-state mutation by the deploy
or verification.

**Scope confirmation.** S5 added **no** player coordinate RPC, UI, processor/cron, Return, Stop, generic
reconciliation, history cleanup/retention, legacy-writer change, `repair_main_ship` change, S2/S3/S4
helper change, or feature enablement. The internal coordinate lifecycle is now complete and dark:
**departure (S3) → arrival settlement (S4) → parked `in_space` → coordinate-complete destruction (S5)**.
**NEXT (not started, awaiting a separate explicit charter):** a PC-first coordinate command/map surface
(public wrapper + UI, gated by `mainship_space_movement_enabled`), then **OSN-4 Stop**.

---

## 2026-06-21 — OSN-3 S4: coordinate-arrival processor — CLOSED (flag OFF)

Fourth **OSN-3** slice (branch `osn3-s4-arrival-processor`, approved head `33588e2`, normal **no-ff**
merge **`6b1a88e`**, migration **`0058`**; final `main == origin/main == 6b1a88e`). **One private,
server-only background PROCESSOR — still NO public RPC, NO UI, NO Return/Stop, NO feature enablement,
NO reconciliation/destruction.** `mainship_space_movement_enabled` stays **false** (the processor does
not gate on it); `mainship_send_enabled` stays **true** (untouched legacy path).

**Migration 0058 — `public.process_mainship_space_arrivals() returns integer`.** One `SECURITY DEFINER`,
owner `postgres`, `search_path=public`, **service_role-only** processor (PUBLIC/anon/authenticated
revoked; no player wrapper), driven by a **pg_cron** job `process-mainship-space-arrivals` at the
established **`30 seconds`** cadence (`command = select public.process_mainship_space_arrivals();`,
idempotent unschedule-by-name). It settles each due, still-coherent S3 coordinate movement **exactly
once**: non-locking candidate scan (`status='moving' and arrive_at<=now()`, `ORDER BY arrive_at,id LIMIT
100`) → per ship `mainship_space_lock_context(id, true)` skip-locked (S2 canonical order ship → fleet →
coordinate-movement → presence; never locks legacy `fleet_movements`) → `validate_context` must be
`in_transit` → `assert_cross_domain_exclusion` → re-confirm under lock → atomic settlement.

- **Arrival transition:** movement **`moving → arrived`** (`resolved_at=now()`,
  `terminal_reason='auto_arrival'`; immutable origin/target/speed/time history preserved); fleet
  **`moving → completed`** with `location_mode='movement'` and `active_space_movement_id` /
  `active_movement_id` / `current_*` cleared (truthful open-space terminal — verified legal once the
  space pointer is NULL; no base field set, `fleet_complete()` not used); ship **`traveling`/`in_transit`
  → `stationary`/`in_space`** at the movement's `target_x`/`target_y`.
- **Terminal history preserved** (the `arrived` row stays; existing FK CASCADE cleans it only on
  owner/ship deletion — no retention/cleanup job added). The S3 creation receipt is immutable; S4 writes
  no receipt and creates/leaves no `location_presence`.
- **Contradiction policy (frozen):** every contradiction / malformed / destroyed / legacy-conflict /
  presence-conflict / pointer-mismatch / ownership-mismatch / not-due / already-terminal case is left
  **untouched** with a concise log (no settle/fail/repair/normalize/delete; hardening deferred to S5).
- **Flag rule:** the processor never reads `mainship_space_movement_enabled` (so disabling it can't
  strand in-transit ships) and never touches `mainship_send_enabled`.

**Authoritative proof (real chain `0001..0058`, disposable Supabase; `osn3-s4-realchain-proof.yml`).**
GREEN at `33588e2`: due settles exactly once; not-yet-due stays moving; second call settles 0
(idempotent); two concurrent processors settle once (loser skip-locked); skip-locked ship skipped then
settles; settlement proceeds with the space flag FALSE; full arrival-state assertions (movement
arrived/`auto_arrival`/`resolved`, ship `stationary`/`in_space` at exact target, fleet `completed`/
`movement` with pointers+base cleared, no presence, no legacy mv, S2 `validate_context`=`in_space`, S3
receipt unchanged, terminal history present); the seven contradiction cases each proven non-mutating
(per-ship state hash) as real due candidates; runtime ACL + SET ROLE denial; REST/RPC denial of the
processor + writer + S2 helpers for anon and a real authenticated JWT; cron asserted present once @30s;
cleanup + flags/cap/cron restored & asserted. *Root-cause note:* the first proof run was red on a
**fixture** timestamp assumption only (transaction-scoped `now()` made `arrive_at < depart_at`),
corrected by moving both timestamps into the past + asserting every fixture's precondition; **the
processor/0058 needed no change** (no `0059`).

**Gates (all green at `33588e2`):** S4 real-chain proof; S1/S2/S3 real-chain regression; the Build gate
via draft PR #2 (`npm ci`, lint, `tsc -b`, `vite build`); `verify:osn:resolver`; the legacy-send
read-only activation verifier. **Live read-only spot check** (`osn3-s4-live-spotcheck.yml`, post-deploy):
0058 applied; processor present with the approved signature (no args), owner=postgres, SECURITY DEFINER,
search_path=public, no dynamic SQL, no player wrapper, service_role-only (anon/authenticated/PUBLIC
denied); S3 writer + four S2 helpers service_role-only; canonical client-RPC inventory unchanged;
anon/authenticated cannot CREATE in `public`; **exactly one** cron job `process-mainship-space-arrivals`
@ `30 seconds` (no duplicate); `mainship_send_enabled=true`, `mainship_space_movement_enabled=false`,
`max_coordinate_travel_seconds=86400`; **`main_ship_space_movements`=0 and
`main_ship_space_command_receipts`=0** — live deployment created zero coordinate movements and zero
receipts; no game-state side effect (a natural cron tick that finds zero due movements is harmless).

**Scope confirmation.** S4 added **no** player coordinate RPC, UI, Return, Stop, reconciliation/auto-
repair, destruction/repair behavior, history cleanup/retention, legacy-writer/processor change, S2/S3
helper change, or feature enablement. `mainship_send_enabled=true` remains the temporary playable legacy
named-location path; `mainship_space_movement_enabled=false` remains dark. **NEXT (not started, awaiting
a separate explicit S5 charter):** reconciler / destruction hardening (S5) → target UI (S7) → a public
player wrapper for the writer → **OSN-4 Stop** (S8).

---

## 2026-06-21 — Legacy main-ship send: controlled production activation (config-only, reversible)

Enabled the **already-built legacy named-location** main-ship travel path on live by flipping **one**
game-config key via the established controlled workflow `dev-mainship-flag.yml` →
`scripts/dev-mainship-flag.mjs --enabled true` (writes only `mainship_send_enabled` via the owned
`set_game_config`). **No migration, no code/UI change, no fixtures, no test users, no writer execution.**

**Target/result live config:** `mainship_send_enabled = true`, **`mainship_space_movement_enabled =
false`** (untouched), `max_coordinate_travel_seconds = 86400` (untouched). The activation script logged
`Before: false → After: true`.

**Read-only preflight** (`osn3-s3-live-spotcheck`, run `27899732391`): confirmed the pre-state —
send=false, space=false, cap=86400, `main_ship_space_movements`=0, `main_ship_space_command_receipts`=0,
S3 writer + four S2 helpers service_role-only, canonical client-RPC inventory unchanged. **Read-only
post-activation verification** (`osn3-legacy-send-activation-check`, run `27899841147`): confirmed
send=true, space_movement=false, cap=86400, `main_ship_space_movements`=0, `command_receipts`=0, and
that `mainship_space_begin_move` + the four S2 helpers remain **service_role-only / non-client-executable**
with the canonical client-RPC inventory unchanged and `public`-schema CREATE denied to anon/authenticated.

**What this does / does not do.** It re-exposes only the **legacy named-location** player capability
(`send_main_ship_expedition` base→location, `move_main_ship_to_location` location→location, plus the
always-available recovery paths `request_main_ship_return` and `repair_main_ship`). It does **not**
enable coordinate movement or any OSN player command: the S3 coordinate writer stays service_role-only
and flag-dark (`mainship_space_movement_enabled=false`), no coordinate UI/command surface exists, and no
coordinate movement or command receipt was created (both counts remain 0). No game-state row was created
or modified by the activation. **Rollback** is the same controlled workflow with
`mainship_send_enabled=false` (single-key, instant, no migration). **S4 has not started.**

---

## 2026-06-21 — OSN-3 S3: first internal coordinate-movement writer — CLOSED (flag OFF)

Third **OSN-3** slice (branch `osn3-s3-begin-move-writer`, approved head `e267eee`, normal **no-ff**
merge **`f4ba07e`**, migration **`0057`**; final `main == origin/main == f4ba07e`). **One private,
server-only WRITER — still NO public RPC, NO UI, NO processor, NO arrival/Return/Stop, NO feature
enablement.** Both flags stay false on live.

**Migration 0057 — `public.mainship_space_begin_move(p_player uuid, p_main_ship_id uuid, p_target_x
double precision, p_target_y double precision, p_request_id uuid) returns jsonb`.** One `SECURITY
DEFINER`, owner `postgres`, `search_path=public`, **service_role-only** function (PUBLIC/anon/
authenticated revoked) that composes the deployed S2 boundary — `mainship_space_lock_context` →
`mainship_space_validate_context` → `mainship_space_assert_cross_domain_exclusion` →
`mainship_space_resolve_origin` — to begin exactly one coordinate move. Hard-gated on
`mainship_space_movement_enabled` (stays false); `mainship_send_enabled` untouched. Adds one additive
non-flag guard `max_coordinate_travel_seconds=86400` (the `[-10000,10000]²` envelope is the distance
bound; no `MAX_COORDINATE_MOVE_DISTANCE`).

- **Supported stationary origins:** `home`/`legacy_home`/`in_space` (materialise a new main-ship fleet
  in-txn) and `at_location`/`legacy_present` (reuse the present fleet, closing its active presence).
  **Space-only target contract** (`target_kind='space'` + `p_target_x`/`p_target_y` + `p_request_id`);
  the client never supplies origin/player/ownership/state/fleet/speed/ETA/status or screen coords.
- **One atomic transaction, canonical S2 lock order** (ship → fleet → coordinate-movement → presence);
  never locks legacy `fleet_movements`; never calls a frozen legacy writer. Creates one `moving`
  `main_ship_space_movements` row + coherent fleet pointer (`active_space_movement_id`, legacy
  `active_movement_id` stays NULL) + ship `traveling`/`in_transit` + finalised idempotency receipt.
- **Idempotency** via `main_ship_space_command_receipts (main_ship_id, request_id)`: same id + same
  canonical payload hash → replays the committed `result_json`; same id + changed payload →
  `request_id_payload_conflict`; rejections write no receipt.
- **Validate-before-mutate:** every admission rejection (incl. `travel_time_exceeds_limit`) returns
  `{ok:false,reason}` *before* any write — no rejection leaves an orphan fleet/movement/ship/presence/
  receipt; only a genuine integrity fault raises and rolls back.

**Authoritative proof (real chain `0001..0057`, disposable Supabase; `osn3-s3-realchain-proof.yml`).**
GREEN at `e267eee`: positives from all five origins (each asserting `movement.origin == resolved
origin`, `speed_used == resolve_fleet_movement_speed(fleet)`, coherent fleet/ship/receipt, presence
closed once); the full rejection matrix each proven non-mutating; idempotent replay + payload conflict;
real concurrent-session races (two distinct → one move, loser rejects after revalidation; two
same-request retries → identical committed receipt); `travel_time_exceeds_limit` with explicit
no-effect; runtime ACL + SET ROLE denial; REST/RPC denial of the writer + S2 helpers for anon and a
real authenticated JWT; cleanup + flags/cap restored & asserted. *Root-cause note:* the first proof run
was red on a **fixture** assumption only (the real chain auto-provisions a Home Base at (0,0) via
`initialize_new_player`, so the zero-distance fixture's hard-coded target was wrong) — corrected by
deriving every origin from `mainship_space_resolve_origin`; **the writer/0057 needed no change** (no
`0058`).

**Gates (all green at `e267eee`):** S3 real-chain proof; S1 trigger/FK + S2 real-chain regression; the
Build gate via draft PR #1 (`npm ci`, lint, `tsc -b`, `vite build`); `verify:osn:resolver` (resolver
unit suite). **Live read-only spot check** (`osn3-s3-live-spotcheck.yml`, post-deploy): 0057 applied;
writer present with the exact approved signature, owner=postgres, SECURITY DEFINER, search_path=public,
no dynamic SQL, `acl={postgres,service_role}` (anon/authenticated/PUBLIC denied); four S2 helpers
service_role-only; canonical client-RPC inventory unchanged; anon/authenticated cannot CREATE in
`public`; `mainship_send_enabled=false`, `mainship_space_movement_enabled=false`,
`max_coordinate_travel_seconds=86400`; **`main_ship_space_movements`=0 and
`main_ship_space_command_receipts`=0** — no coordinate movement created live, no game-state side effect.
No fixtures/users/movements/receipts created by the deployment.

**Scope confirmation.** S3 added **no** public player RPC, UI, processor/cron, arrival settlement,
Return, Stop, reconciler, repair/destruction, legacy-writer change, S2-helper change, or feature
enablement. **NEXT (not started, awaiting a separate explicit S4 charter):** arrival processor (S4) →
reconciler/destruction hardening (S5) → target UI (S7) → OSN-4 Stop (S8).

---

## 2026-06-21 — OSN-3 S2: internal transition boundary + validation core — CLOSED (flag OFF)

Second **OSN-3** slice (branch `osn3-s2-transition-core`, approved head `1f2c45d`, normal **no-ff** merge
`93cb977`, migration `0056`). **Private, server-only transition boundary — NO movement writer, NO
processor, NO Stop, NO UI, NO public RPC, NO flag change.** Current `main == origin/main == a38247f`
(the four commits after `93cb977` changed **only** read-only live-verification tooling:
`.github/workflows/osn3-s2-live-spotcheck.yml`, `scripts/osn3-s2-live-spotcheck.sh`,
`scripts/osn3-s2-live-inspect.sql`). No history rewrite / force-push / rebase / squash / reset.

**Migration 0056 — four `SECURITY DEFINER` helpers (server-only), the locking/validation core for the
future coordinate-move writer (S3+):**
- `public.mainship_space_lock_context(uuid, boolean)` — acquires per-ship locks in the canonical order
  `main_ship_instances → fleets → main_ship_space_movements → location_presence`; never locks legacy
  `fleet_movements` (non-locking `EXISTS` read only); `boolean` = skip-lock (`FOR UPDATE SKIP LOCKED`
  at the ship row → returns `skipped` with no downstream locks).
- `public.mainship_space_validate_context(uuid)` — validates the full ship/fleet/pointer/presence state.
- `public.mainship_space_resolve_origin(uuid)` — resolves the move origin from current authoritative state.
- `public.mainship_space_assert_cross_domain_exclusion(uuid)` — enforces the legacy/coordinate domain
  mutual exclusion.
All are owned by `postgres`, `set search_path = public`, and relocked so `PUBLIC`/`anon`/`authenticated`
have **no** EXECUTE; `service_role` only. None is exposed as a player-facing PostgREST/RPC function. The
canonical client-RPC grants survived the relock intact; `anon`/`authenticated` cannot CREATE in `public`.

**Authoritative proof (real migration chain, off the shared DB).** A disposable local Supabase stack
applied the actual chain `0001..0056` (`osn3-s2-realchain-proof.yml`). Real concurrent psql sessions
(FIFO-driven, `pg_stat_activity` wait-state + `FOR UPDATE NOWAIT` probes) proved the runtime lock
sequence stage-by-stage (`osn3-s2-realchain-lockorder.sh`), plus blocking vs. skip-lock behavior, the
legacy `fleet_movements` non-locking path, valid/contradictory state fixtures, cross-domain exclusions,
ownership/pointer/presence mismatches, origin resolution, no-mutation (md5 before/after), fixture
cleanup, and runtime REST/RPC denial under `anon`/`authenticated` (`osn3-s2-realchain-perm.sql`,
`-fixtures.sql`, `-rest.sh`). The earlier reduced `postgres:15` stub proof
(`osn3-s2-transition-proof.yml`) is demoted to **supplementary / non-gating**.

**Live read-only spot check (`osn3-s2-live-spotcheck.yml`, run passed).** Method = `migration list` +
`db dump` (corroboration) + an **authoritative direct catalog query** (pure `SELECT`s over
`pg_catalog`/`game_config` + one `count`, via the Supabase pooler `aws-1-ap-southeast-1`) + REST reads.
Confirmed on live: `0056` applied; all four helpers present with approved signatures, `owner=postgres`,
`prosecdef=t`, `search_path=public`, `acl={postgres,service_role}` (no PUBLIC/anon/authenticated EXECUTE);
canonical 13-RPC inventory preserved; `anon` keeps `get_world_map`; no helper authenticated-executable;
schema CREATE denied to client roles; **`mainship_send_enabled=false`**, **`mainship_space_movement_enabled=false`**;
**`main_ship_space_movements` row count = 0**. *Note:* `supabase db dump` is `--no-owner` and lossy for
privileges, so owner/ACL facts come from the direct catalog query (authoritative); the dump only
corroborates presence/`SECURITY DEFINER`/`search_path`. No test users, fixtures, game-state rows,
coordinate movements, or flag changes were created during deployment or verification — strictly read-only.

**Scope confirmation.** S2 added **no** coordinate-movement writer, no coordinate return, no arrival
settlement, no processor/cron, no Stop, no target UI, no public movement RPC, no public grant, no
reconciler, no repair/destruction change, no legacy-writer change, no feature enablement, no frontend
change. **NEXT (not started, awaiting a separate explicit S3 charter):** begin-move RPC (S3) → arrival
processor (S4) → reconciler/destruction hardening (S5) → target UI (S7) → OSN-4 Stop (S8).

---

## 2026-06-21 — OSN-3 S1: coordinate-domain schema + invariants + read-model — CLOSED (flag OFF)

First **OSN-3** implementation slice (merge commit `90637d6`, branch `osn3-s1-schema-read`, migration
`0055`). **Schema + read-model only — NO movement writers, NO processor, NO UI, NO Stop.** Both flags
stay false (`mainship_send_enabled`, new `mainship_space_movement_enabled`). Builds on OSN-2 (the
durable open-space position model). Five design gates (A → A3.2) preceded it; all blockers resolved.

**Mandatory preflight (proven before deploy).** A disposable `postgres:15` CI container
(`scripts/osn3-s1-trigger-proof.sql` + `osn3-s1-schema-proof.sql`, workflow `osn3-s1-trigger-proof.yml`)
proved, on the real engine but off the shared DB: the `fleets.main_ship_id` **write-once** trigger
(rejects reassignment / late-attach / ordinary detach), that `ON DELETE SET NULL` fires **after** the
parent ship row is gone (so the trigger permits parent-deletion orphaning and existing user/ship
hard-delete cleanup keeps working), and the full §5.1 constraint matrix. *Bug found by the proof:* the
cyclic `fleets ⇄ main_ship_space_movements` FK graph tripped a constraint mid-cascade on a direct ship
delete → fixed by making `fleets.active_space_movement_id` FK **`DEFERRABLE INITIALLY DEFERRED`**.

**Migration 0055 (additive, transactional).**
- `main_ship_space_movements` — the coordinate route engine, **separate** from frozen `fleet_movements`
  so `process_fleet_movements` can never claim it. `target_kind` ∈ space|location|base with an explicit
  id-iff-kind CHECK; all coords finite + within `[-10000,10000]²`; `speed_used` finite>0; `arrive>depart`;
  status/`resolved_at` integrity; one-active partial-uniques per ship & per fleet; due-arrival index;
  owner-read RLS, no client write; FKs cascade on ship/fleet/user.
- `fleets.active_space_movement_id` (+ FK DEFERRABLE) — the honest moving-fleet pointer; mutual-exclusion
  with `active_movement_id` + requires-moving/movement CHECKs; one-fleet-per-movement unique.
- `main_ship_space_command_receipts` — `UNIQUE(main_ship_id,request_id)` + `canonical_payload_hash`;
  RLS on, **no** client read/write (server-only).
- `main_ship_instances.status += 'stationary'` + six legacy-safe forward lifecycle CHECKs (the reverse
  `stationary` rule uses `… IS TRUE` to reject `stationary`+NULL). No reverse rules for legacy statuses;
  no back-fill (existing rows stay `spatial_state=NULL`).
- write-once `fleets.main_ship_id` trigger; `mainship_space_movement_enabled=false`; execute relock.

**Read-model (the SINGLE resolver, extended — no second resolver).** `resolveMainShipMarker` now reads
the already-deployed coordinate states: `in_transit` (interpolate the active `main_ship_space_movements`
row, fully validated against ship/fleet/pointer/timestamps/presence), `at_location` (validated present
fleet + matching active presence), and `home` (base, no active state). Legacy `NULL` behavior unchanged;
any contradiction → `null`. A new owner-read fetch of the active coordinate movement runs inside the
existing 4s poll; the fleet read gains `location_mode`/`active_movement_id`/`active_space_movement_id`.

**Verification (all green via CI; local toolchain unusable).** Disposable trigger+schema proofs ✓;
branch closure (`npm run lint` + `tsc -b` + `vite build` + resolver unit tests **32/32**) ✓; migration
deploy ✓; phase8 engine regression ✓; live `verify:osn3:s1` **13/13** (both flags false, RLS owner-read,
client writes denied, receipts unreadable, write-once trigger live, **0 coordinate rows**) ✓; live
`spatial_state` distribution **56/56 NULL**. No writer/processor/UI/reconciler/repair/legacy change.
**NEXT (not started):** shared transition boundary → begin-move RPC (S3) → arrival processor (S4) →
reconciler/destruction hardening (S5) → target UI (S7) → OSN-4 Stop (S8). `MAX_COORDINATE_MOVE_DISTANCE`
/ `MAX_COORDINATE_TRAVEL_SECONDS` and the emergency processor-pause contract are deferred to those slices.

---

## 2026-06-21 — OSN-1 / OSN-2a / OSN-2b (Open-Space Navigation, read side) — CLOSED

Cross-cutting **Open-Space Navigation (OSN)** initiative (see `MAINSHIP_TRANSITION.md` §12). These
stages add the main ship's single position model and a durable open-space coordinate — **read/schema
only, no movement writers yet**. `mainship_send_enabled` stays **false**; engine + legacy paths frozen.
(Builds on the earlier, separately-recorded main-ship transition 10C–10H + direct A→B move, which live
in `MAINSHIP_TRANSITION.md` §7 rather than this log.)

**OSN-1 — read-only main-ship map marker (commit `727388f`).** New pure resolver
`src/features/map/resolveMainShipMarker.ts` (single source of main-ship display position: home→base,
present→location, moving/returning→interpolate active movement clamp 0..1, destroyed→null,
in-flight-without-movement→null no-teleport) + `MainShipMarker.tsx` (pointer-transparent, 1s tick only
while moving) + Playwright unit test. Flag-gated; camera/command paths untouched.

**OSN-2a — durable open-space position SCHEMA (commits `1f844e9`, `9534319`; migration `0054`).** Added
nullable-no-default `main_ship_instances.spatial_state` + `space_x`/`space_y` (double precision) as the
single authoritative owner of a "stopped in open space" coordinate. CHECKs: domain
`NULL|home|at_location|in_transit|in_space|destroyed`; coords both-null-or-both-set; coords present IFF
`in_space`; finite-only (reject NaN/±Inf). **No back-fill** — existing ships stay `spatial_state=NULL`
(legacy; position still from base/fleet/movement/presence). No functions → no relock; RLS/grants
unchanged (owner-read, no client write). `verify:osn2` 23/23. *Bug fixed:* ASI hazard (regex at
statement start) in the verifier (`9534319`).

**OSN-2b — resolver reads the new columns, read-model only (commits `bfebb1f`, `30289fe`, `f400ee4`,
`17ceb51`, `8a9518d`).** Extended the **single** resolver (no second resolver): `in_space`→ship-owned
`space_x/space_y` (finite, no active fleet/presence); `NULL`→legacy, with the named-location path now
deterministic (requires fleet `present` + `current_location_id` + matching ACTIVE `location_presence` +
resolvable location, else null); destroyed/contradiction/other→null. Read-side plumbing only:
`MainShipLite` + owner-read select gain the 3 columns; `fetchActiveMainShipPresence` (narrow: linked
`fleet_id` + `status='active'`, 3 fields, limit 1) runs inside the existing poll; `GalaxyMap` threads
presence into the marker. No writer/migration/RPC/flag/status/reconciler/destruction/lock change.

**Closure verification (commit `8a9518d`).** `@playwright/test` pinned **exactly `1.61.0`** (devDep +
lockfile); resolver test runs via `npm ci` (dropped ad-hoc `npm install --no-save`); on-demand strict
closure workflow runs **full `npm run lint` + `tsc -b` + `vite build` + resolver test**, all green;
read-only `verify:osn2:distribution` confirmed the live distribution is **54/54 `spatial_state=NULL`**
(zero `in_space`/`home`/`at_location`/`in_transit`/`destroyed` — no live ship hidden by the resolver).
*Bugs fixed during closure:* resolver workflow missing Playwright install → exit 127 (`30289fe`);
violet `in_space` marker color reverted — it was `LocationMarker`'s derelict-station color, not main-ship
visual language (`f400ee4`); two pre-existing `Date.now()`-during-render eslint errors
(`MainShipPanel.tsx`, `MainShipMarker.tsx`) fixed via the existing `now`-in-state tick so full repo lint
is green (`17ceb51`).

**Local toolchain note:** the dev machine cannot run lint/tsc/build/playwright locally (OneDrive
`node_modules` corruption + TLS-intercepting proxy); all verification runs in CI. Migrations through
**0054**. **NEXT:** OSN-3 (arbitrary-coordinate movement) — Design Gate A produced; 4 open decisions
before schema slice S1 (see the OSN-3 design report / `MAINSHIP_TRANSITION.md`).

---

## 2026-06-19 — Design correction: HIGH-STAKES ships (destructible) + emergency restart (docs)

**Decision (replaces "never destroyed + self-repair"):** main ships are persistent but **NOT
immortal** — they **can be permanently destroyed** (gone/retired) for real strategic stakes.
**Safelock rule: permanent ship loss is allowed; permanent account lockout is not.** When a
player has **zero usable main ships**, grant **one weak emergency starter ship** (starter hull,
**no modules, no captain bonuses, basic readiness, restart-only**) — does NOT restore the
destroyed ship, does NOT refund resources, gated by **strict eligibility + cooldown** (no farming;
a player with any usable ship is ineligible). Future defeat consequences: destroyed ship lost ·
cargo/rewards lost · modules lost/damaged/salvaged later · captains injured/rescued/captured later
· surviving ships keep going.

**Docs only (`MAINSHIP_TRANSITION.md`):** rewrote §6 anti-softlock to the high-stakes
destructible-ship + emergency-restart model; updated the fix-direction, softlock-coupling note,
§5 model (defeat = possible permanent destruction; surviving ships remain), the ★ vision
(persistent ≠ immortal), §8 residual-softlock (zero-ships → mandatory emergency replacement;
airtight eligibility), §9 (no destruction/replacement in 10C; both ship together in 10E), and the
phase table — **10C stays NON-COMBAT-only (no destruction)**; **10E renamed to destruction &
safelock** (permanent destruction + emergency-replacement RPC).

**Not implemented.** No code, no migration, no combat change. 10C not started (awaiting separate
approval). Backend unchanged.

---

## 2026-06-18 — Design correction: deprecate support capacity / support craft (UI + docs)

**Decision:** support capacity / support craft is **no longer part of the byeharu vision**. The
core is **multiple persistent main ships + captains + modules + upgrades**. Remove support
**safely** (hide → stop depending → delete), not by sudden deletion. This step: **hide from UI +
mark deprecated in docs.** No backend change, no migration, no deletes.

**Docs (`MAINSHIP_TRANSITION.md`):** added a ⚠️ deprecation callout in the ★ vision (support is
dormant scaffolding, not core; loadout = captains/modules/upgrades, no support craft, no
capacity budget); revised the model + 10D wording; added a **"9b. Removing support — later"**
safe-order section (hide → stop depending → deprecate fns → drop schema last).

**UI (10B preview revised → "Main Ship" read-only view):** `MainShipPreview.tsx` now shows the
**main ship only** — name, hull, status, readiness (hp/max_hp), speed, cargo, captain slots,
module slots. **Removed: support-craft picker, support-capacity bar, support-loadout wording,
activity selector.** `mainshipApi.ts` rewritten to read `main_ship_instances` (owner-read) +
`main_ship_hull_types` (public) directly — dropped `fetchSupportCraftTypes` /
`fetchExpeditionPreview` (the support-laden client wrappers). Galaxy toggle relabeled
"🛰 Main Ship". Still strictly read-only; no writes.

**Backend: UNCHANGED.** No migration. `get_my_expedition_preview`, `calculate_expedition_stats`,
`support_craft_types`, and the `support_capacity` columns stay in place but **dormant + unused by
the UI**. (`verify:mainship-preview` still exercises the dormant RPC — left as a backend
regression.) **Remaining support dependencies (to remove in a later phase):** `support_craft_types`
table (Phase 6 + `verify-phase6`); `calculate_expedition_stats` support math (Phase 8) +
`get_my_expedition_preview` wrapper (Phase 10B); `support_capacity`/`base_support_capacity`
columns; a non-displayed `support_capacity` read in `useGalaxyMapData` (Phase 9A). **Recommended
later removal phase:** after the captain/module/upgrade stat source replaces the support layer
and no live path calls it. **Docs + UI only; not pushed; no CI run.**

---

## 2026-06-18 — Phase 10B: read-only main-ship expedition preview (implemented; pending verify)

**Scope: strict preview only** — see what your main ship + a support-craft loadout WOULD bring.
No writes, no sending, no combat/engine change; the Phase 9B send path is untouched. Per
`docs/MAINSHIP_TRANSITION.md` (10B).

**Migration `0049_mainship_preview.sql`** — `get_my_expedition_preview(p_loadout jsonb,
p_activity_type text)` → jsonb. **STABLE (read-only)**, SECURITY DEFINER, `auth.uid()`-scoped,
granted to **authenticated**. Reuses the **single stat source** `calculate_expedition_stats`
(Phase 8, stays server-only — the wrapper calls it as the definer; not exposed to clients).
- Ship exists → `{has_ship:true, valid:true, ship, stats}`.
- Validation errors (over-capacity / unknown craft / bad qty) are **caught** → `{valid:false,
  error}` (a preview warning, not a client crash).
- No ship yet → `{has_ship:false, hull:…}` starter-hull teaser. **It does NOT commission a
  ship** (no write) — commissioning is a later phase.

**Frontend (read-only):** `mainshipApi.ts` (`fetchSupportCraftTypes`, `fetchExpeditionPreview`);
`MainShipPreview.tsx` — a panel with an activity dropdown + capacity-limited support-craft
picker + live stat grid + a `support_capacity` used/limit bar + warnings, labeled **"Preview
only · does not send."** Wired into `/galaxy` behind a header toggle (`🛰 Main Ship preview`),
**separate from the send command** (single send surface preserved).

**Verify:** `scripts/verify-mainship-preview.mjs` (`npm run verify:mainship-preview`,
standalone — NOT wired into the chained verify): base stats · valid loadout (reuses adapter) ·
over-capacity → warning · unknown craft → warning · no-ship hull teaser · **wrote-nothing
proof** (no-ship player still has none) · adapter still client-denied.

**Untouched:** combat/fleet/movement/reward/send/cleanup. No deletes, no renames. Known limit:
to see *loadout* numbers a ship must exist; live players without one see the hull teaser
(commissioning = later phase). Test main-ship rows for `mspreviewtest*` users persist (not a
runtime table; tiny). **Pending build + verify (handed off to user).**

---

## 2026-06-18 — Follow-up: M4.5 browser test self-cleaning + orphan cleanup (test hygiene)

**Why** The M4.5 browser test (`m45browser.*@example.com`, no `"test"`, no cleanup step) left
runtime orphans the guarded `cleanup_test_runtime` couldn't remove (3 rows: 1 fleet + 2
build_orders). Pre-existing, predates the Phase C `%test%` convention; not a 9C change.

**Part A — prevent future:** test email `m45browser.*` → **`m45testbrowser.*@example.com`**;
`browser.yml` gains the shared `live-db-tests` **concurrency group** + an `if: always()`
cleanup step `verify-cleanup --pattern '%m45testbrowser%@example.com'`. That pattern is unique:
it can NOT match verify (`m45test.TAG` / `m*test` / `p*test` / `invtest`) or galaxy
(`galaxytest*`).

**Part B — remove existing orphans:** one-time `scripts/cleanup-m45-orphans.mjs` (+ dispatch
workflow, dry-run default). It collects runtime player_ids, **proves ownership via
`auth.admin.getUserById` (email must match `/^m45browser\./`)**, shows the rows, then deletes
child→parent **only** those players' runtime rows. No TRUNCATE; no guard change; never touches
bases/inventory/main_ship/config/world.

**Result:** dry-run proved **1** orphan player (`m45browser.1781756112790@example.com`) owning
exactly 3 rows (1 completed fleet + 2 terminal build_orders); `--confirm` deleted them
(child→parent). The renamed M4.5 browser run self-cleaned its own 3 rows via `%m45testbrowser%`.
**verify:phase8 ✅ 21/21, galaxy 9A/9B ✅, M4.5 browser ✅** — all test data self-cleans to 0.

**db:counts after = 360, and that is CORRECT (not test junk):** a read-only owner diagnostic
(`scripts/whoami-runtime.mjs` + `runtime-owners.yml`) showed all remaining runtime rows belong
to **ONE REAL player — `gkwngns714@gmail.com`** (the project owner's own manual galaxy-map test:
an expedition to a pirate hunt → 1 fleet + 1 combat encounter, 88 ticks/264 events). **Not
deleted — real player data.** Test infrastructure leftover = **0**. (The 88 ticks mean a verify
run had `combat_tick_logging` on during that combat; it's reset to false by m4/m5's finally and
those ticks age out via Phase B 3-day retention.)

**Net:** M4.5 browser test is now self-cleaning + serialized; old orphans removed; no real/
config/permanent data touched; no TRUNCATE; no gameplay change. **Follow-up CLOSED.**

---

## 2026-06-18 — Phase 9C: Expedition UI Reframe (BUILD + VERIFY + BROWSER GREEN ✅)

**Request** Make the player understand: Galaxy Map = where you send expeditions; Command
Center = status + shortcuts; fleet status area = active/returning/completed. Remove duplicate
send controls. Frontend/copy only — no backend.

**Duplicate removed:** the old in-dashboard `SendFleetPanel` (list-based send) duplicated the
Phase 9B map send → **deleted** (`src/features/fleets/SendFleetPanel.tsx`; only the Dashboard
imported it). `/galaxy` is now the **only** send surface.

**Reframe (frontend only):**
- `ExpeditionLauncher.tsx` (new) — replaces the dashboard send panel with a pointer card:
  "Send your first from the Galaxy Map", a prominent **Open Galaxy Map** button, and the
  reward rule in plain words ("pending while out · secured only on return"). Empty-vs-active
  copy. testid `dashboard-expedition-launcher`.
- `Dashboard.tsx` — swaps `SendFleetPanel` → `ExpeditionLauncher`; header already links to the
  map. No other send control remains.
- `FleetStatusPanel.tsx` — kept the `Fleets` heading + "previous run(s)" wording (m45 selectors)
  but added a subtitle ("Active expeditions — travel, on-station, and returns"), reframed the
  empty state to **"No active expedition. Send your first from the Galaxy Map →"** (links to
  `/galaxy`), and made the status badge **activity-aware** (present + hunt → "Fighting", else
  "On station"). Existing reward wording kept ("rewards locked (secured on arrival)").

**No backend touched** — no migration, no RPC/combat/reward/return/cleanup change, no second
map or send flow. Phase 9B send logic unchanged.

**Tests:** `galaxy9b.spec.ts` gains a check that the Command Center shows
`dashboard-expedition-launcher` and has **no** "Send a fleet" control (single-surface proof).
9A/9B/m45 selectors preserved.

**Result (commit `aaea9d5`):** build/typecheck + lint ✅, Pages deployed. **verify:phase8 ✅
21/21.** **Browser: 9A 1/1, 9B 1/1** (incl. single-send-surface assertion), **M4.5 1/1**
(confirms the FleetStatusPanel reframe kept its selectors). **db:counts runtime = 0.** No
backend/migration/table-write change; `/galaxy` is the only send surface. **Phase 9C CLOSED.**

---

## 2026-06-18 — Phase 9B: Map-based Expedition Send (BUILD + VERIFY + BROWSER GREEN ✅)

**Backend path inspection (done before wiring — no backend change, no migration):**
- **RPC used:** `send_fleet_to_location(p_base uuid, p_location uuid, p_units jsonb)` (migration
  0019), via the existing wrapper `sendFleetToLocation(baseId, locationId, units)` in
  `fleetApi.ts`. This is the same path Phase 8's chain (verify-m4) drives — already verified.
- **Inputs:** base id, location id, `units` = `[{unit_type_id, quantity}]`.
- **Success:** `{ fleet_id, movement_id, arrive_at }`.
- **Failure:** raises → supabase-js returns `error.message`; the wrapper throws it.
- **Backend-authoritative validation (already present):** base owned+active · location valid/
  active · `activity_type ∈ {none, hunt_pirates}` · **active-fleet-limit (max_active_fleets=3,
  counts moving/present/returning)** · units non-empty · units available & positive (via
  `base_reserve_units`, which also *reserves* them so the same units can't be re-sent) · fleet
  power ≥ `min_power_required`. → it already blocks invalid sends, over-limit/duplicate active
  expeditions, insufficient units, and invalid/locked destinations. **No second expedition
  system created.**

**Implementation (frontend only):**
- `useGalaxyMapData.ts` — additionally loads `unitTypes` (catalog, static) + `baseUnits`
  (polled) so the command area can offer a loadout. Still read-only fetches.
- `ExpeditionCommand.tsx` (new) — replaces the disabled 9A placeholder. Compact unit picker +
  Send → **confirmation step** → calls `sendFleetToLocation` **exactly once** (synchronous
  `sendingRef` guard + `sending` state → double-submit-proof). Shows sending / success / error
  states + a disabled reason. **No optimistic movement** — on success it calls the hook's
  `refresh()`; the movement line appears only from refetched `movements`.
- `GalaxyMapScreen.tsx` — wires the command area into the detail panel; passes base/units/
  unitTypes; `onSent` → refresh.
- `LocationMarker.tsx` — adds `data-activity` / `data-location-id` (test selectors). `FleetMovementLine.tsx` — adds `data-testid="galaxy-movement-line"`.
- **Frontend-only checks (clarity, not authority):** no destination / non-dispatchable
  activity / no units selected / already sending → disabled with a reason. Everything real
  (ownership, limits, units, power, validity) stays backend-authoritative; backend errors are
  surfaced verbatim.

**No direct table writes from the UI** — the only write is the approved `send_fleet_to_location`
RPC. No combat/reward/return/cleanup/logging logic touched.

**Tests:** `galaxy.spec.ts` updated (9A read-only smoke kept; send button asserted disabled
before a loadout). `galaxy9b.spec.ts` (new) — select a dispatchable marker → pick units → send
→ confirm (double-clicked) → success → assert **exactly one** fleet+movement via backend read
→ movement line on map → no dup from double-submit → send disabled before units → no console
errors. `browser-galaxy.yml` runs both then `verify:cleanup` (test email contains `test` so
`cleanup_test_runtime` removes its runtime rows → db:counts back to 0).

**Result (commit `aefd5ea`):** build/typecheck ✅ (lint clean after remount-via-key + CSS
cursor fixes), Pages deployed. **verify:phase8 ✅ 21/21 … M4 40/40** (run alone). **Browser:
9A smoke 1/1, 9B send 1/1.** **db:counts runtime = 0** (galaxy cleanup scoped to
`%galaxytest%`). **Transient verify failure root-caused + fixed:** I'd dispatched the browser
suite + verify concurrently; the browser workflow's broad `%test%` cleanup deleted verify's
in-flight phase5 fleet mid-combat → "no wave cleared". Fixed: shared `live-db-tests`
concurrency group on both workflows + galaxy cleanup narrowed to `%galaxytest%` (can't touch
verify's m*/p* users). Re-run verify alone = 21/21. **No backend/migration/table-write/second-
expedition-system added.** **Phase 9B CLOSED.**

---

## 2026-06-18 — Phase 9A: Read-only Visual Galaxy Map (BUILD + VERIFY GREEN ✅)

**Request** First visual galaxy map screen — read-only, using existing backend world data.
See the world/locations/home/ship/active movements; select a location for details. No
commands, no writes, no backend change.

**No backend change needed.** All data already exists: `get_world_map()` (sectors→zones→
locations with x,y), `bases` (x,y,name), `fleet_movements` (**origin_x/y + target_x/y** stored
→ paths drawable directly), `location_state` (pressure/danger), `main_ship_instances`
(owner-read). Confirmed before building; **no migration added**.

**Files (all `src/features/map/`, matching the existing feature structure):**
- `useGalaxyMapData.ts` — read-only hook: world map + base once; polls movements + location
  states + a small `main_ship_instances` owner-read every 4s. Builds location→sector/zone meta.
- `GalaxyMap.tsx` — plain **SVG** 2D map (no canvas/WebGL). Normalizes world coords into a
  0..1000 viewBox; transform group gives pan (drag) + zoom (wheel/+/−/reset). Renders movement
  paths, home/ship anchor, and location markers. Labels hidden when zoomed out.
- `LocationMarker.tsx` — colored marker + truncated label, counter-scaled to stay constant
  on-screen size; selecting only highlights.
- `FleetMovementLine.tsx` — dashed origin→target path (amber outbound / sky return) + ETA
  (`formatCountdown`). Purely visual.
- `GalaxyMapScreen.tsx` — page with loading / error / empty / selection states + a **read-only
  detail panel** (name, sector/zone, type, coords, status, difficulty/reward, live world
  state) + a disabled “Send expedition (Phase 9B)” button + “coming in Phase 9B” note.
- `fleetTypes.ts` — additive: `origin_x/y`, `target_x/y` (already returned by `select('*')`).
- `App.tsx` — new `/galaxy` route (RequireAuth). Nav links added from Dashboard + MapPage.

**Read-only guarantees:** the screen calls only read paths (`get_world_map`, table selects on
`location_state`/`fleets`/`fleet_movements`/`main_ship_instances`). No RPC mutation, no
`send_fleet`, no table writes. Action-implying controls are disabled/labeled Phase 9B.

**Result (commit `c1de252`):** frontend **build/typecheck ✅** (`tsc -b && vite build`), **Pages
deployed** (`/galaxy` live), **verify:phase8 ✅** (Phase 8 21/21 … M4 40/40; frontend can't
affect backend). db:counts unaffected (auto-cleanup ran). Manual interactive browser check
not runnable from the dev sandbox (no GUI/network) — offered a Playwright smoke test as
follow-up. **Phase 9A code complete + CI-green.** Phase 9B: click-to-select destination +
expedition send.

**Follow-up — Playwright /galaxy smoke (commit `6d84d19`):** `tests/galaxy.spec.ts` signs in,
opens `/galaxy`, asserts the map + ≥1 marker render, selecting a marker opens the read-only
detail panel, the Send button is **disabled + Phase-9B**, and **no fleet/movement is created**
(read-only proof), failing on serious console/page errors. Stable testids added
(`galaxy-map-screen/-loading/-error`, `galaxy-location-marker`, `galaxy-location-detail-panel`,
`galaxy-send-expedition-disabled`). `verify:galaxy:browser` script + `browser-galaxy.yml`
dispatch. **Result: smoke 1/1 ✅, build ✅, verify:phase8 ✅ (21/21 … M4 40/40), db:counts
runtime = 0.** No backend/migration/write change.

---

## 2026-06-18 — Prevention Phase C: self-cleaning verify runs (DEPLOYED + VERIFIED ✅)

**Request** Stop verify runs leaving runtime/test rows behind. Minimal + safe; no gameplay/
combat/reward/movement/report changes; no TRUNCATE; no real/config/permanent data touched.

**How test data is identified (no `test_run_id` added):** every verify script signs up
throwaway users with emails matching `%test%@example.com` (m4test/m5test/m45test/invtest/
p4test…p8test), and every runtime table carries `player_id`. So verify-created runtime rows =
rows owned by a test-email player. The email pattern is the cleanup key — the existing
convention made a schema column unnecessary.

**Migration `0048_cleanup_test_runtime.sql`:** `cleanup_test_runtime(p_pattern default
'%test%@example.com', p_dry_run default true)` → returns `(table_name, rows_matched,
rows_deleted, cleanup_key)`. Deletes ONLY the 9 runtime tables (+ fleet_units) for test-email
players, child→parent. Guards: pattern MUST contain `test` (else raises); **never** touches
`auth.users`, `bases`, `base_units`, `base_resources`, `player_inventory`, `inventory_ledger`,
`main_ship_instances`, `*_types`, `game_config`, or world tables. No TRUNCATE. SECURITY
DEFINER, service_role only.

**Files:** migration 0048; `scripts/verify-cleanup.mjs` (`verify:cleanup:dry-run` /
`verify:cleanup --confirm`, optional `--pattern`); `package.json`; `verify-phase8.mjs` prints
a cleanup reminder at the end; `verify.yml` adds a final `if: always()` **auto-cleanup step**
so every CI verify removes its own test data (even on failure).

**Result (commit `2ac700f`):** migration 0048 deployed ✅. verify:phase8 ✅ (Phase 8 21/21 …
M4 40/40). Auto-cleanup deleted **728 runtime rows** (matched == deleted every table — the
whole accumulated test backlog + this run). `db:counts` after: **all 10 runtime tables = 0**.
No TRUNCATE; no auth.users/bases/inventory/main_ship/config/world touched. **Phase C CLOSED —
prevention complete (A logging controls · B retention cleanup · C self-cleaning verify).**

---

## 2026-06-18 — Prevention Phase B: safe retention cleanup (DEPLOYED + VERIFIED ✅)

**Request** Add a batched, dry-run-first retention cleanup. No TRUNCATE, no destructive
reset, no active/seeded/player-owned data touched.

**Schema reconciliation (inspected, not assumed) — reported deviations:**
- `combat_ticks` has **`resolved_at`**, not `created_at` → index + rule use `resolved_at`.
- `fleet_movements` has **no `updated_at`** → index + rule use `resolved_at` (set on resolve).
- `reward_grants` has **`granted_at`**, not `claimed_at` → use `granted_at`. (There is no
  "pending"/"claimed" state in this table — a grant row IS an already-secured deposit; pending
  rewards live on `combat_encounters`/`fleet_movements` jsonb and are untouched.)

**Cascade hazard (inspected):** ON DELETE CASCADE roots everything at `fleets`
(→ fleet_units, fleet_movements, location_presence, combat_encounters → ticks/events/reports;
presence → encounters too). Since `combat_reports` (30d) hangs under encounters/presence/
fleets, deleting any ancestor would cascade-delete a still-retained report. So **encounters,
location_presence, and fleets are additionally gated**: never deleted while they have an
ACTIVE encounter or a RETAINED (<30d) report. Net: those three are effectively kept until
their report expires; non-combat presence (no report) still cleans at 1 day.

**Migration `0047_runtime_retention_cleanup.sql`:**
- 10 indexes (`CREATE INDEX IF NOT EXISTS`) on the real scan columns (3 substituted per above).
- `maintenance_cleanup_runtime_data(dry_run boolean default true, batch_limit int default 5000)`
  → returns `(table_name, retention_rule, rows_matched, rows_deleted, dry_run)` per table.
  Batched deletes via `ctid in (… limit batch_limit)` loops — never one-shot, never TRUNCATE.
  Kill-switch: if `runtime_cleanup_enabled=false`, forced to dry-run. SECURITY DEFINER,
  service_role only.
- Retention: ticks 3d, events 7d, reports 30d, encounters terminal>14d(+guard), presence
  terminal>1d(+guard), movements terminal>14d, fleet_units (parent terminal>14d), fleets
  terminal>14d(+guard), reward_grants 30d, build_orders terminal>30d.
- Safety: only TERMINAL statuses deleted (active/retreating/moving/waiting/queued never
  match); active encounters/fleets/movements/rewards/builds never deleted; no bases/
  base_resources/base_units/inventory/main_ship/_types/game_config/world tables referenced.

**Files:** migration 0047; `scripts/db-cleanup.mjs` (`db:cleanup:dry-run` / `db:cleanup
--confirm`); `package.json`; `.github/workflows/db-cleanup.yml` (dispatch; dry-run default,
deletes only on confirm=true; shows size/counts before+after).

**Fix during deploy:** first push failed 42P13 — input param `dry_run` collided with the OUT
column `dry_run`; renamed inputs to `p_dry_run`/`p_batch_limit` (project `p_`-convention),
OUT column stays `dry_run`. **Result (commit `dac35a1`):** migration 0047 deployed ✅.
**Dry-run: 0 matched across all 10 tables** (all data fresh — nothing past the 3/7/14/30-day
cutoffs); **live run (confirm=true): 0 matched / 0 deleted** — delete path executes cleanly,
nothing destructive. **verify:phase8 ✅ — Phase 8 21/21 … M4 40/40** (indexes + function did
not affect combat/regression). **Phase B CLOSED.** Next: Phase C (self-cleaning verify runs).

---

## 2026-06-18 — Prevention Phase A: combat logging controls + DB visibility (DEPLOYED + VERIFIED ✅)

**Request** Stop byeharu re-filling the disk: make high-volume combat logging opt-in and add
size/row visibility. No deletes (that's Phase B), no combat-outcome changes.

**Migration `0046_combat_logging_controls.sql`:**
- `cfg_bool(key)` accessor + `set_game_config(key, value jsonb)` (service_role/CI only).
- 7 `game_config` flags (insert-if-absent): `combat_debug_logging=false`,
  `combat_tick_logging=false`, `combat_event_logging=true`, `runtime_cleanup_enabled=true`,
  `combat_tick_retention_days=3`, `combat_event_retention_days=7`, `combat_report_retention_days=30`.
- `process_combat_ticks` (same combat math) now **gates logging**: all `combat_ticks` inserts
  behind `combat_tick_logging` (default OFF → no per-tick rows); per-unit `hull_damage` events
  behind `combat_debug_logging` (default OFF → kills the worst per-tick multiplier); other
  meaningful events behind `combat_event_logging` (default ON → UI animation + reports intact).
  `v_seq` still advances so display ordering is unchanged.
- `db_table_sizes()` (top-20 by `pg_total_relation_size`) + `db_runtime_counts()` (10 runtime
  tables) — service_role only.

**Default logging after this change:** per combat tick we now write **0** `combat_ticks` rows
and **0** `hull_damage` events (was 1 tick + N hull_damage); only milestone/animation events
(wave_spawned, missile_salvo, laser_burst, unit_destroyed, explosion, retreat) remain.
`combat_reports` (player-facing summary) untouched.

**Regression compatibility:** verify-m4 + verify-m5 inspect `combat_ticks`, so they flip
`combat_tick_logging` on via `set_game_config` at start and **restore it off in finally**
(shared DB → production default stays off). Only those two scripts read ticks.

**Visibility:** `scripts/db-size.mjs` (`npm run db:size`) + `scripts/db-counts.mjs`
(`npm run db:counts`), plus a `db-report.yml` dispatch workflow to run both in CI.

**Restrictions honored:** no TRUNCATE, no deletes, no seeded/config/world/player tables
touched.

**Result (commit `e3d0ba4`):** migration 0046 deployed ✅. `db:size` + `db:counts` work
(post-cleanup DB tiny — largest table 120 kB; 240 total runtime rows). **verify:phase8 ✅ —
Phase 8 21/21, Phase 7 18/18, Phase 6 10/10, Phase 5 25/25, Phase 4 16/16, Inventory 18/18,
M4.5 27/27, M5 28/28, M4 40/40** (incl. "waves last 3+ ticks" — m4/m5 tick-toggle works).
**Phase A CLOSED.** Next: Phase B (retention cleanup function, dry-run first).

---

## 2026-06-18 — Phase 8: calculate_expedition_stats() (DEPLOYED + VERIFIED ✅)

**Request** Build the deterministic stat ADAPTER that will eventually turn Main Ship +
Support Craft (+ later Captains + Modules) + Activity into final expedition stats — the
bridge between the new main-ship model and the proven engine. **Read/compute only**; no
mutation; engine unchanged; live combat still uses the old fleet-stack path.

**Migration `0044_calculate_expedition_stats.sql`** — one function,
`calculate_expedition_stats(p_player, p_main_ship_id, p_loadout jsonb, p_activity_type)`
returns jsonb. SECURITY DEFINER, **STABLE (read-only)**, **service_role only**:
- Reads the owned `main_ship_instances` row (+ `main_ship_hull_types` for base_speed); errors
  if the ship isn't found/owned. Validates `activity_type ∈ {pirate_hunt, trade_run,
  exploration, mining, none}`.
- Normalizes the support loadout: **combines duplicate** craft ids; **rejects** unknown
  types, and non-positive / non-integer / NaN / Inf quantities.
- **Enforces `support_capacity` as a HARD cap** — `used = Σ(qty × capacity_cost)`; over the
  ship limit → rejected. This is the anti-unlimited-stacking mechanism (never a plain sum).
- Effects (conservative, linear within the cap) derive from each craft's Phase-6
  `base_stats_json` (attack→combat_power, defense→survival, repair, cargo, scan→scouting,
  mining→mining_yield, evasion→retreat_safety) plus role rules for `pirate_attention`
  (combat_damage/cargo +2, heavy_cargo +4) and a speed penalty (combat_damage 0.05,
  heavy_cargo 0.08, extraction 0.02). Non-useful-for-activity craft add a non-fatal warning.
- Returns normalized, **clamped (≥0), rounded** stats: support_capacity_used/limit, speed,
  cargo_capacity, combat_power, survival, retreat_safety, scouting, mining_yield, repair,
  pirate_attention, warnings[] — **never NaN, never negative, deterministic**.

**Read/compute only (verified):** mutates nothing — ship row + inventory unchanged after many
calls; no fleets/combat/rewards/ranking/reports touched. **NOT wired into live combat** — the
fleet-stack path still owns outcomes (M2–M5 untouched). Support-craft OWNERSHIP isn't
implemented yet, so Phase 8 validates **type/capacity/math** against `support_craft_types`
only; ownership consumption comes when loadouts attach to real expeditions.

**Anti-cheat:** new function default-grants to PUBLIC on create → re-ran the lockdown
(revoke; re-grant the 8 client RPCs; `calculate_expedition_stats` → service_role only). A
client preview RPC (auth.uid()-scoped) will arrive with the Phase 9 UI.

**Boundaries/docs:** SYSTEM_BOUNDARIES decision #8 (table-less read/compute adapter, mutates
nothing). ROADMAP Phase 8 ✅. ARCHITECTURE Phase 8 note. ACTIVITIES: documented which stats
each activity will read from the adapter later.

**Verify:** `scripts/verify-phase8.mjs` — base stats on empty loadout (0/10, speed 1, cargo
50); mixed loadout capacity (7/10); reject over-capacity / unknown / zero / negative /
non-integer; duplicate-combine; per-craft effects (missile_boat→combat+attention/speed,
cargo_drone→cargo+attention, survey→scouting, mining→yield, decoy→retreat, repair→repair+
survival); no-NaN; determinism; ship + inventory not mutated; client-denied; then chains
`verify-phase7` (full regression). CI runs `verify:phase8`.

**Status (commit `5a4c954`):** Migration 0044 **deployed ✅** (direct-Postgres push succeeded).
**Verification BLOCKED by a Supabase infra issue, not code:** every REST/RPC request returns
`upstream request timeout` — including a trivial read of the public `main_ship_hull_types`
table (which touches no Phase 8 code), persisting 13+ min across two runs. The REST/PostgREST
layer is globally unresponsive (DB accepts direct connections — deploy worked — but the API
gateway times out). Needs the Supabase project checked/restarted (paused / compute-exhausted /
stuck schema reload), then re-run `verify:phase8`.

**Resolution:** free-tier disk was full (combat-log churn from dozens of verify runs).
Cleared via one-time migration `0045_dev_cleanup_churn` (TRUNCATE of 10 throwaway runtime/log
tables over the working direct-Postgres connection — user-authorized), then a dashboard
**project restart** bounced the stuck PostgREST. **Verify ✅ — Phase 8 21/21, Phase 7 18/18,
Phase 6 10/10, Phase 5 25/25, Phase 4 16/16, Inventory 18/18, M4.5 27/27, M5 28/28, M4 40/40.
Phase 8 CLOSED.** Follow-up: Phases A–C add logging controls + safe retention cleanup + self-
cleaning verify so the disk can't fill again.

---

## 2026-06-18 — Phase 7: Main Ship Instance (DEPLOYED + VERIFIED ✅)

**Request** Create the player's ONE main ship — the player identity, not stackable, one
active per player. Additive foundation only: no combat hook, no support-craft attachment, no
`calculate_expedition_stats`, no capacity enforcement. Engine untouched.

**Migration `0043_main_ship_instance.sql`** — two tables + three server-only functions:
- `main_ship_hull_types` (Reference/Config, public-read): one starter hull `starter_frigate`
  — base_hp 500, base_speed 1.0, cargo 50, **support_capacity 10**, captain_slots 2,
  module_slots 3. (Conservative; not final balance.)
- `main_ship_instances` (Main Ship system, owner-read, **no client write**): `player_id`
  UNIQUE (one per player), hull FK, name default 'Byeharu', `status` CHECK in the 10 allowed
  states (default `home`), hp/max_hp/cargo_used/cargo_capacity/support_capacity/captain_slots/
  module_slots with `>=0`/`>0` checks. Stats are copied from the hull on creation so the
  instance can later diverge (damage/upgrades) without mutating the template.
- `ensure_main_ship_for_player(player)` — idempotent, concurrency-safe via the `player_id`
  UNIQUE (`on conflict do nothing` → select) → one ship per player. `get_main_ship(player)`
  read helper. `rename_main_ship(player,name)` — trims, rejects empty + >40 chars, requires an
  existing ship. All SECURITY DEFINER, **service_role only** (clients read their ship via
  owner-read RLS; no client mutation/RPC path).

**What did NOT change (by design):** combat, fleets, `fleet_movements`, presence, production/
build queue, rewards, inventory, support_craft metadata. No fleet-table renames. Player-
creation path (`initialize_new_player`) untouched — the ship is created on demand via
`ensure_main_ship_for_player` (a future bootstrap/RPC will call it). Anti-cheat: new functions
default-grant to PUBLIC → re-ran the lockdown (revoke; re-grant the 8 client RPCs; ensure/get/
rename → service_role). Prior service_role grants untouched.

**Boundaries/docs:** `main_ship_hull_types` added to Reference/Config; new **Main Ship** owner
row (sole writer of `main_ship_instances`) + per-system contract + ownership decision #7.
ROADMAP Phase 7 ✅. ARCHITECTURE Phase 7 note (ship exists, doesn't drive expeditions yet).

**Verify:** `scripts/verify-phase7.mjs` — starter hull public-read + client-write-blocked;
ensure creates exactly one ship (idempotent, no dup); owner-read + cross-user RLS; client
INSERT/UPDATE/DELETE + server-RPCs all blocked; stats valid & copied from hull; status
defaults `home`; rename trims + rejects empty/overlong/no-ship; then chains `verify-phase6`
(full regression) to prove the engine is unchanged. CI runs `verify:phase7`.

**Result (commit `05b1cc5`):** Deploy ✅ · Build ✅ · Pages ✅ · Verify ✅ —
**Phase 7 18/18, Phase 6 10/10, Phase 5 25/25, Phase 4 16/16, Inventory 18/18, M4.5 27/27,
M5 28/28, M4 40/40** (M2 11 / M3 13 chained), 0 failed. Ship created hp 500/500, support 10,
captain 2, module 3, status `home`; idempotent; client writes + server RPCs blocked. Migration
0043 live on `dlkbwztrdvnnjlvaydut`. **Phase 7 CLOSED.**

---

## 2026-06-18 — Phase 6: Support Craft Reframe (DEPLOYED + VERIFIED ✅)

**Request** Reframe "build ships" toward the future "build support craft / expedition
equipment" model — **metadata foundation only**, no engine change. Support craft must be
**capacity-limited loadout choices, not unlimited additive power**. No instances, no
expedition attachment, no `calculate_expedition_stats`, no capacity enforcement yet.

**Migration `0042_support_craft_types.sql`** — one Reference/Config table (mirrors
`item_types`): `support_craft_type_id` PK, name, role, `capacity_cost int check (>0)`,
stackable, buildable, `activity_tags jsonb`, `tradeoffs_json`, `base_stats_json`. Public-read
RLS, **no write policy / no write grant → clients cannot mutate**. Seeds the **8 starter
craft** with real roles + capacity costs + tradeoffs:
- scout_escort (light_escort, cap 1) · missile_boat (combat_damage, cap 3) · repair_drone
  (repair, cap 2) · cargo_drone (cargo, cap 2) · survey_drone (scanning, cap 2) · decoy_drone
  (retreat_safety, cap 1) · mining_drone (extraction, cap 2) · trade_barge (heavy_cargo, cap 5).
- `base_stats_json` is illustrative only — **nothing consumes it yet** (Phase 8).

**What did NOT change (by design):** combat (`unit_types` scout/corvette/frigate untouched,
separate namespace), the serial build queue / `build_orders` / `train_units`, fleets,
movement, rewards, inventory. No fleet-table renames. No new functions (so no execute-lockdown
needed). Frontend wording left as-is to avoid risking the M4.5 browser acceptance; the
build-queue reframe is conceptual/documented (M4.5 = Serial Build Queue Foundation; ARCHITECTURE
+ SYSTEM_BOUNDARIES updated).

**Boundaries/docs:** `support_craft_types` added to the Reference/Config sole-writer row;
new ownership decision #6 (metadata only, capacity enforced later by main ship +
`calculate_expedition_stats`). ROADMAP Phase 6 ✅. ARCHITECTURE Phase 6 note.

**Verify:** `scripts/verify-phase6.mjs` — 8 definitions exist & public-read; capacity_cost > 0
matching documented costs; every craft has role + activity_tags + tradeoffs; zero overlap with
combat `unit_types` (engine untouched); client INSERT/UPDATE blocked by RLS; then chains
`verify-phase5` (→ phase4 → inventory → m45 → m5 → m2/m3/m4) to prove combat + serial queue
unchanged. CI runs `verify:phase6`.

**Result (commit `4038209`):** Deploy ✅ · Build ✅ · Pages ✅ · Verify ✅ —
**Phase 6 10/10, Phase 5 25/25, Phase 4 16/16, Inventory 18/18, M4.5 27/27, M5 28/28,
M4 40/40** (M2 11 / M3 13 chained), 0 failed. 8 craft seeded, capacity 1–5, client writes
blocked, zero overlap with combat unit_types. Migration 0042 live on `dlkbwztrdvnnjlvaydut`.
**Phase 6 CLOSED.**

---

## 2026-06-18 — Phase 5: Multi-Item Pirate Loot (DEPLOYED + VERIFIED ✅)

**Request** Pirate combat should accrue real item drops alongside metal — a controlled
combat-reward DATA change, not an engine rewrite. Reuse the proven Phase 4 bundle; keep the
reward timing law; metal stays in `base_resources`; server-authoritative loot only. No
crafting/modules/captains/UI.

**Migration `0041_pirate_loot.sql`** — two isolated, server-only helpers + a 3-line injection
into the existing combat tick:
- `pirate_loot_for_wave(p_wave int, p_danger numeric)` — the loot table. **Deterministic**
  (no RNG → stable tests), small/clamped, **only Phase-3-seeded ids**: scrap (every wave),
  pirate_alloy (≥3), weapon_parts (≥5), engine_parts (≥8), repair_parts (≥10). `p_danger`
  reserved for future scaling; v1 keeps qty=1 so survival can't make loot explode. Returns
  `[]` below wave 1 (no NaN, no unknown ids).
- `loot_merge_items(a, b)` — combines two items[] by id (summed) to keep the accumulated
  bundle tidy across waves. (reward_grant also de-dups on deposit — belt & suspenders.)
- `process_combat_ticks` (copied verbatim from 0030) gains exactly three PHASE-5 lines:
  declare `v_loot_items`; on wave-clear set `v_loot_items := pirate_loot_for_wave(wave,danger)`
  and put it in `reward_delta`; merge `items[]` into `total_rewards_json` next to the
  accumulated metal. Everything else — carry-home, retreat, defeat-forfeit (`'{}'`),
  secured-on-arrival — is unchanged.

**Reward flow (all unchanged from Phase 4):** drops are pending in `total_rewards_json` →
ride `reward_payload_json` home → `reward_grant` on arrival splits metal→`base_resources`,
items→`player_inventory` (idempotent). Defeat clears the bundle → forfeits metal AND items.
Retreat alone never secures.

**Boundaries/docs:** `ACTIVITIES.md` pirate_hunt loot section made concrete (server-side
only; rare progression ids reserved). Combat still owns only its reward accrual — it writes
the pending bundle, never Inventory/Base directly. Frontend unchanged (no client loot path).

**Anti-cheat:** new helpers default-grant to PUBLIC on create → 0041 re-runs the lockdown
(revoke from public/anon/authenticated, re-grant the 8 client RPCs; loot helpers → service_role
for CI only). reward_grant/inventory_* service_role grants untouched.

**Verify:** `scripts/verify-phase5.mjs` — (A) deterministic loot-table + merge helpers
(positive ints, known ids, clamped, dedup), (B) **real combat**: items appear in
`total_rewards_json`, stay pending through retreat, deposit to `player_inventory` +
`base_resources` on home arrival, report keeps metal; (C) **defeat** forfeits metal+items;
(D) chains `verify-phase4` (→ inventory → m45 → m5 → m2/m3/m4). CI runs `verify:phase5`.

**Result (commit `bf32dbf`):** Deploy ✅ · Build ✅ · Pages ✅ · Verify ✅ —
**Phase 5 25/25, Phase 4 16/16, Inventory 18/18, M4.5 27/27, M5 28/28, M4 40/40** (M2 11 /
M3 13 chained), 0 failed. Real run banked metal +38 and scrap +1 on arrival; defeat forfeited
the bundle. Migration 0041 live on `dlkbwztrdvnnjlvaydut`. **Phase 5 CLOSED.**

---

## 2026-06-17 — Phase 4: Pending Loot Bundle (DEPLOYED + VERIFIED ✅)

**Request** Generalize the metal-only pending reward into a future-proof
`PendingRewardBundle { metal?, items:[{item_id,quantity}] }`. Backend plumbing only — no
new pirate drops, no trading/mining/crafting/UI. Keep the reward timing law exactly:
pending while travelling · secured **once on home arrival** · forfeited on defeat · retreat
doesn't secure. Metal stays in `base_resources`; items go to `player_inventory`.

**Key finding (no schema change needed).** The pending bundle already rides existing jsonb
columns end-to-end: combat accrues → `combat_encounters.total_rewards_json` → (on exit)
`fleet_movements.reward_payload_json` (via `movement_attach_cargo`) → (on arrival)
`reward_grant('combat', encounter, player, base, bundle)`. So Phase 4 is a **single
function change** — additive, no new column, no rename.

**Migration `0040_pending_loot_bundle.sql`** — rewrites `reward_grant()` (the secured-
deposit owner) to **split the bundle**:
- metal (and any scalar resource) → `Base.base_add_resources(p_rewards - 'items')`. The
  `- 'items'` strip is essential: `base_add_resources` casts every jsonb value to double and
  would choke on the items array.
- items[] → `Inventory.inventory_deposit(player, item, qty, key)` with key
  `'<source_type>:<source_id>:<item_id>'`.
- **Idempotency:** metal guarded by `reward_grants` UNIQUE(source_type,source_id) (one
  grant/source, early-return on replay) **plus** the inventory ledger key — both metal and
  items double-deposit-proof across cron retry / reprocessing.
- **Fail-safe validation:** items deduped by id (quantities summed), filtered to positive
  integers `< 1e9` (rejects negative/zero/NaN/Infinity); unknown item ids skipped with a
  logged `WARNING`; per-item + outer exception isolation so one bad entry never forfeits the
  metal or the valid items.
- Anti-cheat: `create or replace` preserves the 0039 client-revoke; added
  `grant execute … reward_grant … to service_role` (server/CI only, never clients) so the
  verifier can drive it — mirrors `inventory_deposit` / `process_build_queue`.

**Boundaries:** `SYSTEM_BOUNDARIES.md` — Reward now splits the bundle (sole caller of
`base_add_resources`; calls `Inventory.inventory_deposit` for items). Call graph stays
acyclic (Reward → Base, Reward → Inventory). Combat/movement unchanged; combat still accrues
**metal only** (no new drops — that's Phase 5). Reports keep `total_rewards_json` (metal
display intact; items ride along for free, display deferred).

**Verify:** `scripts/verify-phase4.mjs` — drives `reward_grant` directly as service_role
(metal-only · metal+items · idempotent re-grant · per-source key · unknown-item-safe ·
duplicate-combine · negative/zero/NaN-skip · empty-bundle no-op · client-denied) then chains
the regression (`verify-inventory` → m45 → m5 → m2/m3/m4) which proves the end-to-end timing
law (defeat forfeits, retreat doesn't secure, reports keep metal). CI `verify.yml` now runs
`verify:phase4`.

**Result (commit `4e1d7eb`):** Deploy ✅ · Build ✅ · Pages ✅ · Verify ✅ —
**Phase 4 16/16, Inventory 18/18, M4.5 27/27, M5 28/28, M4 40/40** (M2 11 / M3 13 chained),
0 failed. Migration 0040 live on `dlkbwztrdvnnjlvaydut`. **Phase 4 CLOSED.**

---

## 2026-06-17 — Phase 3: generic inventory foundation (DEPLOYED + VERIFIED ✅)

**Request** Clean generic item inventory for future rewards/materials. Metal stays in
`base_resources` (untouched); a future loot bundle deposits metal → base_resources, items →
player_inventory. No trading/mining/crafting/etc.

**Migration `0039_inventory.sql`:**
- `item_types` (Reference/Config, public read) + 10 starter items (scrap, ore, crystal,
  pirate_alloy, weapon_parts, engine_parts, repair_parts, captain_memory_shard,
  blueprint_fragment, artifact_core).
- `player_inventory` (PK `(player_id,item_id)`, `quantity >= 0`) — **owner-read RLS, no client
  write**. `inventory_ledger` (audit + `unique(idempotency_key)`) — owner-read.
- Functions (SECURITY DEFINER, server-only): `inventory_deposit(player,item,qty,key?)`
  (validates item+qty, upserts, **idempotent via the ledger key**), `inventory_spend`
  (transactional `FOR UPDATE`, rejects insufficient, **never negative**),
  `inventory_get_balance`. Lockdown re-grant (clients unchanged; inventory_* → service_role).

**Boundaries:** new **Inventory** system owns `player_inventory`+`inventory_ledger`;
`item_types` = Reference/Config. Metal/`base_resources` **untouched**; combat/movement/
world-state/reward unchanged.

**Verify:** `scripts/verify-inventory.mjs` (11 tests: seed, owner-read, cross-user RLS,
client-cannot-mutate, deposit-adds, idempotent deposit, spend-subtracts, insufficient,
no-negative, unknown-item, regression). CI `verify.yml` now runs `verify:inventory` (chains
M4.5 → M5 → M2/M3/M4).

**Result (commit `49cc946`):** Deploy ✅ · Build ✅ · Pages ✅ · Verify ✅ —
**Inventory 18/18, M4.5 27/27, M5 28/28, M4 40/40** (M2/M3 chained green), 0 failed.
Migration 0039 live on `dlkbwztrdvnnjlvaydut`. **Phase 3 CLOSED.**

---

## 2026-06-17 — Phase 2: Expedition Activity Architecture (design doc only)

**Request** Define the clean activity abstraction so future gameplay types plug into the
Expedition Engine without spaghetti. Docs only — no code, no migrations, no `src/`.

**Work:** new **`docs/ACTIVITIES.md`** covering the 10 required items —
`ExpeditionActivityType` (pirate_hunt / trade_run / exploration / mining, mapped to the
existing `activity_type` enum placeholders); shared lifecycle owned by the Engine (travel ·
arrival · presence · dispatch · pending-reward accrual · return · secured-on-arrival deposit ·
status · reports); per-activity ownership table; the **Activity Handler contract**
(`<activity>_create` + `process_<activity>_ticks` cron + optional `_request_leave` +
Engine.finish) — grounded in the existing `activity_start` router + the Combat precedent;
`PendingRewardBundle` (`{ metal?, items[] }`); history-only report/result shape; "add an
activity = enum value + handler + one dispatch line + one panel" (no giant switch); the
anti-spaghetti call graph (`activity → pending → secure-on-return → inventory → progression →
ranking`); explicit non-goals; acceptance criteria.

**No code / migrations / `src/` changes.** ROADMAP Phase 2 marked done → ACTIVITIES.md.
M2 11/11 · M3 13/13 · M4 40/40 · M4.5 27/27 unaffected (nothing executable changed). **Next:**
Phase 3 (generic inventory) when chosen.

---

## 2026-06-17 — Phase 1: roadmap / architecture reconciliation (docs only)

**Request** After M4.5, make the docs match the real game direction — **main-ship expedition
game**. Documentation only; no gameplay code; M2/M3/M4/M4.5 stay green.

**Work (docs only):**
- **New `docs/ROADMAP.md`** — the authoritative forward direction: final identity (one main
  ship + captains + modules + support craft → expedition → activity → return → inventory →
  progression → ranking); reclassification (**M2–M4 = Expedition Engine**, **M4.5 = Serial
  Build Queue Foundation**); standing laws (support craft = capacity-limited loadout, not
  additive power; one-directional pipeline *activity → pending → secure-on-return → inventory →
  progression → ranking*; don't replace the engine, replace the source of expedition stats via
  `calculate_expedition_stats`); the Phase 1–20 plan.
- **README** — intro reframed to main-ship expedition; milestones reclassified (Engine +
  Build Queue Foundation done) + forward direction → ROADMAP; removed the stale "M7 not
  started" / combat-reward-only framing.
- **ARCHITECTURE §16** — direction-update note + reclassification + pointer to ROADMAP.

**Not built (deferred to later phases):** main ship · captains · modules · inventory · trading
· exploration · mining · ranking. No migrations, no frontend behavior change. M2 11/11 · M3
13/13 · M4 40/40 · M4.5 27/27 unaffected. **Next:** Phase 2 (expedition activity architecture,
design only) when chosen.

---

## 2026-06-17 — ✅ M4.5 CLOSED (browser acceptance passed)

The automated **Playwright browser acceptance** test passed against the live Pages site —
M4.5's manual gate is met, so M4.5 is **closed**.

- **Browser test:** `tests/m45.spec.ts` (`verify:m45:browser`), CI workflow
  `.github/workflows/browser.yml`, run against `https://gkwngns714-spec.github.io/byeharu/`.
  **1 passed (17.3s).** Verified live: friendly coords (Sector 0:0, no raw "0, 0") · Train
  Scout ×5 active row (Per ship / Total order / Ship 1 of 5 / Remaining ticking / "delivered
  when full order completes") · Corvette ×2 waiting (no countdown, no Ship N) · cancel inline
  confirm (Refund + Penalty + Keep Building + Confirm Cancel) · Keep Building doesn't cancel ·
  Confirm refunds **once** (+125 = 50%) and the next waiting starts · refresh = no duplicate
  refund, cancelled gone · completed-history fold/unfold. Screenshots + traces uploaded as the
  `playwright-m45` CI artifact.
- **Backend:** `verify:m45` **27/27**; regression **M2 11/11 · M3 13/13 · M4 40/40**; CI build
  green. No gameplay/migration changes for the test (test infra only).

M4.5 reframed for the future as the **Serial Build Queue Foundation** (see
[[byeharu-final-direction]] — Main Ship + Support Craft). **Next:** Phase 1 docs/roadmap
reconciliation (docs only).

---

## 2026-06-17 — M4.5 Core UX + production queue law fix (CLOSED — see entry above)

**Status: NOT closed.** Fixes to the **M7 production queue** + two UI bugs (`build_orders`
is the M7 system — M5/M6/M7 already done; full M2–M7 kept green). Migration `0038`.

**Production now SERIAL** (was accidentally parallel — every order got `complete_at` on
creation): `build_orders` gains `waiting`/`active` states, nullable `complete_at`,
`started_at`; config `max_active_ship_production_slots=1` (designed to become N).
`train_units` enqueues **waiting** then `production_start_next` promotes one to **active**
(absolute `started_at` + `complete_at`). `process_build_queue` completes due **active**
orders then starts the next. Waiting items have **no `complete_at`** and don't tick.

**Cancellation:** `cancel_build_order` RPC — server-authoritative; validates ownership +
status; **waiting → 100% refund, active → 50%, completed/cancelled → rejected** (refund via
`Base.base_add_resources`). Cancelling the active item starts the next waiting one.

**UI:** `BuildQueuePanel` shows active (countdown) vs waiting (no countdown) + Cancel
buttons; `FleetStatusPanel` completed-history fold fixed (was an empty `<details>`) →
controlled toggle "Show N previous run(s)" / "Hide previous run(s)" with real content;
new `src/lib/location.ts` `formatLocationLabel` + `BasePanel` replace raw "0, 0" with
"Sector 0:0" / friendly names.

**Boundaries:** Production-only; combat/movement/world-state/reward untouched; absolute
timestamps (no per-tick decrement). `SYSTEM_BOUNDARIES` Production row already covers it.

**Verify:** `scripts/verify-m45.mjs` (serial · completion-starts-next · cancel waiting/active
· cannot-cancel-completed · ownership · anti-cheat · regression) — **supersedes `verify-m7`**
(parallel model; removed). CI `verify.yml` now runs `verify:m45`.

**Closure gate (pending):** deploy `0038` · `verify:m45` green · M2–M5 regression · CI build ·
browser check (serial countdown, cancel works, history folds, friendly coords).

---

## 2026-06-17 — M7 Ship Training (implemented; pending deploy/verify + click-through)

**Status: NOT closed.** Training-first ship production — the spending loop: **spend metal
→ queue training → cron completes ships into `base_units`**. Metal-only, timed queue, no
buildings/shipyard/research/captains/trade/mining/multi-resource.

**Migrations 0035–0037:**
- `0035_unit_costs.sql` — `unit_types.metal_cost` (scout 50 / corvette 150 / frigate 400);
  config `build_time_scale=1.0`, `min_build_seconds=5`, `max_build_orders=5`.
- `0036_production_system.sql` — `build_orders` table (Production-owned, RLS owner-read, no
  client writes); `base_spend_resources` (Base fn); `production_create_order/complete_order`;
  `train_units` RPC (auth → validate ownership/unit/qty/metal/queue-cap → `Base.spend` →
  `Production.create`); `process_build_queue` cron fn (FOR UPDATE SKIP LOCKED; idempotent —
  only `queued→completed`, ships never double-added); lockdown re-grant (+`train_units` to
  authenticated, `process_build_queue` to service_role).
- `0037_cron_build_queue.sql` — `process-build-queue` every 30s.

**Frontend:** `features/production/{productionTypes,productionApi,TrainShipsPanel,
BuildQueuePanel}`, `game/production/buildPreview` (cost+ETA preview, non-authoritative),
`catalog.ts` +`metal_cost`, `useGameState` +`build_orders`, `Dashboard` composes. Player
wording: **Train Ships / Training Queue / Not enough metal**. Only new action = `train_units`.

**Boundaries:** Production = sole writer of `build_orders` only; **never** writes
`base_units`/`base_resources` (spends via `Base.base_spend_resources`, deposits via
`Base.base_merge_units`). Acyclic Production→Base. Reward logic unchanged (only reads/debits
metal). No combat/world-state/movement changes.

**Verify:** `scripts/verify-m7.mjs` (16 tests) + `verify:m7`; CI `verify.yml` now runs
`verify:m7` (chains m5 → m2/m3/m4).

**Closure gate (pending):** deploy 0035–0037 · `verify:m7` green · M2–M6 regression · CI
build/typecheck · browser check (Train Ships + Training Queue render, train works, ships
appear).

---

## 2026-06-17 — M5 balance correction: pressure decay toward baseline (follow-up #3, Option A)

**Request** Fix the M5 issue where, with no players, every pirate_hunt location drifted to
pressure 100 / Severe and punished new players. **Option A only** (pure decay) — no newbie
zones, no new columns, no Option B/C.

**Change (migration `0034_worldstate_pressure_decay.sql`):** `worldstate_tick` passive
pressure now **DECAYS toward baseline** instead of drifting up:
`pressure += (baseline − pressure) * decay_rate − active_fleets * relief`. The step is a
fraction of the gap, so it asymptotes to baseline and **never overshoots** (decay_rate in
(0,1]). Empty locations return to **NORMAL** (baseline 50 → danger_modifier **exactly 1.0**
≈ M4); hunting still relieves below baseline; future defeat/event pressure can still raise
it above baseline (defeat_pressure remains a TODO, unwired). New config key
`worldstate_pressure_decay_rate = 0.1`. danger_modifier mapping unchanged.

**M5 law preserved:** World State still sole writer of `location_state`/`zone_state`; combat
**reads** `danger_modifier` only; presence is source of truth; `active_fleets` stays a
reconciled cache; cron unchanged (`process_location_state_ticks` → `worldstate_tick`). No
new schema/columns, no newbie zones, no frontend / combat / reward / fleet / presence
changes.

**Verify:** verify-m5 Test 2 changed from drift-up to decay (above→down, below→up,
at-baseline stays + modifier exactly 1.0, no overshoot, clamped); Test 4 relief made
deterministic. M2/M3/M4 regression unchanged.

---

## 2026-06-17 — ✅ M6 CLOSED (frontend depth / player clarity)

M6 browser re-test passed; milestone officially closed.

**Closure evidence:**
- M6 browser re-test passed.
- CI build/typecheck passed.
- Reports now show readable time.
- Round logs show per-round time.
- "en route" was removed from player-facing UI.
- Fleet wording is clearer: Traveling / Traveling to / Returning home.
- Dev-only ship grant script was added.
- No backend logic changed.
- No migrations changed.
- No combat math changed.
- No reward logic changed.
- M2–M5 backend systems remained untouched.

**Open follow-ups (tracked separately — NOT part of M6):** pre-existing react-hooks lint
cleanup · stuck throwaway test users/presences cleanup · danger pressure balance /
newbie-safe zones. **Next:** M7 (not started).

---

## 2026-06-17 — M6 Frontend Depth (implementation record — CLOSED above)

**Status: CLOSED 2026-06-17 (see closure entry above).** Implemented and CI-verified to compile; closure gate is a
manual browser click-through (below). Player-clarity pass over the M2–M5 loop —
**frontend only**: no migrations, no backend/combat/reward math, reads server truth only.

**Created (5):** `src/game/worldstate/danger.ts` (shared display labels +
High/Severe warning), `src/features/map/LocationPanel.tsx`,
`src/features/combat/RoundLog.tsx` (real `combat_ticks` fields only),
`src/features/combat/CombatReportPage.tsx` (`/reports`), `.github/workflows/build.yml`.

**Modified (9):** `combatApi.ts` (+read-only `fetchTicksForEncounter`, owner-RLS),
`useGameState.ts` (+`location_state` poll), `MapPage.tsx` (clickable cards → panel),
`SendFleetPanel.tsx` (pre-dispatch danger preview/warning), `FleetStatusPanel.tsx`
(lifecycle wording), `ActiveCombatPanel.tsx` (RoundLog replaces debug table),
`CombatReportsView.tsx` (link to `/reports`), `Dashboard.tsx` (pass states + nav),
`App.tsx` (`/reports` route).

**CI build/typecheck — ✅ green** (run 27656389298): `tsc -b` pass, `vite build` pass
(92 modules). `lint` is **non-blocking** and flagged 3 **pre-existing** M3/M4 files
(`useState(Date.now())`, `void refresh()` in effect — strict react-hooks v7); none of
the new M6 files. CI frontend verification is required since local npm is unreliable
(see [[byeharu-build-onedrive-bug]] equivalent note).

**Backend untouched:** zero migration/SQL/RPC changes; push did not trigger
deploy/verify. M5-close verification (M5 25/25 · M4 40/40 · M3 13/13 · M2 11/11) stands.

**M6 closure gate (manual browser click-through — all must pass):**
1. Map card click opens LocationPanel.
2. LocationPanel shows correct danger/activity + warning.
3. SendFleetPanel shows pre-dispatch danger preview.
4. FleetStatusPanel lifecycle wording is clear.
5. ActiveCombatPanel shows RoundLog (not the debug table).
6. Retreat/return messaging is understandable.
7. `/reports` opens correctly.
8. A past report can load its RoundLog.
9. No obvious broken layout.
10. No frontend writes to World State.

**Deferred (out of M6):** pre-existing react-hooks lint cleanup; danger-decay balance
(separate small migration only if the UI proves misleading — not rebalanced here).

---

## 2026-06-17 — ✅ M5 CLOSED (deployed + verified green in CI)

Migrations `0031`–`0033` deployed to the remote via the GitHub Action, and the new
**Verify** workflow ran the full suite on CI (Node 22). All green:

- **M5: 25/25** · **M4: 40/40** · **M3: 13/13** · **M2: 11/11** — 0 failures.
- M5 coverage proven: world-state rows seeded, passive drift, register/relief/
  unregister edges, active_fleets reconciliation, double-tick idempotency, and
  combat safely reading `danger_modifier` at a high-pressure location.
- M4 balance confirmed untouched (baseline pressure → danger_modifier 1.0).

**Bugs found + fixed during deploy/verify (couldn't surface without a live DB/CI):**
1. **pg_cron `'60 seconds'` invalid** (SQLSTATE 22023) — sub-minute syntax is 1–59s;
   60s must be standard cron `'* * * * *'`. Fixed in `0033`. (031/032 had already
   applied; 033 rolled back cleanly and re-applied after the fix.)
2. **CI on Node 20 threw "Node.js 20 detected without native WebSocket support"** —
   supabase-js 2.108's realtime client needs native WebSocket (Node 22+). Bumped
   `verify.yml` to Node 22.

**Verify CI:** secrets `VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY` /
`SUPABASE_SERVICE_ROLE_KEY` configured; workflow auto-runs after each deploy and on
manual dispatch. Verification no longer depends on the local toolchain.

**Next:** M6 (frontend depth) per `docs/ARCHITECTURE.md` §16.

---

## 2026-06-17 — M5 Living World (built; pending deploy + verify)

**Request** Build M5 per the "Living World Design Law": world-state pressure +
danger drift + location dynamics via a 60s cron, **without rewriting** the M2–M4
loop. Strict ownership (World State sole writer of `location_state`/`zone_state`),
combat may only *read* `danger_modifier`, acyclic cron, anti-cheat lockdown.

**Step 0 inspection (key findings)**
- No `worldstate_*` / `location_state` / `zone_state` existed — only deferred-stub
  comments (`0002`, `0008`). Built fresh.
- **Single unregister seam:** every terminal presence transition (escape, defeat,
  safe-leave) funnels through `presence_complete()` → one hook, not six.
- **Combat touches one function:** `combat_create_encounter` starts
  `enemy_integrity_current = 0`, so wave 1 spawns inside `process_combat_ticks`;
  the danger read goes there only.

**Work done (migrations `0031`–`0033`)**
- `0031_worldstate_tables.sql`: `location_state` (pressure/danger_modifier/
  active_fleets/last_tick_at) + `zone_state` rollup; public-read RLS, no client
  write; seeded one row per location/zone.
- `0032_worldstate_fns.sql`: 10 `game_config` keys (no magic numbers);
  `worldstate_register_presence` / `worldstate_unregister_presence` (cache ±1) /
  `worldstate_tick()` (reconcile active_fleets from real presences → drift/relief
  if elapsed ≥ min → bounded `danger_modifier` → zone rollup); service-role-only
  `dev_worldstate_prime` test helper; **edges wired** by re-creating
  `presence_create` (→ register) and `presence_complete` (→ unregister), behavior
  otherwise identical; **combat read** added to `process_combat_ticks` (× a
  fallback-guarded `danger_modifier`, else 1.0); re-locked execute surface.
- `0033_cron_location_state.sql`: `process_location_state_ticks()` → only
  `worldstate_tick()`; pg_cron every 60s. Cadences now 30s / 2s / 60s.

**Balance safety (Rule F):** `danger_modifier` is **piecewise with baseline → exactly
1.0**, and seed pressure = baseline = 50 → fresh locations multiply combat by 1.0,
so M4 numbers are unchanged until pressure actually drifts.

**Frontend (minimal, read-only):** `mapTypes.ts` `LocationState`; `mapApi.ts`
`fetchLocationStates()` (public read); `MapPage.tsx` shows "Pirate activity:
Calm/Rising/Severe" + "Danger: Low/Medium/High" on pirate_hunt cards. No writes.

**Verification:** `scripts/verify-m5.mjs` + `verify:m5` — Tests 1–9 (rows, drift,
register, relief, unregister, reconcile, danger-feeds-combat, double-tick
idempotency, M2/M3/M4 regression). Uses a **service-role key** to drive the locked
`worldstate_tick()`/dev helper (clients stay denied), mirroring the `dev_reset_player`
precedent.

**Not yet run (gated on user):** fresh clone has no `.env.local` and migrations
aren't on the remote. Local `npm install`/build also blocked by a known npm bug on
this OneDrive path (optional wasm deps `@tailwindcss/oxide-wasm32-wasi` etc. fail to
reify → "Exit handler never called", no `.bin` shims). **To finish M5:** `supabase
db push`, add `SUPABASE_SERVICE_ROLE_KEY` to `.env.local`, `npm run verify:m5`.

**CI:** added `.github/workflows/verify.yml` — runs `verify:m5` (chains M2/M3/M4) on
ubuntu after the deploy workflow succeeds, or via manual dispatch. Sidesteps the local
npm/TLS toolchain blockers. Needs repo secrets `VITE_SUPABASE_URL`,
`VITE_SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`.

**Also:** reconciled README milestone list to the real M1–M6 roadmap.

---

## 2026-06-17 — M4 cleanup (loose ends; verified 40/40)

**1. Reward deposit → home arrival.** Combat no longer deposits at escape. On
escape/auto-extract the pending rewards are attached to the return movement
(`fleet_movements.reward_grant_source` + `reward_payload_json` via new
`movement_attach_cargo()`), and `process_fleet_movements()`'s **return-arrival
branch** deposits them via `reward_grant` (idempotent unique source). Defeat → none
(zeroed). Deferred so future en-route risk/cargo "just works."
**2. Config extraction.** Added `reward_danger_scale=0.25`, `danger_time_divisor_seconds=180`,
`combat_damage_variance_pct=0.10`, `defense_curve_base=100`; `process_combat_ticks`
now reads them. No combat magic numbers remain in code.
**3. Dead code.** Dropped `fleet_apply_losses()` (superseded by combat_units +
fleet_sync_quantities; confirmed no live caller).

**UI:** combat pending note "secured only after your fleet returns to base"; returning
fleet shows "💰 rewards locked (secured on arrival)"; report "rewards secured when it
reaches base".

**Files:** `0030_m4_cleanup_reward_on_arrival.sql`; `scripts/verify-m4.mjs`;
`fleetTypes.ts`, `FleetStatusPanel.tsx`, `ActiveCombatPanel.tsx`, `CombatReportsView.tsx`;
`SYSTEM_BOUNDARIES.md`. Backend: 1 migration. Frontend: wording/types only.

**Verify:** `verify:m4` **40/40** (escape: not deposited; return carries rewards;
arrival deposits exactly once +metal; defeat/retreat-death: none; destroyed don't
return), `verify:m2` 11/11, `verify:m3` 13/13.

**M4 closed — no known loose ends.**

---

## 2026-06-17 — M4 CLOSE (combined final pass; all verified)

**Part 1 — retreat + wording**
- Retreat delay **20s → 8s** (config `retreat_delay_seconds`; UI countdown reads it).
- Report wording "Return movement started." → "Fleet escaped — now returning to base."
  Banner → "fleet breaks away and heads home in Ns." Combat-state label friendly
  ("In combat" / "Next wave incoming" / "Retreating").

**Part 2 — edge cases (verify:m4 37/37):** destroyed-during-retreat → defeat (no
reward/return); retreat spam → exactly one accepted; **destroyed ships do NOT return**
(base = initial − lost, e.g. scout 98 after losing 2); one-encounter-per-fleet; reward
once (idempotent); safe-zone & invalid-location rejected; defeat leaves no stuck
presence. Browser-refresh/offline: all combat state is server-side (cron-driven), UI
reloads from backend — survives refresh/close. M2 11/11, M3 13/13 (no regressions).

**Part 3 — cleanup**
- Dev helper `dev_reset_player(uuid)` added — SECURITY DEFINER, **not granted to
  clients** (SQL-editor/service-role only): clears stuck combat/movement/presence.
- Reward-securing rule: granted at **escape** (combat end). Return trip is
  uninterruptible (no en-route combat), so this == "secured on guaranteed return";
  death only happens pre-escape → no reward. Kept as-is (would move to home-arrival
  only when en-route risk exists).
- Hard-coded values to extract in a future balance pass: reward danger factor 0.25,
  danger time-divisor 180s, ±10% variance, defense curve 100/(100+def).

**Files:** migrations `0027` (wave HP), `0028` (retreat 8s), `0029` (dev_reset);
`scripts/verify-m4.mjs`; `ActiveCombatPanel.tsx`, `CombatReportsView.tsx`.

**M4 is safe to close.** Remaining (low) risk: balance not tuned to fleet power;
weapon cooldowns prepared not implemented; a few hard-coded balance constants.

---

## 2026-06-17 — M4 final checklist audit (all pass)

**Request** 22-point M4 final checklist before moving on.

**Already passing (no change):** combat start rules, ownership/RLS, one-active-
encounter-per-fleet (partial unique indexes), fixed 3s tick, wave transition,
pirate scaling (HP+attack+reward all danger-scaled), player damage (single
aggregate, no double-count), per-group damage distribution, per-unit integrity,
damage carryover, ship destruction, retreat behavior, defeat behavior, reward
behavior (idempotent), combat feed, debug (`combat_ticks` incl. `unit_snapshot_json`),
processor idempotency (FOR UPDATE SKIP LOCKED), client/server authority, boundaries,
final summaries.

**Needed change:** wave pacing was ~2 ticks for a modest fleet at low danger
(undertuned vs the 3-6 target). Fix `0027`: `enemy_hp_base` 6→14 → easy waves ~3+
ticks, scaling to normal/strong with danger. Added verify cases C (damage w/o loss),
F (one encounter/fleet), G (safe zone starts no combat), pacing assert ≥3, defeat
leaves no active presence.

**Files:** `supabase/migrations/0027_wave_hp_pacing.sql`, `scripts/verify-m4.mjs`.
**Backend:** 1 config value (wave HP). **Frontend:** none.

**Verification:** `verify:m4` **33/33**, `verify:m2` 11/11, `verify:m3` 13/13 — no
regressions (checklist J). Wave 504→320 (dealt 185), 3+ ticks/wave; survivors report
`{scout:7,frigate:2,corvette:5}`.

**Remaining M4 risk (low):** wave HP scales with danger, not fleet power → a
massively-overpowered fleet still clears low-danger waves fast (acceptable/by design);
weapon cooldowns prepared but not implemented; per-unit before/after captured in
`combat_ticks` but not surfaced in the UI debug table. Deep balance deferred.

---

## 2026-06-17 — M4 combat clarity pass (verified 28/28)

**Request**
Combat now feels like a survival loop. Small clarity improvements + fixed-interval
tick confirmation.

**Backend (`0026`)**
- Combat tick **2/4s → fixed 3s** (cron + config; damage keeps ±10% variance, the
  *interval* is fixed/non-random per design). Confirmed fixed-interval model; per-group
  damage loop already structured for future weapon/unit cooldowns (not implemented yet).
- Added `combat_reports.survivors_json`; `report_create` now records exact survivors +
  losses from per-unit `combat_units` (drives the post-retreat summary).

**Frontend (clarity)**
1. Latest exchange while retreating: "Your fleet is retreating — weapons disengaged" +
   "Pirates dealt N damage during disengagement" (no more confusing "0 damage").
2. Pending rewards note: "Locked — secured only if your fleet returns home safely"
   (and not-secured warning while active).
3. Retreat banner: "Retreating — return movement starts in Ns" (ties to M3 spine).
4. Per-unit rows show "alive/original ships (N lost) · HP · %".
5. Post-retreat **result summary** in Combat reports: result, waves, ships returned,
   ships lost, rewards secured/forfeited, "Return movement started."
6. Top line: "Wave 3 · Danger 3 · 2 waves cleared · Retreating".

**Verification — `verify:m4`: 28/28** (incl. report survivors `{scout:7,frigate:2,corvette:5}`).
Boundaries intact: server-authoritative; client renders + retreat only; M3 movement
used only after retreat succeeds; no captain/trading logic.

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
