#!/usr/bin/env node
// gen-0333-items-live-at-ports.mjs — emit (or --check) migration 0333.
//
// WHY A GENERATOR: 0333 re-points the THREE Inventory leaves (0039) at PORT storage and therefore
// has to touch the SEVEN functions that compose them — reward_grant (0040), craft (0109), recruit
// (0126), salvage sell (0174), shipyard order (0188), shipyard refund (0194) and port shop buy
// (0235). Every one of those is LIVE plpgsql. The house law (0303, restated by 0330) is: never
// retype a live function body. So every `old_t` below is SLICED VERBATIM out of the migration that
// is that function's textual head, and every `new_t` is CONSTRUCTED FROM THAT SLICE by exactly-once
// string edits. Nothing in a deployed body is retyped by hand. The migration then proves each slice
// is still what is deployed (it must occur EXACTLY ONCE in pg_get_functiondef) before replacing it.
//
// The three commands that gain a ship parameter do NOT get their argument list retyped either: the
// migration reads it back from pg_get_function_identity_arguments at deploy time and appends.
//
//   node scripts/gen-0333-items-live-at-ports.mjs          # write the migration
//   node scripts/gen-0333-items-live-at-ports.mjs --check  # fail if the file on disk drifted

import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const MIGDIR = join(ROOT, 'supabase/migrations');
const MIG = (f) => join(MIGDIR, f);
const OUT = MIG('20260618000333_items_have_a_place.sql');
const SELF = '20260618000333';

// LINE ENDINGS ARE PART OF THE CONTRACT (the 0306 lesson): pg_get_functiondef text is LF; a Windows
// checkout hands this script CRLF. Normalise on read, refuse to emit a CR.
const load = (f) => readFileSync(MIG(f), 'utf8').replace(/\r\n/g, '\n').split('\n');

// ── HEAD CHECKS ──────────────────────────────────────────────────────────────────────────────────
// For each function this migration cuts a slice from, establish that the named source migration is
// still its TEXTUAL head: no later `create or replace function … <name>` anywhere, and no later
// hunk-surgery rewriter (the house `(idx, '<name>',` shape). A migration that merely NAMES the
// function in a comment or a read-only probe is not drift, so `--` comments are stripped first.
const HEADS = [
  ['reward_grant', '20260617000040'],
  ['production_craft_module', '20260618000109'],
  ['craft_module', '20260618000109'],
  ['production_recruit_captain', '20260618000126'],
  ['recruit_captain', '20260618000126'],
  ['sell_item_at_port', '20260618000174'],
  ['production_start_hull_build', '20260618000188'],
  ['start_hull_build', '20260618000188'],
  ['cancel_build_order', '20260618000194'],
  ['buy_shop_offer_at_port', '20260618000235'],
];
{
  const version = (f) => (f.match(/^(\d{14})_/) || [])[1] ?? '';
  const files = readdirSync(MIGDIR).filter((f) => f.endsWith('.sql') && version(f) !== SELF);
  const stripped = new Map(
    files.map((f) => [f, readFileSync(MIG(f), 'utf8').replace(/--[^\n]*/g, '')]));

  for (const [fname, head] of HEADS) {
    const reCreate = new RegExp(
      `create\\s+or\\s+replace\\s+function\\s+(?:public\\.)?${fname}\\s*\\(`, 'i');
    const newer = files.filter((f) => version(f) > head && reCreate.test(stripped.get(f)));
    if (newer.length > 0) {
      throw new Error(
        `${fname} was textually re-created AFTER ${head} by: ${newer.join(', ')} — ` +
        're-point the slice at the new head before generating.');
    }
    const reHunkRow = new RegExp(`\\(\\s*\\d+\\s*,\\s*'${fname}'\\s*,`);
    const surgery = files.filter((f) => version(f) > head && reHunkRow.test(stripped.get(f)));
    if (surgery.length > 0) {
      throw new Error(
        `${fname} was rewritten by hunk surgery AFTER ${head} by: ${surgery.join(', ')} — ` +
        'read that migration and re-point this slice; do not regenerate blindly.');
    }
  }
}

const F40 = load('20260617000040_pending_loot_bundle.sql');
const F109 = load('20260618000109_modules_p13_craft_command.sql');
const F126 = load('20260618000126_captain_p16_recruit_command.sql');
const F174 = load('20260618000174_salvage_market.sql');
const F188 = load('20260618000188_shipyard1_order_rpc.sql');
const F194 = load('20260618000194_shipyard2_delivery.sql');
const F235 = load('20260618000235_port_shop_buy.sql');

/** Slice [from,to] 1-indexed inclusive, asserting fence lines so source drift fails loudly. */
function slice(lines, file, from, to, startsWith, endsWith) {
  const text = lines.slice(from - 1, to).join('\n');
  const first = lines[from - 1];
  const last = lines[to - 1];
  if (!first.startsWith(startsWith)) {
    throw new Error(`${file}:${from} does not start with ${JSON.stringify(startsWith)} — got ${JSON.stringify(first)}`);
  }
  if (!last.endsWith(endsWith)) {
    throw new Error(`${file}:${to} does not end with ${JSON.stringify(endsWith)} — got ${JSON.stringify(last)}`);
  }
  return text;
}

/** Replace `find` with `repl` in `src`, asserting the match occurs exactly once. */
function once(src, find, repl, what) {
  const n = src.split(find).length - 1;
  if (n !== 1) throw new Error(`${what}: expected exactly 1 occurrence of ${JSON.stringify(find)}, found ${n}`);
  return src.split(find).join(repl);
}

/** A plpgsql dollar-quoted literal that cannot collide with the hunk text. */
const q = (tag, text) => `$${tag}$${text}$${tag}$`;

// ═════════════════════════════════════════════════════════════════════════════════════════════════
// THE HUNKS. Each entry: [idx, function name, old text (sliced), new text (built from the slice)].
// ═════════════════════════════════════════════════════════════════════════════════════════════════

// ── (1) reward_grant — the ITEM arm finally uses the base it has always been handed. ─────────────
const H1_OLD = slice(F40, '0040', 83, 85, '        perform inventory_deposit(', "r.item_id);");
const H1_NEW = once(H1_OLD, '          p_player, r.item_id, r.qty,', '          p_player, p_base, r.item_id, r.qty,', 'H1');

// ── (2) production_craft_module — the spend names the port it draws from. ────────────────────────
const H2_OLD = slice(F109, '0109', 160, 160, '    v_have := public.inventory_get_balance(', 'r.item_id);');
const H2_NEW = once(H2_OLD, '(p_player, r.item_id)', '(p_player, p_base, r.item_id)', 'H2');
const H3_OLD = slice(F109, '0109', 176, 176, '    perform public.inventory_spend(', 'r.qty);');
const H3_NEW = once(H3_OLD, '(p_player, r.item_id, r.qty)', '(p_player, p_base, r.item_id, r.qty)', 'H3');

// ── (3) craft_module — gains the ship, derives the port, refuses when not docked. ────────────────
// The wrapper declare block is byte-identical in craft_module / recruit_captain / start_hull_build;
// it is sliced ONCE and asserted to occur exactly once inside each of the three.
const WRAP_DECL_OLD = slice(F109, '0109', 208, 212, 'declare', 'begin');
const WRAP_DECL_NEW = once(
  WRAP_DECL_OLD, '  v_reason text;\nbegin',
  '  v_reason text;\n  v_ship   uuid;   -- ★ 0333\n  v_loc    uuid;   -- ★ 0333\n  v_base   uuid;   -- ★ 0333\nbegin',
  'WRAP_DECL');

/** The dock→store resolution the three commands all do, in the wrapper, before delegating. */
const dockBlock = (verb) => `  -- ★ 0333 — LAW 3: you build from the port you are DOCKED AT. The port is DERIVED from the
  --   ship's validated dock through the ONE shared resolver; it is never a parameter, so
  --   "${verb} from a port I am not standing in" is not a request this surface can express.
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then
    return jsonb_build_object('ok', false, 'code', 'ship_not_found', 'message', 'No ship available.');
  end if;
  v_loc := public.mainship_resolve_docked_location(v_ship);
  if v_loc is null then
    return jsonb_build_object('ok', false, 'code', 'not_docked', 'message', 'Dock at a port to use what is stored there.');
  end if;
  if not public.is_home_port_eligible(v_loc) then
    return jsonb_build_object('ok', false, 'code', 'port_has_no_storage', 'message', 'This place has no storage.');
  end if;
  v_base := public.get_or_create_store(v_player, v_loc);

`;

const H4_OLD = slice(F109, '0109', 225, 225, '  v_res := public.production_craft_module(', 'p_request_id);');
const H4_NEW = dockBlock('craft') + once(
  H4_OLD, '(v_player, p_module_type, p_request_id)', '(v_player, p_module_type, p_request_id, v_base)', 'H4');

// ── (4) production_recruit_captain / recruit_captain — the same two shapes. ──────────────────────
const H5_OLD = slice(F126, '0126', 165, 165, '    v_have := public.inventory_get_balance(', 'r.item_id);');
const H5_NEW = once(H5_OLD, '(p_player, r.item_id)', '(p_player, p_base, r.item_id)', 'H5');
const H6_OLD = slice(F126, '0126', 181, 181, '    perform public.inventory_spend(', 'r.qty);');
const H6_NEW = once(H6_OLD, '(p_player, r.item_id, r.qty)', '(p_player, p_base, r.item_id, r.qty)', 'H6');
const H7_OLD = slice(F126, '0126', 230, 230, '  v_res := public.production_recruit_captain(', 'p_request_id);');
const H7_NEW = dockBlock('recruit') + once(
  H7_OLD, '(v_player, p_captain_type, p_request_id)', '(v_player, p_captain_type, p_request_id, v_base)', 'H7');

// ── (5) sell_item_at_port — sells what THIS port is holding for you. ─────────────────────────────
const H8_OLD = slice(F174, '0174', 181, 182, '  v_receipt  uuid;', 'begin');
const H8_NEW = once(H8_OLD, '  v_receipt  uuid;\nbegin', '  v_receipt  uuid;\n  v_store    uuid;   -- ★ 0333\nbegin', 'H8');
const H9_OLD = slice(F174, '0174', 213, 216, '  v_loc := public.mainship_resolve_docked_location(', '  end if;');
const H9_NEW = H9_OLD + `

  -- ★ 0333 — items LIVE in this port's storage, so the sale draws from THIS port and no other.
  if not public.is_home_port_eligible(v_loc) then
    return jsonb_build_object('ok', false, 'reason', 'port_has_no_storage', 'location_id', v_loc);
  end if;
  v_store := public.get_or_create_store(v_player, v_loc);`;
const H10_OLD = slice(F174, '0174', 237, 237, '  v_have := public.inventory_get_balance(', 'p_item_id);');
const H10_NEW = once(H10_OLD, '(v_player, p_item_id)', '(v_player, v_store, p_item_id)', 'H10');
const H11_OLD = slice(F174, '0174', 247, 247, '  perform public.inventory_spend(', 'v_qty);');
const H11_NEW = once(H11_OLD, '(v_player, p_item_id, v_qty)', '(v_player, v_store, p_item_id, v_qty)', 'H11');

// ── (6) production_start_hull_build — spends the docked port's stock AND RECORDS IT on the order. ─
const H12_OLD = slice(F188, '0188', 267, 267, '    v_have := public.inventory_get_balance(', 'r.item_id);');
const H12_NEW = once(H12_OLD, '(p_player, r.item_id)', '(p_player, p_base, r.item_id)', 'H12');
const H13_OLD = slice(F188, '0188', 293, 293, '    perform public.inventory_spend(', 'r.qty::integer);');
const H13_NEW = once(H13_OLD, '(p_player, r.item_id, r.qty::integer)', '(p_player, p_base, r.item_id, r.qty::integer)', 'H13');
// THE REFUND ANSWER: the hull order records the store it was placed from, so 0194's refund arm has
// a port to give the ingredients back to. Before this, `build_orders_kind_coherent` FORCED base_id
// NULL on hull orders, so the item refund had no port BY CONSTRUCTION.
const H14_OLD = slice(F188, '0188', 303, 305, '  insert into build_orders (', 'returning id into v_order;');
const H14_NEW = once(
  once(H14_OLD,
    'insert into build_orders (player_id, hull_type_id, quantity, credits_spent, status, queued_at)',
    'insert into build_orders (player_id, base_id, hull_type_id, quantity, credits_spent, status, queued_at)',
    'H14 cols'),
  'values (p_player, p_hull_type_id, 1, v_recipe.credits_cost, \'waiting\', now())',
  'values (p_player, p_base, p_hull_type_id, 1, v_recipe.credits_cost, \'waiting\', now())',
  'H14 vals');

// ── (7) start_hull_build — the wrapper gains the ship. ───────────────────────────────────────────
const H15_OLD = slice(F188, '0188', 350, 350, '  v_res := public.production_start_hull_build(', 'p_request_id);');
const H15_NEW = dockBlock('order a hull') + once(
  H15_OLD, '(v_player, p_hull_type_id, p_request_id)', '(v_player, p_hull_type_id, p_request_id, v_base)', 'H15');

// ── (8) cancel_build_order — the hull refund goes back to the port that placed the order. ────────
const H16_OLD = slice(F194, '0194', 404, 405, '        perform public.inventory_deposit(o.player_id,', "r.item_id);");
const H16_NEW = once(H16_OLD, 'inventory_deposit(o.player_id, r.item_id, v_qty,', 'inventory_deposit(o.player_id, o.base_id, r.item_id, v_qty,', 'H16');

// ── (9) buy_shop_offer_at_port — the goods are put down at the port you bought them at. ──────────
const H17_OLD = slice(F235, '0235', 222, 223, '  v_receipt  uuid;', 'begin');
const H17_NEW = once(H17_OLD, '  v_receipt  uuid;\nbegin', '  v_receipt  uuid;\n  v_store    uuid;   -- ★ 0333\nbegin', 'H17');
const H18_OLD = slice(F235, '0235', 251, 254, '  v_loc := public.mainship_resolve_docked_location(', '  end if;');
const H18_NEW = H18_OLD + `

  -- ★ 0333 — what you buy is put down HERE, in this port's storage, because that is where items live.
  if not public.is_home_port_eligible(v_loc) then
    return jsonb_build_object('ok', false, 'reason', 'port_has_no_storage', 'location_id', v_loc);
  end if;
  v_store := public.get_or_create_store(v_player, v_loc);`;
const H19_OLD = slice(F235, '0235', 296, 297, '    perform public.inventory_deposit(', "p_request_id::text);");
const H19_NEW = once(H19_OLD, '      v_player, v_offer.item_id, v_qty,', '      v_player, v_store, v_offer.item_id, v_qty,', 'H19');

