# OWNER RULING — Berthed fleet-less ships and the port economy

**Issued 2026-08-04. Recorded, NOT implemented.** This ruling is executed only at its approved final
position in the stat-architecture retirement sequence (step 9, the last fold). It does **not**
authorize implementation, merge, or deployment in the dark stat-foundation slice.

---

## The defect this resolves

Two authorities answer "which port is this ship at", and they disagree about one specific state.

| authority | resolution path | a berthed, fleet-less ship |
|---|---|---|
| `mainship_port_of_ship` (wide) — live def `20260618000334_a_wreck_is_where_its_fleet_is.sql:220` | fleet-dock → group-dock → **berth** | resolves **a port** |
| `mainship_resolve_docked_location` (narrow) — live def `20260618000210_fleetgo_group_read_oracle.sql:278` | requires a validated location context **and a present fleet**; never consults berth | resolves **NULL** |

Today **repair** uses the wide one (`20260618000335_one_way_to_repair.sql:284`) and **the entire
economy** uses the narrow one — market buy/sell, offers, item selling, haul accept/deliver, dock
services, commissioning, port shop, item transfer, craft, recruit, hull build.

`20260618000335_one_way_to_repair.sql:44-50` states the consequence in its own words: *"a BERTHED ship
read as 'at a port' for recovery and as `not_docked` for mending, on the same tick. All three of
production's destroyed ships are in exactly that shape right now."*

## The decision

> **A ship with a valid berth at a port is physically present at that port even when it currently
> belongs to no fleet. A validly berthed, fleet-less ship may use port-local economy and ship
> services that do not inherently require a fleet.**

It must not be treated as simultaneously "at a port" for repair and "not docked" for every other port
service.

## The distinction that must NOT be lost

**Do not solve this by replacing every narrow call with `mainship_port_of_ship`.** Both existing
functions conflate two separate questions:

1. **Where is this ship physically located?**
2. **Is this action permitted in the ship's current operational context?**

These become **separate authorities**. The port resolver answers location. The action authority
answers permission.

### Canonical port-presence resolution (question 1)

ONE typed resolver returning: port/location id · ship id · **nullable** fleet id · presence source
(`fleet_dock` / `group_dock` / `berth`) · whether the source record was fully validated · a structured
failure or non-applicable state.

A valid berth is an **authoritative physical-presence source**; a fleet-less berthed ship resolves to
its berth port, never `NULL`. Stale, invalid, conflicting or unpublished-location records **fail
explicitly** — they never fabricate port presence.

### Action authorization (question 2)

Port presence alone authorizes nothing. Each action declares the capabilities it requires, via
**controlled metadata or named policy code — never consumer-specific improvised docking predicates.**
Capabilities include: valid port presence · a present fleet · an eligible ship · real ship-bound cargo
capacity · sufficient free cargo volume · particular items/currency/modules/resources · an active haul
or activity assignment · existing ownership or progression requirements.

## Allowed for a berthed, fleet-less ship

Subject to each action's own requirements: repair and mending · ship fitting and module management ·
port shops and commissary · item or module buying and selling · crafting · captain recruitment and
assignment · hull construction · any service occurring entirely at the port that needs neither fleet
movement nor fleet-scoped cargo.

> **Do not require the player to create a meaningless temporary fleet merely to use a stationary port
> service.**

## Still prohibited without a fleet

Departing or moving · accepting a fleet-scoped voyage or activity · starting a haul requiring an
operational carrier fleet · delivering a haul whose contract belongs to or validates against a fleet ·
combat, mining, exploration or trade-fleet activity · anything requiring fleet composition, fleet
speed, fleet risk, or fleet-wide cargo eligibility.

**Browsing an offer may require only port presence; accepting or executing it may require more.** Do
not give "offers" one blanket rule when different offer types have different operational requirements.

## Cargo transactions

The canonical cargo authority remains **real ship-bound volume capacity**. A fleet-less berthed ship
may buy or sell only when the transaction has a valid authoritative storage destination or source.

Do **not** use the deprecated integer cargo stat · do **not** create an implicit fleet · do **not**
pool cargo · do **not** place goods into nonexistent capacity · preserve ship-bound ownership and
volume constraints · **reject with an explicit capacity or operational-context error** when no valid
ship hold can receive or supply the goods.

Haul acceptance and delivery stay separate from ordinary port-market transactions, because they may
require fleet-scoped operational state.

## Relationship to the NO-HOME / fleet-ownership law

The fleet group remains the authority for strategic movement · fleet docking operations · presence
while operating as a fleet · fleet activities · fleet combat and retreat · fleet-level speed, risk and
activity eligibility.

A berth represents an **individual ship stored or stationed at a port**. Recognizing berth presence
does **not** make the ship an operational fleet and does **not** transfer fleet authority to it.

## Prerequisite before implementation — the action matrix

A complete matrix for **every** current reader: repair · mending · market buy · market sell · offers ·
item selling · haul acceptance · haul delivery · dock services · commissary · crafting · recruitment ·
hull construction.

Per action record: current resolver · current behaviour for a **fleet-docked** ship · for a
**group-docked** ship · for a **berth-only** ship · whether fleet membership is genuinely required ·
whether cargo capacity is required · intended post-migration behaviour.

> **Do not silently broaden all economy RPCs in one undifferentiated replacement.**

## Required test matrix

1. Valid fleet-docked ship · 2. Valid group-docked ship · 3. Valid berth-only fleet-less ship ·
4. Ship with no presence record · 5. Stale berth · 6. Berth pointing at an invalid or inactive
location · 7. Conflicting fleet and berth locations · 8. Port-local repair by a berth-only ship ·
9. Port-local market action by a berth-only ship · 10. Cargo purchase with sufficient ship-bound
volume · 11. Cargo purchase without sufficient volume · 12. Fleet-required haul action without a
fleet · 13. The same action after assignment to a valid present fleet · 14. **No consumer interpreting
resolver failure as `not_docked`** · 15. **No consumer using the deprecated cargo integer for
authorization.**

## Definition of done

Physical port presence has ONE typed authority · a valid berth counts as port presence · action
authorization is capability-specific · fleet-required activities still require a fleet · repair and the
economy no longer disagree about the same ship on the same tick · **neither `mainship_port_of_ship`
nor `mainship_resolve_docked_location` survives as a competing semantic authority** once all callers
are migrated and proven.
