-- Byeharu — ROOMS-8: CONFIGURABLE SHIP ROOMS (owner order: "each ship will have 8 captain slots,
-- and the captains will be inserted accordingly"; "create many rooms as possible"; "we can also
-- change room by modifying the ships … able to choose"). This EXTENDS the 0189 decks system — it
-- does NOT fork a parallel one. Three deltas, all additive/monotonic, all DEPLOY-INERT behind the
-- SAME dark captain gate:
--
--   (1) CAPTAIN SLOTS 6 → 8 — the planned C2-4 raise (the 0171 bump idiom verbatim): every hull's
--       base_captain_slots → 8 + the existing-instance captain_slots backfill, both `<`-guarded so
--       monotonic + idempotent. Player-visible-cosmetic on deploy ("Captain seats 6 → 8", the 0171
--       accepted posture: while assignment is dark no seat can be occupied, so the count is
--       decoration). IRREVERSIBILITY LAW (0171): once captains occupy seats the count must NEVER be
--       lowered — the 0122 adapter refuses over-capacity. Roll back FLAGS, never slots.
--
--   (2) A LARGE ROOM CATALOG — `ship_stations` (0189) IS the room catalog (id/name/sort/affinity/
--       description — the shape fits a "room type" exactly), so this ADDS eight new rooms to it
--       (on-conflict-do-nothing — the 0189/0117 additive-seed posture; the frozen six keep their
--       ids/sorts/affinities so the DECKS-3 affinity mapping and every prior proof stay verbatim).
--       Extensible: more rooms are one additive seed away, never a schema change, never a re-roll.
--       affinity_specialization stays in the 0117 vocabulary (combat/trade/exploration/mining/
--       support) or NULL — the SAME column the 0196 adapter folds, so the new rooms carry affinity
--       for free the moment the knob lights.
--
--   (3) EIGHT CONFIGURABLE ROOM-SLOTS PER SHIP — the genuinely new capability. `ship_room_slots`
--       (main_ship_id, slot_index 1..8, room_type_id → ship_stations) is the ship's FITTED rooms:
--       the player chooses which room type occupies each of the 8 slots (like fitting a module).
--       Distinct rooms per ship (unique (main_ship_id, room_type_id)) so a slot's room IS a unique
--       placement key — which is exactly what `ship_captain_assignments.station` already is (the
--       0189 partial unique (main_ship_id, station)). A ship's 8 slots default to the 8 lowest-sort
--       rooms (deterministic — the 0041 law); an AFTER-INSERT trigger seeds them for every new ship
--       (covers ALL commission paths WITHOUT re-creating one of them — the minimal-spaghetti seam)
--       and a monotonic backfill seeds every existing ship. The sole writer of a slot's room is the
--       new ship_room_configure (client wrapper configure_ship_room); the read is
--       get_my_ship_room_slots — both behind the dark captain gate.
--
-- ── THE ADAPTER IS NOT RE-CREATED (the load-bearing constraint) ──────────────────────────────────
-- calculate_expedition_stats (head 0196/DECKS-3) folds a captain's affinity via
-- `left join ship_stations st on st.station_id = a.station` reading st.affinity_specialization.
-- ROOMS-8 keeps `ship_captain_assignments.station` = a ship_stations.station_id (now called a "room
-- type") — so that LEFT join and its read-shape are BYTE-UNTOUCHED. The ONLY writer change is WHERE
-- the valid station/room set comes from: captain_assign_apply resolves against the ship's CONFIGURED
-- slots (ship_room_slots) instead of the whole catalog — a marked hunk inside the 0189 writer, its
-- signature unchanged. calculate_expedition_stats is NOT in this migration (grep it) — a parallel
-- COMMAND-BUFFS slice owns the next adapter re-create; two in flight = the 0143/0146 collision.
--
-- ── DEPLOY-INERT WHILE DARK (captain_assignment_enabled='false', 0117 — unflipped) ────────────────
-- Rooms ARE the decks/captain system, so they ride the EXISTING captain gate — NO new flag. Every
-- new command (configure_ship_room) + read (get_my_ship_room_slots) rejects
-- captain_assignment_disabled before any row read (anti-probe, the 0189 posture). The slot bump +
-- catalog seeds + slot rows are additive/monotonic data no live path reads while dark
-- (calculate_expedition_stats reads station→affinity, unaffected by slot rows; auto-assign reads
-- slots only when a captain is assigned, and none can be while dark). The 0203 backfill touches
-- zero rows on a captain-dark prod for assignments, and seeds slots for existing ships (pure
-- additive rows). Safe in either posture.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this step): ship_stations stays Reference/Config
-- (migration-seeded, no runtime writer — this migration only ADDS seeds). ship_room_slots is a NEW
-- Captain-family owned table: seeded by the trigger/backfill, mutated ONLY by ship_room_configure
-- (one writer). The station column stays under captain_assign_apply's sole write. No cycle; no flag
-- flipped.
--
-- Forward-only: 0001–0202 unedited.

-- ── 1) CAPTAIN SLOTS 6 → 8 — the 0171 pinned-bump idiom (idempotent + monotonic, `<`-guarded) ─────
update public.main_ship_hull_types
   set base_captain_slots = 8 where base_captain_slots < 8;
