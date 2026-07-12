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
| G8 | **No repair economy**: `repair_main_ship` is the free/instant safelock (0052) — flagged as temporary (ROADMAP §Repair & Recovery) |
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

### P1 — ECON-SEED: the differentiated three-port economy *(S — SHIPPED as mig 0173 / PR #104)*
Port role identities over the six 0073 goods: Haven = city/consumer, Slagworks = industrial,
Driftmarch = frontier premium. Guaranteed routes: ore Slagworks→Haven +200/trip, provisions
Haven→Slagworks +200, machinery Slagworks→Driftmarch +384 (full table + proof in 0173 /
`trade-econ-seed-proof`). `market_offers` stays Reference/Config, migration-seeded only; the P19 drift
multiplier layers on top untouched.

### P2 — HAUL: contracts & logistics between ports *(M — HAUL-0/1/2 SHIPPED dark as migs 0176 + 0179; HAUL-3 UI + flip remain)*
NPC delivery contracts: a per-port bulletin offers "deliver N×good to port B by T for C credits + bonus."
Slices: HAUL-0 `haul_contracts` schema + flag + templates (dark, service-role writers — **shipped**, 0176);
HAUL-1 offer generator (cron, seeded-deterministic per port/day — **shipped**, 0176); HAUL-2 accept/deliver
RPCs (accept = origin-port claim + `deliver_by` deadline + active cap; deliver = docked-verified at the dest
+ cargo debit via Trade-Cargo's own functions + `wallet_credit` with `haul_receipts` — **shipped**, 0179);
HAUL-3 bulletin UI on PortScreen; HAUL-proof (**shipped + extended**, `scripts/haul-proof.{sql,sh}`).
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
byte-inert at level 1). C2-3: XP bars in TeamMemberCaptains. C2-4: the 6→8 slot raise (separate additive
migration, lit-time decision). Deps: Rung 0. Guard: Captain system stays sole writer; XP reads finalized
grants exactly like Ranking does — combat never writes captain XP mid-tick.

### P6 — HULLS-2: ship progression beyond starter_frigate *(M)*
HULLS2-0: seed 2 hulls dark — **bulk_hauler** (hp 650, speed 0.8, cargo 140, modules 2, captains 6,
`{attack 5, defense 15}`) and **strike_corvette** (hp 420, speed 1.3, cargo 20, modules 4, captains 6,
`{attack 30, defense 10}`) — role emergent from fit, no activity locks (MAINSHIP_TRANSITION core vision);
add `main_ship_hull_types.price_credits` (starter 250, hauler 800, corvette 800 — owner decision).
HULLS2-1: parity re-create of commissioning taking `p_hull_type_id` (default `'starter_frigate'` →
byte-inert) — this IS the "next functional rework" that retires the SYSTEM_BOUNDARIES fleets-shim
exception (repoint the sanctioned `fleets` writes through a Fleet-exposed function, re-derive the frozen
prosrc-md5 pins, delete the exception note in the same PR). HULLS2-2: hull picker in CommissionShipPanel
behind `hull_catalog_enabled`; proof. Deps: credits flowing (Rung 3/P3). Guard: stats only ever enter play
via `base_stats_json` through the 0170 adapter fold — no new stat path.

### P7 — MODULES-2: tiers + the defense line *(S/M)*
MOD2-1: seed `shield_lattice` (defense 12, slot 1: repair_parts 4 + pirate_alloy 3 + scrap 8) +
`mining_rig_extension` (mining_yield, uses crystal) — recipes from live drops only (the F4 lesson: never
seed an item nothing drops). MOD2-2: Mk-II tier (`autocannon_battery_mk2` attack 18: blueprint_fragment 2
+ artifact_core 1 + weapon_parts 6; same for shield) — `slot_cost 2` so 3-slot ships face a real tradeoff
(the capacity-tradeoff law). MOD2-3: balance-table refresh with defense live (proof-only). Deps: none.
Guard: all stats flow through `module_types.stats_json` → the existing fitting adapter; the
Σ`slot_cost` ≤ `module_slots` reject-never-clamp cap already enforces tradeoffs.

