// Method — how this game is actually built.
//
// Every other tab answers "what exists" or "what's next." This one answers
// "how does a change get made here at all" — the no-spaghetti law, the
// per-slice build loop, the verification machinery, and the server-authoritative
// stance — grounded in docs/HOW_ITS_BUILT.md and cited against the SAME graph
// the other tabs read, so a claim here can be clicked straight to the node it's
// about. Prose is the primary content (this is a doc, not a derived structure),
// but every concrete example still resolves to a real node with a real,
// evidence-backed status colour — never a hand-picked "looks about right" hex.

import { STATUS } from './status.js'

const esc = (s) => String(s).replace(/[<>&"]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;' }[c]))

export function createMethod({ graph, status, mount, onSelect }) {
  let query = ''
  let selected = null

  const byId = new Map(graph.nodes.map((n) => [n.id, n]))
  const st = (id) => status.get(id) ?? STATUS.NEEDS_CHECK
  const has = (id) => byId.has(id)

  // A cited node: renders as a real chip (same visual language as the timeline's
  // nodeChip) when the id exists in the scanned graph, and as a plain inert label
  // when it doesn't — so a stale citation degrades honestly instead of dangling.
  function cite(id, textOverride) {
    if (!has(id)) return `<span class="mth-missing" title="not found in the scanned graph">${esc(textOverride ?? id)}</span>`
    const n = byId.get(id)
    const s = st(id)
    const label = textOverride ?? n.label
    const selCls = id === selected ? ' sel' : ''
    const dim = query && !label.toLowerCase().includes(query) && !n.label.toLowerCase().includes(query) ? ' dm' : ''
    return `<span class="tl-fchip${selCls}${dim}" data-goto="${esc(id)}"
      style="background:${s.hex}22;color:${s.hex}">
      <span class="swatch" style="background:${s.hex}"></span>${esc(label)}</span>`
  }

  function render() {
    const dimSec = (text) => query && !text.toLowerCase().includes(query) ? ' dm' : ''

    mount.innerHTML = `
      <section class="tl-sec${dimSec('no spaghetti law authority compose fork dark retire')}">
        <div class="tl-era">the law</div>
        <h2>The no-spaghetti law</h2>
        <div class="tl-desc">Recorded verbatim in <code>docs/MOVEMENT_UNIFICATION_CHARTER.md</code>,
          written after the owner called the movement system spaghetti: <em>if work is or becomes
          spaghetti, rip it out and redo it clean.</em> Four rules, each with a real example below —
          click any chip to jump to that node on the 3D map.</div>

        <div class="tl-subhead">1 — one authority per concept</div>
        <p class="mth-p">Every table has exactly one function that writes it — the sole-writer matrix
          in ${cite('system:Movement', 'SYSTEM_BOUNDARIES.md')} names it explicitly, down to which
          function owns which column when two features share a table. The clearest case: a ship's
          location used to be readable three or four independently-drifted ways; the berth model
          collapsed it to one column (${cite('table:main_ship_instances')}) and one CHECK constraint
          making FLEETED-xor-BERTHED true at the schema level — a ghost dock became structurally
          impossible, not just discouraged.</p>

        <div class="tl-subhead">2 — compose, don't fork</div>
        <p class="mth-p">${cite('fn:command_ship_group_go', 'command_ship_group_go')} (the unified
          fleet mover) needed to release a fleet to <code>idle</code> before redirecting it. CI caught
          a hand-rolled first draft that skipped straight past the existing state-transition primitive
          — the fix was composing that primitive, not patching around it.</p>

        <div class="tl-subhead">3 — dark-first: ship behind a flag, byte-identical until lit</div>
        <p class="mth-p">Migrations ${cite('mig:20260618000207')}–<code>0215</code> built the whole
          unified fleet mover, CI-proven and merged to <code>main</code>, then sat inert in production
          behind ${cite('flag:fleet_movement_unified_enabled')} for days before the owner ran the flip
          script. Nothing player-visible changed between merged and flipped — that gap is the point.</p>

        <div class="tl-subhead">4 — retire the old, once the new one is proven</div>
        <p class="mth-p">Dark-first only works if the old path is actually deleted afterward. The
          charter's own case study (§0) is a session that patched the existing tangle instead of
          building the plan — recorded as the mistake the whole document exists to stop repeating.
          The post-flip plan schedules concrete deletions of the legacy per-ship movers under a
          drain-assert, not a permanent second path kept "just in case."</p>
      </section>

      <section class="tl-sec${dimSec('build loop architect implementer reviewer proof deploy')}">
        <div class="tl-era">the loop</div>
        <h2>The per-slice build loop</h2>
        <div class="tl-desc">Every change of consequence goes through the same five stages, used
          slice after slice across the whole dev log.</div>

        <div class="tl-subhead">architect → implementer → adversarial reviewer → real-Postgres proof → owner-gated deploy</div>
        <p class="mth-p"><b>Architect</b> — read-only, re-derives the inventory by grep rather than
          trusting the last person's count. The movement charter records being wrong about its own
          numbers eight times over its life, including a "fifth copy" of dock-read logic
          (<code>commission_first_main_ship</code>) that survived two prior slices because it used no
          table alias and so matched no one's grep. <b>Lesson kept on the wall:</b> "a charter inventory
          is a CLAIM, not evidence."</p>
        <p class="mth-p"><b>Implementer</b> — its own git worktree per slice (never a shared working
          tree for concurrent changes), and byte-parity for any live function it re-creates.</p>
        <p class="mth-p"><b>Adversarial reviewer</b> — job is to break it, not approve it. A 5-agent
          recon on this same fleet-mover work found two real bugs that thirteen green CI markers had
          missed: a "ghost-dock" leak where a departing fleet's members stayed docked and trading at
          the origin port while the fleet was recorded as flying — the exact duality the mover exists
          to kill, reintroduced by the migration meant to kill it — and a move that could be issued
          into a fleet mid-hunt, silently destroying it on arrival. The charter's own words: "a proof
          pins the property you thought of; it says nothing about the one you didn't."</p>
        <p class="mth-p"><b>Real-Postgres CI apply-proof</b> — every DB-touching migration ships with
          a paired <code>.sql</code>/<code>.sh</code> proof run against a disposable, real Postgres
          instance, never a mock. ${cite('mig:20260618000207', 'The fleet-mover proof')} alone found
          three bugs a local selftest could not: SQL's <code>AND</code> not guaranteeing left-to-right
          evaluation, a null-speed guard silently absorbing a plumbing mistake, and a redirect call that
          violated a live function's <code>status='idle'</code> precondition.</p>
        <p class="mth-p"><b>Owner-gated deploy</b> — CI green never deploys anything by itself. The
          assistant is deliberately blocked from approving a production gate; the human runs
          <code>scripts/approve-deploy.sh</code>, which shows exactly which migrations are in the exact
          commit about to ship before anything is approved. <code>docs/PROD_GATE_APPROVAL_POLICY.md</code>
          exists because this boundary was tested for real once, and the harness held.</p>
      </section>

      <section class="tl-sec${dimSec('verification verify first self assert raise dual safe transaction cron guard')}">
        <div class="tl-era">the discipline</div>
        <h2>Verification</h2>
        <div class="tl-desc">Never assume; verify against the live system, not memory — and never let
          a bad write land quietly.</div>

        <div class="tl-subhead">verify-first, against prod, not a stale note</div>
        <p class="mth-p">A prior session's notes claimed prod SQL access was blocked. The next session
          tested it directly instead of repeating the claim, found it wasn't, and recorded the lesson:
          "a handoff note claiming 'the assistant lacks X' is a point-in-time guess and <em>decays</em>."
          The same discipline found a real reconciliation mismatch live in production: four ships stuck
          at <code>status='traveling'</code> with nothing holding them. Live queries — not a synthetic
          fixture — showed every one of their fleets was already <code>present</code> at a real port;
          the ship's own status field was lying, and the fleet layer already knew the truth. No seeded
          test reproduces that shape; only the real accumulated data does.</p>

        <div class="tl-subhead">self-asserting migrations abort rather than corrupt</div>
        <p class="mth-p">Migrations and activation scripts check their own preconditions and
          <code>RAISE</code> rather than half-apply. ${cite('flag:shipyard_enabled', 'activate-shipyard')}
          runs a per-ingredient reachability check that raises if any recipe ingredient has no live
          faucet; ${cite('flag:repair_economy_enabled')}, ${cite('flag:launch_from_dock_enabled')}, and
          every other <code>activate-*</code> script are precondition-guarded the same way.</p>

        <div class="tl-subhead">dual-safe irreversible changes: repoint → soak → drop</div>
        <p class="mth-p">Dropping a live column or function is a one-way door, so retirement is
          sequenced to make the door safe before it's used: repoint every reader onto the new authority
          first (each repoint its own small, byte-parity-checked migration), let production run on the
          new path through a real soak so a missed caller surfaces as a live error, then drop the old
          schema behind its own drain-assert.</p>

        <div class="tl-subhead">all-or-nothing guarded transactions</div>
        <p class="mth-p">${cite('fn:process_fleet_movements')} and ${cite('fn:process_combat_ticks')}
          are the two hottest crons in the game. A 7-agent audit found they ran every row in one
          transaction with no per-row isolation, so a single failing row aborted the whole tick, for
          every player, forever. ${cite('mig:20260618000206', 'CRON-GUARD')} fixed it by composing the
          per-row exception-isolation pattern the build-queue engine already used — no flag needed,
          because a strictly-safer error path with a byte-identical success path is simply correct.</p>
      </section>

      <section class="tl-sec${dimSec('server authoritative data driven client mirror')}">
        <div class="tl-era">the stance</div>
        <h2>Server-authoritative, data-driven</h2>
        <div class="tl-desc">"The client only displays what the server says." No table holding game
          state has a client write path; every mutation is a validated <code>SECURITY DEFINER</code>
          RPC. New capability is new data — rows and flags — not a new engine.</div>
        <p class="mth-p">Mk-II modules are two new rows against the fitting adapter built once. The
          shipyard's hull builds reuse the same build-order queue engine originally built for unit
          training — "never a second timer system." Ship traits, command buffs, and captain trait rolls
          all reuse one deterministic hash-of-id technique instead of each inventing its own randomness.
          The rule for the stat adapter itself: "don't replace the engine — replace the source."</p>
      </section>

      <section class="tl-sec${dimSec('world editor owner authoring rpc audit idempotency concurrency lifecycle revert coordinates dev world')}">
        <div class="tl-era">the editor</div>
        <h2>The World Editor: authoring the world the same way the game mutates it</h2>
        <div class="tl-desc">${cite('phase:WORLDEDIT', 'WORLDEDIT')} is the one place the world's static
          content is authored — locations, mining fields, exploration sites, danger zones. It is worth
          reading as architecture rather than as a feature: it is the stance above applied to the one
          actor who could legitimately have been trusted to bypass it.</div>

        <div class="tl-subhead">why owner-only, and why that is not the authorization</div>
        <p class="mth-p">The editor edits live content in a live multiplayer world, so its blast radius
          is every player at once. Only the owner may author — but "owner" is a fact the server
          establishes, never a claim the client makes. ${cite('fn:is_owner')} is the single
          authorization authority, backed by an owner table, and it is checked <em>inside</em> every
          command body. The client route flag only decides whether the editor UI is worth rendering; it
          decides nothing about permission. That separation is the point: a UX gate that fails open
          costs nothing, an authorization gate that fails open costs the world.</p>

        <div class="tl-subhead">why writes go through RPCs, not tables</div>
        <p class="mth-p">The editor writes tables it does not own: ${cite('table:locations')},
          ${cite('table:zones')}, ${cite('table:sectors')} belong to Map, the mining and exploration
          content to Reference/Config. Under one-authority-per-concept, an authoring surface with direct
          table access would be a second writer — exactly the fork the law forbids. So every edit is a
          <code>SECURITY DEFINER</code> RPC with <code>search_path=''</code> and EXECUTE granted to
          authenticated callers only, and the client's own INSERT/UPDATE/DELETE grants on those tables
          are revoked. The editor is not privileged; it is narrow.</p>

        <div class="tl-subhead">one fixed sequence, in one transaction</div>
        <p class="mth-p">Every command runs the same order, and the order is the design: <b>authorize</b>
          (${cite('fn:is_owner')} in-body, before anything is disclosed — a non-owner cannot even learn
          whether a request was a replay), <b>validate</b> server-side against one shared validator so
          six commands cannot drift into six coordinate rules, <b>deduplicate</b> on a caller-supplied
          request ID recorded in the audit ledger so a retried publish is not a second publish,
          <b>mutate</b>, then <b>audit</b> — the before/after snapshot inserted in the same transaction
          as the change, so an unaudited edit is not a thing that can exist.</p>

        <div class="tl-subhead">optimistic concurrency instead of locks</div>
        <p class="mth-p">Editing is a long human activity; holding a lock across it would be a lie about
          how the work happens. Instead each edit carries the snapshot it was forked from, and
          ${cite('fn:location_update')} (and its siblings) refuse the write if the row has moved since —
          the UI answers with an explicit "reload the live version" rather than silently winning. A lost
          update is turned into a visible conflict.</p>

        <div class="tl-subhead">lifecycle, not deletion — and everything reversible</div>
        <p class="mth-p">Nothing is destroyed. ${cite('fn:zone_unpublish')} moves a zone to inactive and
          ${cite('fn:zone_set_active')} brings it back; ${cite('fn:location_update')} carries the same
          transition for locations. The row survives as its own evidence, which is what makes
          ${cite('fn:world_editor_revert')} possible: the ONE revert replays an audit record's <em>before</em>
          state back through that domain's own update command. A revert is therefore an ordinary edit —
          same authorization, same validation, same new audit row — never a privileged direct write, and
          never a second recovery path to keep in sync. Reading that history is its own owner-only,
          sanitized, paginated command (${cite('fn:world_editor_audit_list')} over
          ${cite('table:world_editor_audit')}), and because every gameplay read is active-only by
          construction, seeing inactive content needs deliberate owner-only reads
          (${cite('fn:world_editor_entity_catalog')}, ${cite('fn:world_editor_entity_detail')}) rather
          than a relaxed filter on the player's.</p>

        <div class="tl-subhead">physical coordinates vs. what the editor draws</div>
        <p class="mth-p">A world too sparse to edit comfortably is a display problem, and the tempting
          fix — rescaling the stored coordinates — would silently rewrite every distance, travel time and
          proximity rule in the game. So the physical frame is frozen and the adapter moved: stored
          gameplay coordinates are untouched, and the editor view is controlled by typed display adapters
          plus the camera. ${cite('fn:location_create')} and ${cite('fn:location_update')} write the
          anchor authority, and one canonical bounds validator is the only place the legal coordinate
          range is written down.</p>

        <div class="tl-subhead">four domains, one surface</div>
        <p class="mth-p">The four domains share the map, the draft model, the concurrency contract, the
          audit panel and the revert button, because they share the command shape underneath — zone
          authoring (${cite('fn:zone_create')}, ${cite('fn:zone_update')}) differs from point authoring
          only in its geometry, not in its rules. A per-domain editor would have been four drafts, four
          audits and four reverts to keep honest; instead the parity is structural.</p>

        <div class="tl-subhead">how it was verified without touching the live world</div>
        <p class="mth-p">Every mutation path — create, update, unpublish, reactivate, revert,
          concurrency, idempotency, audit — is proven end-to-end by the disposable-PostgreSQL apply-proof
          CI, which applies the whole migration chain to a real database and asserts the gameplay readers
          stay byte-identical. The production check was deliberately the other half: a READ-ONLY closure
          smoke on ${cite('fn:world_editor_ping')} and the owner-gated read surface — no production write
          RPC was invoked. That asymmetry is honest and intentional. Live writes are proven by CI, not by
          mutating a world thirty people are playing in.</p>
      </section>

      <section class="tl-sec${dimSec('narrative arc core loop economy movement berth activation combat grew')}">
        <div class="tl-era">the arc</div>
        <h2>How the game grew</h2>
        <div class="tl-desc">Read <code>docs/DEV_LOG.md</code> in build order and one method applies
          across a widening set of systems. See the <b>연혁 Timeline</b> tab for the full chronological
          build log this traces.</div>
        <ol class="mth-arc">
          <li><b>Core loop first.</b> ${cite('system:Movement')} → ${cite('system:Presence')} →
            ${cite('system:Combat')}, nothing else, before anything is layered on.</li>
          <li><b>Economy, layered on the proven loop.</b> Trade, haul contracts, salvage — each its own
            flag, wired onto ${cite('system:Wallet')} / ${cite('system:Inventory')} that already
            existed, never a second currency.</li>
          <li><b>Movement + berth unification</b> — the project's own case study: four overlapping
            movement paths called spaghetti by the owner, replaced by one fleet-level mover
            (${cite('fn:command_ship_group_go')}) that writes nothing to the per-ship table, soaked
            dark, then flipped live.</li>
          <li><b>Activation of the dark systems</b> — exploration, mining, ${cite('flag:shipyard_enabled', 'shipyard')},
            shields, all built and proven, waiting on a human decision and a dependency order before
            they're lit.</li>
          <li><b>Fleet-control and combat overhaul</b> — ${cite('flag:fleet_control_enabled')} and
            ${cite('flag:command_buffs_enabled')}, the pattern at its most mature: related changes,
            each its own migration, each byte-identical while dark.</li>
        </ol>
        <div class="mth-src">Grounded in <code>docs/HOW_ITS_BUILT.md</code>,
          <code>docs/MOVEMENT_UNIFICATION_CHARTER.md</code>, <code>docs/SYSTEM_BOUNDARIES.md</code>,
          <code>docs/FULL_CAPACITY_PLAN.md</code>, <code>docs/ACTIVATION_GUIDE.md</code>,
          <code>docs/ARCHITECTURE.md</code>, <code>docs/PROD_GATE_APPROVAL_POLICY.md</code>,
          <code>docs/WORLD_EDITOR_V1_CLOSURE.md</code>,
          <code>docs/WORLD_EDITOR_ROADMAP_CLOSURE.md</code>, and the
          <code>scripts/*-proof.{sh,sql}</code> + <code>.github/workflows/*proof*.yml</code> family.</div>
      </section>`
  }

  mount.addEventListener('click', (e) => {
    const t = e.target.closest('[data-goto]')
    if (!t || !mount.contains(t)) return
    selected = t.dataset.goto
    onSelect?.(selected)
    render()
  })

  render()

  return {
    setQuery(q) { query = q.trim().toLowerCase(); render() },
  }
}