update public.main_ship_instances i
   set captain_slots = h.base_captain_slots, updated_at = now()
  from public.main_ship_hull_types h
 where i.hull_type_id = h.hull_type_id and i.captain_slots < h.base_captain_slots;

-- ── 2) ROOM CATALOG — eight new rooms appended to ship_stations (additive; the frozen six untouched)
-- Sorts 7..14 keep the frozen 1..6 at the top (so the default-8 slots = the six + Command Deck +
-- Armory, and the DECKS-3 affinity mapping on the six is verbatim). Each affinity is the 0117
-- vocabulary or NULL. on-conflict-do-nothing: additive, re-runnable, never touches rolled data.
insert into public.ship_stations (station_id, name, sort, affinity_specialization, description) values
  ('command_deck', 'Command Deck', 7, null,
   'The flag officer''s station — fleet orders, standing doctrine, the whole ship''s intent in one chair.'),
  ('armory',       'Armory',       8, 'combat',
   'Racked munitions and boarding kit. The quartermaster of violence keeps a tidy ledger.'),
  ('cargo_hold',   'Cargo Hold',   9, 'trade',
   'The working belly of the ship — manifests, lashings, and the smell of a hundred ports.'),
  ('workshop',     'Workshop',    10, 'support',
   'Fabrication benches and spare-part bins. What breaks in the black gets reborn here.'),
  ('comms',        'Comms Array', 11, 'exploration',
   'Encrypted traffic and the long silences between stars. Whoever listens here hears the frontier first.'),
  ('outpost',      'Outpost Control', 12, 'trade',
   'Coordinates forward berths and supply caches — the ship as a moving waystation.'),
  ('sickbay',      'Sickbay',     13, 'support',
   'The overflow ward beside Medbay. When the casualty list runs long, the doors here open too.'),
  ('observatory',  'Observatory', 14, 'exploration',
   'Charts, driftglass lenses, and the patient work of naming what no one has named.')
on conflict (station_id) do nothing;

comment on table public.ship_stations is
  'ROOMS-8 (0203): the ship ROOM catalog (was the 0189 six-station catalog; Reference/Config — '
  'migration-seeded, no runtime writer, public read-only). id/name/sort/affinity_specialization/'
  'description. sort is the deterministic default-slot + display order. affinity_specialization '
  '(0117 vocabulary or NULL) is the column the 0196 adapter folds. Extensible: more rooms are one '
  'additive on-conflict-do-nothing seed, never a schema change.';

-- ── 3) ship_room_slots — the ship's EIGHT configurable room-slots (Captain-family; owner-read) ────
create table public.ship_room_slots (
  main_ship_id uuid        not null references public.main_ship_instances (main_ship_id) on delete cascade,
  slot_index   integer     not null check (slot_index between 1 and 8),
  room_type_id text        not null references public.ship_stations (station_id),
  updated_at   timestamptz not null default now(),
  primary key (main_ship_id, slot_index),
  -- distinct rooms per ship: a slot's room is a UNIQUE placement key, exactly like the 0189
  -- (main_ship_id, station) partial unique the captain assignment carries — so "one captain per
  -- room" is the SAME invariant as the pre-0203 "one captain per station".
  constraint ship_room_slots_distinct_room unique (main_ship_id, room_type_id)
);

