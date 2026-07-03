-- Byeharu — MINING-P12 SLICE E: the dark read surface — get_my_mining_extractions()
-- (reveal-after-extraction). Read-only; no write anywhere; dark-gated like every mining surface.
-- Mirrors the exploration read surface 0101 exactly.
--
-- (1) THE CLIENT NEVER READS mining_fields DIRECTLY. Reveal-after-extraction goes through this ONE
--     server read RPC: it joins the caller's OWN mining_extractions rows to the hidden field rows
--     and returns ONLY fields the player has extracted from. The 0103 no-client-policy posture on
--     mining_fields is untouched — an un-extracted field's existence/name/coordinates/composition
--     remain unreadable by construction (the join can only reach a field through one of the
--     caller's own extraction rows; no browse-all surface). Same spirit as
--     get_my_exploration_discoveries (0101): expose already-authoritative player-owned truth,
--     derive everything server-side, accept no trustable client identifiers.
-- (2) DARK-GATED FIRST (0097 reject-before-any-read law), copying the 0087/0101 read idiom
--     exactly: auth check, then the flag reject BEFORE any extraction/field read, returning the
--     same {ok:false, reason:'mining_disabled'} envelope regardless of caller state — nothing
--     about the caller's ships/extractions can be probed while dark.
-- (3) Extraction is REPEATABLE (0103/0104), so the history legitimately contains multiple rows per
--     field — each extraction is its own row, exactly as the ledger stores it. Extracted-then-
--     disabled fields stay visible (the 0101 posture: the extraction legitimately happened and is
--     the player's own history).
--
-- Returned bundle field = the extraction row's pending_bundle_json snapshot (0104); secured_at
-- NULL = still pending, non-null = deposited by process_mining_securing (0105). The field's own
-- reward_bundle_json is never exposed directly — only the per-row snapshot, mirroring 0101.

create or replace function public.get_my_mining_extractions()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_player      uuid := auth.uid();
  v_extractions jsonb;
  c_empty       constant jsonb := '[]'::jsonb;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK server-reject FIRST (0097 law; 0087/0101 read idiom): before any extraction/field read,
  -- and the identical envelope regardless of the caller's ships/extractions — no probing while dark.
  if not public.cfg_bool('mining_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'mining_disabled');
  end if;

  -- read-only: ONLY the caller's own extractions, joined to the hidden field rows — a field is
  -- reachable exclusively through one of the caller's own extraction rows (reveal-after-
  -- extraction). Writes nothing.
  select coalesce(jsonb_agg(jsonb_build_object(
           'extraction_id', e.id,
           'field_name',    f.name,
           'space_x',       f.space_x,
           'space_y',       f.space_y,
           'extracted_at',  e.created_at,
           'secured_at',    e.secured_at,
           'bundle',        e.pending_bundle_json) order by e.created_at desc),
         c_empty)
    into v_extractions
    from public.mining_extractions e
    join public.mining_fields f on f.id = e.field_id
    where e.player_id = v_player;

  return jsonb_build_object('ok', true, 'extractions', coalesce(v_extractions, c_empty));
end;
$$;

-- ACL (0087/0101 idiom): revoke the default PUBLIC grant, then authenticated only. Dark today: the
-- gate above rejects every call while mining_enabled = 'false'.
revoke execute on function public.get_my_mining_extractions() from public, anon;
grant  execute on function public.get_my_mining_extractions() to authenticated;
