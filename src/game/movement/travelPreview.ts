// THE ONE Euclidean distance helper on the client.
//
// This file used to be a second travel-time authority. Alongside `distance` it exported a client
// mirror of the server's movement formula — `previewTravelSeconds`, `slowestSpeed`,
// `countdownClock`, and its OWN hardcoded `DEFAULT_TRAVEL_SCALE = 1.0` /
// `DEFAULT_MIN_TRAVEL_SECONDS = 5`. Production runs `travel_scale` and `min_travel_seconds` out of
// `game_config`, so those constants were the server's numbers copied into TypeScript and then left
// behind. Nothing imported any of it: the legacy send UI those exports served was retired, and every
// surface has rendered the server-returned `arrive_at` ever since (`docs/OSN3_S6B_PRES0_AUDIT.md:121`
// already listed them as uncalled). They are deleted rather than kept "in case" — a dormant second
// formula with stale defaults is exactly what the no-spaghetti rule forbids, and reading this file
// was enough to believe the client still computed ETAs.
//
// If a preview ETA is ever wanted again, it must come from the server (an RPC that resolves the same
// speed the mover will use), never from arithmetic re-implemented here.

export function distance(ax: number, ay: number, bx: number, by: number): number {
  return Math.hypot(bx - ax, by - ay)
}