alter table public.ship_room_slots enable row level security;
-- Owner-read only (via the ship's owner); NO client write policy/grant → only the security-definer
-- writer (ship_room_configure) + migration/trigger mutate. The 0189 catalog-vs-writer posture.
create policy "ship_room_slots_owner_read" on public.ship_room_slots for select using (
  exists (select 1 from public.main_ship_instances i
            where i.main_ship_id = ship_room_slots.main_ship_id and i.player_id = auth.uid())
);
grant select on public.ship_room_slots to authenticated;

comment on table public.ship_room_slots is
  'ROOMS-8 (0203): a ship''s EIGHT configurable room-slots (slot_index 1..8 → a ship_stations room '
  'type; distinct rooms per ship). The player CHOOSES each slot''s room (configure_ship_room). '
  'Seeded to the 8 lowest-sort rooms by the AFTER-INSERT trigger (new ships) + the §5 backfill '
  '(existing ships). Captains staff a slot''s room via ship_captain_assignments.station = '
  'room_type_id (so the 0196 adapter reads affinity unchanged). Owner-read; sole writer '
  'ship_room_configure.';

-- ── 4) the default-slot seed: the 8 lowest-sort rooms, deterministically (the 0041 law) ───────────
-- ONE reusable shape (the trigger + the §5 backfill both use this exact "8 lowest by sort" walk).
-- 8 = captain_slots (all hulls at 8 after §1); a hull with fewer seats still gets 8 rooms — the
-- headcount cap stays the capacity authority, extra rooms simply sit empty (never over-fill).
create or replace function public.ship_room_slots_seed_defaults()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.ship_room_slots (main_ship_id, slot_index, room_type_id)
    select NEW.main_ship_id, d.rn, d.station_id
      from (select station_id, row_number() over (order by sort) as rn
              from public.ship_stations order by sort limit 8) d
  on conflict (main_ship_id, slot_index) do nothing;
  return NEW;
end $$;

comment on function public.ship_room_slots_seed_defaults() is
  'ROOMS-8 (0203): AFTER-INSERT-on-main_ship_instances seed of the 8 default room-slots (the 8 '
  'lowest-sort rooms, deterministic). on-conflict-do-nothing = idempotent. Covers every commission '
  'path without re-creating one — the minimal-spaghetti seam.';

create trigger trg_ship_room_slots_seed
  after insert on public.main_ship_instances
  for each row execute function public.ship_room_slots_seed_defaults();

-- ── 5) BACKFILL existing ships with the 8 default slots (monotonic — only fills missing) ──────────
-- Deterministic (rooms by sort; slot_index = the rank). MONOTONIC: on-conflict-do-nothing never
-- moves an already-configured slot. Zero-or-more ships; on a fresh chain every ship gets its 8.
insert into public.ship_room_slots (main_ship_id, slot_index, room_type_id)
  select i.main_ship_id, d.rn, d.station_id
    from public.main_ship_instances i
    cross join (select station_id, row_number() over (order by sort) as rn
                  from public.ship_stations order by sort limit 8) d
on conflict (main_ship_id, slot_index) do nothing;

