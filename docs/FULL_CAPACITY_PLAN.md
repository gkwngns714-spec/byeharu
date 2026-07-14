# BYEHARU — MASTER PLAN: THE GAME AT FULL CAPACITY

*(Lead-architect plan, grounded in `main` @ `9d4cdb7`, prod migration head `20260618000170`. Team command
LIVE 2026-07-12; captains fast-follow prep in flight. Every claim cites the doc/migration it comes from.
This is a DECISION/DESIGN PACKET in the PORTCENTRIC_DECISION_PACKET.md family — `docs/ROADMAP.md` remains
the ONE queue-of-record; its phase rows 21–27 (appended after the 2026-07-12 PR wave merges) point here.)*

---

## A. THE GAME AT FULL CAPACITY

**The identity (ROADMAP.md "Final game identity"):** a main-ship expedition game — *"my ship and crew go
on dangerous expeditions, return with rewards, and become stronger"* — amended 2026-07-02 to **multiple
persistent main ships** organized into **3 teams × 6–8 ships, each crewed by 6–8 captains**
(TEAM_COMMAND.md header: "the player's designed endgame").

### The target loops

**Moment-to-moment (MAINSHIP_TRANSITION.md §12 OSN, PORTCENTRIC packet Part A):** undock from a port →
fly real coordinates through void space → cross zone boundaries that *react* (A8's designed depart-port →
cross-dangerous-zone → encounter flow) → dock at another port whose dockability is an explicit
`location_services` capability (WORLDHUB_OWNERSHIP.md), not a location type. Ships are individually
addressed instances that come home *damaged*, not deleted (ROADMAP law 1).

**Session loop (ACTIVITIES.md §1–3, ROADMAP phases 10–12):** pick an activity per team/ship —
`pirate_hunt` (live: team hunts vs Snare/Reaver/Blackden), `exploration` (scan within 750 of 5 hidden
sites — dark, 0097–0101), `mining` (extract 5 hidden fields — dark, 0102–0106), `trade_run` (buy low /
haul m³-bound cargo / sell high across differentiated ports — dark, 0073–0095) — every activity writing a
PENDING bundle secured only when the ship settles safe (the one-directional pipeline, ROADMAP law 3).

**Long-term loop (ROADMAP phases 13–20 + post-visibility sequence):** loot/ore/data → **craft modules**
(live) → **fit** (live) → **recruit + grow captains** (fast-follow / C2) → commission more ships and
**better hulls** → deeper zones gated by `min_power_required` (TEAM_ACTIVATION_PACKET §1.3 Option C) →
**seasonal rankings** on the four `reward_grants` dimensions (0127–0131) → **location investment** as a
credit sink shaping the world (0132–0134) → a **living economy** (price drift, pirate pressure, field
depletion — 0135–0138) narrated by **world events** (0139–0142) → eventually Online Presence & Visibility
v1, then player interaction, main-ship combat with real **Repair & Recovery** (ROADMAP cross-cutting
initiatives).

### The gaps between today's live game and that target

| # | Gap | Evidence |
|---|---|---|
| G1 | **Nine finished systems are dark**: exploration, mining, trade market (+relief), station storage, captains (in flight), ranking, investment, world balance, phase-20 events/assets | flag grep: `exploration_enabled` … `phase20_polish_enabled` all `false` |
| G2 | **The economy is one port deep**: `market_offers` seeds 6 goods at Haven ONLY (0085:48) — Slagworks and Driftmarch have docking but **no market, no services, nothing to do** | 0066 seeds 3 ports; 0085 seeds 1 *(fixed by ECON-SEED-1 / 0173)* |
| G3 | **Combat loot has no economy exit**: items convert only into 4 module recipes + 5 captain recipes; no item→credits path exists | 0107/0125; wallet faucets audit in packet §2 |
| G4 | **Credits have one live faucet** (one-time `starting_credits` 1000) and one live sink (ships @250) | packet §2 facts |
| G5 | **Content ceiling is shallow**: 8 locations total (3 hunts capped at bd 25, 2 safe, 3 ports), 1 hull, 4 modules, 5 captains, 5+5 hidden sites/fields, `min_power_required=0` everywhere | 0002/0066 seeds; packet F3 |
| G6 | **No progression depth**: captains have no XP (C2 unbuilt), no module tiers, `survival` has only the hull's 10 (no defense module exists — packet F2), commissioning hardcodes `starter_frigate` (0080:57) |
| G7 | **No live world dynamics**: `world_events` has writers but no producer; world-state pressure doesn't gate anything the player feels; zones don't react to crossings (A8 is a future contract) |
| G8 | **No repair economy**: `repair_main_ship` is the free/instant safelock (0052) — flagged as temporary (ROADMAP §Repair & Recovery). **ADDRESSED (dark, mig 0201 REPAIR-ECON):** a paid hull-repair economy `repair_ship_hull_at_port` (credits/hp, at-port, DAMAGED-alive ships) now exists behind `repair_economy_enabled=false`; the free destroyed-ship safelock is preserved UNTOUCHED (the seam). Awaits ACT-REPAIR. |
| G9 | **No onboarding/retention scaffolding**: no first-session guidance, no dailies/contracts, no reveal cadence for the hidden-world pattern (0066 proved reveal works) |

---

## B. THE ACTIVATION LADDER

The standing flip mechanism for every rung: a **human-run `scripts/activate-<X>.{sql,sh}`** in the
`activate-team-command` idiom (stage-1 knobs → stage-2 flags via `set_game_config` → stage-3 smoke
asserts → marked rollback section), followed where a compile gate exists by the **one-line client PR**
flipping the `osnReleaseGates.ts` constant, then the post-flip disposable proof. Server first, client
second — server rejects are the authority (TEAM_COMMAND checklist).

- **Rung 0 — Captains (prep shipped: mig 0171 + `activate-captains`).** Bump 2→6 + shard drop
  (`captain_shard_drop_rate`, launch 0.15). Risk: the bump is one-way once slots 3–6 fill. Rollback:
  **flags only, never slot counts**.
- **Rung 0.5 — Coordinate travel (prep shipped: mig 0178 COORD-GUARD + `activate-coordinate-travel`)**
  — the REACHABILITY prerequisite for rungs 1–2: exploration/mining sites sit out to ±4200 and require a
  settled `in_space` ship within 750 units, while every dockable anchor lives in bbox x −50…70, y −30…80
  (WORLD_RECON_F1 §7) — port-to-port travel reaches NO site, only free coordinate travel does. Flip
  `mainship_coordinate_travel_enabled`; mig 0178 first resolver-guards the raw coordinate command (the
  A0-fix — unguarded single-ship read, a real bug under live multi-ship) and the flip script
  preconditions on the guarded prosrc. No flip-time client PR (the coordinate UI is
  server-readiness-driven via `coordinate_travel_available`; the S6C ship-id passthrough already
  shipped with the slice). Rollback: flag only; in-flight moves settle regardless.
- **Rung 1 — Exploration (prep shipped: mig 0172 + `activate-exploration`).** Hard-gated on the 0172
  writer reconcile (the H1 strand fix). **REQUIRES Rung 0.5 first (reachability — see above).**
  Rollback: flag; discoveries persist harmlessly.
- **Rung 2 — Mining (prep shipped: `activate-mining`).** Post-flip watch: `secured_at IS NULL` rows =
  pending yields securing on next safe settle. **REQUIRES Rung 0.5 first (reachability).** Rollback: flag.
- **Rung 3 — Trade market.** Prereq: ECON-SEED-1 (mig 0173, §C P1). Flip `trade_market_enabled` +
  `trade_relief_enabled` + the one-line `TRADE_MARKET_ENABLED` client PR. Relief floor = the no-softlock
  backstop, light together. Rollback: flags; wallets/cargo/receipts persist inert; the
  `check (sell_price >= buy_price)` constraint prevents single-station pumps by construction.
- **Rung 4 — Station storage.** Prereq: trade live. Flip `station_storage_enabled` after
  `verify-station-storage.mjs`. The substrate P2 hauling stands on.
- **Rung 5 — Ranking.** Prereqs: a season (`ranking_season_open`, runtime-created, never migration-seeded)
  + ≥3 of the 4 `reward_grants` dimensions accruing (light after rungs 1–3). Risk near zero (read-only
  downward leaf). Rollback: flag; standings freeze intact.
- **Rung 6 — Location investment.** Prereq: a real credit faucet (trade live) + pair with P8's event
  narration so contributions are felt. Rollback: flag; append-only ledger persists.
- **Rung 7 — World balance + world events.** Prereq: trade + mining live (price drift / field depletion
  need consumers — note 0172 restored the depletion hooks 0143 had clobbered). Flip `world_balance_enabled`,
  then `phase20_polish_enabled` together with P8's producer so the feed isn't empty. Watch
  `price_multiplier` bounds for a week.

---

## C. NEW DEVELOPMENT PHASES

Each phase = dark slices, one green adversarially-reviewed PR per slice, flags + compile gates,
parity-discipline for any live-function re-create, disposable rolled-back proof for DB slices.

### FLEET — the fleet control-model *(S/M — SHIPPED dark as mig 0204; the OWNER'S FLEET-CONTROL RESHAPE)*

After FLEET-RENAME (team→fleet copy) landed, this phase adds the MECHANICS of the owner's control-model,
DARK behind a new flag `fleet_control_enabled` (seeded false) so the LIVE fleet-command game is
byte-unchanged until the owner flips it. The three rules: **(1) caps** — max 3 fleets (already:
`ship_groups` `(player, group_index 1..3)` unique, 0160), **up to 8 ships per fleet** (the new lit-only
`fleet_full` cap in `assign_ship_to_group`), min 1 (inherent); **(2) a fleet needs ≥1 COMMAND SHIP to be
active** — the additive per-ship designation `main_ship_instances.is_command_ship` (sole writer
`set_fleet_command_ship`, owner-scoped, ALWAYS settable [additive data, inert until the flag gates
movement], setting true requires the ship be in a fleet → `ship_not_in_fleet`; a fleet may carry MULTIPLE
command ships as backups); **(3) everything moves as a FLEET** — a fleet with zero command ships is
INACTIVE, so the three LIVE group RPCs (`send_ship_group_expedition` 0187 head, `move_ship_group_to_location`
0190 head, `send_ship_group_hunt` **0199** head — re-created from their TRUE heads with ONE marked
flag-gated hunk each) reject `fleet_inactive_no_command` when lit; the client hides the per-ship Move
affordance (`MainShipCommand`) and routes movement through fleets, guiding a lone ship to "add this ship to a
fleet to move it". DARK = byte-identical (extract-and-diff pinned; the column is ignored, no client surface).
Client mirrors are runtime-flag-gated via `strictConfigFlag('fleet_control_enabled')` / `fetchFleetControlEnabled`
(command-ship toggle + Active/inactive indicator + the 8-cap in the add-ship picker in `TeamRosterPanel`;
inactive-fleet disable/hint in `TeamMapSend`). Proof = the `TEAMCMD_PASS_FLEETCTRL` block (both arms).
**ACT-FLEET-CONTROL** (`scripts/activate-fleet-control.{sql,sh}`) flips the flag — FLAG-ONLY, with a smoke
FYI of how many existing fleets go inactive at flip time (every command-shipless fleet, since no ship is a
command ship on deploy); NO client PR needed (runtime-flag-gated). Does NOT touch the adapter
(`calculate_expedition_stats`) or captains/decks/ShipDossier — reuses `ship_groups` + the group RPCs; the
whole reshape is ONE additive column + marked hunks. COMMAND-BUFFS (below) folds command-ship buffs
through the adapter re-create; FLEET-CONTROL deliberately does not.

