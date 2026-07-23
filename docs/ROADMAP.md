# Byeharu — Forward Roadmap & Game Direction

> Authoritative statement of where Byeharu is going, recorded 2026-06-17 (Phase 1
> reconciliation). The engine design lives in `ARCHITECTURE.md`; the per-system
> ownership law in `SYSTEM_BOUNDARIES.md`; the running history in `DEV_LOG.md`.

## Final game identity

Byeharu is a **main-ship expedition game** — not mass anonymous fleet management.

```
One main ship + captains + modules + support craft + cargo
  → send an Expedition to a pirate / trade / exploration / mining location
  → fight / trade / scan / extract
  → return home to secure loot, profit, resources, discoveries, ranking points
  → craft / upgrade / repair → stronger next expedition
```

Core fantasy: *"my ship and crew go on dangerous expeditions, return with rewards, and
become stronger."*

## What is already built (KEEP — reclassified, not rewritten)

- **M2–M4 = the Expedition Engine.** travel · arrival · pirate combat (3s ticks) · rising
  waves · per-unit HP/losses · retreat (still takes damage) · return movement ·
  **reward deposit only on home arrival** · combat report. Reused by every future activity.
- **M4.5 = the Serial Build Queue Foundation.** serial queue · one active slot · waiting
  orders don't tick · cancel + refund/penalty preview · per-ship + total time · active
  progress · history fold · friendly location labels. Future meaning: **support craft /
  module / repair-kit / drone / equipment production** (same queue).
- **M5–M7** (also done): World State pressure/danger (60s cron, decay-to-baseline);
  frontend depth (location panel, round log, /reports); metal-spend ship training.

## Standing laws (every future system obeys these)

1. **Main-ship centered.** The main ship is a unique INSTANCE (not stackable), the emotional
   center; usually returns damaged / needs repair rather than being deleted.
   > **AMENDMENT (2026-07-02, user-directed — see `DEV_LOG.md` 2026-07-02):** a player may own
   > **multiple** persistent main ships. Each ship remains a distinct, non-stackable, individually
   > addressed INSTANCE (the emotional-center framing is unchanged) — "not stackable" means ships
   > are never fungible counts, **not** "one per player." Multi-ship ownership is a **Trading V1
   > foundation (TRADE-FLEET-0)**, not a later feature. Trade cargo is **ship-bound** and measured
   > **by volume only (m³)** — no account/fleet-pooled cargo, no kilograms/mass in V1 (mass is
   > future-only).
2. **Support craft are capacity-limited loadout choices, NOT additive power.** Each consumes
   `support_capacity`; specialized roles with opposing tradeoffs (combat↔cargo, safety↔speed,
   scouting↔fighting, repair↔damage, mining↔protection, heavy-trade↔low-risk). More support
   also costs more (fuel/supply, speed, pirate attention, replacement loss). You can never
   bring every best type at once.
3. **The pipeline is one-directional — systems never mutate each other:**
   ```
   Activity creates a PENDING result
     → Return-home SECURES it (idempotent; lost if the expedition fails before return)
     → Inventory STORES it
     → Progression (crafting / captains / modules) CONSUMES inventory
     → Ranking READS finalized result events
   ```
   Wrong: mining crafts modules directly · exploration upgrades captains directly · combat
   fits modules directly · trading resets rankings directly.
4. **Don't replace the engine — replace the SOURCE of expedition stats.** Combat/trade/etc.
   read final stats from `calculate_expedition_stats(main ship + captains + modules + support
   craft + cargo + activity)`, which **enforces capacity + tradeoffs (never a plain sum)**.
5. **One owner per system** (extends `SYSTEM_BOUNDARIES.md`): Movement=travel/return ·
   Combat=ticks/damage · Return-home=secured deposit · Production=support craft/crafting ·
   Inventory=item balances · Main Ship=ship instance · Fitting=modules · Captain=assignment ·
   World State=location/zone state · Ranking=seasons/leaderboards · Report=history.
   Server-authoritative everywhere; frontend never mutates inventory/fitting/captains/rankings.
6. **Don't rename backend tables yet** (`fleet_id` → conceptually `expedition_id` later);
   rename only after behavior is stable and tests green. Activity types route via the existing
   Activity system: `pirate_hunt`, `trade_run`, `exploration`, `mining` (more later).

