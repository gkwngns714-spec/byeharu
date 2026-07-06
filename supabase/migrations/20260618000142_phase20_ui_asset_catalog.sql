-- Byeharu — PHASE20-POLISH SLICE 4: the UI asset-key vocabulary — ui_asset_catalog (static reference
-- table + seed) + its flag-gated fail-closed read surface get_ui_asset_catalog(...). The
-- server-authoritative asset-key vocabulary the Phase-20 frontend polish renders. NO runtime writer;
-- read-only client path; uniformly DARK behind phase20_polish_enabled. NO flag flipped true.
--
-- Mirrors the static seeded reference-catalog idiom (0073 trade_goods / 0042 support_craft_types) for
-- the table+seed shape, and the 0141 World Events read surface for the flag-gate-first `{ok, …:[...]}`
-- read envelope — the SAME conventions, no new one invented. Deviates ONLY in read posture: this table
-- is SERVER-ONLY (no client policy, client-revoked — the world_events/mining_fields posture), so the
-- ONLY client path is the flag-gated read RPC below (uniform dark Phase-20 surface), NOT a public-read
-- policy like trade_goods.
--
-- SELF-APPROVED LOCKED DESIGN DECISION (owner-directed, STEP 4; recorded in docs/DEV_LOG.md +
-- docs/SYSTEM_BOUNDARIES.md this SAME step):
--   1. ONE TABLE, discriminated by `asset_kind ('portrait'|'icon')` — NOT two near-identical parallel
--      tables. Portraits and icons share the SAME shape (key → display metadata → asset ref), so a
--      single leaf catalog avoids a duplicated parallel system (DRY / no-spaghetti). A future third
--      kind is an additive forward-only CHECK change here, not a new table.
--   2. SERVER-OWNED VOCABULARY, FRONTEND-OWNED FILES. Server rows reference a STABLE, server-known
--      asset KEY (e.g. world_events.severity → an icon key; a future captain → a portrait key); the
--      actual image FILES + the key→file resolution live in the FRONTEND. This table owns ONLY the
--      key→metadata vocabulary (`asset_ref` = the stable identifier the client resolves to a bundled
--      file), never binary assets.
--   3. PURE STATIC LEAF. Reference/Config, SEED-ONLY: edited ONLY by forward-only seed migrations,
--      NEVER at runtime — so it has NO sole-writer function and adds NO second writer anywhere. It
--      references nothing (no FK out), and is exposed only through the flag-gated fail-closed read RPC,
--      so the ENTIRE Phase-20 surface stays uniformly dark.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): §1 gains `ui_asset_catalog` under
-- **Reference/Config** (admin/migration; seed-migration only, NO runtime writer; server-only read);
-- §2 gains a **UI Assets** read-leaf exposing `get_ui_asset_catalog` (flag-gated → empty while dark,
-- authenticated-only, reads ONLY its own table + the master flag, references nothing → pure downward
-- leaf, no new call-edge). Leaves `0001–0141` unedited; forward-only.

-- ── (a) ui_asset_catalog — static asset-key vocabulary (Reference/Config; server-only) ─────────────
create table public.ui_asset_catalog (
  asset_kind   text not null check (asset_kind in ('portrait', 'icon')),
  -- the stable vocabulary key server rows reference (e.g. world_events.severity 'critical' → an icon
  -- key). PK is the (kind, key) pair — the same key may exist for a different kind.
  asset_key    text not null,
  display_name text not null,
  -- the stable frontend asset IDENTIFIER the client resolves to a bundled image file. THE IMAGE FILES
  -- LIVE IN THE FRONTEND — this table owns only the key→metadata vocabulary, never binary assets.
  asset_ref    text not null,
  category     text,
  sort_order   integer not null default 0,
  -- lets a vocabulary entry be retired without deleting the row (no destructive cleanup); future
  -- readers must treat is_active=false as absent.
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  primary key (asset_kind, asset_key)
);

-- Server-only static Reference/Config (the 0103 mining_fields / 0139 world_events posture): RLS
-- enabled with NO client policy and NO grant → no client read, no client write. There is NO runtime
-- writer — this catalog is edited ONLY by forward-only seed migrations (like the static Map), so it
-- has no sole-writer function and adds no second writer anywhere. The ONLY client path is the
-- flag-gated read RPC below.
alter table public.ui_asset_catalog enable row level security;
revoke all on public.ui_asset_catalog from public, anon, authenticated;