-- ── 6) captain_assign_apply — the 0189 head (its TRUE head — grep-verified: 0119 create → 0189
--       re-create, nothing after 0189 re-creates it) re-created with the marked -- ROOMS-8 hunks
--       ONLY. PARITY DISCIPLINE: body byte-identical to 0189 EXCEPT the two marked resolution hunks
--       (explicit-room existence now scopes to THIS ship's configured slots; auto-assign walks the
--       ship's slots by sort). Signature unchanged (uuid,uuid,uuid,text) → create-or-replace (no
--       drop; grants survive, re-asserted below). The station column, the (main_ship_id, station)
--       insert, the headcount cap, and every 0189 reject/order are UNTOUCHED — so the 0196 adapter
--       read-shape is preserved and the DECKS proof's dark/replay/unassign properties hold. ────────
create or replace function public.captain_assign_apply(
  p_player_id           uuid,
  p_captain_instance_id uuid,
  p_main_ship_id        uuid,  -- NOT NULL = ASSIGN to this ship · NULL = UNASSIGN
  p_station             text default null  -- DECKS-1: assign only — explicit station, or NULL =
                                           -- auto-assign the lowest-sort FREE station; ignored on
                                           -- unassign (the row delete frees whatever it held)
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_captain     captain_instances%rowtype;
  v_ship_owner  uuid;
  v_slots_limit integer;
  v_used        integer;
  v_current     uuid;
  v_prev_ship   uuid;
  v_station     text;  -- DECKS-1: the resolved station for the insert
begin
  -- 1) per-player serialization FIRST (the exact 0112:99–103 idiom, captain domain): ALL of a
  --    player's assignment mutations queue here, so the headcount below cannot be raced by
  --    another assign/unassign of the same player (and every assignment on a ship belongs to the
  --    ship's owner, so per-player IS per-ship-assignment-set).
  perform pg_advisory_xact_lock(hashtext('captain_assignment'), hashtext(p_player_id::text));

  -- 2) the captain instance must exist AND belong to p_player_id (intra-system read). One reason
  --    for both cases — another player's instance answers exactly like a nonexistent one.
  select * into v_captain from captain_instances
    where id = p_captain_instance_id and player_id = p_player_id;
  if not found then
    raise exception 'captain_assign_apply: captain_not_owned — captain instance % not found for player %',
      p_captain_instance_id, p_player_id;
  end if;

  -- ── UNASSIGN (p_main_ship_id NULL): delete the captain's assignment row ─────────────────────────
  if p_main_ship_id is null then
    delete from ship_captain_assignments
      where captain_instance_id = p_captain_instance_id
      returning main_ship_id into v_prev_ship;
    if v_prev_ship is null then
      -- distinct truthful reason; idempotency ENVELOPES are the future command slice's job
      -- (receipt replay), not this writer's — a bare re-unassign is a real not_assigned here.
      raise exception 'captain_assign_apply: not_assigned — captain instance % has no assignment',
        p_captain_instance_id;
    end if;
    return;
  end if;

  -- ── ASSIGN (p_main_ship_id NOT NULL) ────────────────────────────────────────────────────────────
  -- 3) the target ship is read by the (main_ship_id, player_id) PAIR — never "the player's ship"
  --    singular (the player_id UNIQUE was dropped in 0079; the 0115:96–101 shape). Also fixes
  --    owner-consistency: row.player_id = captain owner = ship owner (0115:47–50).
  select player_id, captain_slots into v_ship_owner, v_slots_limit
    from main_ship_instances where main_ship_id = p_main_ship_id;
  if v_ship_owner is null or v_ship_owner <> p_player_id then
    raise exception 'captain_assign_apply: ship_not_owned — ship % not found for player %',
      p_main_ship_id, p_player_id;
  end if;

  -- 4) one-ship-per-captain: an already-assigned captain is REJECTED naming its current ship —
  --    never silently re-homed (an explicit unassign must come first). The PK backstops this
  --    check.
  select main_ship_id into v_current from ship_captain_assignments
    where captain_instance_id = p_captain_instance_id;
  if v_current is not null then
    raise exception 'captain_assign_apply: already_assigned — captain instance % is assigned to ship %',
      p_captain_instance_id, v_current;
  end if;

  -- 5) HEADCOUNT HARD CAP (the captain analogue of the Σ slot_cost ≤ module_slots gate,
  --    0112:144–156 / 0044:112–115 — reject, NEVER clamp): count, not a slot_cost sum, because
  --    one captain occupies exactly one slot (slice-A locked decision; captain_slots is a
  --    headcount). Race-free under the step-1 player lock (see header (4)).
  select count(*) into v_used from ship_captain_assignments
    where main_ship_id = p_main_ship_id;
  if v_used >= v_slots_limit then
    raise exception 'captain_assign_apply: captain_slots_full — ship % has % of % captain slots occupied',
      p_main_ship_id, v_used, v_slots_limit;
  end if;

  -- 5b) DECKS-1 — STATION RESOLUTION (appended AFTER every pre-existing reject, so old callers
  --     keep their exact reject order; capacity above stays the ONE authority — this step is
  --     placement only). Race-free under the step-1 player lock (owner-consistency makes
  --     per-player per-ship, exactly like the headcount read); the partial unique index
  --     backstops. Deterministic: no randomness, lowest sort wins (the 0041 law).
  --     ROOMS-8 (0203): the valid set is now THIS ship's CONFIGURED room-slots (ship_room_slots),
  --     not the whole catalog — a captain can only staff a room the ship has FITTED. The resolved
  --     value is still a ship_stations.station_id written into .station, so the 0196 adapter read
  --     is byte-unchanged.
  if p_station is not null then
    -- explicit room: must be one of THIS ship's configured slots…  -- ROOMS-8 (0203): was `ship_stations` catalog-wide
    if not exists (select 1 from ship_room_slots
                     where main_ship_id = p_main_ship_id and room_type_id = p_station) then
      raise exception 'captain_assign_apply: unknown_station — station % is not a fitted room on ship %',  -- ROOMS-8 (0203)
        p_station, p_main_ship_id;
    end if;
    -- …and be free on THIS ship.
    if exists (select 1 from ship_captain_assignments
                 where main_ship_id = p_main_ship_id and station = p_station) then
      raise exception 'captain_assign_apply: station_occupied — station % on ship % is already held',
        p_station, p_main_ship_id;
    end if;
    v_station := p_station;
  else
    -- auto-assign: the lowest-sort FREE room among THIS ship's configured slots. With
    -- captain_slots = 8 = the slot count the headcount cap (step 5) fires first, so exhaustion is
    -- UNREACHABLE today — but it is handled honestly, never silently (a NULL insert would invent a
    -- ninth place). ROOMS-8 (0203): walk ship_room_slots (joined to ship_stations for the sort),
    -- not the whole catalog.
    select slot.room_type_id into v_station  -- ROOMS-8 (0203)
      from ship_room_slots slot
      join ship_stations s on s.station_id = slot.room_type_id
      where slot.main_ship_id = p_main_ship_id
        and not exists (select 1 from ship_captain_assignments a
                          where a.main_ship_id = p_main_ship_id and a.station = slot.room_type_id)
      order by s.sort
      limit 1;
    if v_station is null then
      raise exception 'captain_assign_apply: no_free_station — ship % has every room occupied',  -- ROOMS-8 (0203)
        p_main_ship_id;
    end if;
  end if;

  -- 6) the ONE mutation. Plain insert: the PK cannot conflict here — step 4 ran under the step-1
  --    lock, and only the owner (serialized above) can reference this captain.
  insert into ship_captain_assignments (captain_instance_id, main_ship_id, player_id, station)  -- DECKS-1: + station
    values (p_captain_instance_id, p_main_ship_id, p_player_id, v_station);
