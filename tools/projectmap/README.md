# Byeharu — Project Map

A 3D map of this codebase: what exists, what connects to what, and what is
**actually live in production** versus merely merged to `main`.

It is a brainstorming/orientation tool, not part of the game.

```bash
cd tools/projectmap
npm install
npm run refresh     # scan the repo + read production
npm run dev         # http://localhost:5183
```

## It is fully decoupled from the game

This directory has its **own** `package.json`, `node_modules`, and Vite build.
It is invisible to the game's pipeline, by construction:

| Game pipeline step | Why this tool is invisible to it |
|---|---|
| `npx tsc -b` | `tsconfig.app.json` has `"include": ["src"]` — never `tools/` |
| `npm run lint` | `eslint.config.js` matches only `**/*.{ts,tsx}`; this app is plain `.js`/`.mjs` |
| `npx vite build` | the root build is rooted at the repo's own `index.html` |
| `npm ci` | root lockfile; this app's deps install separately |

Nothing in the game imports from here, and nothing here writes to the game.
Deleting this folder would have zero effect on the game.

## Where the colours come from

The whole point is that a colour is **evidence**, not a vibe. There are two
generators, and they are kept separate on purpose.

### `scan/scan.mjs` — what exists (offline, no production knowledge)

Parses all `supabase/migrations/*.sql` plus `docs/SYSTEM_BOUNDARIES.md` and emits
`public/graph.json`. Every node and edge traces back to a file on disk.

Nodes: `migration`, `function`, `table`, `flag`, `system`.

Edges — this is the part worth caring about:

| Edge | Meaning |
|---|---|
| `creates` | a migration defines a function/table |
| **`supersedes`** | **a later migration re-creates a function an earlier one defined** |
| `extends` | a later migration alters a table an earlier one created |
| `alters` / `drops` | a migration changes/removes a symbol |
| `seeds` | a migration inserts a `game_config` flag row |
| `gated-by` | a migration reads a flag to gate behaviour |
| `calls` | a function calls another function |
| `touches` | a function reads/writes a table |
| `owned-by` | a table belongs to a system (the sole-writer matrix) |

`supersedes` and `extends` are the "which migrations affect which other
migrations" edges. They are derived, not hand-written: when `0194` re-creates
`production_start_next`, an edge appears to whichever migration defined it last.
This is the same relationship `SYSTEM_BOUNDARIES.md` writes in prose as
"head now 0194 over 0038".

Note it deliberately only treats a flag as real if some migration **seeds it as a
`game_config` row**. Strings like `shield_enabled` appear in migration prose but
are never seeded, so they are not flags and get no node.

### `scan/live.mjs` — what is actually true in production

Emits `public/live.json` from two real sources:

1. **`game_config`** over REST with the anon key. The `game_config_public_read`
   policy (`for select using (true)`) makes this readable without service-role.
   Reads `.env.local` (or `--env <path>`); the key is never written to output.
2. **`gh run list`** — the state of the *Deploy Supabase migrations* workflow.
   Migrations here do **not** auto-apply; that workflow waits on a production
   environment approval, so `main` can sit ahead of the database.

If either source is unavailable the map says so in the HUD and downgrades the
affected nodes to *Needs checking*, rather than guessing.

## The five colours

| Colour | Status | Means |
|---|---|---|
| 🟢 green | **Live in production** | deployed and its gate is on |
| 🔵 cyan | **Live, ungated** | in prod, no feature flag (additive/always-on) |
| 🟣 violet | **Dark** | deployed but flag is `false` — code live, behaviour not |
| 🟠 amber | **Merged, not deployed** | on `main` but not in the prod database |
| 🔴 red | **Needs checking** | production state could not be proven |

### How "deployed" is decided (the honest bit)

A migration that seeds a flag leaves a fingerprint: if the `game_config` row is
in prod, that migration ran. That yields a highest-proven-deployed stamp and a
lowest-proven-missing stamp — a **deploy frontier**.

- seeds a flag, row present → proven in prod (`Live` or `Dark` by the value)
- seeds a flag, row absent → proven **not** in prod (`Merged, not deployed`)
- seeds no flag, sits before the frontier → `Live, ungated`
- seeds no flag, sits after the first proven-missing → `Merged, not deployed`
- otherwise → **`Needs checking`**

Functions and tables inherit from the newest migration that defines them, then
go violet if a flag gates them. Systems roll up from the tables they own.

"Merged to `main`" is never treated as evidence of deployment. On this project
those are different things, and the map is built to show exactly that gap.

## Using it

- **drag** orbit · **wheel** zoom · **click** a node to isolate it and its
  neighbours · **click empty space** to deselect
- the inspector explains *why* a node has the colour it has, and lists every
  connection (click one to walk the graph)
- filter by status / node type / connection type; search matches labels + detail
- the HUD shows the prod host, live-flag count, deploy state, and the frontier

## Refreshing

`npm run scan` is offline and instant. `npm run live` needs `.env.local` and an
authenticated `gh`. `npm run refresh` does both.

`public/graph.json` **is** committed (it is pure repo derivation), so the map
opens with no credentials.

`public/live.json` is **not** committed, and is git-ignored on purpose. This
repo is public, and that file is a point-in-time read of production posture —
which flags are on, which migrations have landed, the deploy run state. Nothing
in it is secret (`game_config` is anon-readable and the Supabase URL already
ships in the public Pages bundle), but a public repo should not accumulate a
running log of production state as a side effect of refreshing a picture.

So a fresh clone shows the graph with every node *Needs checking* and a HUD that
says the live read is missing. Run `npm run live` to colour it in. The HUD
always shows the read's timestamp — treat it as a snapshot, not a live feed.