// Body hunks, applied by replace-surgery over the DEPLOYED definition, exactly once each.
const HUNKS = [
  [1, 'reward_grant', H1_OLD, H1_NEW],
  [2, 'production_craft_module', H2_OLD, H2_NEW],
  [3, 'production_craft_module', H3_OLD, H3_NEW],
  [4, 'craft_module', WRAP_DECL_OLD, WRAP_DECL_NEW],
  [5, 'craft_module', H4_OLD, H4_NEW],
  [6, 'production_recruit_captain', H5_OLD, H5_NEW],
  [7, 'production_recruit_captain', H6_OLD, H6_NEW],
  [8, 'recruit_captain', WRAP_DECL_OLD, WRAP_DECL_NEW],
  [9, 'recruit_captain', H7_OLD, H7_NEW],
  [10, 'sell_item_at_port', H8_OLD, H8_NEW],
  [11, 'sell_item_at_port', H9_OLD, H9_NEW],
  [12, 'sell_item_at_port', H10_OLD, H10_NEW],
  [13, 'sell_item_at_port', H11_OLD, H11_NEW],
  [14, 'production_start_hull_build', H12_OLD, H12_NEW],
  [15, 'production_start_hull_build', H13_OLD, H13_NEW],
  [16, 'production_start_hull_build', H14_OLD, H14_NEW],
  [17, 'start_hull_build', WRAP_DECL_OLD, WRAP_DECL_NEW],
  [18, 'start_hull_build', H15_OLD, H15_NEW],
  [19, 'cancel_build_order', H16_OLD, H16_NEW],
  [20, 'buy_shop_offer_at_port', H17_OLD, H17_NEW],
  [21, 'buy_shop_offer_at_port', H18_OLD, H18_NEW],
  [22, 'buy_shop_offer_at_port', H19_OLD, H19_NEW],
];

// Signature widenings, applied to the SAME re-created definitions. The argument list is read back
// from the catalog at deploy time — it is never retyped here.
const SIGS = [
  ['production_craft_module', 'p_base uuid', false],
  ['craft_module', 'p_main_ship_id uuid DEFAULT NULL::uuid', true],
  ['production_recruit_captain', 'p_base uuid', false],
  ['recruit_captain', 'p_main_ship_id uuid DEFAULT NULL::uuid', true],
  ['production_start_hull_build', 'p_base uuid', false],
  ['start_hull_build', 'p_main_ship_id uuid DEFAULT NULL::uuid', true],
];

const hunkRows = HUNKS.map(([i, f, o, n]) =>
  `    (${i}, '${f}',\n     ${q(`o${i}`, o)},\n     ${q(`n${i}`, n)})`).join(',\n');
const sigRows = SIGS.map(([f, add, client]) =>
  `    ('${f}', '${add}', ${client})`).join(',\n');