end;
$$;

-- ACL re-asserted on the (unchanged) identity (create-or-replace preserves grants — re-emitted for
-- an explicit posture, the 0092/0179 idiom): the ONE writer stays OFF the client surface.
revoke execute on function public.captain_assign_apply(uuid, uuid, uuid, text) from public, anon, authenticated;
grant  execute on function public.captain_assign_apply(uuid, uuid, uuid, text) to service_role;

-- ── 7) ship_room_configure — the SOLE writer of a slot's room type (exception-style, the 0119
--       captain_assign_apply posture: reject, never clamp; the command wrapper composes the
--       envelope) ──────────────────────────────────────────────────────────────────────────────────
create or replace function public.ship_room_configure(
  p_player       uuid,
  p_main_ship_id uuid,
  p_slot_index   integer,
  p_room_type_id text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner   uuid;
  v_current text;
begin
  -- per-player serialization (the SAME 'captain_assignment' key the assignment writer takes — one
  -- player's room + captain mutations queue on one lock, so a reconfigure cannot race an assign).
  perform pg_advisory_xact_lock(hashtext('captain_assignment'), hashtext(p_player::text));

  -- 1) the ship must exist AND belong to p_player.
  select player_id into v_owner from main_ship_instances where main_ship_id = p_main_ship_id;
  if v_owner is null or v_owner <> p_player then
    raise exception 'ship_room_configure: ship_not_owned — ship % not found for player %', p_main_ship_id, p_player;
  end if;

  -- 2) the slot must be a real 1..8 slot on this ship (the trigger/backfill guarantees all 8 exist).
  if p_slot_index is null or p_slot_index < 1 or p_slot_index > 8 then
    raise exception 'ship_room_configure: invalid_slot — slot % is out of the 1..8 range', p_slot_index;
  end if;
  select room_type_id into v_current from ship_room_slots
    where main_ship_id = p_main_ship_id and slot_index = p_slot_index;
  if v_current is null then
    raise exception 'ship_room_configure: unknown_slot — ship % has no slot %', p_main_ship_id, p_slot_index;
  end if;

  -- 3) the chosen room must exist in the catalog.
  if not exists (select 1 from ship_stations where station_id = p_room_type_id) then
    raise exception 'ship_room_configure: unknown_room — room % is not in the ship_stations catalog', p_room_type_id;
  end if;

  -- 4) no-op if the slot already holds this room (idempotent; skips the occupied/dup checks so a
  --    replayed configure of the current room always succeeds).
  if v_current = p_room_type_id then
    return;
  end if;

  -- 5) the room must not already occupy ANOTHER slot on this ship (distinct rooms; the unique index
  --    backstops — this is the honest pre-read reason instead of a raw constraint error).
  if exists (select 1 from ship_room_slots
               where main_ship_id = p_main_ship_id and room_type_id = p_room_type_id) then
    raise exception 'ship_room_configure: room_duplicate — room % already fills a slot on ship %', p_room_type_id, p_main_ship_id;
  end if;

  -- 6) a captain currently STAFFING this slot's current room blocks the refit (changing the room
  --    would orphan that captain's station) — the player must unassign first. Deterministic reject.
  if exists (select 1 from ship_captain_assignments
               where main_ship_id = p_main_ship_id and station = v_current) then
    raise exception 'ship_room_configure: room_occupied — a captain still holds room % on ship %; unassign first', v_current, p_main_ship_id;
  end if;

  -- 7) the ONE mutation.
  update ship_room_slots set room_type_id = p_room_type_id, updated_at = now()
    where main_ship_id = p_main_ship_id and slot_index = p_slot_index;
