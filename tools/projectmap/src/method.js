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
          <code>docs/ARCHITECTURE.md</code>, <code>docs/PROD_GATE_APPROVAL_POLICY.md</code>, and the
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