const sql = `-- Byeharu — 0333: ITEMS LIVE AT PORTS.   (rev.3 — see THE TWO CORRECTIONS below)
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE OWNER'S DESIGN LAWS THIS MIGRATION EXISTS TO SATISFY (stated long ago, repeated 2026-08-03):
--   1. Items are NOT unlimited — VOLUME matters. An item with no volume is a bug.
--   2. Storage is PER-PORT. Each city holds its own stock.
--   3. You can only reach a port's storage while DOCKED there. No remote retrieval, EVER.
--   4. The player moves items between the SHIP'S HOLD and the PORT'S STORAGE. That transfer is
--      the core logistics verb.
--
-- ── THE MODEL, SETTLED. DO NOT RE-LITIGATE IT. ───────────────────────────────────────────────────
-- ITEMS LIVE IN PORT STORAGE. THE FLEET HOLD IS PURELY WHAT YOU CARRY.
--   · \`base_items\` (per-port, keyed to the player's \`bases\` row for that port) is where items LIVE.
--     It is their home. Crafting, recruiting and ordering a hull all consume from the port you are
--     DOCKED AT — nothing consumes from a pool that has no place.
--   · \`fleet_items\` (per-FLEET) is the HOLD: purely what a fleet is carrying between ports. It is
--     transient. Its capacity is Σ \`cargo_capacity_m3\` over that fleet's LIVING ships.
--   · \`transfer_items\` is the ONE verb that moves a stack between them, and only while docked.
--   · \`player_inventory\` — a single GLOBAL, LOCATION-LESS, WEIGHTLESS pool — is the thing that
--     contradicted laws 2 and 3 outright. Its 312 rows land in port storage and THE TABLE IS
--     DROPPED. A model that ships while its predecessor stays live is spaghetti by construction.
--
-- ── THE TWO CORRECTIONS THAT PRODUCED THIS REVISION (so they are never repeated) ─────────────────
-- rev.2 of this migration made the hold PLAYER-WIDE (Σ over all the player's ships, across fleets)
-- and left items LIVING in it. Both were wrong, and the owner said so:
--   (1) A player-wide hold TELEPORTS goods between fleets standing in different ports — the same
--       violation as the global pool, just less visible. A fleet is in exactly ONE place; that is
--       why the fleet is the unit.
--   (2) Items living in the hold means a player with no ship owns items that are NOWHERE. 155 of
--       the 157 item-holders on production own no ship at all. Items live at PORTS; the hold is
--       what you pick up and carry.
-- rev.1 additionally aborted its own production deploy at check (c) —
--       ERROR: 0333 (c) FAIL: anon can SELECT base_items (SQLSTATE P0001)
-- because it ASSERTED a grant posture it had never ESTABLISHED. The transaction guard rolled it
-- back whole; head stayed 20260618000332. THE FULL REVOKE POSTURE FROM rev.2 SURVIVES HERE
-- UNWEAKENED — see section 12 and self-assert (c).
--
-- THE EVIDENCE FOR THAT POSTURE, read off production rather than reasoned about (pg_default_acl):
--     objtype 'r' (table) · owner postgres · schema public
--     default_acl = {postgres=arwdDxtm/postgres, anon=arwdDxtm/postgres,
--                    authenticated=arwdDxtm/postgres, service_role=arwdDxtm/postgres}
-- \`arwdDxtm\` = INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN. Every new
-- public table owned by postgres inherits ALL EIGHT for anon and authenticated at creation. A
-- disposable \`supabase start\` carries no such default, so a verb-list revoke reads green in CI and
-- fails on production. \`revoke all\` is a SUPERSET of any default and is therefore correct in both
-- worlds without needing to know which world it is in.
--
-- ── WHY THE HOLD IS KEYED ON \`fleets.id\` ─────────────────────────────────────────────────────────
-- \`mainship_resolve_fleet\` (0210) is the ONE ship→fleet resolver and it already answers for both
-- shapes: a ship in a group resolves to the group's unified fleet, a lone ship to its own per-ship
-- fleet. So keying the hold on \`fleets.id\` needs NO new concept, gives a grouped fleet ONE shared
-- hold (the owner's correction), and still gives an ungrouped ship a hold of its own. Capacity is
-- the inverse of that same resolver, in one leaf, over LIVING ships only — a wreck carries nothing.
--
-- ── WHERE EACH VERB NOW DRAWS FROM (the whole point of the slice) ────────────────────────────────
--   craft_module / recruit_captain / start_hull_build   → the port you are DOCKED AT
--   sell_item_at_port / buy_shop_offer_at_port          → the port you are DOCKED AT
--   reward_grant (loot)                                 → the base it is already handed; and where
--                                                         that is NULL (loot secured in open space)
--                                                         the player's OLDEST ACTIVE base, so a
--                                                         deposit never strands. 0307:153 already
--                                                         resolves exactly that, citing 0221.
--   cancel_build_order (hull refund)                    → the port that PLACED the order
--
-- ── DEPOSITS NEVER STRAND; SPENDS REFUSE ─────────────────────────────────────────────────────────
-- \`inventory_deposit\` accepts a NULL base and falls back to the oldest active base: never destroy
-- an asset to satisfy a rule. \`inventory_spend\` and \`inventory_get_balance\` REFUSE a NULL base —
-- a spend that does not name its port is not a spend, and the three commands return a typed
-- \`not_docked\` envelope long before the leaf is ever reached.
--
-- ── THE THREE COMMANDS GAIN A SHIP ───────────────────────────────────────────────────────────────
-- \`craft_module\`, \`recruit_captain\` and \`start_hull_build\` gain \`p_main_ship_id uuid default null\`
-- — the established sole-ship shim shape (0081), so an existing single-ship caller keeps working
-- byte-for-byte. The PORT is derived from that ship's validated dock through
-- \`mainship_resolve_docked_location\`; it is NEVER a parameter, so "craft from a port I am not
-- standing in" is not a request the surface can express. "Oldest base" was REJECTED for these three:
-- it would let a player craft from Haven's materials while standing at Slagworks, which is remote
-- retrieval and violates law 3 for exactly the person who asked for the law.
--
-- ── HULL ORDERS MUST RECORD THEIR STORE (the refund answer) ──────────────────────────────────────
-- \`build_orders_kind_coherent\` (0188:104-108) CHECK-constrained hull orders to \`base_id IS NULL\`,
-- and the hull arm is the ONLY refund path that returns ITEMS (0194:404). So the item refund had no
-- port BY CONSTRUCTION. \`production_start_hull_build\` now records the docked port's store on the
-- order and the CHECK is flipped to REQUIRE \`base_id NOT NULL\` on hull orders, matching unit orders.
-- \`build_orders\` has ZERO rows on production, so there is nothing to backfill and no row can fail
-- the new CHECK.
--
-- ── BLAST RADIUS (production is a LIVE ~30-player game), measured 2026-08-03 ─────────────────────
--   \`module_craft_receipts\`   3 rows / 1 player — all within 0.6s on 2026-07-19, the SpatialCanary
--                             scripted account, currently not docked.
--   \`captain_recruit_receipts\` 0 rows.   \`build_orders\` 0 rows.   \`base_items\` does not exist.
--   \`player_inventory\`        312 rows / 157 players; EVERY ONE of those players has an active base
--                             (checked: zero without), so the move below strands nobody.
--   The live behavioural regression is therefore ONE non-organic account.
--
--   ADDS:    \`item_types.volume_m3\`; \`base_items\`; \`fleet_items\`; \`item_transfer_receipts\`;
--            \`inventory_ledger.base_id\`; the six leaves (\`base_items_add\`/\`_take\`,
--            \`fleet_items_add\`/\`_take\`, \`fleet_hold_capacity_m3\`/\`_used_m3\`);
--            \`transfer_items\` + \`get_my_hold\` (authenticated RPCs).
--   DROPS:   \`player_inventory\` (after its rows move), and the three 0039 leaf signatures, which
--            are re-created against port storage.
--   CHANGES: the ten functions listed in section 11, each by replace-surgery over its DEPLOYED
--            definition using a slice cut verbatim from its own textual head.
--   TOUCHES NOT AT ALL: any cron, any combat function, any movement function, \`market_buy\`,
--            \`ship_cargo_lots\`, \`base_resources\`, \`base_units\`. No feature flag is created; the
--            slice rides the ALREADY-LIT \`station_storage_enabled\` because it IS the per-port
--            storage feature finally completed. Shipping LIT is the standing order.
--
-- ── SELF-ASSERT MAP (one DO block per check — the statement number IS the diagnosis) ─────────────
--   (a) every item type carries a POSITIVE volume, and the CHECK that guarantees it is validated
--   (b) \`base_items\` and \`fleet_items\` mirror \`base_resources\`: shape, RLS, one owner-scoped
--       SELECT policy whose DEPLOYED expression really scopes to the owner, no client write
--   (c) ACLs, each ESTABLISHED here and then asserted: 120 has_table_privilege assertions across
--       5 tables x 8 verbs x 3 client grantees, plus the anon SEAT made to try the reads for real
--   (d) \`transfer_items\` composes ONE authority per fact and acquires no second one; law 3 is
--       UNEXPRESSABLE (no location-shaped parameter), not merely checked
--   (e) \`get_my_docked_store\` carried through every 0211 invariant
--   (f) capacity is DERIVED (never stored), fleet-scoped, and excludes wrecks
--   (g) THE THREE LEAVES ARE THE ONLY WRITERS OF \`base_items\`/\`fleet_items\`, they all take a port,
--       \`player_inventory\` is GONE, and no second global pool replaced it
--   (h) the ten re-created functions changed BODY AND NOTHING ELSE (metadata parity), the three
--       commands really gained the ship, and the hull order really records its store
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 0. PRECONDITIONS (read-only) — refuse to build on a base we did not slice from ───────────────
do $pre$
declare
  v_orphans integer;
begin
  if to_regclass('public.player_inventory') is null
     or to_regclass('public.item_types') is null
     or to_regclass('public.bases') is null
     or to_regclass('public.base_resources') is null
     or to_regclass('public.fleets') is null
     or to_regclass('public.build_orders') is null then
    raise exception '0333 PRECONDITION FAIL: a table this slice re-points is absent';
  end if;

  if to_regclass('public.base_items') is not null or to_regclass('public.fleet_items') is not null then
    raise exception '0333 PRECONDITION FAIL: base_items/fleet_items already exist — this migration must not re-run or land over an unknown edit';
  end if;

  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'item_types' and column_name = 'volume_m3') then
    raise exception '0333 PRECONDITION FAIL: item_types.volume_m3 already exists — same reason';
  end if;

  -- the capacity authority must be the column this slice believes it is.
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'main_ship_instances'
                    and column_name = 'cargo_capacity_m3' and data_type = 'numeric'
                    and is_nullable = 'NO') then
    raise exception '0333 PRECONDITION FAIL: main_ship_instances.cargo_capacity_m3 is not the numeric NOT NULL capacity column — the hold has no capacity authority';
  end if;

  -- bases must already BE the per-port store (0157), or "per-port" has nothing to key on.
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'bases' and column_name = 'location_id') then
    raise exception '0333 PRECONDITION FAIL: bases.location_id is missing — bases is not the per-port store this slice keys on';
  end if;

  -- every function this migration COMPOSES must exist. It invents none of them.
  if to_regprocedure('public.inventory_deposit(uuid,text,integer,text)') is null
     or to_regprocedure('public.inventory_spend(uuid,text,integer)') is null
     or to_regprocedure('public.inventory_get_balance(uuid,text)') is null
     or to_regprocedure('public.get_or_create_store(uuid,uuid)') is null
     or to_regprocedure('public.is_home_port_eligible(uuid)') is null
     or to_regprocedure('public.mainship_resolve_owned_ship(uuid,uuid)') is null
     or to_regprocedure('public.mainship_resolve_docked_location(uuid)') is null
     or to_regprocedure('public.mainship_resolve_fleet(uuid)') is null
     or to_regprocedure('public.mainship_space_lock_context(uuid,boolean)') is null
     or to_regprocedure('public.get_my_docked_store(uuid)') is null
     or to_regprocedure('public.cfg_bool(text)') is null then
    raise exception '0333 PRECONDITION FAIL: a function this migration composes is missing';
  end if;

  -- the gate this slice rides must already exist (0157). It is NOT created or flipped here.
  if not exists (select 1 from public.game_config where key = 'station_storage_enabled') then
    raise exception '0333 PRECONDITION FAIL: station_storage_enabled is absent — this slice rides that gate, it does not invent one';
  end if;

  -- NOBODY MAY BE STRANDED BY THE MOVE. Every player holding an item must have an active base for
  -- it to land in. On production this is 0; if it is ever not 0 the move stops rather than losing
  -- somebody's property.
  select count(*) into v_orphans from (
    select distinct pi.player_id from public.player_inventory pi
     where pi.quantity > 0
       and not exists (select 1 from public.bases b
                        where b.player_id = pi.player_id and b.status = 'active')) s;
  if v_orphans <> 0 then
    raise exception '0333 PRECONDITION FAIL: % item-holding player(s) have no active base to move their items into — refusing to strand them', v_orphans;
  end if;
end $pre$;

-- ═══ 1. VOLUME — one number per item type, catalog-set ═══════════════════════════════════════════
-- DEFAULT 1.0 is deliberate and load-bearing: law 1 says an item with no volume is a bug, so a
-- future catalog row can never be volumeless. NOT NULL + CHECK (> 0) makes zero-volume — the
-- "infinite items" loophole — unrepresentable rather than merely discouraged.
alter table public.item_types
  add column volume_m3 numeric not null default 1.0
  constraint item_types_volume_m3_positive check (volume_m3 > 0);

-- The scale, set against the 50 m3 starter hull so the numbers mean something in play:
-- 50 m3 carries 25 ore, or 50 crystal, or 100 scrap, or 250 weapon_parts, or 1000 rounds.
-- Bulk raw material is big; refined components are small; data and progression tokens are tiny but
-- never free. The five the owner named keep exactly the values he gave.
update public.item_types t set volume_m3 = v.m3
  from (values
    -- materials — the bulk end of the scale
    ('ore',                  2.00),   -- owner-set: unrefined rock, the bulkiest thing you mine
    ('crystal',              1.00),   -- owner-set
    ('scrap',                0.50),   -- owner-set
    ('pirate_alloy',         0.50),   -- owner-set
    ('anomaly_shard',        0.20),   -- a shard, not a seam: well under a whole crystal
    -- components — refined, compact, carried by the hundred
    ('weapon_parts',         0.20),   -- owner-set; the reference point for the component class
    ('repair_parts',         0.20),   -- same class, same size
    ('engine_parts',         0.30),   -- a drive assembly is the bulkiest of the three
    -- ammunition — you carry it in quantity or it is not ammunition
    ('autocannon_rounds',    0.05),
    -- data — near-massless, never weightless (law 1)
    ('scan_data',            0.01),
    -- progression — small tokens, but an artifact core is a real object
    ('captain_memory_shard', 0.10),
    ('blueprint_fragment',   0.10),
    ('artifact_core',        0.50)
  ) as v(item_id, m3)
 where t.item_id = v.item_id;

-- ═══ 2. base_items — WHERE ITEMS LIVE. Mirrors base_resources exactly. ═══════════════════════════
-- Column shape, FK-with-cascade, uniqueness and RLS are a deliberate byte-mirror of
-- \`base_resources\` (0005:31-38 / :53-58). The ONLY differences are the value domain (INTEGER
-- quantity, because an item is a whole thing) and the FK on \`item_types\`.
create table public.base_items (
  id         uuid    primary key default gen_random_uuid(),
  base_id    uuid    not null references public.bases (id) on delete cascade,
  item_id    text    not null references public.item_types (item_id),
  quantity   integer not null default 0 check (quantity >= 0),
  updated_at timestamptz not null default now(),
  unique (base_id, item_id)
);
create index base_items_base_id_idx on public.base_items (base_id);

alter table public.base_items enable row level security;
create policy "base_items_select_own" on public.base_items
  for select using (exists (
    select 1 from public.bases b where b.id = base_items.base_id and b.player_id = auth.uid()
  ));

-- ── ESTABLISH the WHOLE posture. REVOKE EVERYTHING FIRST, then grant back exactly what is meant. ──
-- This is the hunk whose rev.1 omission aborted a production deploy. See the header for the
-- pg_default_acl evidence: every new public table inherits all EIGHT privileges for anon and
-- authenticated at creation, and a disposable CI database reproduces none of it.
revoke all on table public.base_items from public, anon, authenticated;
grant select on table public.base_items to authenticated;

-- ═══ 3. The SOLE writers of base_items (the Base-system law, 0005:3-7) ═══════════════════════════
create or replace function public.base_items_add(p_base uuid, p_item text, p_qty integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_base is null or p_item is null then
    raise exception 'base_items_add: base and item are required';
  end if;
  if p_qty is null or p_qty <= 0 then
    raise exception 'base_items_add: invalid quantity %', p_qty;
  end if;
  if not exists (select 1 from public.item_types where item_id = p_item) then
    raise exception 'base_items_add: unknown item %', p_item;
  end if;

  insert into public.base_items (base_id, item_id, quantity)
    values (p_base, p_item, p_qty)
    on conflict (base_id, item_id)
    do update set quantity = base_items.quantity + excluded.quantity, updated_at = now();
end;
$$;

create or replace function public.base_items_take(p_base uuid, p_item text, p_qty integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_have integer;
begin
  if p_base is null or p_item is null then
    raise exception 'base_items_take: base and item are required';
  end if;
  if p_qty is null or p_qty <= 0 then
    raise exception 'base_items_take: invalid quantity %', p_qty;
  end if;

  -- FOR UPDATE re-check under the row lock IS the authoritative enforcement (the inventory_spend
  -- 0039:117-121 posture); a caller's friendly pre-check never is.
  select quantity into v_have from public.base_items
    where base_id = p_base and item_id = p_item for update;
  if v_have is null or v_have < p_qty then
    raise exception 'base_items_take: insufficient % (have %, need %)', p_item, coalesce(v_have, 0), p_qty;
  end if;

  update public.base_items set quantity = quantity - p_qty, updated_at = now()
    where base_id = p_base and item_id = p_item;
end;
$$;

revoke all on function public.base_items_add(uuid, text, integer)  from public, anon, authenticated;
revoke all on function public.base_items_take(uuid, text, integer) from public, anon, authenticated;
grant execute on function public.base_items_add(uuid, text, integer)  to service_role;
grant execute on function public.base_items_take(uuid, text, integer) to service_role;

-- ═══ 4. fleet_items — THE HOLD. What a fleet is CARRYING, and nothing else. ══════════════════════
-- Keyed on \`fleets.id\` because that is what \`mainship_resolve_fleet\` (0210) — the ONE ship→fleet
-- resolver — already answers with, for both a grouped fleet and a lone ship. A fleet is in exactly
-- one place at a time, which is the entire reason it, and not the player, is the unit of carrying.
create table public.fleet_items (
  id         uuid    primary key default gen_random_uuid(),
  fleet_id   uuid    not null references public.fleets (id) on delete cascade,
  item_id    text    not null references public.item_types (item_id),
  quantity   integer not null default 0 check (quantity >= 0),
  updated_at timestamptz not null default now(),
  unique (fleet_id, item_id)
);
create index fleet_items_fleet_id_idx on public.fleet_items (fleet_id);

alter table public.fleet_items enable row level security;
create policy "fleet_items_select_own" on public.fleet_items
  for select using (exists (
    select 1 from public.fleets f where f.id = fleet_items.fleet_id and f.player_id = auth.uid()
  ));
revoke all on table public.fleet_items from public, anon, authenticated;
grant select on table public.fleet_items to authenticated;

create or replace function public.fleet_items_add(p_fleet uuid, p_item text, p_qty integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_fleet is null or p_item is null then
    raise exception 'fleet_items_add: fleet and item are required';
  end if;
  if p_qty is null or p_qty <= 0 then
    raise exception 'fleet_items_add: invalid quantity %', p_qty;
  end if;
  if not exists (select 1 from public.item_types where item_id = p_item) then
    raise exception 'fleet_items_add: unknown item %', p_item;
  end if;

  insert into public.fleet_items (fleet_id, item_id, quantity)
    values (p_fleet, p_item, p_qty)
    on conflict (fleet_id, item_id)
    do update set quantity = fleet_items.quantity + excluded.quantity, updated_at = now();
end;
$$;

create or replace function public.fleet_items_take(p_fleet uuid, p_item text, p_qty integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_have integer;
begin
  if p_fleet is null or p_item is null then
    raise exception 'fleet_items_take: fleet and item are required';
  end if;
  if p_qty is null or p_qty <= 0 then
    raise exception 'fleet_items_take: invalid quantity %', p_qty;
  end if;

  select quantity into v_have from public.fleet_items
    where fleet_id = p_fleet and item_id = p_item for update;
  if v_have is null or v_have < p_qty then
    raise exception 'fleet_items_take: insufficient % (have %, need %)', p_item, coalesce(v_have, 0), p_qty;
  end if;

  update public.fleet_items set quantity = quantity - p_qty, updated_at = now()
    where fleet_id = p_fleet and item_id = p_item;
end;
$$;

revoke all on function public.fleet_items_add(uuid, text, integer)  from public, anon, authenticated;
revoke all on function public.fleet_items_take(uuid, text, integer) from public, anon, authenticated;
grant execute on function public.fleet_items_add(uuid, text, integer)  to service_role;
grant execute on function public.fleet_items_take(uuid, text, integer) to service_role;

-- ═══ 5. The capacity leaves — DERIVED, never stored, FLEET-scoped ════════════════════════════════
-- There is no \`hold_capacity\` column anywhere and there must never be one: a stored copy of a
-- derivable number is a second authority that drifts.
create or replace function public.fleet_hold_capacity_m3(p_fleet uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  -- The INVERSE of mainship_resolve_fleet (0210), and the only place it is written: a unified
  -- fleet's ships are its GROUP's members; a per-ship fleet's ship is its own. A wreck carries
  -- nothing, so \`status <> 'destroyed'\`. Zero living ships -> 0, which is the honest answer.
  select coalesce((
    select sum(m.cargo_capacity_m3)
      from public.fleets f
      join public.main_ship_instances m
        on ((f.group_id is not null and f.main_ship_id is null
             and m.group_id = f.group_id and m.player_id = f.player_id)
            or (f.main_ship_id is not null and m.main_ship_id = f.main_ship_id))
     where f.id = p_fleet and m.status <> 'destroyed'
  ), 0)::numeric;
$$;

create or replace function public.fleet_hold_used_m3(p_fleet uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  -- The hold's occupancy: every carried stack at its catalog volume. Items only — trade cargo
  -- (\`ship_cargo_lots\`, keyed per hull) is a separate hold on purpose and is left byte-untouched.
  select coalesce((
    select sum(fi.quantity * t.volume_m3)
      from public.fleet_items fi
      join public.item_types t on t.item_id = fi.item_id
     where fi.fleet_id = p_fleet and fi.quantity > 0
  ), 0)::numeric;
$$;

revoke all on function public.fleet_hold_capacity_m3(uuid) from public, anon, authenticated;
revoke all on function public.fleet_hold_used_m3(uuid)     from public, anon, authenticated;
grant execute on function public.fleet_hold_capacity_m3(uuid) to service_role;
grant execute on function public.fleet_hold_used_m3(uuid)     to service_role;

-- ═══ 6. THE MOVE — every existing item goes home to a port, then the global pool DIES ════════════
-- Uniform rule, one rule for everybody: the player's OLDEST ACTIVE base. That is not invented here
-- — it is the securing-processor idiom (0221:1031-1036) that 0307:153 already uses for loot with
-- no port. The precondition above proved every holder has one, so nothing is stranded, nothing is
-- clamped, nothing is deleted. Quantities are summed per (base, item) in case a player somehow
-- holds the same item twice; \`base_items_add\` is the sole writer and is used as such.
do $move$
declare
  r      record;
  v_rows integer := 0;
  v_qty  bigint  := 0;
begin
  for r in
    select pi.player_id,
           (select b.id from public.bases b
             where b.player_id = pi.player_id and b.status = 'active'
             order by b.created_at, b.id limit 1) as base_id,
           pi.item_id,
           sum(pi.quantity)::integer as qty
      from public.player_inventory pi
     where pi.quantity > 0
     group by pi.player_id, pi.item_id
     order by pi.player_id, pi.item_id
  loop
    if r.base_id is null then
      raise exception '0333 MOVE FAIL: player % has items but no active base (the precondition should have caught this)', r.player_id;
    end if;
    perform public.base_items_add(r.base_id, r.item_id, r.qty);
    v_rows := v_rows + 1;
    v_qty  := v_qty + r.qty;
  end loop;
  raise notice '0333 MOVE: % stack(s), % item(s) total moved from the global pool into their owner''s oldest active port store. Nothing was deleted, clamped or confiscated.', v_rows, v_qty;
end $move$;

-- The ledger gains the place, so an audit row can answer WHERE as well as what.
alter table public.inventory_ledger
  add column base_id uuid references public.bases (id) on delete set null;

-- RESTRICT by design (the default): if anything at all still depends on the global pool, this
-- statement fails loudly rather than silently taking a dependency with it.
drop table public.player_inventory;

-- ═══ 7. THE THREE LEAVES, RE-POINTED AT PORT STORAGE ═════════════════════════════════════════════
-- The signature CHANGES on purpose. A balance, a spend and a deposit are always AT A PLACE, and
-- making the place a required argument is what turns law 2 from a rule into a shape: a caller
-- CANNOT ask "how much do I have" without saying where. The old signatures are dropped in the same
-- statement group, so there is never a moment with two answers.
drop function public.inventory_deposit(uuid, text, integer, text);
drop function public.inventory_spend(uuid, text, integer);
drop function public.inventory_get_balance(uuid, text);

-- ── inventory_deposit: add items to a PORT; idempotent when a key is provided ────────────────────
-- p_base NULL is legal and means "I have no port for this" — loot secured in open space. It falls
-- back to the oldest active base rather than raising, because NEVER DESTROY AN ASSET TO SATISFY A
-- RULE. Only when the player has no active base at all does it refuse, and then it refuses loudly.
create or replace function public.inventory_deposit(p_player uuid, p_base uuid, p_item text, p_qty integer, p_key text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base uuid := p_base;
begin
  if p_qty is null or p_qty <= 0 then raise exception 'inventory_deposit: invalid quantity %', p_qty; end if;
  if not exists (select 1 from item_types where item_id = p_item) then
    raise exception 'inventory_deposit: unknown item %', p_item;
  end if;

  if v_base is null then
    select b.id into v_base from public.bases b
      where b.player_id = p_player and b.status = 'active'
      order by b.created_at, b.id limit 1;
    if v_base is null then
      raise exception 'inventory_deposit: player % has no active port store to deposit % x% into', p_player, p_item, p_qty;
    end if;
  elsif not exists (select 1 from public.bases b where b.id = v_base and b.player_id = p_player) then
    -- A store belongs to exactly one player. Depositing into somebody else's is not a thing.
    raise exception 'inventory_deposit: store % does not belong to player %', v_base, p_player;
  end if;

  -- Idempotency: the ledger insert is the guard. A duplicate key is a no-op.
  if p_key is not null then
    insert into inventory_ledger (idempotency_key, player_id, base_id, item_id, quantity_delta, reason)
      values (p_key, p_player, v_base, p_item, p_qty, 'deposit')
      on conflict (idempotency_key) do nothing;
    if not found then return; end if;  -- already applied
  else
    insert into inventory_ledger (player_id, base_id, item_id, quantity_delta, reason)
      values (p_player, v_base, p_item, p_qty, 'deposit');
  end if;

  perform public.base_items_add(v_base, p_item, p_qty);
end;
$$;

-- ── inventory_spend: subtract items FROM A NAMED PORT; never negative ────────────────────────────
-- A NULL base REFUSES. This is the asymmetry the design demands: a deposit with nowhere to go must
-- not lose an asset, but a spend with nowhere to draw from is a law-3 violation wearing a NULL.
create or replace function public.inventory_spend(p_player uuid, p_base uuid, p_item text, p_qty integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_qty is null or p_qty <= 0 then raise exception 'inventory_spend: invalid quantity %', p_qty; end if;
  if not exists (select 1 from item_types where item_id = p_item) then
    raise exception 'inventory_spend: unknown item %', p_item;
  end if;
  if p_base is null then
    raise exception 'inventory_spend: a spend must name the port it draws from (law 3)';
  end if;
  if not exists (select 1 from public.bases b where b.id = p_base and b.player_id = p_player) then
    raise exception 'inventory_spend: store % does not belong to player %', p_base, p_player;
  end if;

  -- ONE authority for the balance check: base_items_take's FOR UPDATE re-check. This function does
  -- not re-implement it, so there is exactly one place a shortfall can be decided.
  perform public.base_items_take(p_base, p_item, p_qty);

  insert into inventory_ledger (player_id, base_id, item_id, quantity_delta, reason)
    values (p_player, p_base, p_item, -p_qty, 'spend');
end;
$$;

-- ── inventory_get_balance: how much is stored AT THIS PORT ───────────────────────────────────────
create or replace function public.inventory_get_balance(p_player uuid, p_base uuid, p_item text)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_qty integer;
begin
  if p_base is null then
    raise exception 'inventory_get_balance: a balance is always AT a port (law 2) — no port was named';
  end if;
  if not exists (select 1 from public.bases b where b.id = p_base and b.player_id = p_player) then
    raise exception 'inventory_get_balance: store % does not belong to player %', p_base, p_player;
  end if;
  select coalesce((select bi.quantity from public.base_items bi
                    where bi.base_id = p_base and bi.item_id = p_item), 0)
    into v_qty;
  return v_qty;
end;
$$;

revoke all on function public.inventory_deposit(uuid, uuid, text, integer, text) from public, anon, authenticated;
revoke all on function public.inventory_spend(uuid, uuid, text, integer)         from public, anon, authenticated;
revoke all on function public.inventory_get_balance(uuid, uuid, text)            from public, anon, authenticated;
grant execute on function public.inventory_deposit(uuid, uuid, text, integer, text) to service_role;
grant execute on function public.inventory_spend(uuid, uuid, text, integer)         to service_role;
grant execute on function public.inventory_get_balance(uuid, uuid, text)            to service_role;

-- ═══ 8. item_transfer_receipts — per-ship idempotency (the 0174 salvage_receipts shape) ══════════
create table public.item_transfer_receipts (
  receipt_id   uuid    primary key default gen_random_uuid(),
  main_ship_id uuid    not null references public.main_ship_instances (main_ship_id),  -- NEVER player_id
  request_id   uuid    not null,
  direction    text    not null check (direction in ('to_storage', 'to_hold')),
  item_id      text    not null references public.item_types (item_id),
  base_id      uuid    not null references public.bases (id),
  fleet_id     uuid    not null references public.fleets (id),      -- the hold the stack moved to/from
  location_id  uuid    not null references public.locations (id),   -- the port the move happened at
  qty          integer not null check (qty > 0),
  volume_m3    numeric not null check (volume_m3 > 0),              -- the moved volume, at move time
  created_at   timestamptz not null default now(),
  unique (main_ship_id, request_id)                                 -- per-ship idempotency key
);
create index item_transfer_receipts_main_ship_id_idx on public.item_transfer_receipts (main_ship_id);

alter table public.item_transfer_receipts enable row level security;
create policy "item_transfer_receipts_select_own" on public.item_transfer_receipts
  for select using (
    exists (
      select 1 from public.main_ship_instances m
      where m.main_ship_id = item_transfer_receipts.main_ship_id
        and m.player_id = auth.uid()
    )
  );
revoke all on table public.item_transfer_receipts from public, anon, authenticated;
grant select on table public.item_transfer_receipts to authenticated;

-- ═══ 9. transfer_items — THE ONE VERB THAT MOVES A STACK ═════════════════════════════════════════
--
-- ONE RPC, not two. The two directions share the ENTIRE spine — resolve the owned ship, take the
-- locks, resolve the dock server-side, resolve the fleet and the port's store, check the replay,
-- move, receipt. The direction decides two things only: which side is decremented, and whether the
-- capacity check applies.
--
-- LAW 3 IS ENFORCED BY CONSTRUCTION, NOT BY A CHECK: there is no p_location_id parameter. The port
-- is DERIVED from the ship's validated dock via mainship_resolve_docked_location — the one shared
-- resolver (0211), which itself goes through mainship_space_validate_context and accepts only
-- 'at_location'. A caller cannot name a port at all, so "withdraw from a port I am not docked at"
-- is not a request the surface can express.
--
-- REJECT ORDER (the 0174 charter's envelope order; each named):
--   not_authenticated -> station_storage_disabled (gate FIRST, before ANY read) -> invalid_request
--   -> invalid_direction -> invalid_item -> invalid_quantity -> ship_not_found -> [LOCKS]
--   -> not_docked -> port_has_no_storage -> idempotent_replay -> insufficient_items /
--   insufficient_stored -> hold_over_capacity -> ok
--
-- ATOMICITY: one function, one transaction. The take, the add and the receipt commit or roll back
-- TOGETHER — a stack can never be in both places or in neither.
--
-- CONCURRENCY: two locks, in this order. The per-PLAYER advisory lock (the 0078/0109/0112 house
-- idiom) comes first because the capacity check reads the WHOLE fleet hold and a player may drive
-- two ships of the same fleet; a per-ship lock alone would let both pass the check and land the
-- hold over capacity between them, and no leaf below can re-check a capacity. The per-SHIP row lock
-- comes second and protects the replay check against a concurrent transfer on the same ship.
create or replace function public.transfer_items(
  p_main_ship_id uuid, p_direction text, p_item_id text, p_quantity numeric, p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_ship     uuid;
  v_fleet    uuid;
  v_loc      uuid;
  v_store    uuid;
  v_qty      integer;
  v_vol      numeric;
  v_have     integer;
  v_used     numeric;
  v_cap      numeric;
  v_delta    numeric;
  v_existing public.item_transfer_receipts%rowtype;
  v_receipt  uuid;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- The gate this slice rides (0157). Reject deterministically BEFORE any ship/store/item read.
  if not public.cfg_bool('station_storage_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'station_storage_disabled');
  end if;

  if p_request_id is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_request');
  end if;
  if p_direction is null or p_direction not in ('to_storage', 'to_hold') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_direction');
  end if;
  if p_item_id is null or p_item_id = '' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_item');
  end if;
  -- Items are INTEGER quantities: null / non-positive / fractional all reject as invalid_quantity
  -- rather than rounding. The 1e6 cap keeps the integer cast safe (the 0040 magnitude posture).
  if p_quantity is null or p_quantity <= 0 or p_quantity <> floor(p_quantity) or p_quantity > 1000000 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_quantity');
  end if;
  v_qty := p_quantity::integer;

  -- The catalog volume. An unknown item falls out here (the column is NOT NULL with a CHECK (> 0),
  -- so a found row always yields a usable volume).
  select t.volume_m3 into v_vol from public.item_types t where t.item_id = p_item_id;
  if v_vol is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_item');
  end if;

  -- Resolve the SELECTED owned ship (ownership asserted server-side) or the sole ship (shim);
  -- UI selection is never trusted.
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then
    return jsonb_build_object('ok', false, 'reason', 'ship_not_found');
  end if;

  -- PLAYER LOCK FIRST (the 0078/0109/0112 house idiom: advisory, per-domain, per-player, taken
  -- BEFORE any row lock). See the CONCURRENCY note above for why the capacity check needs it.
  perform pg_advisory_xact_lock(hashtext('item_transfer'), hashtext(v_player::text));

  -- PER-SHIP LOCK (the 0090/0174 idiom): held to txn end, so the replay check and the receipt's
  -- (main_ship_id, request_id) key are race-safe against concurrent transfers on the SAME ship.
  perform public.mainship_space_lock_context(v_ship);

  -- LAW 3, SERVER-SIDE: the port comes from the ONE shared docked resolver. Never inlined, never
  -- the client, never a parameter.
  v_loc := public.mainship_resolve_docked_location(v_ship);
  if v_loc is null then
    return jsonb_build_object('ok', false, 'reason', 'not_docked');
  end if;

  -- THE HOLD: the ship's fleet, from the ONE ship->fleet resolver (0210). It cannot be null here —
  -- the docked resolver above goes through the same call and would already have returned null —
  -- so this collapses onto the same honest refusal rather than inventing a second reason code.
  v_fleet := public.mainship_resolve_fleet(v_ship);
  if v_fleet is null then
    return jsonb_build_object('ok', false, 'reason', 'not_docked');
  end if;

  -- Only a real dockable port carries a store (the canonical 6-part predicate, reused).
  if not public.is_home_port_eligible(v_loc) then
    return jsonb_build_object('ok', false, 'reason', 'port_has_no_storage', 'location_id', v_loc);
  end if;

  -- IDEMPOTENCY: a receipt for (ship, request_id) already exists -> replay verbatim, no write, no
  -- re-move (the 0174 semantics; no payload-conflict check).
  select * into v_existing from public.item_transfer_receipts
    where main_ship_id = v_ship and request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'idempotent_replay', true,
      'receipt_id', v_existing.receipt_id, 'direction', v_existing.direction,
      'item_id', v_existing.item_id, 'qty', v_existing.qty, 'volume_m3', v_existing.volume_m3,
      'location_id', v_existing.location_id,
      'hold_used_m3', public.fleet_hold_used_m3(v_fleet),
      'hold_capacity_m3', public.fleet_hold_capacity_m3(v_fleet));
  end if;

  -- The player's store AT THIS PORT (idempotent, race-safe; materializes an empty store on first
  -- dock exactly as get_my_docked_store already does).
  v_store := public.get_or_create_store(v_player, v_loc);

  v_delta := v_qty * v_vol;

  if p_direction = 'to_storage' then
    -- HOLD -> PORT. Always allowed on capacity grounds: it only ever REDUCES the hold's load, and
    -- it is the direction that puts items back where they LIVE.
    select coalesce(fi.quantity, 0) into v_have from public.fleet_items fi
      where fi.fleet_id = v_fleet and fi.item_id = p_item_id;
    v_have := coalesce(v_have, 0);
    if v_have < v_qty then
      return jsonb_build_object('ok', false, 'reason', 'insufficient_items',
        'item_id', p_item_id, 'have', v_have, 'need', v_qty);
    end if;
    perform public.fleet_items_take(v_fleet, p_item_id, v_qty);   -- the fleet-hold sole writer
    perform public.base_items_add(v_store, p_item_id, v_qty);     -- the port-store sole writer
  else
    -- PORT -> HOLD. This is the direction the capacity governs.
    select coalesce(bi.quantity, 0) into v_have from public.base_items bi
      where bi.base_id = v_store and bi.item_id = p_item_id;
    v_have := coalesce(v_have, 0);
    if v_have < v_qty then
      return jsonb_build_object('ok', false, 'reason', 'insufficient_stored',
        'item_id', p_item_id, 'have', v_have, 'need', v_qty, 'location_id', v_loc);
    end if;

    -- CAPACITY: REFUSE, never clamp. The player asked to move N; they get N or a refusal with the
    -- numbers, never a silent partial move they did not ask for.
    v_used := public.fleet_hold_used_m3(v_fleet);
    v_cap  := public.fleet_hold_capacity_m3(v_fleet);
    if v_used + v_delta > v_cap then
      return jsonb_build_object('ok', false, 'reason', 'hold_over_capacity',
        'item_id', p_item_id, 'qty', v_qty,
        'hold_used_m3', v_used, 'hold_capacity_m3', v_cap, 'delta_m3', v_delta,
        'hold_free_m3', greatest(v_cap - v_used, 0));
    end if;

    perform public.base_items_take(v_store, p_item_id, v_qty);    -- the port-store sole writer
    perform public.fleet_items_add(v_fleet, p_item_id, v_qty);    -- the fleet-hold sole writer
  end if;

  -- RECEIPT — the (main_ship_id, request_id) key finalizes idempotency atomically with the move.
  insert into public.item_transfer_receipts
    (main_ship_id, request_id, direction, item_id, base_id, fleet_id, location_id, qty, volume_m3)
    values (v_ship, p_request_id, p_direction, p_item_id, v_store, v_fleet, v_loc, v_qty, v_delta)
    returning receipt_id into v_receipt;

  return jsonb_build_object('ok', true, 'receipt_id', v_receipt,
    'direction', p_direction, 'item_id', p_item_id, 'qty', v_qty, 'volume_m3', v_delta,
    'location_id', v_loc,
    'hold_used_m3', public.fleet_hold_used_m3(v_fleet),
    'hold_capacity_m3', public.fleet_hold_capacity_m3(v_fleet));
end;
$$;

revoke execute on function public.transfer_items(uuid, text, text, numeric, uuid) from public, anon;
grant  execute on function public.transfer_items(uuid, text, text, numeric, uuid) to authenticated;

-- ═══ 10. get_my_hold — THE ONE AUTHORITY FOR THE HOLD ════════════════════════════════════════════
-- The hold is a PLACE, so it gets exactly one read authority, the same way the docked port has one
-- (get_my_docked_store). Every m3 number the player ever sees comes from here; the client computes
-- none of them, because a client-side second copy of the capacity formula is the drift this whole
-- migration exists to prevent.
--
-- It takes the SHIP (the sole-ship shim default) because the hold belongs to that ship's FLEET.
-- It is readable wherever the fleet is — the hold travels with it; only the PORT's storage is
-- location-gated.
create or replace function public.get_my_hold(p_main_ship_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_ship   uuid;
  v_fleet  uuid;
  v_items  jsonb;
  v_used   numeric;
  v_cap    numeric;
  c_empty  constant jsonb := '[]'::jsonb;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated',
      'items', c_empty, 'used_m3', 0, 'capacity_m3', 0, 'free_m3', 0, 'over_capacity', false);
  end if;

  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then
    return jsonb_build_object('ok', false, 'reason', 'ship_not_found',
      'items', c_empty, 'used_m3', 0, 'capacity_m3', 0, 'free_m3', 0, 'over_capacity', false);
  end if;

  v_fleet := public.mainship_resolve_fleet(v_ship);
  if v_fleet is null then
    return jsonb_build_object('ok', false, 'reason', 'no_fleet',
      'items', c_empty, 'used_m3', 0, 'capacity_m3', 0, 'free_m3', 0, 'over_capacity', false);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
             'item_id', fi.item_id, 'quantity', fi.quantity,
             'volume_m3', t.volume_m3, 'stack_m3', fi.quantity * t.volume_m3)
           order by fi.item_id), c_empty)
    into v_items
    from public.fleet_items fi
    join public.item_types t on t.item_id = fi.item_id
   where fi.fleet_id = v_fleet and fi.quantity > 0;

  v_used := public.fleet_hold_used_m3(v_fleet);
  v_cap  := public.fleet_hold_capacity_m3(v_fleet);

  return jsonb_build_object(
    'ok', true,
    'items', coalesce(v_items, c_empty),
    'used_m3', v_used,
    'capacity_m3', v_cap,
    'free_m3', greatest(v_cap - v_used, 0),
    -- An honest state, never an error: a fleet can lose ships and end up over capacity, and when it
    -- does it may still unload. The client says so instead of hiding it.
    'over_capacity', v_used > v_cap);
end;
$$;

revoke execute on function public.get_my_hold(uuid) from public, anon;
grant  execute on function public.get_my_hold(uuid) to authenticated;

-- ═══ 11. get_my_docked_store — the 0211:131-215 body; the port's ITEMS join the projection ═══════
-- PARITY: the body below is the textual head from 0211:131-215, byte-verified against the LIVE prod
-- definition (pg_get_functiondef, 2026-08-03) before slicing. TWO marked hunks, both purely
-- additive:
--   HUNK 1 — every one of the return envelopes gains an 'items' key. Uniform across all of them,
--            because this function's own header states the shape must be byte-identical on every
--            return so the client parser has ONE contract. Existing keys are untouched.
--   HUNK 2 — the docked-with-a-store branch reads base_items alongside base_resources/base_units,
--            in the same coalesce(jsonb_agg(... order by ...), c_empty) idiom, with the catalog
--            volume joined in so the panel never has to compute one.
-- Nothing else changes: not the dark gate, not the resolver chain, not the storeless-port branch,
-- not the ACL, not one existing key or literal.
create or replace function public.get_my_docked_store(p_main_ship_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player    uuid := auth.uid();
  v_ship      uuid;
  v_ctx       jsonb;
  v_ok        boolean;
  v_vstate    text;
  v_loc       uuid;
  v_name      text;
  v_store     uuid;
  v_resources jsonb;
  v_units     jsonb;
  v_items     jsonb;   -- ★ 0333 HUNK 2
  c_empty     constant jsonb := '[]'::jsonb;
begin
  if v_player is null then
    return jsonb_build_object('state','no_main_ship','docked',false,'location_id',null,'location_name',null,'store_id',null,'resources',c_empty,'units',c_empty,'items',c_empty);
  end if;

  -- DARK gate: feature off → inert empty surface (panel hidden), production byte-unchanged.
  if not cfg_bool('station_storage_enabled') then
    return jsonb_build_object('state','disabled','docked',false,'location_id',null,'location_name',null,'store_id',null,'resources',c_empty,'units',c_empty,'items',c_empty);
  end if;

  -- §2.5: resolve the SELECTED owned ship (explicit p_main_ship_id, ownership asserted server-side) or the
  -- sole ship (shim); UI selection is never trusted. Null (no ship / unowned / zero / ambiguous >1) → the
  -- existing no_main_ship projection, verbatim (was: \`where player_id = v_player\`, arbitrary at N>1).
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then
    return jsonb_build_object('state','no_main_ship','docked',false,'location_id',null,'location_name',null,'store_id',null,'resources',c_empty,'units',c_empty,'items',c_empty);
  end if;

  -- Canonical validated ship context (coherence-checked: fleet + presence + movement). SAME authority the
  -- dock-services read uses; never invents a dock from stale fields.
  v_ctx    := public.mainship_space_validate_context(v_ship);
  v_ok     := (v_ctx->>'ok')::boolean;
  v_vstate := v_ctx->>'state';

  if v_ok is true and v_vstate = 'at_location' then
    -- FLEET-GO 3c-2 (the ONE hunk): the dock comes from the ONE shared resolver instead of the inlined
    -- \`f.main_ship_id = <ship>\` read (NULL on a unified fleet — a docked group's hangar vanished).
    -- Dark → the resolver's per-ship fallback returns the exact row the inline read selected →
    -- byte-identical. Null keeps collapsing to the same incoherent envelope below.
    v_loc := public.mainship_resolve_docked_location(v_ship);
    if v_loc is null then
      return jsonb_build_object('state','incoherent_or_unavailable','docked',false,'location_id',null,'location_name',null,'store_id',null,'resources',c_empty,'units',c_empty,'items',c_empty);
    end if;

    select l.name into v_name from public.locations l where l.id = v_loc;

    -- Only a real dockable port carries a store (canonical 6-part predicate, reused). A docked-but-not-storable
    -- location returns docked=true with an empty, storeless surface (defensive — Dock-0 only docks eligible ports).
    if not public.is_home_port_eligible(v_loc) then
      return jsonb_build_object('state','at_location','docked',true,'location_id',v_loc,'location_name',v_name,'store_id',null,'resources',c_empty,'units',c_empty,'items',c_empty);
    end if;

    v_store := public.get_or_create_store(v_player, v_loc);

    select coalesce(jsonb_agg(jsonb_build_object('resource_code', r.resource_code, 'amount', r.amount)
                              order by r.resource_code), c_empty)
      into v_resources
      from public.base_resources r where r.base_id = v_store;

    select coalesce(jsonb_agg(jsonb_build_object('unit_type_id', u.unit_type_id, 'quantity', u.quantity)
                              order by u.unit_type_id), c_empty)
      into v_units
      from public.base_units u where u.base_id = v_store and u.quantity > 0;

    -- ★ 0333 HUNK 2: this port's own ITEM stock — where items LIVE — with the catalog volume carried
    -- so the panel shows what a withdrawal would cost in hold space without computing a volume.
    select coalesce(jsonb_agg(jsonb_build_object('item_id', i.item_id, 'quantity', i.quantity,
                                                 'volume_m3', t.volume_m3,
                                                 'stack_m3', i.quantity * t.volume_m3)
                              order by i.item_id), c_empty)
      into v_items
      from public.base_items i
      join public.item_types t on t.item_id = i.item_id
     where i.base_id = v_store and i.quantity > 0;

    return jsonb_build_object(
      'state','at_location','docked',true,
      'location_id',v_loc,'location_name',v_name,'store_id',v_store,
      'resources',coalesce(v_resources, c_empty),'units',coalesce(v_units, c_empty),
      'items',coalesce(v_items, c_empty));

  elsif v_ok is true and v_vstate in ('in_transit','in_space','destroyed') then
    return jsonb_build_object('state',v_vstate,'docked',false,'location_id',null,'location_name',null,'store_id',null,'resources',c_empty,'units',c_empty,'items',c_empty);
  else
    -- home / legacy_home / legacy_present / contradictory / unknown → no hangar surface.
    return jsonb_build_object('state','incoherent_or_unavailable','docked',false,'location_id',null,'location_name',null,'store_id',null,'resources',c_empty,'units',c_empty,'items',c_empty);
  end if;
end;
$$;

revoke all    on function public.get_my_docked_store(uuid) from public;
grant  execute on function public.get_my_docked_store(uuid) to authenticated;

-- ═══ 12. THE TEN CONSUMERS, RE-POINTED BY REPLACE-SURGERY OVER THEIR DEPLOYED DEFINITIONS ════════
-- Nothing below is retyped. Every \`old_t\` was SLICED VERBATIM out of the migration that is that
-- function's textual head (0040 / 0109 / 0126 / 0174 / 0188 / 0194 / 0235 — each proven to still BE
-- the head by the generator's own drift gate), and every \`new_t\` was CONSTRUCTED FROM THAT SLICE by
-- exactly-once string edits. The rewrite below proves each slice is still what is DEPLOYED (it must
-- occur EXACTLY ONCE in pg_get_functiondef) before replacing it — so a body that drifted since the
-- slice was cut aborts the deploy instead of being silently clobbered.
--
-- SIGNATURES: the three commands gain a ship and the three writers gain a port. The argument list
-- is READ BACK from pg_get_function_identity_arguments at deploy time and appended to — it is never
-- retyped either. The old signature is dropped immediately after the new one is created, so there
-- is never a moment when two overloads could make a call ambiguous.
do $rw$
declare
  r        record;
  s        record;
  v_oid    oid;
  v_src    text;
  v_n      integer;
  v_before integer;
  v_after  integer;
  v_args   text;
  v_head   text;
  v_defs   jsonb := '{}'::jsonb;
  v_fname  text;
begin
  -- (1) capture each function's deployed definition ONCE, keyed by name.
  for r in
    select distinct fname from (
      select unnest(array[
${HUNKS.map(([, f]) => `        '${f}'`).join(',\n')}
      ]) as fname) t
    order by fname
  loop
    select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.fname;
    if v_oid is null then
      raise exception '0333 REWRITE FAIL: function public.% not found', r.fname;
    end if;
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = r.fname) <> 1 then
      raise exception '0333 REWRITE FAIL: public.% is overloaded — refusing to guess', r.fname;
    end if;
    v_defs := v_defs || jsonb_build_object(r.fname, pg_get_functiondef(v_oid));
  end loop;

  -- (2) apply every body hunk, each exactly once, in index order.
  for r in
    select * from (values
${hunkRows}
    ) as t(idx, fname, old_t, new_t)
    order by idx
  loop
    v_src := v_defs->>r.fname;
    v_n := (length(v_src) - length(replace(v_src, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0333 REWRITE FAIL [%]: hunk source occurs % time(s) in public.% (expected exactly 1) — the deployed body drifted from the slice', r.idx, v_n, r.fname;
    end if;
    v_defs := jsonb_set(v_defs, array[r.fname], to_jsonb(replace(v_src, r.old_t, r.new_t)));
  end loop;

  -- (3) widen the six signatures, reading the current argument list back from the catalog.
  for s in
    select * from (values
${sigRows}
    ) as t(fname, add_arg, is_client)
    order by fname
  loop
    select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = s.fname;
    v_args := pg_get_function_identity_arguments(v_oid);
    v_head := 'public.' || s.fname || '(' || v_args || ')';
    v_src  := v_defs->>s.fname;
    v_n := (length(v_src) - length(replace(v_src, v_head, ''))) / length(v_head);
    if v_n <> 1 then
      raise exception '0333 REWRITE FAIL: the signature head % occurs % time(s) in its own definition (expected exactly 1)', v_head, v_n;
    end if;
    v_defs := jsonb_set(v_defs, array[s.fname],
      to_jsonb(replace(v_src, v_head, 'public.' || s.fname || '(' || v_args || ', ' || s.add_arg || ')')));
  end loop;

  -- (4) execute the rewritten definitions, then retire the old signatures.
  select count(*) into v_before from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public';

  for v_fname in select jsonb_object_keys(v_defs) order by 1 loop
    execute v_defs->>v_fname;
  end loop;

  for s in
    select * from (values
${sigRows}
    ) as t(fname, add_arg, is_client)
    order by fname
  loop
    -- The OLD signature is the one WITHOUT the added argument. Both exist for exactly this moment;
    -- dropping by explicit identity arguments can never take the new one by accident.
    for r in
      select p.oid, pg_get_function_identity_arguments(p.oid) as args
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = s.fname
    loop
      if position(split_part(s.add_arg, ' ', 1) in r.args) = 0 then
        execute format('drop function public.%I(%s)', s.fname, r.args);
      end if;
    end loop;
    -- and exactly ONE overload must survive, or a caller could bind the wrong one.
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = s.fname) <> 1 then
      raise exception '0333 REWRITE FAIL: public.% did not collapse to exactly one overload', s.fname;
    end if;
  end loop;

  select count(*) into v_after from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public';
  if v_after <> v_before then
    raise exception '0333 REWRITE FAIL: the public function count moved % -> % across the rewrite (expected no net change)', v_before, v_after;
  end if;

  raise notice '0333 REWRITE: % body hunk(s) over % function(s) and % signature widening(s), every hunk sliced verbatim from its own textual head and matched exactly once against the deployed body', ${HUNKS.length}, (select count(*) from jsonb_object_keys(v_defs) k), ${SIGS.length};
end $rw$;

-- The three client-facing commands keep their authenticated grant across the signature change
-- (a NEW signature carries no inherited ACL — the 0039 blanket revoke is the default here).
revoke execute on function public.craft_module(text, text, uuid)         from public, anon;
revoke execute on function public.recruit_captain(text, text, uuid)      from public, anon;
revoke execute on function public.start_hull_build(uuid, text, uuid)     from public, anon;
grant  execute on function public.craft_module(text, text, uuid)         to authenticated;
grant  execute on function public.recruit_captain(text, text, uuid)      to authenticated;
grant  execute on function public.start_hull_build(uuid, text, uuid)     to authenticated;
-- ...and the three private writers stay server-only.
revoke all on function public.production_craft_module(uuid, text, text, uuid)      from public, anon, authenticated;
revoke all on function public.production_recruit_captain(uuid, text, text, uuid)   from public, anon, authenticated;
revoke all on function public.production_start_hull_build(uuid, text, uuid, uuid)  from public, anon, authenticated;
grant execute on function public.production_craft_module(uuid, text, text, uuid)     to service_role;
grant execute on function public.production_recruit_captain(uuid, text, text, uuid)  to service_role;
grant execute on function public.production_start_hull_build(uuid, text, uuid, uuid) to service_role;

-- ═══ 13. A HULL ORDER MUST RECORD ITS STORE ══════════════════════════════════════════════════════
-- 0188:104-108 forced \`base_id IS NULL\` on hull orders, which is precisely why 0194's hull refund
-- arm — the ONLY refund path that returns ITEMS — had no port to return them to. Flip it: a hull
-- order now REQUIRES its store, exactly like a unit order. \`build_orders\` has zero rows on
-- production, so no existing row can fail the new CHECK, and the assert below proves it.
do $bo$
declare
  v_n integer;
begin
  select count(*) into v_n from public.build_orders where hull_type_id is not null and base_id is null;
  if v_n <> 0 then
    raise exception '0333 CHECK-FLIP FAIL: % hull order(s) carry no base_id — they would fail the new constraint and their item refund would have no port', v_n;
  end if;
end $bo$;

alter table public.build_orders drop constraint if exists build_orders_kind_coherent;
alter table public.build_orders add constraint build_orders_kind_coherent check (
  (hull_type_id is null and unit_type_id is not null and base_id is not null)
  or
  (hull_type_id is not null and unit_type_id is null and base_id is not null)
);

-- ═══ 14. The grant posture of every table this slice's invariant rests on ════════════════════════
-- All of these carry the Supabase project-default arwdDxtm for anon AND authenticated that no
-- migration ever revoked (verified on production 2026-08-03). RLS with no write policy denies the
-- writes today, so the write half is defense in depth — but the 2026-07-20 danger_zones abort, and
-- this migration's OWN rev.1 abort, are the standing lesson: a publish slice ESTABLISHES its
-- posture, it never merely asserts one. \`inventory_ledger\` is here specifically because it is the
-- idempotency guard for every keyed deposit: a client able to pre-insert an idempotency key could
-- make a legitimate deposit silently no-op.
--
-- Grepped the whole chain: \`grant\` on the two pre-existing tables appears in exactly two places,
-- both in 0039 —
--   0039:25  grant select on public.item_types       to anon, authenticated;   <- PUBLIC-READ catalog
--   0039:70  grant select on public.inventory_ledger to authenticated;
-- so revoking everything and re-issuing exactly those two lines lands on the migration-intended
-- state and strips only the project-default drift. (0039:52's \`player_inventory\` grant went with
-- the table.) Anything not re-granted below was never granted by any migration — it was inherited.
--
-- ⚠ item_types KEEPS its anon SELECT ON PURPOSE. It is Reference/Config with an \`using(true)\` read
-- policy (0039:24-25), the same posture as module_types/market_offers, and the client's catalog read
-- depends on it. A blind \`revoke all\` with no re-grant here would have been a self-inflicted outage
-- — which is exactly why this block enumerates a per-table INTENDED posture instead of applying one
-- rule to every table it touches.
revoke all on table public.inventory_ledger from public, anon, authenticated;
revoke all on table public.item_types       from public, anon, authenticated;

grant select on table public.inventory_ledger to authenticated;              -- 0039:70, verbatim
grant select on table public.item_types       to anon, authenticated;        -- 0039:25, verbatim

-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- SELF-ASSERTS — one DO block per check. Absence is FAILURE, never a pass.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── (a) every item type carries a POSITIVE volume, and the CHECK is present AND validated ────────
do $a$
declare
  v_n        integer;
  v_bad      integer;
  v_conv     boolean;
  v_default  text;
begin
  select count(*) into v_n from public.item_types;
  if v_n < 13 then
    raise exception '0333 (a) FAIL: expected at least the 13 seeded item types, found %', v_n;
  end if;

  -- LAW 1, established: not one row is volumeless or zero-volume.
  select count(*) into v_bad from public.item_types where volume_m3 is null or volume_m3 <= 0;
  if v_bad <> 0 then
    raise exception '0333 (a) FAIL: % item type(s) have no positive volume', v_bad;
  end if;

  -- the owner's five, pinned exactly as he gave them.
  if (select volume_m3 from public.item_types where item_id = 'ore')          <> 2.0
     or (select volume_m3 from public.item_types where item_id = 'crystal')      <> 1.0
     or (select volume_m3 from public.item_types where item_id = 'scrap')        <> 0.5
     or (select volume_m3 from public.item_types where item_id = 'weapon_parts') <> 0.2
     or (select volume_m3 from public.item_types where item_id = 'pirate_alloy') <> 0.5 then
    raise exception '0333 (a) FAIL: an owner-set volume does not match the value he gave';
  end if;

  -- the CHECK must EXIST and be VALIDATED (a NOT VALID constraint would let a bad row in later).
  select c.convalidated into v_conv
    from pg_constraint c
    where c.conrelid = 'public.item_types'::regclass
      and c.conname  = 'item_types_volume_m3_positive'
      and c.contype  = 'c';
  if v_conv is null then
    raise exception '0333 (a) FAIL: the volume_m3 > 0 CHECK is absent';
  end if;
  if v_conv is not true then
    raise exception '0333 (a) FAIL: the volume_m3 CHECK exists but is NOT VALIDATED';
  end if;

  -- the DEFAULT is what makes a future volumeless catalog row impossible.
  select column_default into v_default from information_schema.columns
    where table_schema = 'public' and table_name = 'item_types' and column_name = 'volume_m3';
  if v_default is null or position('1.0' in v_default) = 0 then
    raise exception '0333 (a) FAIL: volume_m3 has no 1.0 default — a new item type could arrive volumeless (got %)', coalesce(v_default, '<null>');
  end if;

  -- and the deployed CHECK, EVALUATED rather than re-typed: it must actually reject 0 and negatives.
  begin
    insert into public.item_types (item_id, name, category, volume_m3)
      values ('_0333_probe_', 'probe', 'material', 0);
    raise exception '0333 (a) FAIL: the deployed CHECK accepted volume_m3 = 0';
  exception when check_violation then
    null;  -- correct: the real constraint expression rejected it
  end;

  raise notice '0333 SELF-ASSERT (a) PASS: % item types, every one with a positive volume; the owner-set five pinned; CHECK present, validated and proven to reject zero; default 1.0 makes a volumeless item unrepresentable', v_n;
end $a$;

-- ── (b) the two stores mirror base_resources: shape, RLS, one owner-scoped SELECT policy ─────────
do $b$
declare
  v_n    integer;
  v_qual text;
  v_t    text;
  v_par  text;
  v_col  text;
begin
  foreach v_t in array array['base_items', 'fleet_items'] loop
    if to_regclass('public.' || v_t) is null then
      raise exception '0333 (b) FAIL: public.% was not created', v_t;
    end if;
    v_par := case v_t when 'base_items' then 'bases' else 'fleets' end;
    v_col := case v_t when 'base_items' then 'base_id' else 'fleet_id' end;

    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name=v_t and column_name=v_col
                      and data_type='uuid' and is_nullable='NO') then
      raise exception '0333 (b) FAIL: %.% is not the NOT NULL uuid key base_resources uses', v_t, v_col;
    end if;
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name=v_t and column_name='quantity'
                      and data_type='integer' and is_nullable='NO') then
      raise exception '0333 (b) FAIL: %.quantity is not NOT NULL integer', v_t;
    end if;

    -- ON DELETE CASCADE from the owner (base_resources' rule) — a deleted store/fleet takes its
    -- items with it rather than leaving orphans nobody can reach.
    if not exists (
      select 1 from pg_constraint c
       where c.conrelid = ('public.' || v_t)::regclass and c.contype = 'f'
         and c.confrelid = ('public.' || v_par)::regclass and c.confdeltype = 'c') then
      raise exception '0333 (b) FAIL: %.% does not cascade from % the way base_resources does', v_t, v_col, v_par;
    end if;

    -- FK on item_types: an item id that is not in the catalog (and so has no volume) is unstorable.
    if not exists (
      select 1 from pg_constraint c
       where c.conrelid = ('public.' || v_t)::regclass and c.contype = 'f'
         and c.confrelid = 'public.item_types'::regclass) then
      raise exception '0333 (b) FAIL: %.item_id is not FK-bound to item_types — an uncatalogued (volumeless) item could be stored', v_t;
    end if;

    -- one stack per (place, item).
    if not exists (
      select 1 from pg_constraint c
       where c.conrelid = ('public.' || v_t)::regclass and c.contype = 'u'
         and c.conkey @> array[
               (select attnum from pg_attribute where attrelid=('public.' || v_t)::regclass and attname=v_col),
               (select attnum from pg_attribute where attrelid=('public.' || v_t)::regclass and attname='item_id')]::smallint[]) then
      raise exception '0333 (b) FAIL: % has no unique (%, item_id) — one place could hold two stacks of one item', v_t, v_col;
    end if;

    -- RLS on, EXACTLY one policy, and it is a SELECT policy (no write policy may ever appear).
    if not (select relrowsecurity from pg_class where oid = ('public.' || v_t)::regclass) then
      raise exception '0333 (b) FAIL: RLS is not enabled on %', v_t;
    end if;
    select count(*) into v_n from pg_policies where schemaname='public' and tablename=v_t;
    if v_n <> 1 then
      raise exception '0333 (b) FAIL: % has % policies, expected exactly 1 (the owner-scoped SELECT)', v_t, v_n;
    end if;
    if not exists (select 1 from pg_policies where schemaname='public' and tablename=v_t and cmd='SELECT') then
      raise exception '0333 (b) FAIL: the one % policy is not a SELECT policy', v_t;
    end if;

    -- ...and the policy's EXPRESSION actually scopes to the owner. A policy that exists but reads
    -- \`using (true)\` is a DIFFERENT failure from a missing one, and would leak every player's
    -- storage to every other player. Read the deployed qual; do not trust the policy's name.
    select pg_get_expr(p.polqual, p.polrelid) into v_qual
      from pg_policy p where p.polrelid = ('public.' || v_t)::regclass;
    if v_qual is null then
      raise exception '0333 (b) FAIL: the % SELECT policy has no USING expression — it would admit every row', v_t;
    end if;
    if position('auth.uid()' in v_qual) = 0 or position('player_id' in v_qual) = 0
       or position(v_par in v_qual) = 0 then
      raise exception '0333 (b) FAIL: the % SELECT policy does not scope through %.player_id = auth.uid() (got: %)', v_t, v_par, v_qual;
    end if;
  end loop;

  -- the same for the receipt ledger: RLS on, exactly one SELECT policy, scoped through the ship.
  if not (select relrowsecurity from pg_class where oid = 'public.item_transfer_receipts'::regclass) then
    raise exception '0333 (b) FAIL: RLS is not enabled on item_transfer_receipts';
  end if;
  select count(*) into v_n from pg_policies where schemaname='public' and tablename='item_transfer_receipts';
  if v_n <> 1 then
    raise exception '0333 (b) FAIL: item_transfer_receipts has % policies, expected exactly 1', v_n;
  end if;
  select pg_get_expr(p.polqual, p.polrelid) into v_qual
    from pg_policy p where p.polrelid = 'public.item_transfer_receipts'::regclass;
  if v_qual is null or position('auth.uid()' in v_qual) = 0 or position('main_ship_instances' in v_qual) = 0 then
    raise exception '0333 (b) FAIL: the item_transfer_receipts policy does not scope through the owning ship (got: %)', coalesce(v_qual,'<null>');
  end if;

  raise notice '0333 SELF-ASSERT (b) PASS: base_items and fleet_items both mirror base_resources — cascade from their owner, FK to item_types, one stack per (place,item); all three new tables have RLS on with exactly one SELECT policy whose DEPLOYED expression really scopes to the owner';
end $b$;

-- ── (c) ACLs, ESTABLISHED above and asserted here ────────────────────────────────────────────────
do $c$
declare
  v_g         text;
  v_bad       text;
  v_n         bigint;
  v_prev_role text;
begin
  -- the two client RPCs: authenticated YES, anon/public NO.
  if not has_function_privilege('authenticated', 'public.transfer_items(uuid,text,text,numeric,uuid)', 'execute') then
    raise exception '0333 (c) FAIL: transfer_items is not executable by authenticated';
  end if;
  if has_function_privilege('anon', 'public.transfer_items(uuid,text,text,numeric,uuid)', 'execute')
     or has_function_privilege('public', 'public.transfer_items(uuid,text,text,numeric,uuid)', 'execute') then
    raise exception '0333 (c) FAIL: transfer_items is reachable by anon/public';
  end if;
  if not has_function_privilege('authenticated', 'public.get_my_hold(uuid)', 'execute') then
    raise exception '0333 (c) FAIL: get_my_hold is not executable by authenticated';
  end if;
  if has_function_privilege('anon', 'public.get_my_hold(uuid)', 'execute')
     or has_function_privilege('public', 'public.get_my_hold(uuid)', 'execute') then
    raise exception '0333 (c) FAIL: get_my_hold is reachable by anon/public';
  end if;
  -- the carried-through 0211 ACL on the re-created read.
  if not has_function_privilege('authenticated', 'public.get_my_docked_store(uuid)', 'execute') then
    raise exception '0333 (c) FAIL: the re-created get_my_docked_store lost its authenticated grant';
  end if;
  -- the three re-signatured commands kept theirs.
  foreach v_g in array array['public.craft_module(text,text,uuid)',
                             'public.recruit_captain(text,text,uuid)',
                             'public.start_hull_build(uuid,text,uuid)'] loop
    if not has_function_privilege('authenticated', v_g, 'execute') then
      raise exception '0333 (c) FAIL: % lost its authenticated grant across the signature change', v_g;
    end if;
    if has_function_privilege('anon', v_g, 'execute') or has_function_privilege('public', v_g, 'execute') then
      raise exception '0333 (c) FAIL: % is reachable by anon/public', v_g;
    end if;
  end loop;

  -- the leaves are SERVER-ONLY. A client-callable base_items_add would be an item printer.
  foreach v_g in array array['public.base_items_add(uuid,text,integer)',
                             'public.base_items_take(uuid,text,integer)',
                             'public.fleet_items_add(uuid,text,integer)',
                             'public.fleet_items_take(uuid,text,integer)',
                             'public.fleet_hold_capacity_m3(uuid)',
                             'public.fleet_hold_used_m3(uuid)',
                             'public.inventory_deposit(uuid,uuid,text,integer,text)',
                             'public.inventory_spend(uuid,uuid,text,integer)',
                             'public.inventory_get_balance(uuid,uuid,text)',
                             'public.production_craft_module(uuid,text,text,uuid)',
                             'public.production_recruit_captain(uuid,text,text,uuid)',
                             'public.production_start_hull_build(uuid,text,uuid,uuid)'] loop
    if has_function_privilege('anon', v_g, 'execute')
       or has_function_privilege('authenticated', v_g, 'execute')
       or has_function_privilege('public', v_g, 'execute') then
      raise exception '0333 (c) FAIL: leaf % is client-callable', v_g;
    end if;
    if not has_function_privilege('service_role', v_g, 'execute') then
      raise exception '0333 (c) FAIL: leaf % is not executable by service_role', v_g;
    end if;
  end loop;

  -- ── THE WHOLE TABLE MATRIX, not just the write half. ──────────────────────────────────────────
  -- rev.1 checked three verbs and shipped; the project default grants EIGHT, and the deploy died on
  -- the SELECT it never revoked. So: every verb the default can carry x every client grantee, 5
  -- tables x 8 verbs x 3 grantees = 120 assertions, and each one is measured against a stated
  -- INTENDED posture rather than against whatever happened to be inherited.
  -- has_table_privilege is the check — it folds in privilege held via the PUBLIC pseudo-role, which
  -- information_schema.role_table_grants and a naive read of pg_class.relacl both miss (0309).
  --
  -- NOT-ALLOWED = everything, for every client grantee, on every one of the five tables...
  select string_agg(t || '.' || v || ' [' || r || ']', ', ' order by t, v, r) into v_bad
    from unnest(array['base_items', 'fleet_items', 'item_transfer_receipts',
                      'item_types', 'inventory_ledger'])                             as t
   cross join unnest(array['INSERT','SELECT','UPDATE','DELETE',
                           'TRUNCATE','REFERENCES','TRIGGER','MAINTAIN'])              as v
   cross join unnest(array['anon', 'authenticated', 'public'])                         as r
   where has_table_privilege(r, 'public.' || t, v)
     -- ...EXCEPT the reads a migration deliberately established (0039:25/70) and the three this
     -- slice establishes for its own new tables. Anything outside this allow-list is drift.
     and not (v = 'SELECT' and r = 'authenticated')                       -- all five: owner-scoped read
     and not (v = 'SELECT' and r = 'anon' and t = 'item_types');          -- the PUBLIC-READ catalog
  if v_bad is not null then
    raise exception '0333 (c) FAIL: privilege OUTSIDE the intended posture survives on: %', v_bad;
  end if;

  -- ...and the reads that MUST survive really did. A revoke that took too much is as broken as one
  -- that took too little — it would blind the hangar or the item catalog.
  select string_agg(t || ' [authenticated]', ', ' order by t) into v_bad
    from unnest(array['base_items', 'fleet_items', 'item_transfer_receipts',
                      'item_types', 'inventory_ledger']) as t
   where not has_table_privilege('authenticated', 'public.' || t, 'SELECT');
  if v_bad is not null then
    raise exception '0333 (c) FAIL: the revoke took an authenticated SELECT it must keep — lost on: %', v_bad;
  end if;
  if not has_table_privilege('anon', 'public.item_types', 'SELECT') then
    raise exception '0333 (c) FAIL: the revoke took anon SELECT on item_types — it is a PUBLIC-READ Reference/Config catalog (0039:24-25) and the client catalog read would break';
  end if;

  -- ── AND THE SAME QUESTION ANSWERED BY EXECUTION, not by reading a catalog. ────────────────────
  -- has_table_privilege reports what the ACL says; this proves what the database DOES. Each probe
  -- BECOMES the anon seat and tries the read. Permission denied (42501) is the pass. If the grant
  -- were still open the select would SUCCEED — and RLS would hand back zero rows, so a row-count
  -- check would be fooled into calling that safe — which is why the probe asserts on the RAISE, not
  -- on the count. Same "evaluate the deployed rule, never re-type it" shape as the volume CHECK.
  --
  -- Verified on production before relying on any of it (2026-08-03): PostgreSQL 17.6, so MAINTAIN is
  -- a real privilege verb; anon/authenticated/service_role all exist; \`postgres\` is a member of anon
  -- WITH ADMIN OPTION, so the deploy role can assume the seat; and \`postgres\` carries BYPASSRLS,
  -- which the seat change correctly drops.
  --
  -- The role is restored via set_config('role', <saved>, true) rather than RESET ROLE: RESET returns
  -- to the SESSION user, which is only the same thing if the deploy connected as the role it is
  -- currently running as. Saving and restoring the actual GUC is exact under any connection shape.
  v_prev_role := current_setting('role');   -- 'none' when no SET ROLE is active

  begin
    set local role anon;
    execute 'select count(*) from public.base_items' into v_n;
    perform set_config('role', v_prev_role, true);
    raise exception '0333 (c) FAIL: the anon seat could SELECT base_items — the table grant is still open (RLS returning 0 rows is NOT the boundary being asserted)';
  exception
    when insufficient_privilege then
      perform set_config('role', v_prev_role, true);   -- the pass: the grant is genuinely gone
  end;

  begin
    set local role anon;
    execute 'select count(*) from public.fleet_items' into v_n;
    perform set_config('role', v_prev_role, true);
    raise exception '0333 (c) FAIL: the anon seat could SELECT fleet_items';
  exception
    when insufficient_privilege then
      perform set_config('role', v_prev_role, true);
  end;

  -- THE POSITIVE CONTROL. Without it the two probes above would pass for a reason that has nothing
  -- to do with this migration — an anon seat that cannot read anything at all, or a probe that never
  -- actually changed seat, produces the same 42501. anon MUST still reach the PUBLIC-READ catalog.
  begin
    set local role anon;
    execute 'select count(*) from public.item_types' into v_n;
    perform set_config('role', v_prev_role, true);
  exception
    when insufficient_privilege then
      perform set_config('role', v_prev_role, true);
      raise exception '0333 (c) FAIL: the anon seat CANNOT read item_types — either the catalog grant was lost, or the two probes above passed vacuously because the seat can read nothing at all';
  end;

  -- and prove the seat was really restored, or every later statement in this migration would run as
  -- anon and fail in a way that points nowhere near here.
  if current_setting('role') is distinct from v_prev_role then
    raise exception '0333 (c) FAIL: the anon probes did not restore the role (now %, expected %)', current_setting('role'), v_prev_role;
  end if;

  raise notice '0333 SELF-ASSERT (c) PASS: transfer_items + get_my_hold authenticated-only, the three commands kept their grant across the signature change, twelve leaves service-role only; ALL EIGHT privileges checked across 5 tables x 3 client grantees (120 assertions) against a stated intended posture, not against whatever was inherited; the authenticated reads and the item_types PUBLIC-READ catalog both survived; and the anon SEAT was made to try the reads for real — denied on base_items and fleet_items, allowed on item_types as the positive control';
end $c$;

-- ── (d) transfer_items composes the ONE authority for every fact, and acquires no second one ─────
do $d$
declare
  v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'transfer_items';
  if v_src is null then
    raise exception '0333 (d) FAIL: transfer_items is absent';
  end if;
  -- strip comments so no probe below can be satisfied by prose alone (the 0222 vacuity lesson).
  v_src := regexp_replace(v_src, '--[^\\n]*', '', 'g');

  -- LAW 3: the dock comes from the ONE shared resolver, and the surface CANNOT name a port.
  if position('mainship_resolve_docked_location(' in v_src) = 0 then
    raise exception '0333 (d) FAIL: transfer_items does not resolve the dock through the one shared resolver';
  end if;
  -- Not a text probe of the body: the SIGNATURE ITSELF, read from the catalog, must carry no
  -- location-shaped argument. This is what makes law 3 unexpressable rather than merely checked.
  if (select pg_get_function_identity_arguments(p.oid)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname='public' and p.proname='transfer_items') ilike '%location%' then
    raise exception '0333 (d) FAIL: transfer_items has a location-shaped parameter — law 3 must be unexpressable, not merely checked';
  end if;
  if (select pg_get_function_identity_arguments(p.oid)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname='public' and p.proname='transfer_items')
     is distinct from 'p_main_ship_id uuid, p_direction text, p_item_id text, p_quantity numeric, p_request_id uuid' then
    raise exception '0333 (d) FAIL: transfer_items signature drifted from the one this slice established (got %)',
      (select pg_get_function_identity_arguments(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
        where n.nspname='public' and p.proname='transfer_items');
  end if;

  -- ownership, the locks, the fleet, the port predicate and the store all come from the existing
  -- authorities — transfer_items invents none of them.
  if position('mainship_resolve_owned_ship(' in v_src) = 0 then
    raise exception '0333 (d) FAIL: transfer_items does not assert ownership through the one resolver';
  end if;
  if position('mainship_resolve_fleet(' in v_src) = 0 then
    raise exception '0333 (d) FAIL: transfer_items does not resolve the hold through the one ship->fleet resolver';
  end if;
  if position('mainship_space_lock_context(' in v_src) = 0 then
    raise exception '0333 (d) FAIL: transfer_items does not take the per-ship lock';
  end if;
  if position('pg_advisory_xact_lock(hashtext(''item_transfer'')' in v_src) = 0 then
    raise exception '0333 (d) FAIL: transfer_items does not take the per-player advisory lock — the capacity check would not be authoritative across a fleet''s ships';
  end if;
  -- ORDER MATTERS (the 0112:30 law): the advisory lock is taken BEFORE any row lock, or two
  -- transactions can acquire them in opposite orders and deadlock.
  if position('pg_advisory_xact_lock(' in v_src) > position('mainship_space_lock_context(' in v_src) then
    raise exception '0333 (d) FAIL: the per-ship row lock is taken BEFORE the per-player advisory lock — inverted lock order';
  end if;
  if position('is_home_port_eligible(' in v_src) = 0 then
    raise exception '0333 (d) FAIL: transfer_items does not reuse the canonical port predicate';
  end if;
  if position('get_or_create_store(' in v_src) = 0 then
    raise exception '0333 (d) FAIL: transfer_items does not resolve the store through the one resolver';
  end if;
  if position('auth.uid()' in v_src) = 0 then
    raise exception '0333 (d) FAIL: transfer_items does not derive the actor from auth.uid()';
  end if;

  -- the writes go through the sole writers and through NOTHING else.
  if position('fleet_items_add(' in v_src) = 0 or position('fleet_items_take(' in v_src) = 0 then
    raise exception '0333 (d) FAIL: transfer_items does not move the hold through the fleet_items sole writers';
  end if;
  if position('base_items_add(' in v_src) = 0 or position('base_items_take(' in v_src) = 0 then
    raise exception '0333 (d) FAIL: transfer_items does not move the port stock through the base_items sole writers';
  end if;
  if v_src ~* '(insert\\s+into|update|delete\\s+from)\\s+public\\.(base_items|fleet_items)' then
    raise exception '0333 (d) FAIL: transfer_items writes a store directly — a second writer';
  end if;
  -- and it touches nothing outside its own domain.
  if v_src ~* '(insert\\s+into|update|delete\\s+from)\\s+public\\.(base_resources|base_units|ship_cargo_lots|player_wallet|main_ship_instances|fleets)' then
    raise exception '0333 (d) FAIL: transfer_items writes a table outside the item-transfer domain';
  end if;

  -- capacity is REFUSED, never clamped: the reject envelope exists and no clamping verb appears.
  if position('hold_over_capacity' in v_src) = 0 then
    raise exception '0333 (d) FAIL: transfer_items has no over-capacity refusal';
  end if;
  if v_src ~* 'least\\s*\\(\\s*v_qty' or v_src ~* 'v_qty\\s*:=\\s*least' then
    raise exception '0333 (d) FAIL: transfer_items clamps the quantity instead of refusing';
  end if;

  -- idempotency is the receipt key, not a best-effort guess.
  if position('item_transfer_receipts' in v_src) = 0 or position('idempotent_replay' in v_src) = 0 then
    raise exception '0333 (d) FAIL: transfer_items is not receipt-idempotent';
  end if;

  raise notice '0333 SELF-ASSERT (d) PASS: transfer_items composes the docked/ownership/fleet/lock/port/store authorities, moves both sides only through their sole writers, cannot name a port at all, refuses over-capacity without clamping, and is receipt-idempotent';
end $d$;

-- ── (e) get_my_docked_store carried through every 0211 invariant ─────────────────────────────────
do $e$
declare
  v_src text;
  v_n   integer;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_my_docked_store';
  if v_src is null then
    raise exception '0333 (e) FAIL: get_my_docked_store is absent';
  end if;
  v_src := regexp_replace(v_src, '--[^\\n]*', '', 'g');

  -- EIGHT return envelopes (0211 had eight: two no_main_ship, disabled, the null-dock incoherent,
  -- the storeless port, the full docked return, the in_transit/in_space/destroyed branch and the
  -- else) plus the THREE aggregate builders in the docked branch = exactly 11 sites. Any other
  -- number means a branch was lost or duplicated in the re-create.
  select count(*) into v_n from regexp_matches(v_src, 'jsonb_build_object\\(', 'g');
  if v_n <> 11 then
    raise exception '0333 (e) FAIL: the re-created body has % jsonb_build_object sites, expected exactly 11 — a return branch was lost or duplicated', v_n;
  end if;

  -- every carried-through state literal must still be emitted.
  if position('''no_main_ship''' in v_src) = 0
     or position('''disabled''' in v_src) = 0
     or position('''at_location''' in v_src) = 0
     or position('''incoherent_or_unavailable''' in v_src) = 0
     or position('''in_transit''' in v_src) = 0
     or position('''in_space''' in v_src) = 0
     or position('''destroyed''' in v_src) = 0 then
    raise exception '0333 (e) FAIL: a 0211 state literal is missing from the re-created body';
  end if;

  -- the dark gate, the resolver chain and the port predicate all survived.
  if position('cfg_bool(''station_storage_enabled'')' in v_src) = 0 then
    raise exception '0333 (e) FAIL: the station_storage_enabled gate was lost';
  end if;
  if position('mainship_resolve_owned_ship(' in v_src) = 0
     or position('mainship_space_validate_context(' in v_src) = 0
     or position('mainship_resolve_docked_location(' in v_src) = 0
     or position('is_home_port_eligible(' in v_src) = 0
     or position('get_or_create_store(' in v_src) = 0 then
    raise exception '0333 (e) FAIL: a 0211 resolver was lost from the re-created body';
  end if;

  -- the existing projections are untouched.
  if position('base_resources' in v_src) = 0 or position('base_units' in v_src) = 0 then
    raise exception '0333 (e) FAIL: the resources/units projections were lost';
  end if;

  -- HUNK 1: the 'items' key is on EVERY return, so the client parser keeps ONE contract — exactly
  -- eight emissions, one per envelope. Fewer means an envelope shape diverged.
  select count(*) into v_n from regexp_matches(v_src, '''items''', 'g');
  if v_n <> 8 then
    raise exception '0333 (e) FAIL: the items key appears on % sites, expected exactly 8 — it is not uniform across every envelope', v_n;
  end if;

  -- HUNK 2: the port's item stock is read from base_items, joined to the catalog for the volume.
  if position('public.base_items' in v_src) = 0 then
    raise exception '0333 (e) FAIL: the docked branch does not read base_items';
  end if;
  if position('volume_m3' in v_src) = 0 then
    raise exception '0333 (e) FAIL: the item projection carries no volume — the panel would have to compute one';
  end if;

  -- it acquired no write authority: a read function must stay a read function (get_or_create_store's
  -- lazy store materialization is the one pre-existing exception, unchanged from 0211).
  if v_src ~* '(insert\\s+into|update|delete\\s+from)\\s+public\\.(base_items|fleet_items|base_resources|base_units)' then
    raise exception '0333 (e) FAIL: the re-created read acquired a write';
  end if;

  raise notice '0333 SELF-ASSERT (e) PASS: get_my_docked_store kept all six branches, every state literal, the dark gate and the whole resolver chain; the items key is uniform across every envelope and the docked branch reads base_items with the catalog volume';
end $e$;

-- ── (f) the capacity is DERIVED from one source, is FLEET-scoped, and no second one exists ───────
do $f$
declare
  v_cap  text;
  v_used text;
  v_n    integer;
begin
  select pg_get_functiondef(p.oid) into v_cap
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='fleet_hold_capacity_m3';
  select pg_get_functiondef(p.oid) into v_used
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='fleet_hold_used_m3';
  if v_cap is null or v_used is null then
    raise exception '0333 (f) FAIL: a capacity leaf is absent';
  end if;
  v_cap  := regexp_replace(v_cap,  '--[^\\n]*', '', 'g');
  v_used := regexp_replace(v_used, '--[^\\n]*', '', 'g');

  -- capacity reads cargo_capacity_m3, is keyed on the FLEET, and excludes wrecks.
  if position('cargo_capacity_m3' in v_cap) = 0 then
    raise exception '0333 (f) FAIL: fleet_hold_capacity_m3 does not read cargo_capacity_m3';
  end if;
  if position('public.fleets' in v_cap) = 0 then
    raise exception '0333 (f) FAIL: fleet_hold_capacity_m3 is not keyed on the fleet — a player-wide hold teleports goods between fleets in different ports';
  end if;
  if position('destroyed' in v_cap) = 0 then
    raise exception '0333 (f) FAIL: fleet_hold_capacity_m3 counts destroyed ships';
  end if;
  -- and it reads the DEAD integer columns from 0043 nowhere (they are a lookalike trap).
  if position('cargo_capacity ' in v_cap) <> 0 or position('cargo_used' in v_cap) <> 0 then
    raise exception '0333 (f) FAIL: fleet_hold_capacity_m3 reads the dead 0043 cargo columns';
  end if;

  -- occupancy reads the catalog volume, and only the hold.
  if position('volume_m3' in v_used) = 0 or position('fleet_items' in v_used) = 0 then
    raise exception '0333 (f) FAIL: fleet_hold_used_m3 is not the item-volume fold over the fleet hold';
  end if;

  -- NO STORED CAPACITY COLUMN may exist anywhere — a stored copy is the drift this prevents.
  select count(*) into v_n from information_schema.columns
   where table_schema='public' and column_name in ('hold_capacity_m3','hold_used_m3','hold_capacity');
  if v_n <> 0 then
    raise exception '0333 (f) FAIL: % stored hold-capacity column(s) exist — capacity must be derived, never stored', v_n;
  end if;

  -- and NO PLAYER-WIDE capacity leaf survives: rev.2 shipped one, and it is the exact thing the
  -- owner corrected. Two answers to "how big is my hold" is the disease.
  if to_regprocedure('public.hold_capacity_m3(uuid)') is not null
     or to_regprocedure('public.hold_used_m3(uuid)') is not null then
    raise exception '0333 (f) FAIL: a player-wide hold capacity leaf exists — the hold is per-FLEET and may have exactly one authority';
  end if;

  -- market_buy is left BYTE-UNTOUCHED: trade cargo keeps its own per-ship check (see the header).
  if to_regprocedure('public.market_buy(uuid,text,numeric,uuid)') is not null then
    if (select position('ship_cargo_lots' in pg_get_functiondef(to_regprocedure('public.market_buy(uuid,text,numeric,uuid)')::oid))) = 0 then
      raise exception '0333 (f) FAIL: market_buy no longer checks ship_cargo_lots — this migration must not have touched it';
    end if;
  end if;

  raise notice '0333 SELF-ASSERT (f) PASS: hold capacity is DERIVED from cargo_capacity_m3 over a FLEET''s non-destroyed ships, occupancy from item_types.volume_m3 over that fleet''s hold; no stored capacity column and no player-wide leaf exists; market_buy untouched';
end $f$;

-- ── (g) ONE AUTHORITY PER PLACE: the pool is gone and nothing replaced it ────────────────────────
do $g$
declare
  v_bad  text;
  v_src  text;
  v_name text;
begin
  -- THE GLOBAL POOL IS GONE. Not deprecated, not left beside the new model — gone.
  if to_regclass('public.player_inventory') is not null then
    raise exception '0333 (g) FAIL: public.player_inventory still exists — a feature that ships while its predecessor stays live is spaghetti by construction';
  end if;
  -- ...and no function still READS OR WRITES it. Line comments are stripped first: several bodies
  -- carry a prose reference ("the sole player_inventory writer") that is documentation, not a
  -- dependency, and failing on prose would be the 0222 vacuity bug wearing the opposite mask.
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and regexp_replace(p.prosrc, '--[^\\n]*', '', 'g')
         ~* '(from|into|update|join)\\s+(public\\.)?player_inventory';
  if v_bad is not null then
    raise exception '0333 (g) FAIL: these functions still read or write the deleted global pool: %', v_bad;
  end if;

  -- THE THREE LEAVES ALL TAKE A PORT. A balance, a spend and a deposit are always AT A PLACE.
  foreach v_name in array array['inventory_deposit', 'inventory_spend', 'inventory_get_balance'] loop
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = v_name) <> 1 then
      raise exception '0333 (g) FAIL: public.% is not exactly one function — an old placeless overload survived', v_name;
    end if;
    if (select pg_get_function_identity_arguments(p.oid)
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = v_name) not like '%p_base uuid%' then
      raise exception '0333 (g) FAIL: public.% does not take a port — law 2 would be a rule instead of a shape', v_name;
    end if;
  end loop;

  -- THE SOLE-WRITER LAW, proven by reading every function in the schema rather than by assertion:
  -- only the named leaves may write base_items / fleet_items.
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname not in ('base_items_add', 'base_items_take', 'fleet_items_add', 'fleet_items_take')
     and p.prosrc ~* '(insert\\s+into|update|delete\\s+from)\\s+(public\\.)?(base_items|fleet_items)';
  if v_bad is not null then
    raise exception '0333 (g) FAIL: these functions write a store directly instead of through its sole writer: %', v_bad;
  end if;

  -- A SPEND MUST NAME ITS PORT — proven by EVALUATING the deployed rule, not by reading it.
  begin
    perform public.inventory_spend('00000000-0000-0000-0000-000000000000'::uuid, null, 'scrap', 1);
    raise exception '0333 (g) FAIL: inventory_spend accepted a NULL port — remote retrieval would be expressible';
  exception when raise_exception then
    if position('must name the port' in sqlerrm) = 0 then
      raise exception '0333 (g) FAIL: inventory_spend refused a NULL port for the wrong reason: %', sqlerrm;
    end if;
  end;

  -- ...and a DEPOSIT must never strand: the same NULL is legal and falls back, so the only way it
  -- can fail is a player with no active base at all.
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'inventory_deposit';
  if position('order by b.created_at' in v_src) = 0 then
    raise exception '0333 (g) FAIL: inventory_deposit has no oldest-active-base fallback — a deposit with no port would strand or destroy an asset';
  end if;

  -- THE HULL ORDER RECORDS ITS STORE, so the refund has somewhere to go.
  if not exists (
    select 1 from pg_constraint
     where conname = 'build_orders_kind_coherent' and conrelid = 'public.build_orders'::regclass
       and contype = 'c') then
    raise exception '0333 (g) FAIL: build_orders_kind_coherent is missing';
  end if;
  if position('base_id IS NULL' in (
       select pg_get_constraintdef(oid) from pg_constraint
        where conname = 'build_orders_kind_coherent' and conrelid = 'public.build_orders'::regclass)) <> 0 then
    raise exception '0333 (g) FAIL: build_orders_kind_coherent still allows a hull order with no base_id — its item refund would have no port BY CONSTRUCTION';
  end if;

  raise notice '0333 SELF-ASSERT (g) PASS: the global pool is deleted and unreferenced; all three leaves take a port; base_items/fleet_items are written by their four sole writers and nothing else; a NULL-port spend is REFUSED (evaluated, not read) while a NULL-port deposit falls back to the oldest active base; and a hull order must now record the store it was placed from';
end $g$;

-- ── (h) the re-created functions changed BODY AND NOTHING ELSE, and really gained what they needed ─
do $h$
declare
  r     record;
  v_n   integer := 0;
  v_src text;
begin
  -- Every consumer must still exist, exactly once, SECURITY DEFINER, with search_path pinned —
  -- the properties a careless re-create silently loses.
  for r in
    select unnest(array['reward_grant', 'production_craft_module', 'craft_module',
                        'production_recruit_captain', 'recruit_captain', 'sell_item_at_port',
                        'production_start_hull_build', 'start_hull_build', 'cancel_build_order',
                        'buy_shop_offer_at_port']) as fname
  loop
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = r.fname) <> 1 then
      raise exception '0333 (h) FAIL: public.% is not exactly one function after the rewrite', r.fname;
    end if;
    select pg_get_functiondef(p.oid) into v_src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.fname;
    if position('SECURITY DEFINER' in v_src) = 0 then
      raise exception '0333 (h) FAIL: public.% lost SECURITY DEFINER across the rewrite', r.fname;
    end if;
    if position('search_path' in v_src) = 0 then
      raise exception '0333 (h) FAIL: public.% lost its pinned search_path across the rewrite', r.fname;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 10 then
    raise exception '0333 (h) FAIL: checked % function(s), expected 10', v_n;
  end if;

  -- THE THREE COMMANDS REALLY GAINED THE SHIP, and the port they derive from it is NOT a parameter.
  for r in
    select unnest(array['craft_module', 'recruit_captain', 'start_hull_build']) as fname
  loop
    if (select pg_get_function_identity_arguments(p.oid)
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname='public' and p.proname=r.fname) not like '%p_main_ship_id uuid%' then
      raise exception '0333 (h) FAIL: public.% did not gain the ship parameter', r.fname;
    end if;
    if (select pg_get_function_identity_arguments(p.oid)
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname='public' and p.proname=r.fname) ilike '%location%' then
      raise exception '0333 (h) FAIL: public.% has a location-shaped parameter — the port must be DERIVED from the dock, never named', r.fname;
    end if;
    select pg_get_functiondef(p.oid) into v_src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public' and p.proname=r.fname;
    if position('mainship_resolve_docked_location(' in v_src) = 0 then
      raise exception '0333 (h) FAIL: public.% does not derive its port from the one docked resolver', r.fname;
    end if;
    if position('''not_docked''' in v_src) = 0 then
      raise exception '0333 (h) FAIL: public.% has no typed not_docked refusal — a raw Postgres error would reach the player', r.fname;
    end if;
    if position('get_or_create_store(' in v_src) = 0 then
      raise exception '0333 (h) FAIL: public.% does not resolve the store through the one resolver', r.fname;
    end if;
  end loop;

  -- THE HULL ORDER WRITES ITS STORE.
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='production_start_hull_build';
  if position('insert into build_orders (player_id, base_id, hull_type_id' in v_src) = 0 then
    raise exception '0333 (h) FAIL: production_start_hull_build does not record the store on the order';
  end if;

  -- THE HULL REFUND GIVES THE ITEMS BACK TO THAT STORE.
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='cancel_build_order';
  if position('inventory_deposit(o.player_id, o.base_id,' in v_src) = 0 then
    raise exception '0333 (h) FAIL: the hull refund does not return the ingredients to the port that ordered them';
  end if;

  -- AND THE LOOT DEPOSIT USES THE BASE IT HAS ALWAYS BEEN HANDED.
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='reward_grant';
  if position('p_player, p_base, r.item_id, r.qty' in v_src) = 0 then
    raise exception '0333 (h) FAIL: reward_grant still deposits items without a place';
  end if;

  raise notice '0333 SELF-ASSERT (h) PASS: all ten consumers survived the rewrite with SECURITY DEFINER and a pinned search_path; craft/recruit/hull-order each gained the SHIP, derive the port from the one docked resolver, and refuse with a typed not_docked; the hull order records its store and the refund returns the ingredients to it; loot banks where it lands';
end $h$;

-- ── final ────────────────────────────────────────────────────────────────────────────────────────
do $z$
declare
  v_stacks integer;
  v_qty    bigint;
  v_ports  integer;
begin
  select count(*), coalesce(sum(quantity), 0), count(distinct base_id)
    into v_stacks, v_qty, v_ports from public.base_items;
  raise notice '0333 RESULT: % stack(s) / % item(s) now LIVE across % port store(s). The fleet hold is empty by construction — it is what you pick up and carry.', v_stacks, v_qty, v_ports;
  raise notice '0333 SELF-ASSERT PASS: items live at ports — a volume, a per-port home, a per-fleet hold, and one docked-only transfer verb between them.';
end $z$;

commit;
`;

if (sql.includes('\r')) {
  throw new Error('generated 0333 carries a CR — the rewrite hunks would never match the deployed bodies');
}

const check = process.argv.includes('--check');
if (check) {
  let onDisk;
  try {
    onDisk = readFileSync(OUT, 'utf8');
  } catch {
    console.error('0333 CHECK FAIL: migration file is missing — run the generator');
    process.exit(1);
  }
  if (onDisk.replace(/\r\n/g, '\n') !== sql) {
    console.error('0333 CHECK FAIL: the migration on disk is not what the slices generate.');
    console.error('Either a source migration drifted or the file was hand-edited. Re-run the generator.');
    process.exit(1);
  }
  console.log('0333 CHECK OK: migration matches the slices taken from 0040/0109/0126/0174/0188/0194/0235.');
} else {
  writeFileSync(OUT, sql);
  console.log(`0333 written: ${OUT}`);
  console.log(`  ${HUNKS.length} body hunks over ${new Set(HUNKS.map((h) => h[1])).size} functions, ` +
    `${SIGS.length} signature widenings — nothing retyped.`);
}