end $$;

revoke execute on function public.ship_room_configure(uuid, uuid, integer, text) from public, anon, authenticated;
grant  execute on function public.ship_room_configure(uuid, uuid, integer, text) to service_role;

-- ── 8) configure_ship_room — the client wrapper (auth + dark gate FIRST + settled-safe, then
--       delegate; the 0189 assign_captain_to_ship envelope idiom, receipt-free because a room
--       config is naturally idempotent — setting a slot to its current room is a no-op success) ────
create or replace function public.configure_ship_room(
  p_main_ship_id uuid,
  p_slot_index   integer,
  p_room_type_id text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_owned  uuid;
  v_reason text;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated', 'message', 'You must be signed in.');
  end if;
  -- DARK GATE FIRST (anti-probe, the 0189 wrapper posture): while dark the answer is the identical
  -- locked envelope REGARDLESS of input — no ship read, no slot existence oracle.
  if not public.cfg_bool('captain_assignment_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'captain_assignment_disabled');
  end if;
  -- settled-safe (owner-scoped read: only the player's OWN ship can be probed) — a loadout is
  -- frozen mid-transit/combat, rooms included (the 0121 rule, mirrored). A non-owned ship falls
  -- through to the writer's ship_not_owned (the final authority).
  select main_ship_id into v_owned from main_ship_instances
    where main_ship_id = p_main_ship_id and player_id = v_player;
  if v_owned is not null and not public.mainship_space_assert_settled_safe(v_owned) then
    return jsonb_build_object('ok', false, 'reason', 'ship_not_settled',
      'message', 'The ship must be settled at home or docked to change its rooms.');
  end if;

  begin
    perform public.ship_room_configure(v_player, p_main_ship_id, p_slot_index, p_room_type_id);
  exception when others then
    v_reason := substring(sqlerrm from '^ship_room_configure: ([a-z_]+)');
    if v_reason in ('ship_not_owned','invalid_slot','unknown_slot','unknown_room','room_duplicate','room_occupied') then
      return jsonb_build_object('ok', false, 'reason', v_reason, 'message',
        case v_reason
          when 'ship_not_owned'  then 'That ship is not yours.'
          when 'invalid_slot'    then 'That room slot does not exist.'
          when 'unknown_slot'    then 'That room slot does not exist.'
          when 'unknown_room'    then 'That room type does not exist.'
          when 'room_duplicate'  then 'That room already fills another slot on this ship.'
          when 'room_occupied'   then 'A captain still staffs this room. Unassign them first.'
          else 'Room configuration is unavailable right now.'
        end);
    end if;
    raise;
  end;

  return jsonb_build_object('ok', true, 'main_ship_id', p_main_ship_id,
    'slot_index', p_slot_index, 'room_type_id', p_room_type_id);
end $$;

revoke execute on function public.configure_ship_room(uuid, integer, text) from public, anon;
grant  execute on function public.configure_ship_room(uuid, integer, text) to authenticated;

-- ── 9) get_my_ship_room_slots — the client read of ONE owned ship's 8 slots (dark-gated, owner-
--       scoped; the get_my_captain_instances read posture) ────────────────────────────────────────
create or replace function public.get_my_ship_room_slots(p_main_ship_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_owned  uuid;
  v_slots  jsonb;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;
  -- DARK server-reject FIRST (anti-probe): identical envelope regardless of the ship, no row read.
  if not public.cfg_bool('captain_assignment_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'captain_assignment_disabled');
  end if;
  select main_ship_id into v_owned from main_ship_instances
    where main_ship_id = p_main_ship_id and player_id = v_player;
  if v_owned is null then
    return jsonb_build_object('ok', false, 'reason', 'ship_not_owned');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'slot_index',              sl.slot_index,
           'room_type_id',            sl.room_type_id,
           'name',                    s.name,
           'affinity_specialization', s.affinity_specialization) order by sl.slot_index),
         '[]'::jsonb)
    into v_slots
    from public.ship_room_slots sl
    join public.ship_stations s on s.station_id = sl.room_type_id
   where sl.main_ship_id = p_main_ship_id;

  return jsonb_build_object('ok', true, 'slots', coalesce(v_slots, '[]'::jsonb));