### FLEET — command buffs: the FINALE of the fleet reshape *(M — SHIPPED dark as mig 0205; the OWNER'S COMMAND-BUFF DESIGN)*

The finale of the fleet reshape, DARK behind a new flag `command_buffs_enabled` (seeded false). Owner's
words: "each tier will have ~10 buffs, assigned RANDOMLY when bought or manufactured … command ship will
provide those buffs … a buff slot, activated only when the ship is set on command ship." This maps onto
SHIP-SOUL almost exactly (no new mechanism): **(1) a CATALOG** — `command_buff_types` (the `ship_trait_types`
0186 mold: `buff_id` collate-"C" / `tier` / `name` / `description` / `stats_json` in the shared 0180/0198
adapter vocabulary), organized by ship TIER via the new additive `main_ship_hull_types.tier` column
(`starter_frigate`=T0; `bulk_hauler`/`strike_corvette`=T1 — the 0185 split), ~10 buffs per tier, themed
(gunnery→fleet attack, engineering→fleet speed, logistics→fleet cargo, …), EXTENSIBLE (additive
on-conflict seeds — a later buff never re-derives a rolled ship). **(2) a ROLL** — the ship's BUFF SLOT
`main_ship_instances.command_buff_id` (nullable FK), rolled DETERMINISTICALLY at commission
(`hashtextextended('<ship_id>:cmdbuff',0)` → the tier pool's collate-"C" order — the 0186 pure-hash law,
no RNG) by an AFTER-INSERT trigger (the ROOMS-8 0203 seed-trigger seam — covers every commission path
WITHOUT re-creating a commission function) + a monotonic backfill; IMMUTABLE once set (NULL-guarded
write). The roll is ALWAYS-ON additive data — NOT flag-gated; inert until the fold. **(3) the FOLD** —
`calculate_expedition_stats` re-created from its TRUE head **0198** (NANGUARD; the ONE adapter re-create
of this program, extract-and-diff pinned — every accumulated 0115/0122/0170/0180/0193/0196/0198 hunk
byte-identical, only the marked COMMAND-BUFFS hunk differs) with ONE hunk: when `command_buffs_enabled`
AND the ship is in a fleet (`group_id` not null), fold the fleet's ACTIVE command ship(s)' rolled buff
`stats_json` FLEET-WIDE into THIS ship's totals (the shared additive 8-key fold; multiple command ships
sum — backups). DOUBLE-GATED: flag false → the loop is skipped entirely (dark = byte-identical); flag
true + ungrouped / no command ship → empty loop (byte-identical) — the DECKS-3/level double inertness.
DEPENDENCY: the fold needs `fleet_control_enabled` too (is_command_ship is only meaningfully set through
FLEET-CONTROL) — the fold itself gates on `command_buffs_enabled` alone. Client: the ShipDossier gains a
runtime-flag-gated **Command buff** line (name + effect + "applies to the whole fleet when this ship is
the command ship") reusing the SOUL-2 trait-display idiom. Proof = the `TEAMCMD_PASS_CMDBUFF` block (dark
parity + lit fleet-wide fold exactness + no-command-no-buff + the group_id gate). **ACT-COMMAND-BUFFS**
(`scripts/activate-command-buffs.{sql,sh}`) flips the flag — FLAG-ONLY, with a catalog-freeze +
buff-slot-coverage precondition and the FLEET-CONTROL dependency; NO client PR needed (runtime-flag-gated).

### P0 — NO-HOME: launch from the dock, dock at the return port *(S/M — SHIPPED dark as mig 0199; the OWNER'S ABSOLUTE LAW)*

There is NO home base; ports are the only base; a ship acts from WHEREVER it is docked. The bug: SEND
(`send_main_ship_expedition`) and HUNT (`send_ship_group_hunt`) require ship `status='home'` and launch
from the legacy invisible base at (0,0); a docked ship can MOVE (`move_main_ship_to_location`, 0156) but
not SEND/HUNT. **NO-HOME (0199, DARK behind `launch_from_dock_enabled`):** send/hunt ADDITIVELY accept a
docked ship as a launch state (the settled-safe `spatial_state in ('home','at_location')` rule of
0100/0105/0114/0121), launch from the docked port (the 0156 present-fleet origin), and take a chosen
`p_return_location_id` (recorded on the additive `fleets.return_location_id`); the reconciler
`process_mainship_expeditions` DOCKS the returning ship at that port (the 0153 helper) instead of
re-homing, and `repair_main_ship` revives docked (recovery always works). Every DARK else-branch is the
grep-verified TRUE head verbatim (parity discipline; team command is LIVE on prod). Client reads the
flag at runtime via `strictConfigFlag` and, when lit, treats a docked-together team as sendable/huntable
with a return-port control — byte-identical when dark. **ACT-NOHOME** (`scripts/activate-nohome.{sql,sh}`)
flips the flag; the `TEAMCMD_PASS_NOHOME` proof block witnesses both arms. Orthogonal to team-command /
mainship-send activation (it changes HOW a launch is sourced/returned, not WHETHER send/hunt are lit).

### P1 — ECON-SEED: the differentiated three-port economy *(S — SHIPPED as mig 0173 / PR #104)*
Port role identities over the six 0073 goods: Haven = city/consumer, Slagworks = industrial,
Driftmarch = frontier premium. Guaranteed routes: ore Slagworks→Haven +200/trip, provisions
Haven→Slagworks +200, machinery Slagworks→Driftmarch +384 (full table + proof in 0173 /
`trade-econ-seed-proof`). `market_offers` stays Reference/Config, migration-seeded only; the P19 drift
multiplier layers on top untouched.

