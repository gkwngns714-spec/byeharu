import { supabase } from '../../lib/supabase'
import type { GetUiAssetCatalogResult, UiAssetKind } from './assetsTypes'

// PHASE20-POLISH — typed client API for the dark UI asset-key catalog read surface
// (get_ui_asset_catalog, 0142). Mirrors explorationApi.ts / eventsApi.ts conventions: a thin
// supabase.rpc wrapper; on a transport/DB error resolve to a normalized fail-closed value ({ ok:false })
// — never throw a raw error into the render path. DARK: while phase20_polish_enabled is false the server
// returns { ok:true, assets:[] } (empty catalog) — visibility is server-driven, no client flag constant.

/**
 * Read the active UI asset-key vocabulary, optionally filtered by kind (null = all kinds). Consumers
 * pass the kind they render (this slice: 'icon'); the server empties the catalog while dark.
 */
export async function getUiAssetCatalog(
  assetKind: UiAssetKind | null = null,
): Promise<GetUiAssetCatalogResult> {
  const { data, error } = await supabase.rpc('get_ui_asset_catalog', {
    p_asset_kind: assetKind,
  })
  if (error) return { ok: false }
  return data as GetUiAssetCatalogResult
}
