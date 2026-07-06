// PHASE20-POLISH — the CLIENT "files" side of the UI asset split.
//
// ARCHITECTURE (STEP 4 decision, not duplication): the SERVER owns the icon VOCABULARY — the
// `ui_asset_catalog` keys + display metadata + the stable `asset_ref` (migration 0142). This file owns
// the rendered GLYPH per `asset_ref` — the "files" side — as tiny inline emoji so ZERO binary assets
// ship. The two never overlap: the server decides WHICH icon a row means; the client decides how that
// `asset_ref` LOOKS. A new server icon key is a forward-only seed row + one entry here.
//
// Keys are the `asset_ref` values seeded in 0142. An unrecognized `asset_ref` resolves to `undefined`
// (via the plain index access) — the consumer renders no glyph, never breaking the feed (fail-safe).

export const assetGlyphs: Record<string, string> = {
  // severity icons (paired with world_events.severity)
  'icon.severity.info': 'ℹ️',
  'icon.severity.warning': '⚠️',
  'icon.severity.critical': '🛑',
  // generic event icons
  'icon.event.notice': '📣',
  'icon.event.world_state': '🌐',
}