### P8 — EVENTS-LIVE: world events as a live system *(M)*
EV-1: `worldstate_tick` publishes threshold events through the existing `world_events_publish` (pressure
crossings, depletion warnings, drift extremes — dedup-keyed). EV-2: **event sites** — a producer that
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
| 11 | MOD2-1 shield line **[D: stat values]** | queued |
| 12 | HAUL-0/1 contracts foundation **[D: template/reward table — proposed in the 0176 header, owner-tunable]** | **shipped (dark)** — mig `0176` (`haul_contract_templates` 10-template seed over the 0173 economy + `haul_contracts` + `haul_contracts_enabled=false` + `haul_offers_per_port=2` + the deterministic `haul_generate_offers()` generator (pure-hash per (day, port, slot), idempotent natural key, offered-only expiry) + hourly cron `haul-generate-offers` — a cron-safe dark no-op), proof `scripts/haul-proof.{sql,sh}` wired into `trade-v1-proof.yml` (slice-haul). **HAUL-2 shipped (dark)** — mig `0179` (slice-haul2): `haul_accept_contract` (origin-port claim — moves NO cargo/credits; `deliver_by = accepted_at + template duration` [the 0176 duration reused as the delivery window — the contract's tempo]; `haul_max_active_per_player=3` cap [D]) + `haul_deliver_contract` (ANY owned ship docked at the DEST; `trade_cargo_consume` + `wallet_credit`, atomic + receipted; cost basis consumed-and-lost, the reward covers it) + `haul_receipts` (the salvage_receipts shape, sole writers = the two RPCs) + the generator re-created (0176-head parity, ONE marked (a2) hunk: accepted past `deliver_by` → 'cancelled', freeing the cap slot; no penalty v1 [D]) — same flag, still dark; proof extended (dark RPC rejects, accept/deliver happy+guards+replays incl. replay-at-cap, deadline cancel). HAUL-3 UI + ACT-HAUL flip = later slices |
| 13 | CAPXP-0/1 captain XP foundation **[D: xp knobs 10/6/4 + curve `1 + floor(sqrt(xp/100))` — proposed in the 0177 header, owner-tunable]** | **shipped (dark)** — mig `0177` (additive `captain_instances.xp/level` read by NOTHING until C2-2 + `captain_growth_enabled=false` + the per-(grant, captain) `captain_counted_grants` ledger with a NULL-captain sentinel (consume-exactly-once; no retroactive backfill) + `captain_xp_accrue()` folding FINALIZED `reward_grants` into CURRENTLY-assigned captains (the derivable semantic — captain-at-sortie is recorded nowhere; ship linkage: combat manifest ∪ solo fleet tag, exploration scanner, mining extractor; grants with no linkage → sentinel) + 5-min cron `captain-xp-accrue`, a cron-safe dark no-op), proof = the `TEAMCMD_PASS_CAPXP` block in `team-command-proof`; NOTE for the future ACT-CAPXP flip: the first lit run folds the entire dark backlog into current assignees — accept or pre-seed sentinels (0177 header). **C2-2 shipped (dark)** — mig `0180` (slice-c2-2): `calculate_expedition_stats` re-created from its TRUE head (`0170` — grep-verified: creates at 0044→0115→0122→0170 only) with the ONE marked captain-fold hunk — each assigned captain's stats_json contribution × `(1 + (level-1) × captain_level_bonus_per_level)` [D seeded 0.10, owner-tunable: level 2 = +10% on the captain-contributed portion only; specialization tradeoffs stay level-flat] + `i.level` joined into the fold (additive column). DOUBLY inert today: the flag is read ONCE at entry → ×1.0 exactly while `captain_growth_enabled` is dark regardless of level, AND ×1.0 exactly at level 1 regardless of the flag (knob floored at 0 — never a nerf); self-asserted at migration time (flag dark + zero captains above level 1 + prosrc pins: the gated multiplier token, exactly 8 scale sites, tradeoffs unscaled). Proof = the `TEAMCMD_PASS_CAPLEVEL` block in `team-command-proof` (exact lit bonus over the level-1 baseline on the CAPXP level-2 fixture, independently derived from catalog joins, + BOTH inertness arms; reconciliation checked: no earlier block calls the adapter post-flip/post-level-2, so every existing pin stays byte-valid). C2-3 XP bars UI + C2-4 the 6→8 slot raise = later slices |
| 14 | WORLD-RECON-F1 (read-only) | **shipped** (docs/WORLD_RECON_F1.md, second run @ head 0177 — surfaced the §7 reachability finding that produced #14.5) |
| 14.5 | COORD-GUARD + ACT-COORD-TRAVEL (the Rung-0.5 prereq for the exploration/mining flips: resolver-guard the raw coordinate command — the A0-fix — BEFORE `mainship_coordinate_travel_enabled` can flip) | **shipped** — mig `0178` (0070-head parity re-create; trailing `p_main_ship_id` + `mainship_resolve_owned_ship`, fail-closed at N≠1; self-asserting) + the S6C ship-id passthrough (buildSpaceMoveRpcArgs / commandMainShipSpaceMove / useSpaceMoveCommand / GalaxyMap thread the SELECTED ship exactly like stop/settle/readiness — dark until the flip) + `scripts/activate-coordinate-travel.{sql,sh}` (guard-pinned preconditions, the ONE flag write, anchors + reachability + envelope smokes — awaiting the human flip; NO flip-time client PR: the coordinate UI is server-readiness-driven). COMPLETE signature-pin repoint list in TRADE_FLEET_0C_VERIFIER_REPOINT.md §#1 (incl. the COORD_SURFACE_COUNT arg-type census + the S6A exact-args / security-intent asserts) |
| 15 | ACT-INVEST + ACT-WORLDBAL | queued |
| 16 | EV-1 + ACT-PHASE20 | queued |

*(Then: HAUL-3 + flip (HAUL-2 shipped dark, 0179), HULLS2 line [D], MOD2-2, RR line, OB line, C2-3
(C2-2 shipped dark, 0180) — resequenced at the next plan review.)*

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
phase20_polish_enabled · captain_shard_drop_rate (knob)`; compile gates in
`src/features/map/osnReleaseGates.ts` (`TRADE_MARKET_ENABLED` the last dark one); knobs:
`main_ship_price=250 · starting_credits=1000 · max_active_fleets=6 · max_main_ships_per_player=24`.
Content today: 8 locations (3 hunts bd 10/15/25, 3 ports, 2 safe), 1 hull, 4 modules, 5 captains,
6 goods × 3 ports (0173), 5 exploration sites, 5 mining fields, 12 item types.
