# World Editor V1B-0 — Owner Security Spine

Mutation-**readiness** only. This slice builds the reusable, server-authoritative owner boundary + the
audit / idempotency / command contracts that **every** future World Editor command reuses. It mutates
**no** world content. Migration `0243` ships **UNDEPLOYED** pending separate review; it is fail-closed
(no owner seeded ⇒ `is_owner()` false for everyone). Authoritative design: `ZONE_TEMPLATES_ARCH.md`
§7 + §WE.10.

## Architecture (one authority per concept — no spaghetti)

| Concept | The one authority |
|---|---|
| Owner identity | `public.app_owners` (deny-all allow-list; RLS on, no client grant) |
| Authorization guard | `public.is_owner()` — `SECURITY DEFINER`, keyed off `auth.uid()`; **every** command calls it first |
| Audit ledger | `public.world_editor_audit` (sole writer = the command entrypoint) |
| Idempotency key | `world_editor_audit.request_id` **UNIQUE** (one applied command per request id) |
| Command entrypoint pattern | `public.world_editor_ping(text, jsonb)` — the guarded **NO-OP** template |

`is_owner()` checks the JWT subject **in the function body**, so no client flag, route, or direct RPC
role can bypass it — even a superuser with a non-owner JWT is refused.

## Typed command contract

Envelope (client → server): `{ requestId, commandType, targetType, targetId, payload }`.
Result (server → client):

- success: `{ ok:true, request_id, command_type, result }`
- idempotent replay: `{ ok:true, request_id, command_type, replayed:true, code:'duplicate_request', result:<prior> }`
- failure: `{ ok:false, request_id, error:<code> }`

Error codes: `not_authenticated` (anonymous), `not_authorized` (authenticated non-owner),
`invalid_request` (blank request id), `duplicate_request` (replay). The client adds `transport_error`
for a failed RPC call. Shared FE types live in `src/features/worldeditor/commandClient.ts` (types +
thin client only — **not** wired to any write control).

## Authorization matrix

| Caller | `is_owner()` | `world_editor_ping` |
|---|---|---|
| Owner (in `app_owners`) | `true` | `ok:true` (audit row written) |
| Authenticated non-owner | `false` | `ok:false, error:'not_authorized'` (no audit row) |
| Anonymous (no JWT subject) | `false` | `ok:false, error:'not_authenticated'` (no audit row) |

## Privilege matrix (EXECUTE / table grants)

| Object | anon | authenticated | service_role / owner |
|---|---|---|---|
| `is_owner()` | — | EXECUTE | EXECUTE |
| `world_editor_ping(text,jsonb)` | — | EXECUTE (guard enforces owner in-body) | EXECUTE |
| `app_owners` writes/reads | — | — (deny-all) | full (out-of-git seed only) |
| `world_editor_audit` writes/reads | — | — (deny-all) | full (definer writes) |

Unchanged by this slice: `pirate_zone_create` / `pirate_zone_delete` remain **execute-locked** to
authenticated/anon (the 0239 lockdown), and the read-only editor RPCs `get_world_map` /
`get_danger_zones` / `get_active_mining_fields` keep their existing `authenticated` execute grant.

## Verification

`.github/workflows/worldeditor-ownerspine-proof.yml` runs `scripts/worldeditor-ownerspine-proof.sql`
against a throwaway `supabase start` (full chain incl. 0243). Distinct PASS markers: owner accepted;
non-owner rejected; anon rejected; direct RPC as the authenticated role cannot bypass; request id
idempotent (no duplicate audit row); privilege matrix; 0239 lockdown intact; read surface intact. The
proof is self-rolling-back and touches no production.

## Deploy posture

Migration `0243` is **undeployed**. Deploy order when approved: (1) deploy `0243`, (2) run the
out-of-git owner seed on the target, (3) then rely on any owner-gated command. Until (2), the spine is
fail-closed.