### P2 — HAUL: contracts & logistics between ports *(M — FULLY STOCKED DARK: HAUL-0/1/2/3 shipped as migs 0176 + 0179 + 0181; ACT-HAUL flip script SHIPPED — awaiting the human flip, AFTER trade)*
NPC delivery contracts: a per-port bulletin offers "deliver N×good to port B by T for C credits + bonus."
Slices: HAUL-0 `haul_contracts` schema + flag + templates (dark, service-role writers — **shipped**, 0176);
HAUL-1 offer generator (cron, seeded-deterministic per port/day — **shipped**, 0176); HAUL-2 accept/deliver
RPCs (accept = origin-port claim + `deliver_by` deadline + active cap; deliver = docked-verified at the dest
+ cargo debit via Trade-Cargo's own functions + `wallet_credit` with `haul_receipts` — **shipped**, 0179);
HAUL-3 bulletin UI on PortScreen (`get_port_contracts` gated read + server-lit HaulBoardPanel — **shipped**,
0181/PR #117); HAUL-proof (**shipped + extended**, `scripts/haul-proof.{sql,sh}`); ACT-HAUL flip
(**script shipped**, `scripts/activate-haul.{sql,sh}` — one txn: flag then ONE sanctioned generator invoke
for instant offers at all 3 ports; hard-preconditions on `trade_market_enabled=true` — deliver consumes
`ship_cargo_lots` and `market_buy` is the SOLE cargo-lot producer, so dark-trade contracts are
undeliverable; mining's ore is item-inventory, never cargo. FLIP ORDER: after ACT-TRADE).
Deps: P1 + Rung 3. Guard: Contracts owns only `haul_contracts` + `haul_receipts`; cargo moves only through
Trade-Cargo, credits only through Wallet — the SYSTEM_BOUNDARIES rows landed in the same PRs as the schema.

### P3 — SALVAGE: combat-loot → port-economy feed *(S/M)*
Ports gain item buy-lists: `port_item_demand (location_id, item_id, unit_price)` — migration-seeded,
per-port differentiated (Slagworks pays best for scrap/pirate_alloy, Haven for repair_parts, Driftmarch
for engine_parts; progression items `captain_memory_shard`/`blueprint_fragment`/`artifact_core` are
**never** sellable). Slices: SALVAGE-0 schema+seed+flag `salvage_market_enabled`; SALVAGE-1
`sell_item_at_port` (docked-verified via the ONE trade docked-resolver 0092/0138, `inventory_spend` +
`wallet_credit`, idempotent receipts — the 0090 sell shape); SALVAGE-2 UI on DockedPortCard; proof.
Deps: Rung 3. Guard: pipeline unchanged — combat → pending → inventory; SALVAGE consumes inventory
exactly like crafting does; combat never grants credits directly (ROADMAP law 3).

### P4 — ZONES-2: the C-seeds — new zone, difficulty tiers, reveal cadence *(S — ZONES2-1/2 SHIPPED as mig 0175 + `scripts/reveal-ember-reach.{sql,sh}`; hidden, awaiting the human reveal)*
ZONES2-1: additive `locations` seed — "Ember Reach" with 3 hunt sites at bd 40 / min_power 150,
bd 50 / 220, bd 60 / 300 (≈4/6/8 kitted+captained ships per packet §0.3 math), seeded `status='hidden'`.
ZONES2-2: a reveal operation script (the reveal-starter-ports runbook idiom — reveal IS the cadence
mechanism: ship content hidden, reveal deliberately, ~monthly). ZONES2-3 (only if live tuning demands):
the packet's Option-B `enemy_team_scale` knob via a parity-shaped tick re-create — never a second engine.
Deps: none (pure data). Guard: zero engine edits in 1/2.

### P5 — CAPTAIN-C2: progression *(M)*
C2-0: additive `captain_instances.xp/level` + flag `captain_growth_enabled`. C2-1: XP accrual as a
**downward reader of finalized `reward_grants`** (the exact commit-safe 0144/0145 anti-join idiom) with a
`captain_counted_grants` ledger. C2-2: level curve → adapter parity delta (`stats × (1 + level_bonus)`,
byte-inert at level 1). C2-3: XP bars in TeamMemberCaptains. **C2-4: the 6→8 slot raise — SHIPPED (dark)
inside ROOMS-8 (mig 0203, slice-rooms8): all hulls `base_captain_slots`→8 + instance backfill (the 0171
idiom), folded into the CONFIGURABLE-ROOMS reshape below.** Deps: Rung 0. Guard: Captain system stays sole
writer; XP reads finalized grants exactly like Ranking does — combat never writes captain XP mid-tick.

**ROOMS-8 — configurable ship rooms (owner order 2026-07): "8 captain slots … create many rooms …
change room by modifying the ships … able to choose"). SHIPPED (dark)** — mig `0203` (slice-rooms8),
extends the 0189/0196 decks system, DOES NOT fork it. (1) captain slots 6→8 (C2-4 above). (2) `ship_stations`
IS the room catalog — eight rooms appended (additive on-conflict-do-nothing; the frozen six + the 0196
affinity mapping unmoved). (3) NEW `ship_room_slots` (main_ship_id, slot_index 1..8, room_type_id;
distinct rooms per ship) = the ship's 8 configurable slots the player CHOOSES — sole writer
`ship_room_configure` (wrapper `configure_ship_room`), read `get_my_ship_room_slots`, defaults seeded by
an AFTER-INSERT trigger + monotonic backfill. (4) `captain_assign_apply` re-created from its 0189 head
(marked hunks ONLY) to scope station resolution to the ship's FITTED slots — **the DECKS-3 adapter
`calculate_expedition_stats` was NOT re-created** (`ship_captain_assignments.station` stays a
`ship_stations.station_id`, so the 0196 LEFT-join read-shape is byte-untouched — a parallel COMMAND-BUFFS
slice owns the next adapter re-create). (5) client: the ShipDossier Captains section becomes the 8-slot
room board (room picker + staffing captain), server-lit gated → deploy-inert. Proof = the extended
`decks-proof.{sql,sh}` (8-slot seed, slot-scoped assign, room config rejects, cap-first, the affinity fold
STILL firing through the preserved read-shape, station + slot backfills). Rides the existing captain gate
`captain_assignment_enabled` (no new flag). ACT: lights with the captains flip (ACT-CAPTAINS).

### P6 — SHIPYARD: ships are BUILT, not bought *(M/L — SHIPYARD-0 SHIPPED dark as mig 0185; supersedes the old HULLS-2 line per the SHIPYARD charter)*
**The production model (owner directive: "ships must be made through mining, production, level
requirement and more"):** T0 = `starter_frigate` — the existing credits-only commission, UNTOUCHED.
T1 = **bulk_hauler** ('Mule-class Hauler': hp 650, speed 0.8, cargo 140, modules 2, captains 6,
`{attack 5, defense 15}`) and **strike_corvette** ('Talon-class Corvette': hp 420, speed 1.3, cargo 20,
modules 4, captains 6, `{attack 30, defense 10}`) — BUILT from mined/dropped materials + credits over a
build timer (role emergent from fit, no activity locks — MAINSHIP_TRANSITION core vision; the 0184
Mule/Talon class register). T2+ = later hulls gated by `required_hull_type_id` (own the prerequisite
hull) + `required_captain_level` (the owner's "level requirement") — the gate columns exist from day 0;
T1 seeds both NULL (honest: captain levels are dark). Recipes [D, owner-tunable]: hauler = ore 24 +
crystal 6 + engine_parts 6 + scrap 12 + blueprint_fragment 2; corvette = ore 16 + crystal 4 +
weapon_parts 6 + pirate_alloy 8 + blueprint_fragment 2; both credits 400 / build 3600s.
**Slices (0 shipped, all dark behind `shipyard_enabled=false`):**
SHIPYARD-0 **shipped** (mig `0185`, slice-shipyard0): `shipyard_enabled='false'` +
`hull_build_recipes`/`hull_recipe_ingredients` (Reference/Config, migration-seeded only, public read —
the 0107 posture) + the 2 T1 hulls seeded dark + the **blueprint faucet** — `pirate_loot_for_wave`
re-created from its TRUE head (0171, grep-verified; parity diff = the one marked hunk) with the
config-gated w≥8 blueprint_fragment drop (`blueprint_fragment_drop_rate` seeded '0' → byte-inert; the
exact 0171 shard idiom; shards w≥2, blueprints w≥8 — the deep-run gate; the 0098 exploration one-shot
remains the second source); self-asserting (exact hull/recipe shapes, F4 drop grounding vs loot
prosrc/field bundles/site bundles, hunk-token + rate-0 parity pins, flag dark); proof = the
`TEAMCMD_PASS_SHIPYARD0` block in `team-command-proof` (catalog exact; rate-0 byte-parity / rate-1
w≥8 exactly-one-appended-blueprint / w<8 + wave-1 thresholds — the SHARDDROP technique).
SHIPYARD-1 **shipped** (mig `0188`, slice-shipyard1): the build command — `start_hull_build`
(authenticated wrapper → private `production_start_hull_build`, the 0109 two-layer idiom; gate-first
in both layers, no hull-existence oracle while dark) on the REUSED M4.5 `build_orders` serial queue
(never a second timer system; additive generalization: nullable unit/base + `hull_type_id` FK to
`hull_build_recipes` — only recipe-carrying hulls orderable, T0 stays commission-only — +
`credits_spent` + the kind-coherence CHECK), spending items via `inventory_spend` + credits via
`wallet_debit` (all-or-nothing under a per-player advisory lock), enforcing the 0185 recipe gates
(required hull / captain level — dormant-NULL on T1, enforced when a recipe sets them) + the SHARED
`max_build_orders` cap, receipted + replay-idempotent on (player, request_id) via
`hull_build_receipts`. Orders land 'waiting' and are INVISIBLE to the 0038 engine by construction
(the unit_types-join promotion + active-only processing, both prosrc-pinned by the 0188
self-assert). **SHIPYARD-2 seam items — ALL THREE pre-flip requirements RESOLVED (mig `0194`,
slice-shipyard2): the engine's hull arm (activation with recipe `build_seconds` + completion),
delivery through the commission core, and hull-aware `cancel_build_order` refund semantics** —
see the SHIPYARD-2 shipped entry below. A fourth seam risk —
the 0047 retention reaper (terminal `build_orders` >30d) cascading receipts away and silently
expiring the replay guarantee — was **RESOLVED IN-SLICE** (review H1): `hull_build_receipts.order_id`
is nullable, FK ON DELETE SET NULL — receipts are the durable replay/audit ledger and outlive the
reap (unlike the three items above, this was never a pre-flip requirement). Proof =
`scripts/shipyard-proof.{sql,sh}` + `shipyard-proof.yml` (standalone workflow —
team-command-proof is contended by in-flight slices; trade-proof-lib reused): dark gate/no-oracle ·
exact-spend order · verbatim replay · blueprint/credit shortfalls · both gate arms · self-prereq
impossibility · the engine seam · receipt survival past the REAL 0047 reaper.
SHIPYARD-2 **shipped** (mig `0194`, slice-shipyard2 — RENUMBERED from 0192 per 0193's recorded
collision choreography): build completion → DELIVERY, dark +
double-inert (no hull order can exist while `shipyard_enabled` is false, and with zero hull rows
every re-created body behaves byte-identically — the unit arm's proofs stay green). The 0038
queue engine re-created from its TRUE head (grep-verified: 0036/0038 the only create sites) with
marked hunks: `production_start_next` gains the hull candidate branch (oldest waiting hull via the
strict `hull_build_recipes` join competes with the oldest waiting unit by `queued_at`; duration =
recipe `build_seconds` under the 0038 min floor, no `build_time_scale` — recipe seconds are
owner-tuned directly) + the per-player 'production_start' advisory xact lock (review M1 — closes
the pre-existing concurrent-promotion race past max_active; strictly a race-closure, the one
deliberate unit-path delta); `process_build_queue` guards `base_merge_units` behind a hull-null
kind dispatch, runs the HULL arm of its completion loop in a PER-ORDER begin/exception
subtransaction (review H1, the EV-1 per-publication precedent, query_canceled re-raised: a
permanently-failing delivery — e.g. the commission port undockable — leaves THAT order active for
retry and never wedges other players' completions; the unit arm keeps the exact 0038 abort
posture), and gains the hull-only PROMOTER SWEEP (hull orders enqueue with no immediate start —
the 0188 order RPC is untouched; the 30s cron promotes, ≤30s activation latency, self-healing);
`production_complete_order` delivers a completed hull through the ONE commission build core —
`port_entry_commission_build` re-created from its 0193 TRUE head (the 0184 body + SOUL-1's gated
trait-roll hook, carried verbatim — a delivered hull is born with its soul when lit) taking
`p_hull_type_id` default `'starter_frigate'` (byte-inert: both existing callers are single-arg;
the starter path keeps the exact 'Sparrow' output) — under the 0184 `main_ship_commission`
naming-race lock; a delivered hull
gets its catalog stats verbatim + the 0184 name idiom with the class name riding the hull row and
the numeral counting ALL of the player's ships across classes (a third ship that is a first Mule
= 'Mule-class Hauler III' — the per-player-ordinal law, not a per-class counter), docked at the
commission port (Haven Reach — the charter's
"ordering port" is unrecorded on 0188 orders, so the 0184 behavior is kept, documented [D]);
delivery deliberately does NOT check `max_main_ships_per_player` (the cap guards the commission
RPCs; a built hull is bought and paid — recorded for the flip review [D]). `cancel_build_order`
re-created with the hull refund arm MATCHING the unit arm's semantics [D]: waiting → 100%,
active → 50% floored (credits via `wallet_credit` 0093 — no idempotency key, the FOR UPDATE
status flip is the sole and sufficient credit double-refund guard — + ingredients via
per-deposit-keyed `inventory_deposit` 0039, the bill read from the durable
`hull_build_receipts.ingredients_json`;
receipt never rewritten — replay stays verbatim after delivery AND after cancel). **The
fleets-shim retirement the charter sketched here is EXPLICITLY DEFERRED** [D]: build is NOT one
of the three md5-pinned PORT-ENTRY bodies (pins = writer / commission_first / normalize,
grep-verified; 0184's build re-create is the precedent), all three pinned bodies are
byte-untouched, and the fleets insert inside build is byte-identical — retiring the exception
would force a hygiene-only re-create of the FROZEN pinned `normalize_main_ship_dock`, exactly the
live-path risk the SYSTEM_BOUNDARIES note forbids; the exception note is updated (not deleted)
with this recorded deferral — boundary hygiene, NOT a pre-flip requirement. Proof extended (the
same standalone harness): `SHIPYARD_PASS_PROMOTE` (cron-sweep promotion with recipe
build_seconds exact; serial one-slot law across kinds) · `SHIPYARD_PASS_DELIVER` (two-timestamp
exact-duration fast-forward — the frozen-now() `complete_after_queue` CHECK law — → exact
stats/name delivery docked at the port; unit order promotes/completes
byte-identically — the exact 0038 formula + `base_merge_units`; post-delivery replay verbatim) ·
`SHIPYARD_PASS_DELIVERY_GUARD` (a POISONED delivery — port undockable, in-txn fixture — leaves
its order active and uncounted while a second player's co-tick unit completion proceeds; fixture
restored → the next tick self-heals and delivers) ·
`SHIPYARD_PASS_CANCEL_REFUND` (exact full refund from the receipt bill; double-cancel rejected,
no double refund; post-cancel replay verbatim; active-cancel floor-half exact) — the original 8
markers stay green (P6's engine-invisibility block honestly rewritten to pin the CLOSED seam).
SHIPYARD-3 **shipped** (PR #137, slice-shipyard3 — client-only: the ShipyardPanel recipe list +
build queue on PortScreen, dark behind `shipyard_enabled` / server-lit; no migration, no engine
edits — merged while SHIPYARD-2 was in review, reconciled here). ACT-SHIPYARD: the human flip script — **preconditions: mining lit (the ore/crystal
faucet) + trade/salvage lit (the credits faucet)**, blueprint knob raised [D] in the same window;
still needs: the `shipyard_enabled` flip + the `blueprint_fragment_drop_rate` faucet knob raise +
those preconditions (all three pre-flip engine seams are now closed; the deferred fleets-shim
retirement does NOT gate the flip).
Deps: credits flowing (Rung 3/P3) + ACT-MINING. Guard: stats only ever enter play via
`base_stats_json` through the 0170 adapter fold — no new stat path; the recipe tables stay
Reference/Config (migration-seeded, NO runtime writer); combat never grants ships.

### P7 — MODULES-2: tiers + the defense line *(S/M — MOD2-1 SHIPPED as mig 0183 + the team-proof MOD2 block; dark behind the existing module gates)*
MOD2-1 **shipped** (mig `0183`, slice-mod2): `shield_lattice` (slot_type `defense`, slot 1,
`{"defense": 12}` → the adapter's `survival` output — key names prosrc-verified against the 0180
head's module loop at migration time) with recipe repair_parts 4 + pirate_alloy 3 + scrap 8 (all
live 0171 loot drops; the repair_parts w≥10 gate makes the shield a deliberate MID-GAME unlock) +
`mining_rig_extension` (slot_type `mining`, slot 1, `{"mining": 8}` → `mining_yield`) with recipe
crystal 2 + ore 6 + scrap 4 (crystal/ore are mining-field drops — the mine-to-mine-better loop;
NOTE `mining_yield` has no engine consumer until weighted yields ship — the stat surfaces in
previews/group totals only). Recipes from live drops only (the F4 lesson, self-asserted against
loot prosrc / field bundles); both new archetypes take the adapter's `else 0` tradeoff arm (the
engine posture — their cost is the slot). Proof = the `TEAMCMD_PASS_MOD2` block in
`team-command-proof` (exact-price craft → fit → survival +12 / mining_yield +8 exactly — the
defense stat's FIRST end-to-end pin); verify-modules/verify-fitting contracts extended 4→6.
MOD2-2 **shipped** (mig `0202`, slice-mod22): the Mk-II tier — `autocannon_battery_mk2` (slot_type
`weapon`, `slot_cost 2`, `{"attack": 18}` → the adapter's `combat_power` + the weapon tradeoff
attention/speed cost) with recipe blueprint_fragment 2 + artifact_core 1 + weapon_parts 6, and
`shield_lattice_mk2` (slot_type `defense`, `slot_cost 2`, `{"defense": 20}` → `survival`, else-0 arm)
with recipe blueprint_fragment 2 + artifact_core 1 + repair_parts 6 (the shared progression pair +
the base tier's line component; the tier rule is a flat +8 on the base stat — attack 10→18, defense
12→20). `slot_cost 2` so 3-slot frigates carry at most one Mk-II + one base module (the capacity-
tradeoff law made real). Recipes from live drops only (F4, self-asserted: blueprint_fragment/
weapon_parts/repair_parts vs the 0185 loot prosrc, artifact_core vs the Singularity Scar mining-field
bundle). HONEST FAUCET GATE: blueprint_fragment's combat faucet (`blueprint_fragment_drop_rate`) is
committed 0 and its only non-combat source is the one-shot 0098 exploration site (qty 1 — NOT a mining
drop), so the shipped ceiling is 1 while each Mk-II needs qty 2 → both Mk-II are UNCRAFTABLE under
every shipped config until the combat faucet lights (a separate activation this slice does not ride),
the EXACT deep-gate SHIPYARD-0's T1 ships already carry (blueprint_fragment 2 behind the same closed
faucet). Deliberate; self-corrects at the flip. No new flag — lights with the existing `module_crafting_enabled`/
`module_fitting_enabled` flips. Proof = the `TEAMCMD_PASS_MOD22` block in `team-command-proof` (two
fresh fixture users, one Mk-II each since a slot-2 pair overflows the 3-slot frigate: shield fit →
survival +20 exactly on the else-0 arm; autocannon fit → combat_power +18 + the FIRST end-to-end pin
of the weapon tradeoff arm, pirate_attention +4 / speed × 0.94 exactly; both exact-price craft →
insufficient_items boundary, minus-key isolation both fits); verify-modules/verify-fitting contracts
extended 6→8 types / 18→24 recipe rows. MOD2-3: balance-table refresh with defense live (proof-only).
Deps: none.
Guard: all stats flow through `module_types.stats_json` → the existing fitting adapter; the
Σ`slot_cost` ≤ `module_slots` reject-never-clamp cap already enforces tradeoffs.

### P8 — EVENTS-LIVE: world events as a live system *(M — EV-1 SHIPPED dark as mig 0182; EV-2/EV-3 + the Rung-7 flips remain)*
EV-1 (**shipped**, mig `0182` / `scripts/ev1-proof.{sql,sh}` / `world-events-proof.yml`):
`worldstate_tick` publishes STATE-detected threshold events through the existing
`world_events_publish` (`pressure_high` warning/critical while at/above
`event_pressure_high_threshold=75` — a parked-high location re-announces daily, intended
pressure-nagging — + `pressure_eased` as the exact complement suppressed unless today's high was
announced; `field_depleting` below `event_depletion_warn_fraction=0.25`; `price_surge`/`price_crash`
outside `event_drift_extreme_band_low/_high=0.6/1.4` — all [D] owner-tunable with gated+guarded knob
reads, all dedup-keyed per (subject, UTC day); one failure-guarded subtransaction PER publication so
the 60s heartbeat never aborts and a failed publish genuinely retries; DOUBLE-DARK behind
`world_balance_enabled` × `phase20_polish_enabled`, zero events until BOTH flip — exactly the Rung-7
order). EV-2: **event sites** — a producer that
time-activates seeded `event_site` locations (the `location_type` value has existed since 0002, never
used): a boosted-tier hunt zone live for 48h, retired by lifecycle (`hidden`), never deleted (A6). EV-3:
event feed UI (WorldEventsPanel + map badges via `ui_asset_catalog`). Deps: Rung 7. Guard: events
*narrate* — World Events is a downward leaf; it never writes zone_state/rewards (its own charter); the
reacting systems remain the owners.

### P9 — REPAIR-ECON: Repair & Recovery *(M/L — the designed initiative)*
RR-0: `repair` service rows in `location_services` at the 3 ports + flag `port_repair_enabled` (the
WORLDHUB vocabulary already includes `repair`). RR-1: `repair_ship_at_port` (docked-verified, cost =
f(missing hp) in credits + repair_parts, duration via the **reused M4.5 build-queue**, not a second timer
system). RR-2: recovery redesign per MAINSHIP_TRANSITION §13 (destroyed → recovery at last-safe-dock,
Haven fallback per A7) with the 0052 safelock preserved as the compatibility path until a flagged cutover.
RR-3: UI. Deps: credits (Rung 3/P3). Guard: one owner — Repair extends Main Ship + Production; the free
safelock is replaced by a flagged cutover with rollback, never edited in place.

**REPAIR-ECON v1 SHIPPED DARK (mig `0201`, slice-repairecon):** the honest-minimal core of RR-1 + RR-3.
A NEW paid RPC `repair_ship_hull_at_port(p_main_ship_id, p_repair_hp, p_request_id)` mends a DAMAGED-but-
alive ship's HULL for credits at a port — reject-before-read, all-or-nothing, idempotent on
`(main_ship_id, request_id)` via a new `repair_receipts` table (the 0174 salvage_receipts shape). Reject
order: `not_authenticated → repair_economy_disabled` (gate FIRST) `→ invalid_amount` (integer hp)
`→ ship_not_found → ship_destroyed` (THE SEAM — see below) `→ not_docked → idempotent_replay →
nothing_to_repair → repair_misconfigured → insufficient_credits → ok`. Fan-out is downward-only: resolve/
lock/dock (reused `mainship_resolve_owned_ship` / `mainship_space_lock_context` /
`mainship_resolve_docked_location`) → `cfg_num` knob → `wallet_debit` (0093, false-if-poor) → its own hp
heal → its own receipt. Cost model [D owner-tunable]: `total = hp_restored × repair_credits_per_hp`
(seeded **0.5** → a full 500-hp Frigate rebuild = 250cr = one ship's price; a ~120-hp dent = 60cr = a
Snare-run salvage); the request is CLAMPED to the actual missing hull (over-request tops up, never
over-charges). **THE SEAM (the G8 mandate, preserved):** DESTROYED ships (status='destroyed') are
REJECTED by the paid path and keep the FREE, ungated, instant `repair_main_ship` safelock (0052 head,
re-created verbatim-else-branch by 0199) — this slice leaves that function UNTOUCHED (a new additive RPC,
no re-create, no parity risk). **v1 scope (deliberate):** hull only (shield self-regens, 0197 — paying to
top a self-refilling bar is a non-feature), credits only, INSTANT at-port. FULL_CAPACITY_PLAN RR-1's
richer model (repair_parts materials + M4.5-queue duration) and MAINSHIP_TRANSITION §13's open
cost/duration questions are the documented FOLLOW-UP behind the SAME flag ([D] `repair_parts_per_hp` /
`repair_seconds_per_hp`) — a re-create of THIS new RPC, never the live safelock. Client: `RepairPanel`
(dark, on the Port main rail — the SalvageMarketPanel dark-panel mold: strict `strictConfigFlag` fold
read FIRST, sticky-lit, server-receipted cost, advise-on-shortfall; a destroyed ship shows the
free-recovery note, never a paid button; renders nothing while dark). Proof: standalone
`scripts/repair-econ-proof.{sql,sh}` + `.github/workflows/repair-econ-proof.yml` (REPAIR_PASS_* markers:
dark gate, 0.5 knob, full mend exact-debit + receipt, partial mend, replay idempotency, guards,
destroyed-safelock seam free + intact). **ACT-REPAIR** ready: `scripts/activate-repair-econ.{sql,sh}`
(flips `repair_economy_enabled`; preconditions pin the paid-RPC gate/seam bodies AND that
`repair_main_ship` stays ungated). AWAITS the owner's flip.

### P10 — ONBOARD: first-session experience *(S, frontend-heavy)*
OB-1: a client-side "First Orders" checklist derived from server state (dock → hunt Snare → craft
autocannon → fit → create team → commission #2) — read-only, zero new server surface. OB-2: a
`starting_contract` (P2 template) paying the first 250-credit ship. OB-3: copy/empty-state polish.
Deps: none for OB-1. Guard: onboarding *reads* game state; it never grants (grants ride existing systems).

### P11 — WORLD-MODEL (the long arc): PORTCENTRIC F1→F2 *(L, decision-heavy)*
F1 read-only World Model Recon (PORTCENTRIC Part E §1–10 — the only authorized next step there) → F2
resolves D4 (stable world-object identity, `space_anchors.kind` generalization, capability table replacing
the type switch, zone geometry, docked/last-safe-dock anchor ids) → only then Gen-1 expansion seeding.
Schedule the recon early (read-only; informs P4/P8/P9 schema choices). The packet's D5 non-authorizations
stand until each explicit gate.

### P12 — SHIP-SOUL: per-ship original traits *(M — SOUL-0 SHIPPED dark as mig 0186; SOUL-1 SHIPPED dark as mig 0193; SOUL-2 + ACT-SOUL remain)*
The owner directive: every ship has its own ORIGINAL stats/quirks — the Uncharted-Waters "this ship
is MINE" identity. SOUL-0 (**shipped**, mig `0186`, slice-soul0): `ship_trait_types` (Reference/Config
catalog, the 0117 posture — 8 birthmark traits [D owner-tunable], every magnitude below the same-stat
module band, five of eight carrying a minus key per the law-4 tradeoff posture; `stats_json` in the
ONE shared input vocabulary — self-assert-pinned against the 0180 adapter's module-read key set —
plus `hp_mult >= 1.0`, `veteran_frame` 1.08 the sole carrier) + `main_ship_traits` (2 slots per ship,
owner-read, INSERT-ONLY immutable) + `soul_roll_traits_for_ship` (service-only sole writer: traits
are a PURE FUNCTION of the ship id — the 0041 determinism law via the 0176 `hashtextextended`
pure-hash technique, `:soul:<slot>` salts, deterministic slot-2 re-salt to distinctness; idempotent
`on conflict do nothing`, so a re-roll cannot exist; hp_mult applied once at roll, monotonic) — all
behind NEW `ship_traits_enabled=false` and DOUBLY dark (nothing calls the roll fn). Proof = the
`TEAMCMD_PASS_SOUL0` block in `team-command-proof` (catalog verbatim; rolls equal the proof's own
inline hash re-derivation on both the veteran and plain fixture arms; exact hp_mult; idempotent-replay
immutability). SOUL-1 (**shipped**, mig `0193`, slice-soul1): the commission-path parity re-creates —
`port_entry_commission_build` (0184 head; covers first + additional ships, both writers delegate) and
`ensure_main_ship_for_player` (0078 head; the legacy service creator — a starter Sparrow deserves a
soul too, create-branch-only so a replay never rolls) each gain ONE double-gated hook
(`cfg_bool('ship_traits_enabled')` checked at the call site AND inside the roll fn: dark = zero calls,
byte-parity) that `perform`s `soul_roll_traits_for_ship` at the 0169 definer-to-definer leaf-call
pattern — plus the adapter fold: `calculate_expedition_stats` re-created from its 0180 head with the
ONE knob-gated trait fold (each `main_ship_traits` row's `stats_json` into the SAME accumulators as
the module loop, the shared 8-key vocabulary; `speed_mult_bonus` inside the ONE multiplier; placed
adjacent to the 0170 hull fold — traits are the ship itself; `hp_mult` NEVER read — applied once at
roll, prosrc-pinned). Doubly inert: flag false → the read is skipped entirely; lit + zero rows → an
empty loop. Proof = the `TEAMCMD_PASS_SOUL1` block (dark-commission zero-roll, knob-gated-read
byte-parity, lit fold = stored-trait sums exactly, hook = the derivation, hp_mult once + no adapter
re-scale, ensure create-branch replay law). SOUL-2: read surface + trait display in the Ship Dossier. ACT-SOUL: the
backfill roll over EXISTING ships + the human flip — deterministic AT A FIXED CATALOG: the
derivation maps into the catalog's size and byte order (collate "C", the 0186 collation law), so
any catalog change BEFORE the backfill changes every unrolled ship's derivation; ACT-SOUL's flip
script MUST assert catalog count = 8 (the catalog-freeze precondition, the ACT-HAUL
precondition-block idiom) before rolling. Already-rolled ships are immutable rows — safe under any
later catalog growth. Deps: none (rides the shipped adapter). Guard: the catalog stays migration-seeded
(NO runtime writer); `main_ship_traits` keeps ONE writer and NO update/delete path, ever — a ship's
soul never changes; all stats enter play ONLY via the ONE adapter (no parallel stat path).

### P13 — SHIELD: regenerating ship shields *(M — COMPLETE dark: SHIELD-0/1/2 ALL SHIPPED (migs 0191/0195/0197); only the human ACT-SHIELD flip remains)*
The owner directive: ships get a SHIELD that regenerates during and outside combat. SHIELD-0
(**shipped**, mig `0191`, slice-shield0): the schema foundation, DEPLOY-INERT and **data-gated —
deliberately NO `shield_enabled` flag** (the 0170 hull-stats posture: the system is dark because
every number is 0, not because a gate hides it). Columns mirror the hp model (0043):
`main_ship_hull_types.base_shield` (integer, default 0, `>= 0` — 0 = shieldless is legal, unlike
`max_hp > 0`) + `main_ship_instances.shield`/`max_shield` (integer, default 0, `shield >= 0`,
`max_shield >= 0`, `shield <= max_shield`) + `combat_units.shield_max`/`shield_current` (double
precision NULL — the 0167 member-snapshot shape, with the pairing CHECK ADAPTED: paired-together +
member-row-only, NOT the strict 0167 IFF, because the live member writer (D2, activated
2026-07-12) does not write shields until SHIELD-1 — a strict IFF would break live team hunts on
deploy). The ONE sync leaf `mainship_sync_combat_shield(ship, shield)` — the
`mainship_sync_combat_hp` (0167:129-145) sibling posture exactly (SECURITY DEFINER,
service-role-only ACL, missing row = zero rows, one-leaf-one-concern: writes `shield` ONLY) plus
BOTH clamps (`least(max_shield, greatest(0, …))` — regen can overshoot upward where combat only
lowered hp); NO caller until SHIELD-1. Knobs `shield_regen_combat_pct`/`shield_regen_idle_pct`
seeded '0' (double-inert: no consumer + OFF). A partial index on
`main_ship_instances (main_ship_id) where shield < max_shield` is the future regen pass's scan
surface (matches zero rows while everything is 0/0). Commission needs NO re-create this slice
(verified: the 0184/0078 heads ENUMERATE insert columns, so default-0 columns ride free — new
ships are born 0/0). Proof = the `TEAMCMD_PASS_SHIELD0` block in `team-command-proof` (schema
pins; total inertness; leaf clamp smoke with hp byte-untouched; knobs never touched even in-txn).
**SHIELD-1** (**shipped**, mig `0195`, slice-shield1): the engine — tick/creator parity re-creates
from the grep-verified TRUE heads (`combat_create_group_encounter` ← 0168:359 its only create
site; `process_combat_ticks` ← 0169:93, nothing later; the solo `combat_create_encounter` verified
member-row-free — catalog inserts only — and deliberately untouched): the member
`shield_max`/`shield_current` snapshot frozen at encounter creation in the SAME read as msi.hp
(the one-read law), **NULL/NULL for a shieldless ship** (every ship until ACT-SHIELD) and for a
degraded member — the write-count-parity decision (regen NULL-propagates, absorb coalesces to 0,
the leaf never fires → the pre-SHIELD1 tick byte-identical including writes; the 0191 pairing
CHECK's optional IFF tightening declined by design); shield-absorbs-first damage with ONE absorb
point (`v_absorb := least(coalesce(pool, 0), damage)` — the hull takes ONLY the overflow, no
second damage path); in-combat regen via `shield_regen_combat_pct` (hoisted to ONE read per tick
invocation; `least(max, pool + max × knob)`, capped, knob-'0' arithmetically inert);
`mainship_sync_combat_shield` wired in the same member branch as its hp sibling, gated on a
non-NULL pool — the leaf's FIRST caller. Integrity accounting (Σ hp_max, hull-only), defeat
detection (hull-only — a shielded ship at hull 0 IS dead) and every report/tick jsonb key
byte-unchanged, all self-assert-pinned (marked-hunk tokens present, old-head fingerprints absent,
knob-read placement pinned). Proof = the `TEAMCMD_PASS_SHIELD1` block in `team-command-proof`
(zero state on real member rows + the in-txn lit arm: exact snapshot-carries-CURRENT-pool,
absorb/overflow, regen climb + max cap, leaf mirror, hull-only integrity + defeat). The
commission-path base_shield → instance copy moved to **SHIELD-2** (a provable no-op while every
hull is 0 — the 0195 header's scope note). **SHIELD-2** (**shipped**, mig `0197`, slice-shield2 —
0196 reserved for DECKS-3's renumber): the system's final slice. (a) The OUT-OF-COMBAT regen
home = `process_mainship_expeditions` re-created from its TRUE head (0169:446, grep-re-verified)
with ONE guarded set-based hunk riding the 0191 partial index: `shield := least(max_shield,
shield + ceil(max_shield × shield_regen_idle_pct))` where `shield < max_shield`, `status <>
'destroyed'`, and **the §1.3.2 double-writer EXCLUSION predicate** — `not exists` an
active/retreating encounter membership: while an encounter lives, the 3s tick is the SOLE shield
writer (via the 0191 leaf); outside one, the reconciler's set statement is (a disjoint-writers
partition, not a second lock system). DOUBLE-GUARDED zero-knob: `least(max, shield+0)` = shield
but a same-value UPDATE still fires row writes, so knob 0 skips the statement ENTIRELY (`if
v_idle > 0`) — zero writes, byte-inert cron; knob read once behind the house NaN-guard SHAPE (a documented PG no-op — see the NANGUARD row), floored at 0; the
return envelope unchanged. (b) The commission copy: BOTH creators (`port_entry_commission_build`
— re-created on the merged 0194 SHIPYARD-2 body (PR #138), order-robust
drops — and `ensure_main_ship_for_player`, 0193 head) insert `shield, max_shield :=
h.base_shield, h.base_shield` — ships are BORN FULL (the base_hp posture mirrored); 0/0 while
every hull is 0. (c) UI: the classic shield-above-hull meter pair on ShipStatusCard + ShipDossier
through ONE shared component (`MeterPairBars`) + ONE pure view-model (`meterPair.ts`, spec'd) —
**data-gated on `max_shield > 0`** (zero new DOM on prod today; no flag, the 0191 posture);
`shield, max_shield` added to the enumerated owner-ship selects (SHIP_COLS + the map read); team
roster/member rows carry no hp today so they gain no shield readout (skipped, documented). Proof
= the `TEAMCMD_PASS_SHIELD2` block (24th marker): knob-0 zero-writes via an updated_at sentinel,
ceil-pinned exact climb + least cap + full-pool-never-rewritten, both exclusions on REAL fixtures
(active encounter / destroyed hull), born-full 25/25 through both real creators under a
sanctioned raised-then-restored hull seed; the idle knob moved to the raised-and-restored-in-txn
idiom (its consumer arrived — the SHIELD-1 combat-knob precedent). **ACT-SHIELD** (the human
flip, [D — all owner-tunable; the charter's proposals]), ONE BEGIN..COMMIT script
(`scripts/activate-shield.{sql,sh}`, the ACT-HAUL precondition-block idiom): (1) preconditions —
migs 0191/0195/0197 recorded; the tick/creator/reconciler/commission bodies prosrc-pinned to
their heads (regen hunk + exclusion predicate + absorb point + copy tokens present); both knobs
still '0'; every instance `shield <= max_shield`-coherent; (2) the monotonic per-hull
`base_shield` backfill — **Sparrow 100 / Mule 130 / Talon 85** [D] (monotonic: only 0 → value,
never lowering — re-run-safe); (3) the instance backfill `shield := base_shield, max_shield :=
base_shield` for ships whose hull now carries a shield AND whose `max_shield = 0` (monotonic,
born-full shape — the same copy the creators use; already-shielded ships untouched); (4) knobs
**0.02 combat / 0.10 idle** [D] via `set_game_config`; (5) smoke — a damaged-shield fixture
regens on a real reconciler pass in-txn and a fresh commission is born full. Rollback =
knobs/data back to 0, never a schema revert. Guards: the leaf mirrors its sibling (no parallel
sync path); `shield`'s TWO runtime writers stay disjoint by the exclusion predicate (the updated
SYSTEM_BOUNDARIES law); `max_shield`'s only runtime writers are the two creators' inserts; all
engine changes are parity-discipline re-creates from grep-verified true heads; deploy-inert
provable at every slice.

**Evaluated & deferred:** support-craft revival — NO (deprecated scaffolding per MAINSHIP_TRANSITION §★).
PvP/guilds/visibility — NO until exploration/mining/trading all consume OSN (the ROADMAP timing rule).
Coordinate-envelope growth — NO until the World-Range Recon. New expedition `activity_type`s — fold into
P2 contracts + P8 event sites first.

---

## D. THE EXECUTION QUEUE — next ~15 slices

**[D] = needs owner DECISION; [E] = pure execution.** Status as of 2026-07-12 wave:

| # | Slice | Status |
|---|---|---|
| 1 | ACT-CAPTAINS (mig 0171 + script) | **PR #102 — CI green, at the merge gate** |
| 2 | ACT-EXPLORE (script + 0172 reconcile) | **PR #103 — CI green, at the merge gate** |
| 3 | ACT-MINING (script, same PR) | **PR #103** |
| 4 | ECON-SEED-1 (mig 0173) **[D: price table — approved 2026-07-12]** | **PR #104 — CI re-running after the 0C fixture fix** |
| 5 | ACT-TRADE (flip script + TRADE_MARKET_ENABLED client PR) | **script shipped** (`scripts/activate-trade.{sql,sh}`, slice-act-trade — awaiting the human flip, then the one-line client PR) |
| 6 | SALVAGE-0/1 **[D: item prices — proposed in the 0174 header, owner-tunable]** | **shipped (dark)** — mig `0174` (`port_item_demand` 3-port × 5-droppable seed + `salvage_market_enabled=false` + `sell_item_at_port` + `salvage_receipts`), proof `scripts/salvage-market-proof.{sql,sh}` wired into `trade-v1-proof.yml` (slice-salvage); UI + flip = #10 |
| 7 | ZONES2-1 Ember Reach **[D: bd/min_power numbers — set 40/150, 50/220, 60/300 per packet §0.3 (≈4/6/8 kitted+captained ships)]** | **shipped** (mig `0175`, slice-zones2-ember — sector Ashen Frontier + zone Ember Reach ACTIVE-but-empty, 3 hunt sites seeded HIDDEN) |
| 8 | ZONES2-2 + reveal script | **shipped** (`scripts/reveal-ember-reach.{sql,sh}` — awaiting the human reveal; recommend AFTER teams kit up) |
| 9 | RANK-SEASON + ACT-RANKING **[D: season windows — proposed, owner-tunable]** | **script shipped** (`scripts/activate-ranking.{sql,sh}`, slice-rank-season — awaiting the human flip). One BEGIN..COMMIT, **flag FIRST then seasons** (`ranking_season_open` dark-gates on `ranking_enabled`, so the order is forced); weekly + monthly opened conditionally via `ranking_season_open` (re-run in-window = no-op success; re-run in a later window = the manual roll). [D proposed: weekly = ISO-Monday-UTC window, label `2026-W28`; monthly = calendar month, `2026-07`]. No client PR (RankingPanel server-lit, CommandScreen aside). **OPERATIONAL: seasons do NOT auto-roll** — nothing closes a season at `ends_at` (boards freeze); roll manually each Monday / 1st (a re-run IS the roll) until a **RANK-ROLL** automation slice ships |
| 10 | SALVAGE-2 + ACT-SALVAGE | queued |
| 11 | MOD2-1 shield line **[D: defense 12 (the plan's number) / mining 8 (banded: mining_drone cap-2 → 8, the deep-scan slot-1 precedent) — owner-tunable]** | **shipped (dark)** — mig `0183` (slice-mod2): shield_lattice + mining_rig_extension seeds + live-drop recipes, self-asserting (exact shapes; drop grounding vs loot prosrc + field bundles; adapter stats-key prosrc pins; craftable shape; gates still dark); proof = the `TEAMCMD_PASS_MOD2` grant→craft→fit→adapter block in `team-command-proof` (survival +12 / mining_yield +8 exact); verify-modules/verify-fitting catalog contracts extended 4→6 types / 12→18 recipe rows. No new flag — lights with the existing `module_crafting_enabled`/`module_fitting_enabled` flips. **MOD2-2 shipped (dark)** — mig `0202` (slice-mod22): the Mk-II tier `autocannon_battery_mk2` (weapon, slot_cost 2, attack 18: blueprint_fragment 2 + artifact_core 1 + weapon_parts 6) + `shield_lattice_mk2` (defense, slot_cost 2, defense 20: blueprint_fragment 2 + artifact_core 1 + repair_parts 6) — the tier rule is a flat +8 on the base stat (attack 10→18, defense 12→20), slot_cost 2 = the real capacity tradeoff (a 3-slot frigate carries at most one Mk-II + one base), same shape/self-asserts as 0183 (exact shapes; F4 drop grounding — combat items vs the 0185 loot prosrc, artifact_core vs the Singularity Scar field; adapter stats-key + weapon-tradeoff prosrc pins; craftable shape; no new flag). Honest deep-gate: blueprint_fragment 2 exceeds the shipped ceiling of 1 (one-shot 0098 site; combat faucet committed 0), so the Mk-II is UNCRAFTABLE until `blueprint_fragment_drop_rate` lights — the same activation gate SHIPYARD-0's T1 ships carry. Proof = the sibling `TEAMCMD_PASS_MOD22` block (two fresh users, one Mk-II each — shield fit → survival +20 exact else-0 arm; autocannon fit → combat_power +18 + the FIRST weapon-tradeoff-arm pin, pirate_attention +4 / speed × 0.94 exact); verify-modules/verify-fitting contracts extended 6→8 types / 18→24 recipe rows |
| 12 | HAUL-0/1 contracts foundation **[D: template/reward table — proposed in the 0176 header, owner-tunable]** | **shipped (dark)** — mig `0176` (`haul_contract_templates` 10-template seed over the 0173 economy + `haul_contracts` + `haul_contracts_enabled=false` + `haul_offers_per_port=2` + the deterministic `haul_generate_offers()` generator (pure-hash per (day, port, slot), idempotent natural key, offered-only expiry) + hourly cron `haul-generate-offers` — a cron-safe dark no-op), proof `scripts/haul-proof.{sql,sh}` wired into `trade-v1-proof.yml` (slice-haul). **HAUL-2 shipped (dark)** — mig `0179` (slice-haul2): `haul_accept_contract` (origin-port claim — moves NO cargo/credits; `deliver_by = accepted_at + template duration` [the 0176 duration reused as the delivery window — the contract's tempo]; `haul_max_active_per_player=3` cap [D]) + `haul_deliver_contract` (ANY owned ship docked at the DEST; `trade_cargo_consume` + `wallet_credit`, atomic + receipted; cost basis consumed-and-lost, the reward covers it) + `haul_receipts` (the salvage_receipts shape, sole writers = the two RPCs) + the generator re-created (0176-head parity, ONE marked (a2) hunk: accepted past `deliver_by` → 'cancelled', freeing the cap slot; no penalty v1 [D]) — same flag, still dark; proof extended (dark RPC rejects, accept/deliver happy+guards+replays incl. replay-at-cap, deadline cancel). **HAUL-3 shipped (dark)** — mig `0181` + PR #117 (slice-haul3-capbars): `get_port_contracts` gated bulletin read (gate-first reject-before-read over the raw RLS select — the house law + the 0176 emergency-darkening rationale; fresh-offered + caller-scoped mine + `max_active` surfaced) + HaulBoardPanel mounted server-lit on the Port screen aside (PortScreen.tsx:80; isServerLit → null while dark). **ACT-HAUL script shipped** — `scripts/activate-haul.{sql,sh}` (slice-act-haul — awaiting the human flip, **AFTER ACT-TRADE**): one BEGIN..COMMIT — preconditions (0176/0179/0181 recorded; generator/accept/deliver/read bodies prosrc-pinned to their 0179/0181 heads; 10 templates worth-taking re-derived vs the live market; 3 starter ports generator-eligible; knobs sane read-only; cron exactly once; ██ `trade_market_enabled` COMMITTED TRUE — the deliverability gate: deliver consumes `ship_cargo_lots` via `trade_cargo_consume` and `market_buy` is the SOLE cargo-lot producer (grep-verified 0089/0092/0136/0138); mining does NOT substitute — its ore is item-inventory via `reward_grant` (0102), never a cargo lot, so dark-trade contracts are 100% undeliverable) → the ONE flag write → ██ INSTANT OFFERS ██ (the sanctioned generator invoked once in-txn: fresh offers at all 3 ports the moment it commits instead of waiting ≤1h for the minute-7 cron; same-day re-run = tolerated no-op via the natural key) → smoke (the authed `get_port_contracts` called for real under a txn-local fake JWT and matched to table truth). NO client PR (HaulBoardPanel server-lit). Rollback = flag-only + the EXPIRY-FREEZE choice documented (darkening freezes both generator passes; a dark generator run no-ops — accept the frozen rows (re-light sweeps them) or run the commented manual service-role sweep) |
| 13 | CAPXP-0/1 captain XP foundation **[D: xp knobs 10/6/4 + curve `1 + floor(sqrt(xp/100))` — proposed in the 0177 header, owner-tunable]** | **shipped (dark)** — mig `0177` (additive `captain_instances.xp/level` read by NOTHING until C2-2 + `captain_growth_enabled=false` + the per-(grant, captain) `captain_counted_grants` ledger with a NULL-captain sentinel (consume-exactly-once; no retroactive backfill) + `captain_xp_accrue()` folding FINALIZED `reward_grants` into CURRENTLY-assigned captains (the derivable semantic — captain-at-sortie is recorded nowhere; ship linkage: combat manifest ∪ solo fleet tag, exploration scanner, mining extractor; grants with no linkage → sentinel) + 5-min cron `captain-xp-accrue`, a cron-safe dark no-op), proof = the `TEAMCMD_PASS_CAPXP` block in `team-command-proof`; NOTE for the future ACT-CAPXP flip: the first lit run folds the entire dark backlog into current assignees — accept or pre-seed sentinels (0177 header). **C2-2 shipped (dark)** — mig `0180` (slice-c2-2): `calculate_expedition_stats` re-created from its TRUE head (`0170` — grep-verified: creates at 0044→0115→0122→0170 only) with the ONE marked captain-fold hunk — each assigned captain's stats_json contribution × `(1 + (level-1) × captain_level_bonus_per_level)` [D seeded 0.10, owner-tunable: level 2 = +10% on the captain-contributed portion only; specialization tradeoffs stay level-flat] + `i.level` joined into the fold (additive column). DOUBLY inert today: the flag is read ONCE at entry → ×1.0 exactly while `captain_growth_enabled` is dark regardless of level, AND ×1.0 exactly at level 1 regardless of the flag (knob floored at 0 — never a nerf); self-asserted at migration time (flag dark + zero captains above level 1 + prosrc pins: the gated multiplier token, exactly 8 scale sites, tradeoffs unscaled). Proof = the `TEAMCMD_PASS_CAPLEVEL` block in `team-command-proof` (exact lit bonus over the level-1 baseline on the CAPXP level-2 fixture, independently derived from catalog joins, + BOTH inertness arms; reconciliation checked: no earlier block calls the adapter post-flip/post-level-2, so every existing pin stays byte-valid). C2-3 XP bars UI + C2-4 the 6→8 slot raise = later slices |
| 14 | WORLD-RECON-F1 (read-only) | **shipped** (docs/WORLD_RECON_F1.md, second run @ head 0177 — surfaced the §7 reachability finding that produced #14.5) |
| 14.5 | COORD-GUARD + ACT-COORD-TRAVEL (the Rung-0.5 prereq for the exploration/mining flips: resolver-guard the raw coordinate command — the A0-fix — BEFORE `mainship_coordinate_travel_enabled` can flip) | **shipped** — mig `0178` (0070-head parity re-create; trailing `p_main_ship_id` + `mainship_resolve_owned_ship`, fail-closed at N≠1; self-asserting) + the S6C ship-id passthrough (buildSpaceMoveRpcArgs / commandMainShipSpaceMove / useSpaceMoveCommand / GalaxyMap thread the SELECTED ship exactly like stop/settle/readiness — dark until the flip) + `scripts/activate-coordinate-travel.{sql,sh}` (guard-pinned preconditions, the ONE flag write, anchors + reachability + envelope smokes — awaiting the human flip; NO flip-time client PR: the coordinate UI is server-readiness-driven). COMPLETE signature-pin repoint list in TRADE_FLEET_0C_VERIFIER_REPOINT.md §#1 (incl. the COORD_SURFACE_COUNT arg-type census + the S6A exact-args / security-intent asserts) |
| 15 | ACT-INVEST + ACT-WORLDBAL | queued |
| 16 | EV-1 + ACT-PHASE20 **[D: thresholds 75 / 0.25 / 0.6–1.4 — proposed in the 0182 header, owner-tunable]** | **EV-1 shipped (dark)** — mig `0182` (slice-ev1): `worldstate_tick` re-created from its TRUE head (0137, grep-verified; parity diff clean) with the marked EV-1 hunks — ALL STATE-detected (never edge: a failed publish's condition still holds next minute, so the retry is genuine): pressure high (at/above `event_pressure_high_threshold=75`; critical ≥ threshold + half the headroom; a parked-high location re-announces daily — intended pressure-nagging) + eased (the exact complement, suppressed unless today's high was announced — a read-only lookup of the tick's own published rows), depletion warnings (post-regen reserve < `event_depletion_warn_fraction=0.25`, global-scope, field NAME only), drift extremes (`price_surge`/`price_crash` outside 0.6/1.4 — 1.4 grounded: the 0136 drift target caps at 1.5 under coeff 0.5, so the notional 1.6 is unreachable) — every publication through the EXISTING `world_events_publish` (never a direct insert; 5 call sites pinned), per-(subject, UTC-day) dedup keys, EACH publication its own begin/exception subtransaction (query_canceled re-raised; a publish failure logs a WARNING, never aborts the tick, never rolls back a sibling — D2), the four knobs read ONLY when `world_balance_enabled` and guarded (uncastable/NaN → seeded default + WARNING — a knob typo cannot kill the live heartbeat), double-dark (`world_balance_enabled` × publish's own `phase20_polish_enabled` gate), NO new cron (the 0033 60s heartbeat, self-asserted unchanged); proof `scripts/ev1-proof.{sql,sh}` in NEW `world-events-proof.yml` (family-pure host — trade-v1 stays trade-only). ACT-PHASE20 (the Rung-7 flips) remains |
| 17 | SOUL-0 per-ship traits foundation **[D: the 8-trait table + magnitudes — proposed in the 0186 header, owner-tunable]** | **shipped (dark)** — mig `0186` (slice-soul0): `ship_trait_types` (the 0117 catalog posture — 8 birthmark traits, stats keys self-assert-pinned to the shared 0180 adapter input vocabulary, `hp_mult >= 1.0` with `veteran_frame` 1.08 the sole carrier) + `main_ship_traits` (2 slots per ship, owner-read, INSERT-ONLY immutable — no update/delete path anywhere) + `soul_roll_traits_for_ship` (service-only sole writer; traits = a pure `hashtextextended(':soul:')` function of the ship id, the 0041/0176 determinism technique; idempotent, hp_mult applied once + monotonic) — behind NEW `ship_traits_enabled=false`, DOUBLY dark (no caller yet). Proof = the `TEAMCMD_PASS_SOUL0` block in `team-command-proof` (catalog verbatim; rolls = the proof's own inline hash re-derivation on veteran + plain arms; exact hp_mult; idempotent-replay immutability). **SOUL-1 shipped (dark)** — mig `0193` (slice-soul1): the commission roll hook (`port_entry_commission_build` 0184-head + `ensure_main_ship_for_player` 0078-head re-creates, ONE double-gated `soul_roll_traits_for_ship` hook each — every new ship born with its soul WHEN LIT; ensure's hook create-branch-only) + the adapter trait fold (`calculate_expedition_stats` 0180-head re-create, the ONE knob-gated fold in the shared 8-key vocabulary adjacent to the 0170 hull fold, speed inside the one multiplier, hp_mult never read); proof = the `TEAMCMD_PASS_SOUL1` block (SOUL0 reconciled: fixtures commission dark, gate re-darkened before TEAMMAP). SOUL-2 (read surface + dossier UI), ACT-SOUL (backfill roll — deterministic at a FIXED catalog, so the flip script must assert catalog count = 8 first — + the human flip) = later slices — see §C P12 |
| 18 | SHIELD-0 shield foundation **[D: base_shield at flip Sparrow 100 / Mule 130 / Talon 85 + regen 0.02 combat / 0.10 idle — the §C P13 proposals, owner-tunable at ACT-SHIELD]** | **shipped (dark)** — mig `0191` (slice-shield0): the hp-mirrored shield columns (`base_shield` + instance `shield`/`max_shield` integer default 0 with the 0043-shaped CHECKs, `max_shield` 0-legal) + `combat_units.shield_max`/`shield_current` (0167 snapshot shape; pairing CHECK adapted member-only — live member rows stay NULL-legal until SHIELD-1) + the `mainship_sync_combat_shield` leaf (the 0167 sibling posture + both clamps; NO caller yet) + `shield_regen_combat_pct`/`shield_regen_idle_pct` seeded '0' + the `shield < max_shield` partial regen index (matches zero rows). Data-gated (NO flag); zero function re-creates (the 0184/0078 commission heads enumerate columns → default-0 rides free). Proof = the `TEAMCMD_PASS_SHIELD0` block in `team-command-proof`. **SHIELD-1 shipped (inert)** — mig `0195` (slice-shield1): the 0168/0169-head tick/creator parity re-creates (member shield snapshot NULL-for-shieldless in the one-read pass, ONE absorb point with hull-only overflow, hoisted knob regen capped at max, the 0191 leaf's FIRST caller gated on a non-NULL pool; integrity/defeat/reports byte-unchanged, self-assert-pinned); proof = `TEAMCMD_PASS_SHIELD1` (22nd marker, reconciled after SOUL-1's 21st — both blocks kept, the established idiom). **SHIELD-2 shipped (inert)** — mig `0197` (slice-shield2; 0196 landed as DECKS-3, merged): the out-of-combat regen home (the 0169-head reconciler + ONE guarded set-based hunk — knob-0 = the statement skipped entirely, zero writes; the §1.3.2 active/retreating encounter-membership EXCLUSION predicate keeps the tick the sole in-combat shield writer; destroyed excluded) + the commission copy (both creators born-full `h.base_shield, h.base_shield`; build re-created on the merged 0194 SHIPYARD-2 body, PR #138) + the UI meter pair (ONE shared `MeterPairBars` + pure `meterPair.ts` view-model, data-gated `max_shield > 0` — zero new DOM on prod); proof = `TEAMCMD_PASS_SHIELD2` (24th marker; the idle knob joins the raised-and-restored-in-txn idiom). P13 COMPLETE dark — only ACT-SHIELD (the human flip: monotonic base_shield backfill Sparrow 100 / Mule 130 / Talon 85 [D] + instance copy + knobs 0.02/0.10 [D] + smoke) remains — see §C P13 for the flip-script charter |
| 19 | DECKS-3 station affinity **[D: bonus 0.15 — proposed in the 0196 header, owner-tunable at ACT-DECKS3]** | **shipped (inert)** — mig `0196` (slice-decks3; rides the 0189 DECKS-0/1 station catalog + station axis): `calculate_expedition_stats` re-created from its TRUE head (`0193` — grep-verified: creates at 0044→0115→0122→0170→0180→0193; SHIELD-1's 0195 touches the combat engine, never the adapter) with the marked DECKS-3 delta — a captain whose specialization matches their held station's `affinity_specialization` (`ship_stations` 0189: Gunnery=combat, Engineering=mining, Logistics=trade, Sensors=exploration, Medbay=support, Bridge=NULL) folds at contribution × `v_lvl_mult` × `(1 + station_affinity_bonus)`, composed at the EXISTING 0180 scale sites (ONE LEFT station join — an unstationed row keeps folding; unstationed/Bridge/mismatch = ×1.0 EXACTLY, never a per-row knob read; specialization tradeoffs stay affinity-flat). Knob `station_affinity_bonus` seeded '0' → ×(1+0) = ×1.0 byte-inert (the 0180 double-inertness law: seed-zero arm AND no-match arm; floored at 0 — never a nerf; the 0180 guard SHAPE kept for parity — its `x <> x` NaN arm is a PG no-op, see the NANGUARD row). Self-asserting (knob reads exactly 0 at deploy; the 0189 affinity mapping re-asserted verbatim; prosrc pins: 1 once-at-entry knob read / 1 LEFT station join / 1 no-match CASE with the literal-1 ELSE / exactly 8 composed `* v_lvl_mult * v_aff_mult` scale sites; every 0180 level pin + 0193 trait pin re-run — the accumulated-hunk law). Proof = the `TEAMCMD_PASS_DECKS3` block in `team-command-proof` (23rd marker, after SHIELD1's 22nd — both blocks kept: knob-0 totals with a gunnery-stationed matching level-2 captain = the pre-DECKS3 expectation to the byte; knob 0.15 in-txn = baseline + knob × the independently-derived matched share EXACTLY, composed with a real level multiplier, the NULL-affinity bridge holder earning nothing; a medbay-mismatch+bridge board byte-identical lit or dark; the unstationed arm pinned structurally — no writer can produce a station-NULL row post-0189). **ACT-DECKS3 = ONE knob write** — `set_game_config('station_affinity_bonus', '0.15')` [D proposed 0.15, owner-tunable; e.g. a gunnery_veteran (attack 4) on Gunnery contributes 4.6 at level 1, 5.06 at level 2 under lit growth]; rollback = the same write back to '0', flags/knobs never data |
| 20 | NANGUARD — fix the inherited no-op NaN guards (both adapter sites + the 0197 reconciler) **[E — found by the DECKS-3 hostile review]** | **shipped** — mig `0198` (slice-nanguard): the `x <> x` NaN-detect idiom is a NO-OP in PostgreSQL — `'NaN'::float8 = 'NaN'::float8` is TRUE (PG deviates from IEEE 754 here), so the guard arm is UNREACHABLE and a knob mis-set to `"NaN"` WOULD poison the guarded math. THREE sites: the 0180 level knob (`captain_level_bonus_per_level`) and the 0196 affinity knob (`station_affinity_bonus`) in `calculate_expedition_stats`, plus the 0197 idle-regen knob (`shield_regen_idle_pct`) in `process_mainship_expeditions` — each inherited the 0180 shape byte-for-byte DELIBERATELY (0180-parity over a mid-slice idiom fork). ONE slice fixes ALL THREE to the working `= 'NaN'::float8` idiom (the 0182 worldstate-knob precedent) via fresh re-creates from their then-true heads, updates the guard-shape prosrc self-asserts across the 0180/0193/0196/0197 lineage pins, and corrects the inherited comments. SHIPPED: mig `0198` re-created `calculate_expedition_stats` (0196 head — the LEVEL + AFFINITY guards) and `process_mainship_expeditions` (0197 head — the IDLE-REGEN guard) VERBATIM except the marked `-- NANGUARD (0198)` guard-operator flip + its honesty comment at each of the THREE sites (extract-and-diff clean; the ONLY code delta is `<>`→`= 'NaN'::double precision`). `process_combat_ticks` (0195) confirmed NOT a fourth site — its `shield_regen_combat_pct` read is a bare `coalesce(cfg_num(...),0)`, no `x <> x` guard at all. BEHAVIORALLY INERT at the seed-0 knobs (0 is not NaN under either idiom) — every prior proof stayed green unchanged; witnessed by `TEAMCMD_PASS_NANGUARD` (25th marker): a jsonb `"NaN"` affinity knob (real gunnery-matched captain aboard) leaves the adapter byte-identical to the knob-0 baseline with a finite combat_power, and a jsonb `"NaN"` idle knob leaves the reconciler a clean no-op (no `ceil(NaN)::integer` abort) — a targeted proof that would have FAILED pre-fix (NaN propagates/aborts). Server-only, zero src/ changes |

*(Then: the SHIPYARD line (P6 — SHIPYARD-0 shipped dark as mig 0185; SHIPYARD-1 shipped dark as
mig 0188, slice-shipyard1 — the order RPC + queue seam; SHIPYARD-2 shipped dark as mig 0194,
slice-shipyard2 — the engine's hull arm + commission-core delivery + hull-aware cancel refunds,
ALL pre-flip seams closed; SHIPYARD-3 shipped client-only via PR #137; only ACT-SHIPYARD
remains) [D],
MOD2-2, RR line, OB line, C2-4 — resequenced at the next plan review.
HAUL is now FULLY STOCKED: HAUL-3 shipped 0181/PR #117 and the ACT-HAUL flip script shipped
(slice-act-haul) — only the human flip remains, ordered after ACT-TRADE. C2-3 shipped in PR #117.)*

---

## E. HOW EVERY SLICE SHIPS (the standing dev law)

1. **Dark-first.** Every feature lands behind a server `game_config` flag seeded `false` (+ a compile-time
   `osnReleaseGates.ts` mirror when it mounts UI). RPCs reject-before-read; UI fails closed independently.
2. **Parity discipline.** A live function is never edited — it is re-created from its **grep-verified true
   head** with provably-inert deltas only, each marked, the shipped body diff-verified against the head.
   *(The law exists for a proven failure class: 0146 and 0143 both copied stale bodies and silently
   dropped later features — found and fixed in 0172.)*
3. **One green PR per slice**, adversarially reviewed; migrations carry a verify script.
4. **Disposable proof for DB slices**: a write-then-ROLLBACK proof wired into CI (the team-command-proof /
   trade-v1-proof idiom), with selftest greps pinning the key asserts in assert form.
5. **Activation is never a slice.** Every flip is a human-run `scripts/activate-*.{sql,sh}` (staged
   knobs→flags→smoke, marked rollback), one observable change per window, server before client, post-flip
   proof mandatory. Roll back **flags, never data**.
6. **The owner's two gates** stand: every prod migration deploy and every flag flip/reveal is its own
   recorded human go/no-go. (Operationally: PR merges + deploy approvals + running the activation scripts
   are all owner-run `!` commands.)
7. **Boundaries first.** A new table names its sole writer in `SYSTEM_BOUNDARIES.md` in the same PR that
   creates it; the pipeline law (activity → pending → secure → inventory → progression → ranking) admits
   no new edges.

**Key flag/knob index:** flags in `game_config`: `exploration_enabled · mining_enabled ·
trade_market_enabled · trade_relief_enabled · station_storage_enabled · captain_assignment_enabled ·
captain_progression_enabled · ranking_enabled · location_investment_enabled · world_balance_enabled ·
phase20_polish_enabled · captain_shard_drop_rate (knob) · station_affinity_bonus (knob, 0196 —
seeded 0, ACT-DECKS3 proposes 0.15)`; compile gates in
`src/features/map/osnReleaseGates.ts` (`TRADE_MARKET_ENABLED` the last dark one); knobs:
`main_ship_price=250 · starting_credits=1000 · max_active_fleets=6 · max_main_ships_per_player=24`.
Content today: 8 locations (3 hunts bd 10/15/25, 3 ports, 2 safe), 1 hull, 4 modules, 5 captains,
6 goods × 3 ports (0173), 5 exploration sites, 5 mining fields, 12 item types.