end $$;

revoke execute on function public.get_my_ship_room_slots(uuid) from public, anon;
grant  execute on function public.get_my_ship_room_slots(uuid) to authenticated;

-- ── 10) SELF-ASSERTS — the migration proves its own grounding or refuses to land ─────────────────
do $$
declare
  n int;
  v_src text;
begin
  -- 1. the 6→8 bump: every hull at 8, no instance below its hull.
  select count(*) into n from public.main_ship_hull_types where base_captain_slots < 8;
  if n <> 0 then raise exception 'ROOMS-8 self-assert FAIL: % hull row(s) below base_captain_slots 8', n; end if;
  select count(*) into n from public.main_ship_instances i
    join public.main_ship_hull_types h on h.hull_type_id = i.hull_type_id
    where i.captain_slots < h.base_captain_slots;
  if n <> 0 then raise exception 'ROOMS-8 self-assert FAIL: % instance(s) below the hull captain_slots (backfill incomplete)', n; end if;

  -- 2. the catalog: the frozen six survive verbatim (id/sort/affinity) AND the eight new rooms
  --    landed — >= 14 rooms, the six unmoved.
  select count(*) into n from public.ship_stations;
  if n < 14 then raise exception 'ROOMS-8 self-assert FAIL: ship_stations has % rooms (want >= 14)', n; end if;
  select count(*) into n
    from (values ('bridge',1,null::text), ('gunnery',2,'combat'), ('engineering',3,'mining'),
                 ('logistics',4,'trade'), ('sensors',5,'exploration'), ('medbay',6,'support')) w(id, srt, aff)
    join public.ship_stations s
      on s.station_id = w.id and s.sort = w.srt and s.affinity_specialization is not distinct from w.aff;
  if n <> 6 then raise exception 'ROOMS-8 self-assert FAIL: the frozen six-station 0189/0196 mapping drifted (% of 6 verbatim)', n; end if;
  select count(*) into n from public.ship_stations
    where station_id in ('command_deck','armory','cargo_hold','workshop','comms','outpost','sickbay','observatory');
  if n <> 8 then raise exception 'ROOMS-8 self-assert FAIL: % of the 8 new rooms present (want 8)', n; end if;
  -- every affinity is the 0117 vocabulary or NULL (the adapter reads it — a bad value would poison a fold).
  select count(*) into n from public.ship_stations
    where affinity_specialization is not null
      and affinity_specialization not in ('combat','trade','exploration','mining','support');
  if n <> 0 then raise exception 'ROOMS-8 self-assert FAIL: % room(s) carry an off-vocabulary affinity', n; end if;

  -- 3. the slot model: the table + the two uniques, the trigger, and EVERY ship carries exactly 8
  --    distinct default slots (the trigger + backfill did their job).
  if to_regclass('public.ship_room_slots') is null then
    raise exception 'ROOMS-8 self-assert FAIL: ship_room_slots table missing'; end if;
  select count(*) into n from pg_constraint
    where conname = 'ship_room_slots_distinct_room' and contype = 'u';
  if n <> 1 then raise exception 'ROOMS-8 self-assert FAIL: the (main_ship_id, room_type_id) distinct-room unique is missing'; end if;
  select count(*) into n from pg_trigger where tgname = 'trg_ship_room_slots_seed' and not tgisinternal;
  if n <> 1 then raise exception 'ROOMS-8 self-assert FAIL: the default-slot seed trigger is missing'; end if;
  -- no ship is left with a wrong slot count (0 or 8 only — 0 is impossible after the backfill, but
  -- asserted honestly: a ship with 1..7 would mean the seed walk broke).
  select count(*) into n from (
    select i.main_ship_id, count(sl.slot_index) as c
      from public.main_ship_instances i
      left join public.ship_room_slots sl on sl.main_ship_id = i.main_ship_id
      group by i.main_ship_id) q
    where q.c <> 8;
  if n <> 0 then raise exception 'ROOMS-8 self-assert FAIL: % ship(s) not carrying exactly 8 room-slots', n; end if;

  -- 4. the writer prosrc: the ROOMS-8 hunks are present (slot-scoped resolution), the 0189 station
  --    insert survives, the headcount cap survives, no random().
  select prosrc into v_src from pg_proc where oid = 'public.captain_assign_apply(uuid, uuid, uuid, text)'::regprocedure;
  if v_src not like '%ROOMS-8 (0203)%' then
    raise exception 'ROOMS-8 self-assert FAIL: captain_assign_apply lacks the ROOMS-8 marked hunks'; end if;
  if v_src not like '%from ship_room_slots slot%' or v_src not like '%where main_ship_id = p_main_ship_id and room_type_id = p_station%' then
    raise exception 'ROOMS-8 self-assert FAIL: captain_assign_apply resolution is not slot-scoped (still catalog-wide?)'; end if;
  if v_src not like '%p_player_id, v_station);%' then
    raise exception 'ROOMS-8 self-assert FAIL: captain_assign_apply lost the 0189 station insert (parity breach)'; end if;
  if v_src not like '%captain_slots_full%' then
    raise exception 'ROOMS-8 self-assert FAIL: captain_assign_apply lost the headcount cap'; end if;
  if v_src like '%random(%' then
    raise exception 'ROOMS-8 self-assert FAIL: captain_assign_apply contains random()'; end if;

  -- 5. the ADAPTER IS UNTOUCHED — its 0196 read-shape (the LEFT station join) is intact and this
  --    migration did NOT re-create it (a coarse but honest pin: the join token still reads
  --    ship_captain_assignments.station → ship_stations, exactly what the fold needs).
  select prosrc into v_src from pg_proc where oid = 'public.calculate_expedition_stats(uuid, uuid, jsonb, text)'::regprocedure;
  if v_src not like '%left join ship_stations st on st.station_id = a.station%' then
    raise exception 'ROOMS-8 self-assert FAIL: the adapter station-affinity read-shape drifted (someone re-created it?)'; end if;

  -- 6. the new command surface ACLs: writer/internal service_role-only; client wrappers
  --    authenticated-only.
  if has_function_privilege('authenticated', 'public.ship_room_configure(uuid, uuid, integer, text)', 'execute')
     or has_function_privilege('anon', 'public.ship_room_configure(uuid, uuid, integer, text)', 'execute') then
    raise exception 'ROOMS-8 self-assert FAIL: ship_room_configure writer is client-executable'; end if;
  if not has_function_privilege('authenticated', 'public.configure_ship_room(uuid, integer, text)', 'execute')
     or has_function_privilege('anon', 'public.configure_ship_room(uuid, integer, text)', 'execute') then
    raise exception 'ROOMS-8 self-assert FAIL: configure_ship_room wrapper ACL wrong'; end if;
  if not has_function_privilege('authenticated', 'public.get_my_ship_room_slots(uuid)', 'execute')
     or has_function_privilege('anon', 'public.get_my_ship_room_slots(uuid)', 'execute') then
    raise exception 'ROOMS-8 self-assert FAIL: get_my_ship_room_slots read ACL wrong'; end if;

  raise notice 'ROOMS-8 self-asserts ok: hulls+instances at 8 captain slots; ship_stations >= 14 rooms (frozen six verbatim, 8 new, all affinities in-vocab); ship_room_slots + distinct-room unique + seed trigger, every ship at exactly 8 slots; captain_assign_apply slot-scoped with the 0189 insert/cap intact and no random(); the adapter read-shape untouched (not re-created); new command ACLs correct';
end $$;
