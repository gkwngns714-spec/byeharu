// PHASE20-POLISH — PURE, framework-free types for the dark UI asset-key catalog surface.
//
// Mirrors the server contract exactly: get_ui_asset_catalog's row shape + envelope (migration 0142).
// No React/DOM/fetch here (the eventsTypes.ts / explorationTypes.ts idiom). DARK: while
// phase20_polish_enabled is false the server returns { ok:true, assets:[] } (the flag gate empties the
// catalog server-side) — visibility is server-driven, no client flag constant.

export type UiAssetKind = 'portrait' | 'icon'

/** One row of get_ui_asset_catalog() (0142) — a key→metadata vocabulary entry, never binary data. */
export interface UiAsset {
  asset_kind: UiAssetKind
  asset_key: string
  display_name: string
  // The stable identifier the CLIENT resolves to a rendered glyph/image (assetGlyphs.ts) — the "files"
  // side. The server owns the key vocabulary; the client owns the rendered form per asset_ref.
  asset_ref: string
  category: string | null
  sort_order: number
}

// get_ui_asset_catalog() envelope (0142): dark → { ok:true, assets:[] }; transport error → { ok:false }.
// A DISCRIMINATED union (the eventsTypes.ts idiom), NOT a flat { ok:boolean; assets? } — so the shared
// isServerLit() guard narrows to the { ok:true } member cleanly (a flat shape would Extract to `never`).
export type GetUiAssetCatalogResult =
  | { ok: true; assets?: UiAsset[] }
  | { ok: false }