## Phased plan (incremental — M2/M3/M4/M4.5 stay green every phase; nothing built until asked)

| Phase | Scope | Notes |
|---|---|---|
| **1** ✅ | **Docs/roadmap reconciliation** | this doc + README/ARCHITECTURE; no code |
| **2** ✅ | Expedition activity architecture (design only) → **`docs/ACTIVITIES.md`** | clean activity abstraction; no giant switch |
| **3** ✅ | Generic inventory (`item_types`, `player_inventory`, `inventory_ledger`; deposit/spend/balance fns) | metal kept in base_resources; items in player_inventory |
| **4** ✅ | Pending **loot bundle** (`{ metal?, items[] }`) — `reward_grant` splits metal→base_resources, items→player_inventory | jsonb-only (no schema change); deposit-on-arrival law kept; no new drops yet |
| **5** ✅ | Multi-item pirate loot — `pirate_loot_for_wave` (deterministic, seeded items) merged into the combat bundle | combat → pending bundle; secured on return only; no crafting/UI yet |
| **6** ✅ | **support craft metadata** (`support_craft_types`: role + capacity_cost + activity tags + tradeoffs; 8 seeded) | metadata-only reframe; no instances/attachment/enforcement yet; serial queue reused conceptually |
| **7** ✅ | `main_ship_hull_types` + `main_ship_instances` (one per player; hull base stats; ensure/get/rename) | server-authoritative; sits `home`; doesn't drive expeditions yet |
| **8** ✅ | `calculate_expedition_stats()` (read/compute adapter; capacity hard-cap + tradeoffs, not a sum) | old fleet-stack path still owns combat; not live-wired yet |
| **9** ✅ | Expedition UI reframe + **docked-port read surface** (`get_my_current_dock_services()` + `DockServicesPanel`, migration `0069`) | done & deployed; main-ship/expedition wording reconciled; dock surface shows the current port + active services only at `at_location` (today: Docking). OSN port-to-port is **enabled**; free coordinate travel is **server-gated off** (`mainship_coordinate_travel_enabled=false`, migration `0070`). **⚠ SUPERSEDED 2026-07-23:** the *per-ship* movement surface described here was closed on 2026-07-18 and then **physically dropped** (`0231` columns, `0232` 20 functions). Movement is now the ONE unified fleet mover `command_ship_group_go` (TRUE head `20260618000233_…:589`), and free-coordinate travel is a property of *that* mover, not of `mainship_coordinate_travel_enabled` (which is `false`). See `docs/MOVEMENT_UNIFICATION_CHARTER.md` + `docs/MOVEMENT_ROLLBACK_DEFECT.md` |
| 10 ⏳ | Trading (buy low / travel / sell high; **volume-only (m³)** ship-bound cargo, route danger) | **implemented DARK, NOT activated.** **FIXED product direction 2026-07-02** (see `DEV_LOG.md` 2026-07-02 + `TRADE_FLEET_0A_IMPACT_AUDIT.md`): **volume-only per-ship cargo (m³ canonical; NO kilograms/mass/dual-cap in V1), ship-bound cargo (never pooled), multiple persistent main ships as a Trading V1 foundation, commodities with fixed canonical m³ denominations, every market action targets one selected docked ship (atomic volume check), ships as first credit sink.** Out of V1 scope: pooled cargo, account trade inventory, remote market, **ship-to-ship transfer**, warehouses, auto-routes, P2P trade, dynamic supply/demand, cargo loss/insurance, mass/fuel mechanics. Retained: free-port eligibility, server-owned `market_offers`, lazy wallet, `trade_receipts` idempotency, per-offer allowance (re-scoped to a selected ship). **Sequence:** PORT-ENTRY (done, mig `0072`) → **TRADE-FLEET-0A** (read-only impact audit) → **TRADE-FLEET-0B** (explicit user-approved multi-ship + volume-cargo contract) → **TRADE-FLEET-0C** (coherent implementation slice) → **TRADE-MARKET-1** (server-authoritative market) → **TRADE-UI-1** (selected-ship market + fleet UI). **Status 2026-07-03:** the pipeline (TRADE-FLEET-0C `0073–0084`, TRADE-MARKET-1 `0085–0091`, TRADE-UI-1 client, docked-location cleanup helper `0092`, ECONOMY-BOOTSTRAP `0093–0095` — seed capital via the shared `wallet_ensure` + the no-softlock relief floor `market_claim_relief`, proven by the disposable self-rolling-back `scripts/trade-economy-bootstrap-proof.{sql,sh}` wired into `.github/workflows/trade-v1-proof.yml`) is **implemented DARK & PR-ready** on `autopilot/20260703-064048` (migration head `0095`; **not deployed/activated** — all trade flags/gates OFF, incl. `trade_relief_enabled=false`); see `DEV_LOG.md` 2026-07-03. **Status 2026-07-12 (ECON-SEED-1, queue #4):** the differentiated three-port economy is **seeded** — migration `0173` upserts the owner-approved 3-port × 6-good price table into `market_offers` (Haven consumer / Slagworks industrial / Driftmarch frontier; ≥3 profitable routes, e.g. ore Slagworks 12 → Haven 16; self-asserting + proven by `scripts/trade-econ-seed-proof.{sql,sh}` in `trade-v1-proof.yml`). Still DARK — **awaiting the ACT-TRADE flip** (queue #5: `trade_market_enabled` + `trade_relief_enabled` + client `TRADE_MARKET_ENABLED`), which is human-gated. **Status 2026-07-12 (ACT-TRADE, queue #5): flip script shipped** — `scripts/activate-trade.{sql,sh}` (one BEGIN..COMMIT, management-API compatible; preconditions: `0173` recorded + 18 active offers / anti-pump / 3 routes recomputed from live rows + the deployed trade RPC bodies prosrc-pinned to the `0138` re-creates + relief knobs sane; flips `trade_market_enabled` + `trade_relief_enabled` TOGETHER — relief is the no-softlock backstop; read-only smoke; commented flag-only rollback). The flip itself + the one-line client PR (mounts `MarketPanel` on PortScreen; the ShipSwitcher OR-gate merely completes — the switcher is already mounted via `MAINSHIP_ADDITIONAL_ENABLED`) remain human-gated. |
| 11 | Exploration (scan/discover → data/shards/blueprints) | **implemented DARK, not activated** (migrations `0097–0101`, `0146`, `0172` — the writer reconcile restoring the 0100 `main_ship_id` securing link 0146 had clobbered; `exploration_enabled=false`). pending discovery rewards; scan in **OSN** proximity of unexplored coordinates where applicable. **Activation script shipped** (`scripts/activate-exploration.{sql,sh}`, 2026-07-12; hard-gated on `0172`) — awaiting human flip (recommended order: exploration first, per `TEAM_ACTIVATION_PACKET.md` §7) |
| 12 | Mining (extract → ore/crystal/cores) | **implemented DARK, not activated** (`mining_enabled=false`; incl. the `0143` double-extract guard + `0172` — the writer reconcile restoring the `0137` P19 depletion hooks 0143 had clobbered). pending resource rewards; navigate via **OSN**, extract within proximity where applicable. **Activation script shipped** (`scripts/activate-mining.{sql,sh}`, 2026-07-12; hard-gated on `0172`) — awaiting human flip (recommended a few days after the exploration flip; the scripts are independent) |
| 13 | Module instances + crafting | **implemented DARK, not activated** (migrations `0107–0110`; `module_crafting_enabled=false`). instances, not stack-only |
| 14 | Module fitting (`fit_module_to_ship`) | **implemented DARK, not activated** (migrations `0111–0116`; `module_fitting_enabled=false`). server-validated; feeds stats |
| 15 | Captain instances + assignment | **implemented DARK, not activated** (migrations `0117–0122`; `captain_assignment_enabled=false`). effects via `calculate_expedition_stats` |
| 16 | Captain progression (consumes inventory) | **implemented DARK, not activated** (`captain_progression_enabled=false`). inventory is the bridge |
| 17 | Ranking / competition (weekly/monthly seasons; combat/trade/explore/mine) | **implemented DARK, not activated** (`ranking_enabled=false`; incl. `0144/0145/0147` counted grants + accrue cron). reads finalized events; reset by season, not deletion. **Activation script shipped** (`scripts/activate-ranking.{sql,sh}`, 2026-07-12; one txn: flag first — `ranking_season_open` dark-gates on it — then weekly/monthly seasons opened via the sole writer; NO client PR — RankingPanel is server-lit on the CommandScreen aside) — awaiting human flip (plan §B rung 5: recommended after rungs 1–3 so ≥3 dimensions accrue). NOTE: seasons do **not** auto-roll — manual roll each Monday / 1st (a script re-run IS the roll) until a RANK-ROLL automation slice |
| 18 | Location investment (seasonal score vs persistent state) | **implemented DARK, not activated** (`location_investment_enabled=false`). no infinite exploit |
| 19 | World balance / living economy (pirate pressure, price drift, field depletion) | **implemented DARK, not activated** (`world_balance_enabled=false`; price drift `0136–0138`). world-state owns world-state |
| 20 | Polish / expansion (map UI, portraits, icons, events; guilds/PvP much later, if ever) | **implemented DARK, not activated** (world events + UI asset catalog `0139–0142`; `phase20_polish_enabled=false`). NOTE: the **Mission Control UI renewal (R0–R4)** shipped LIVE 2026-07-12 as a frontend-only renewal — separate from this dark phase-20 content |
| 21 | Salvage market (combat loot → port credits; `FULL_CAPACITY_PLAN.md` §C P3 — the phase-21 economy wave) | **SALVAGE-0/1 implemented DARK, not activated** (mig `0174`: `port_item_demand` + `sell_item_at_port` + `salvage_receipts`; `salvage_market_enabled=false`; proof in `trade-v1-proof.yml`); SALVAGE-2 UI + ACT-SALVAGE flip are later queue slices |
| 22 | Delivery contracts — HAUL (per-port NPC delivery bulletins: "deliver N×good to port B by T for C credits"; `FULL_CAPACITY_PLAN.md` §C P2 — the retention loop) | **HAUL-0/1 implemented DARK, not activated** (mig `0176`: `haul_contract_templates` — 10 migration-seeded templates over the 0173 three-port economy, incl. two above-market Drift backhauls — + `haul_contracts` + the deterministic offer generator `haul_generate_offers()` on the hourly cron `haul-generate-offers`, a cron-safe no-op while `haul_contracts_enabled=false`; offers are a pure hash function of (day, port, slot), rewards priced off the LIVE `market_offers` rows and always modestly beating the same-haul self-trade; proof `scripts/haul-proof.{sql,sh}` in `trade-v1-proof.yml`); **HAUL-2 implemented DARK** (mig `0179`: `haul_accept_contract` origin-port claim + `deliver_by` deadline + `haul_max_active_per_player=3` cap; `haul_deliver_contract` — ANY owned ship docked at the dest, cargo via `trade_cargo_consume`, credits via `wallet_credit`, `haul_receipts` idempotency; generator (a2) deadline-cancel pass) + **HAUL-3 implemented DARK** (mig `0181`/PR #117: `get_port_contracts` gate-first bulletin read + HaulBoardPanel server-lit on the Port screen aside, PortScreen.tsx:80 — renders null while dark). **Activation script shipped** (`scripts/activate-haul.{sql,sh}`, slice-act-haul, 2026-07-12; one txn: the flag write, then ONE sanctioned in-txn generator invoke = INSTANT offers at all 3 starter ports instead of a ≤1h wait for the minute-7 cron; the authed bulletin read smoked under a txn-local fake JWT and matched to table truth; rollback = flag-only + the expiry-freeze choice documented) — awaiting the human flip, **hard-preconditioned on `trade_market_enabled=true`** (deliver consumes `ship_cargo_lots` and `market_buy` is the sole cargo-lot producer; mining ore is item-inventory, never cargo — dark-trade contracts are undeliverable): FLIP ORDER = after ACT-TRADE. NO client PR needed |
| 23 | **Content expansion I — ZONES-2 "Ember Reach"** (`FULL_CAPACITY_PLAN.md` §C P4; phase rows 21–27 follow that plan's queue and are appended as their slices ship — historical numbering preserved) | **seeded HIDDEN, reveal script shipped, awaiting the human reveal** (2026-07-12, queue #7+#8): migration `0175` seeds sector Ashen Frontier + zone Ember Reach (active, empty) + 3 hidden hunt sites — Ember Gate bd 40/gate 150, Cinder Maw bd 50/220, The Furnace bd 60/300 (tiers 4/4/5); `scripts/reveal-ember-reach.{sql,sh}` is the one all-or-nothing reveal (rollback-capable, unlike the port reveal). **Recommend revealing only AFTER teams have had time to kit up** — the packet's C-seed rationale (`TEAM_ACTIVATION_PACKET.md` §0.3/§1.3-C) prices the `min_power_required` gates at ≈4/6/8 kitted+captained ships (38 combat_power each), so modules/captains should be flowing first |
| 24 | **Captain progression I — CAPXP (C2-0/1)** (`FULL_CAPACITY_PLAN.md` §C P5, queue #13: captains accrue XP from finalized reward grants for sorties whose manifest included their ship) | **CAPXP-0/1 implemented DARK, not activated** (mig `0177`: additive `captain_instances.xp/level` — READ BY NOTHING until the C2-2 adapter delta — + `captain_growth_enabled=false` + the commit-safe per-(grant, captain) `captain_counted_grants` ledger (the 0144/0145 anti-join idiom + a NULL-captain sentinel: every grant consumed exactly once, bounded scans, NO retroactive backfill to later-assigned captains) + `captain_xp_accrue()` on the 5-min cron `captain-xp-accrue` (a cron-safe dark no-op) crediting captains **assigned at accrual time** — the only derivable semantic: captain-at-sortie-time is recorded nowhere (a D-family manifest extension could snapshot it — noted future refinement). Ship linkage per source: combat = encounter → fleet → `group_sortie_members` manifest ∪ the `fleets.main_ship_id` solo tag; exploration = the discovery's recorded scanner (nullable); mining = the extraction's ship (NOT NULL); no-linkage grants (legacy unit fleets, retention-cleaned encounters, future 'trade') → sentinel, 0 xp. Knobs `captain_xp_per_{combat,exploration,mining}_grant` = 10/6/4 + curve `level = 1 + floor(sqrt(xp/100))` [D proposed, owner-tunable]; proof = the CAPXP block of `scripts/team-command-proof.{sql,sh}`); C2-2 level-curve adapter parity delta + C2-3 XP bars + C2-4 slot raise + the ACT-CAPXP flip (which must decide the dark-backlog question — the first lit run folds every dark-era grant into current assignees; 0177 header) are later slices |

**Each phase has its own acceptance criteria + verification; backend changes go through a
migration with a `verify:*` script, and the engine's M2/M3/M4/M4.5 tests must stay green.**

> **STATUS NOTE (2026-07-12): the TEAM-COMMAND system (the multi-ship amendment's expedition
> "groups" — 3 teams of owned ships, team send/stop, captains-in-teams, team combat over the
> existing engine) is implemented DARK end to end (slices A → D4, migrations `0160–0169`;
> `team_command_enabled=false` + compile-time `TEAM_COMMAND_ENABLED=false`). See
> `docs/TEAM_COMMAND.md` (slice record + ACTIVATION CHECKLIST) and
> `docs/TEAM_ACTIVATION_PACKET.md` (the activation decision packet).**

## Cross-cutting initiative: Open-Space Navigation (OSN)

OSN is a **cross-cutting spatial foundation — NOT a numbered Phase.** It deliberately sits *outside*
the numbered plan above so it does not collide with **Phase 10 (Trading)** / **Phase 11 (Exploration)**
or the separate main-ship **Phase 10A–10H** transition. It gives the main ship one authoritative
position model, free movement across open space, stop-in-space, and proximity rules.

**Product direction (2026-06-20):** prioritize **OSN before new main-ship combat** — the intended game
is exploration / mining / trading / persistent open-space movement, and combat should later build on
the resulting real coordinate, route, and proximity model.

Stages (sequential, additive; every completed system stays green each stage):
- **OSN-1** — live read-only marker + route of the **local player's own** main ship (one shared position resolver). Marker layer is multi-entity-capable, but **no other-player data** until Online Presence & Visibility v1.
- **OSN-2** — durable free-space position model (storage choice deferred; criteria only).
- **OSN-3** — arbitrary-coordinate movement (parallel, main-ship-only; verified location RPCs frozen).
- **OSN-4** — stop mid-travel (server-side, one locked transaction; DB time, no orphans).
- **OSN-5** — proximity / docking semantics (interaction range ≠ docked/present).

OSN is the **preferred** shared spatial substrate for trading, exploration, mining, main-ship combat,
and multi-ship work — **not a hard prerequisite** for a minimal version of each (sequencing stays
flexible). Full architecture rules and the main-ship-specific design live in
`docs/MAINSHIP_TRANSITION.md` **§12. Open-Space Navigation (OSN)**.

## Cross-cutting initiative: Online Presence & Visibility v1

Byeharu will become an online persistent-space game, but other-player visibility is **deliberately
deferred** — not built merely because the game is online. **Timing rule:**

> Implement **Online Presence & Visibility v1 AFTER** the baseline **Exploration, Mining, and Trading**
> loops are functioning (each consuming the OSN position/proximity model), **and BEFORE** any
> player-to-player interaction (player trade, alliances, escorting, piracy, PvP, shared exploration,
> player combat, or any direct player encounter).

**Why this timing:** OSN must first establish a reliable single-ship coordinate + proximity model;
Exploration/Mining/Trading must first reveal what "visibility" should mean in real gameplay; and
online visibility must arrive **before** player-interaction systems so those systems don't invent
separate, incompatible position/visibility logic.

**Purpose — define what *seeing another player* means, from real gameplay.** The design must decide:
1. **Who sees whom:** nearby-only / global / alliance-only / scan-revealed / docked-station-visible / hostile-war / fog-of-war.
2. **Position precision:** exact-live / sampled / delayed / last-seen / approximate-area-only.
3. **Movement visibility:** current marker only / no route line by default / moving vs stopped/docked treated differently.
4. **Scale & interest management:** never load every ship in the galaxy by default; query only relevant ships/areas; define viewport/radius/sector/subscription boundaries; define polling/realtime cadence + limits.
5. **Interaction authority:** visibility alone permits nothing — trade / attack / inspect / follow / dock each need their own server-authoritative rule.

**First implementation scope (deliberately small):** nearby visible ships only; **no** global
all-player map; **no** full route display for other players; **no** automatic interaction; likely
**sampled/delayed** positions (not exact live tracking); an explicit **relation field**
(self / ally / neutral / hostile); server/RLS rules expose only what the visibility policy allows.

**Deferred until AFTER v1:** player-to-player trade, alliances, escorting, piracy, PvP, shared
exploration, player combat. **Global player visibility, realtime feeds, and player interaction are
explicitly deferred** — and during OSN there is **no** marker table, global ship feed, realtime
listener, or cross-player coordinate query (see the OSN marker rule in `docs/MAINSHIP_TRANSITION.md` §12).

### Post-visibility sequence (after Online Presence & Visibility v1)
1. Player-to-player trade & market interaction.
2. Alliances, escorting, cooperative exploration.
3. Piracy / hostile encounters / PvP rules.
4. **Main-ship combat** using the same coordinate / proximity / visibility model (defeat → the already-built **10F** safelock).
5. Captains, modules, fitting, support craft, deeper specialization (extends Phases **13–16**).
6. Rankings / leagues on stable combat / trade / exploration / mining metrics (Phase **17**).
7. Outpost → Station → Colony progression once economy + location investment mature (Phases **18–19**).

*(These extend the existing numbered phases where applicable; historical labels are not renamed.)*

## Cross-cutting initiative: Main Ship Repair & Recovery

A **cross-cutting initiative — NOT a numbered Phase.** **Timing:** **after** OSN establishes a durable
free-space position (**OSN-2**) and proximity/docking (**OSN-5**), and **before main-ship combat is
released** (combat causes destruction, so real repair/recovery must exist first).

The current `repair_main_ship()` is a **temporary safelock / test-recovery path** only — it's instant,
free, teleports to Home, and has no location/cargo/time/cost consequence. It is **preserved unchanged**
as a compatibility path until this initiative replaces it. Full design (destruction/recovery state +
last-known coordinate, Home-vs-station/colony repair, server-authoritative duration/queue, cost,
emergency-vs-normal recovery, cargo/activity/movement consequences, open-space destruction, and a
non-breaking migration of the existing `destroyed`/`repair_main_ship()` safelock) lives in
`docs/MAINSHIP_TRANSITION.md` **§13. Main Ship Repair & Recovery**.

## Cross-cutting initiative: World Editor

A **cross-cutting initiative — NOT a numbered Phase.** An owner-only authoring tool on the REAL game map
(never a bespoke second map), replacing the retired standalone `ZoneEditor`. Full architecture —
the unified shell + typed layer adapters, the shared owner security + draft/audit framework, and the
bounded phased roadmap — lives in `docs/ZONE_TEMPLATES_ARCH.md` **§WE (World Editor — Proposed
Architecture)**; slice records in `docs/WORLD_EDITOR_V1B0_OWNERSPINE.md` and `DEV_LOG.md` (session
2026-07-19→20).

**Status (2026-07-23) — the World Editor program is CLOSED.** V1 → V5 shipped end to end. The migration
chain `0263`→`0271` is **deployed** (production migration head is now **`0272`**, after the DARK elite
stat-wiring migration `0272` deployed on 2026-07-23 — see `docs/DEV_LOG.md` §9), and client V5 (entity search +
camera jump, coordinate jump, global lifecycle filter, pending-drafts indicator, unsaved-draft navigation
guard, inactive-entity selection + reactivation) is merged, plus a UX comfort pass (PR #287). All four
domains now have **create · update · lifecycle flip**; location reactivation runs through
`location_update` (status) — **there is no `location_set_active`**, by design. Ownership is recorded in
`docs/SYSTEM_BOUNDARIES.md` §6: the World Editor is a **function-owning, table-owning-nothing** system;
`locations` / `sectors` / `zones` remain **Map**-owned. Full closure record:
**`docs/WORLD_EDITOR_ROADMAP_CLOSURE.md`** + `DEV_LOG.md` 2026-07-23.

> **Verification posture:** production closure verification was a **READ-ONLY smoke**. Mutation paths are
> covered by the CI disposable apply-proofs, **not** by a live production mutation smoke.

**The V1C coordinate normalize was NOT what shipped.** The ×17 normalize direction was **rejected**
(PR #245 closed unmerged; migration slot `0253` is intentionally reserved and absent from `main`). What
shipped instead was a **read-then-write cutover onto `space_anchors`** (`0263`/`0264`) with a single
canonical ±10000 validation authority (`0265`) — **no coordinate was moved.** Staged coordinate work
continues under the separate coordinate program.

**The per-slice status list below is the 2026-07-20 snapshot — ⚠ SUPERSEDED, kept for the record:**
- **V1 Foundation** ✅ shipped, merged (PR #228) — read-only unified editor shell on the real map + 4
  typed read-only layer adapters (locations/mining/exploration/zones) + inspectors, reusing the shared
  map primitives (`openSpaceTransform`/`galaxyCamera`/marker styling); no migration, no mutation, no flag.
- **V1B-0 Owner Security Spine** ✅ shipped, merged (PR #229) **and DEPLOYED LIVE** (mig `0243`) — the
  reusable `app_owners`/`is_owner()`/`world_editor_audit`/`world_editor_ping` guard + idempotency + audit
  contracts every future write command routes through. Verified live: head `0243`, owner seeded,
  `0239` pirate-zone lockdown intact, combat unaffected.
- **V1B-1 Location Drafts & Preview** ✅ shipped, merged (PR #230) — client-side location draft model
  (draft/preview only, FNV-1a fingerprint, localStorage-backed), dark behind `dev_zone_editor_enabled`;
  zero live `locations` write, no publish path yet.
- **V1B-2 Location Validation** ⏳ **in progress** — typed validation ruleset over V1B-1 drafts, single
  enum source-of-truth; still no publish.
- **V1C Canonical `space_anchors` coordinate authority** ⏳ **next** — inventory complete: two
  incompatible coordinate scales coexist today (map-seed frame ~±300 unbounded vs. OSN frame ±10000 used
  by `space_anchors`/mining/exploration/fleets). Staged normalize-then-cutover migration (approach A:
  normalize `locations` into the ±10000 frame, make `space_anchors` the single authority) is in design —
  **world-affecting, deferred behind separate deploy approval**, not yet a migration.

**Sequencing note:** publish/mutation (the eventual point of the editor) is intentionally the LAST piece —
every slice before V1C stays read-only or client-local-draft-only, so the owner security spine (V1B-0) and
the coordinate-authority cutover (V1C) are both settled before any command can touch a live world row.