comment on table public.ui_asset_catalog is
  'PHASE20-POLISH (0142): server-authoritative UI asset-key VOCABULARY (portraits + icons in ONE table, '
  'discriminated by asset_kind). Static Reference/Config — SEED-ONLY, NO runtime writer (edited only by '
  'forward-only seed migrations, like the static Map); no sole-writer function, no second writer '
  'anywhere. Server rows reference a stable asset_key; the actual image FILES + key→file resolution live '
  'in the FRONTEND (asset_ref = the stable identifier the client resolves to a bundled file — never '
  'binary data here). SERVER-ONLY: RLS with no client policy/grant; the only client path is the '
  'flag-gated get_ui_asset_catalog. References nothing → a pure downward leaf. DARK behind '
  'phase20_polish_enabled.';
comment on column public.ui_asset_catalog.asset_ref is
  'PHASE20-POLISH (0142): the stable frontend asset identifier the client resolves to a bundled image '
  'file. The image files live in the frontend; this table owns only the key→metadata vocabulary.';

-- ── (b) seed the starter vocabulary (minimal — enough to prove the vocabulary, no bloat) ───────────
-- icons: the three that pair with world_events.severity (info/warning/critical) + a couple of generic
-- activity/event icons. portraits: a small generic set (default captain, a pirate/faction portrait).
-- asset_ref values are stable frontend identifiers, NOT file paths (the frontend owns resolution).
insert into public.ui_asset_catalog
  (asset_kind, asset_key, display_name, asset_ref, category, sort_order) values
  ('icon',     'severity_info',      'Info',              'icon.severity.info',      'severity', 10),
  ('icon',     'severity_warning',   'Warning',           'icon.severity.warning',   'severity', 20),
  ('icon',     'severity_critical',  'Critical',          'icon.severity.critical',  'severity', 30),
  ('icon',     'event_notice',       'Notice',            'icon.event.notice',       'event',    40),
  ('icon',     'event_world_state',  'World State',       'icon.event.world_state',  'event',    50),
  ('portrait', 'captain_default',    'Default Captain',   'portrait.captain.default','captain',  10),
  ('portrait', 'captain_veteran',    'Veteran Captain',   'portrait.captain.veteran','captain',  20),
  ('portrait', 'faction_pirate',     'Pirate',            'portrait.faction.pirate', 'faction',  30)
on conflict (asset_kind, asset_key) do nothing;

-- ── (c) get_ui_asset_catalog — flag-gated fail-closed read surface (the 0141 envelope) ─────────────
create or replace function public.get_ui_asset_catalog(
  p_asset_kind text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_assets jsonb;
  c_empty  constant jsonb := '[]'::jsonb;
begin
  -- DARK server fail-closed FIRST (0097 reject-before-any-read law; 0141 idiom): while
  -- phase20_polish_enabled is false, return an EMPTY result BEFORE any table read — the uniform Phase-20
  -- dark posture; the frontend renders nothing while dark.
  if not coalesce(public.cfg_bool('phase20_polish_enabled'), false) then
    return jsonb_build_object('ok', true, 'assets', c_empty);
  end if;

  -- read-only: active vocabulary rows, optionally filtered by kind (NULL = all kinds). Deterministic
  -- order (asset_kind, sort_order, asset_key). Writes nothing.
  select coalesce(jsonb_agg(jsonb_build_object(
           'asset_kind',   a.asset_kind,
           'asset_key',    a.asset_key,
           'display_name', a.display_name,
           'asset_ref',    a.asset_ref,
           'category',     a.category,
           'sort_order',   a.sort_order)
           order by a.asset_kind, a.sort_order, a.asset_key),
         c_empty)
    into v_assets
    from public.ui_asset_catalog a
    where a.is_active
      and (p_asset_kind is null or a.asset_kind = p_asset_kind);

  return jsonb_build_object('ok', true, 'assets', coalesce(v_assets, c_empty));
end;
$$;

-- ACL (0141/0087 idiom): revoke the default PUBLIC grant + anon, then authenticated only — the
-- map/dashboard are behind auth. NO write path is exposed (read RPC). Dark today: the gate above
-- returns an empty list for every call while phase20_polish_enabled = 'false'.
revoke execute on function public.get_ui_asset_catalog(text) from public, anon;
grant  execute on function public.get_ui_asset_catalog(text) to authenticated;
