# World-Hub ownership rules (WORLD-HUB-1A)

WORLD-HUB-1A adds the domain boundaries for future real cities/ports. It is **additive, dark, and
disconnected** from OSN movement — no seed, no anchors, no services consumed, no flag, no UI. These are the
ownership rules it establishes; later phases must respect them and must not create duplicate authorities.

| Concern | Owner (single authority) | Notes |
| --- | --- | --- |
| **Location physical identity** | `locations.physical_role` (`city`/`port`/`station`/`landmark`/`activity_site`/`unclassified`) | The durable "what kind of place" identity. **Not** `location_type`/`activity_type` (those describe gameplay activity). Existing rows are `unclassified` (not reclassified). |
| **City/port capabilities** | `location_services` (`docking`/`market`/`repair`/`refit`/`recruitment`) | Services are **separate from coordinates and from `activity_type`**. A location may hold several services. Server-only; empty until a future phase. |
| **Canonical coordinates** | `space_anchors` | Coordinate truth only. **Anchors do not imply any service or dockability.** Untouched by this phase. |
| **Player default home port** | `player_home_port` (player → location) | A player-level **affiliation**. **Not** the base, **not** a base anchor, **not** the source of a ship's current position. Server-owned; owner-read only; no player write; unassigned. |
| **Ship current physical location** | `location_presence` (+ fleet / main-ship spatial state) | Unchanged. A ship can be docked at City A while the player's home port is City B. |
| **Base** | `bases` | Non-spatial economy/production/admin entity. **No base anchor, no base coordinate authority, no base-return navigation.** |

## Invariants

- Cities/ports are real `locations` rows — there is **no separate `cities` table**.
- A location's services never come from `space_anchors`; anchors never decide dockability.
- Home-port affiliation (player property) is distinct from physical presence (ship property): being "home" is
  not the same as being physically docked somewhere.
- Configuration (physical role, services, home-port affiliation) has **no public player mutation path**;
  writes are service-role only (home-port owner-read is allowed; everything else is server-only).
- This phase changes no OSN movement/Dock-0/arrival/Stop behavior, no legacy `home`, presence, repair, or
  initialization, and no feature flag.
