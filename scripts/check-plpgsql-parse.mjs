#!/usr/bin/env node
// ═══════════════════════════════════════════════════════════════════════════════════════════════
// check-plpgsql-parse — THE OFFLINE PARSE GATE FOR MIGRATIONS AND DISPOSABLE PROOFS
// ═══════════════════════════════════════════════════════════════════════════════════════════════
//
// ── WHY THIS EXISTS, IN TWO FAILURES IT WOULD HAVE CAUGHT ───────────────────────────────────────
//
// 1. `combat-spatial-proof.sql` (commit 6d7cb2d) used a LONE `$` as a dollar-quote delimiter in
//    four places. A delimiter is `$`, an optional tag, then `$`; PostgreSQL throws a lone one back
//    as a bare token and raises `syntax error at or near "$"` AT PARSE TIME, so the whole suite
//    died before one assert ran. The `.sh` selftest is a grep gate and was green on it.
//
// 2. Migration `20260618000351` (PR #410, 13 red legs) shipped a surgery hunk whose REPLACEMENT
//    text dropped one `end if;`. The file itself lexes perfectly — the defect only becomes plpgsql
//    when `do $rewrite$` EXECUTEs the assembled function body, and it surfaced as
//    `ERROR: syntax error at end of input (SQLSTATE 42601)` on the apply, in CI, on every leg.
//
// 3. The SAME migration, after (2) was fixed, was STILL red with the SAME error. Hunk [6] put a
//    BARE `case when … then … end` inside an IF condition. plpgsql does not parse an IF condition
//    as SQL and then look for THEN — it scans for the first THEN at parenthesis depth 0. The CASE
//    supplies one, so the condition is truncated, every statement after it shifts, and the function
//    ends with the parser still open. Checks (A) and (B) are both GREEN on it: the file parses, and
//    the hunk is perfectly `if`/`end if` balanced. Only check (C) sees it.
//
// Three layers, three checks, and none of them subsumes another.
//
// ══ ⚠ WHAT A GREEN FROM THIS TOOL DOES AND DOES NOT MEAN ════════════════════════════════════════
// It means: every file PARSES, every plpgsql block COMPILES, every hunk is block-balanced, and the
// surgery chain reconstructed from THIS REPO produces bodies that compile.
// It does NOT mean the migration will apply. This gate has no schema, so it resolves no table,
// column, function, constraint or permission; it does not run a single self-assert; and it models
// the DISPOSABLE chain (built from these files, in this order), never PRODUCTION, whose deployed
// body may legitimately differ. Defect (3) above shipped past a green from checks (A) and (B) —
// the coverage boundary is exactly where bugs live. Only CI's disposable matrix is the apply proof.
// Every target this gate could not decide is COUNTED and LISTED, so the boundary is visible in the
// output rather than implied by silence.
//
// ── (A) PARSE + COMPILE, against a real PostgreSQL ──────────────────────────────────────────────
// A WASM PostgreSQL (@electric-sql/pglite) lexes the whole file with the real scanner — catching
// dollar-quoting, unterminated literals and statement splitting — and every `do $tag$ … $tag$;`
// block is handed to plpgsql_compile by re-wrapping it as a function. That catches: missing
// `end if` / `end loop` / `end case`, malformed DECLARE, bad assignment syntax, and RAISE
// parameter arity in BOTH directions (too few and too many — a wrong-arity RAISE turns a clean
// proof failure into a confusing one, which is the opposite of what a failure message is for).
// It does NOT resolve tables, columns or functions: plpgsql parses embedded SQL lazily, and there
// is no schema here. That is the honest boundary of this gate — it is a PARSE gate, not an apply
// proof, and it does not replace the disposable matrix.
//
// ── (B) SURGERY HUNK BALANCE, which is where 0351 actually died ─────────────────────────────────
// A generated migration rewrites LIVE plpgsql by replacing marked hunks of the deployed text. The
// hunks live inside the migration as dollar-quoted STRING LITERALS, so check (A) never sees them
// as code — they only become plpgsql at apply time, inside the target function, in a context this
// tool cannot reconstruct offline (the pre-image is the DEPLOYED body, not anything in the repo).
//
// But one invariant needs no pre-image: A REPLACEMENT MUST LEAVE THE BLOCK NESTING WHERE IT FOUND
// IT. Whatever `old_t` did to the enclosing block depth, `new_t` must do the same, or the
// surrounding function stops being balanced. So for each (old_t, new_t) pair this compares the NET
// depth delta of `if`/`end if` and `loop`/`end loop`, and fails when they differ. On 0351 hunk [5]
// that is old 0 vs new +1 — exactly the dropped `end if`. This is textual and cheap, and it
// generalises to every surgery migration in the repo.
// CASE and BEGIN are deliberately OUT OF SCOPE: a bare `end` closes a BEGIN block, a statement CASE
// and an expression `case when … end` alike, so counting them produces false reds on correct hunks
// (0351 hunk [3] adds two case EXPRESSIONS inside a function call). `end if` and `end loop` are
// unambiguous two-word closers with no expression form, and they are what surgeries get wrong.
//
// ── (C) ASSEMBLE THE SURGERY CHAIN AND COMPILE THE RESULT — the check that catches (3) ──────────
// The chain's own law (0350 assert (f)) makes this possible offline: after the last FULL textual
// re-create of a function, every later migration only does SURGERY over the deployed text. So walk
// the migrations in version order, reset the body on a top-level `create or replace`, apply every
// later hunk, and compile the result. Self-validating: every needle must match EXACTLY ONCE, which
// is what the migrations assert at apply time — a drifted reconstruction reports a missed needle
// rather than quietly compiling a body nobody will run.
// BLAME IS SCOPED: the pre-hunk BASE is compiled FIRST. If the base does not compile in this
// schema-less harness, the reconstruction is what is suspect and the target is recorded as a
// coverage gap — never a red. A false red is the thing that teaches people to stop reading a gate.
//
// ── NON-VACUITY, because an empty scan reporting success is the whole failure mode ──────────────
// `--require-files N` / `--require-blocks N` / `--require-hunks N` make the gate FAIL when it
// found less than it was told to expect. A glob that stops matching, a splitter that silently
// stops recognising `do` blocks, or a hunk-extractor that stops seeing VALUES rows must be a RED
// gate, not a quiet green one. This is the [[proofs-never-assert-ambient-defaults]] corollary
// applied to a tool: a check that cannot fail is not a check.
//
// usage:
//   node scripts/check-plpgsql-parse.mjs <file.sql|glob> [...] [--require-files N]
//        [--require-blocks N] [--require-hunks N] [--assemble <migrations-dir>]
//        [--require-assembled N] [--quiet]
// exit 0 = every file parses, every plpgsql block compiles, every hunk is balanced, and the
//          non-vacuity floors were met.
// ═══════════════════════════════════════════════════════════════════════════════════════════════
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { globSync } from 'node:fs';
import path from 'node:path';

// ── the argument surface ─────────────────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
const opts = { requireFiles: 0, requireBlocks: 0, requireHunks: 0, requireAssembled: 0, assembleDir: null, quiet: false };
const patterns = [];
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--require-files') opts.requireFiles = Number(argv[++i]);
  else if (a === '--require-blocks') opts.requireBlocks = Number(argv[++i]);
  else if (a === '--require-hunks') opts.requireHunks = Number(argv[++i]);
  else if (a === '--require-assembled') opts.requireAssembled = Number(argv[++i]);
  else if (a === '--assemble') opts.assembleDir = argv[++i];
  else if (a === '--quiet') opts.quiet = true;
  else patterns.push(a);
}
if (patterns.length === 0) {
  console.error('usage: node scripts/check-plpgsql-parse.mjs <file.sql|glob> [...] [--require-files N] [--require-blocks N] [--require-hunks N]');
  process.exit(2);
}

// ── PATH RESOLUTION, AND WHY IT IS HAND-ROLLED ───────────────────────────────────────────────────
// The harness that calls this runs under Git Bash, whose $REPO_ROOT is an MSYS path like
// `/c/Users/…`. Node does not understand that on win32: fs.globSync returns ZERO matches for it,
// silently. That is exactly the shape this tool exists to refuse, and when it first happened the
// --require-* floors are what caught it — but a gate should not need its own floors to notice that
// it scanned nothing, so the resolution is made correct rather than merely alarmed.
function toNativePath(p) {
  if (process.platform === 'win32') {
    const m = /^\/([A-Za-z])\/(.*)$/.exec(p);          // /c/Users/... -> C:/Users/...
    if (m) return `${m[1].toUpperCase()}:/${m[2]}`;
  }
  return p;
}
function expand(pattern) {
  const p = toNativePath(pattern);
  if (!p.includes('*')) return existsSync(p) ? [p] : [];
  let out = [];
  try { out = globSync(p); } catch { out = []; }
  if (out.length > 0) return out;
  // fall back to an explicit readdir of the pattern's own directory — globSync's behaviour across
  // platforms and Node versions is not something a gate should quietly depend on.
  const dir = path.dirname(p), base = path.basename(p);
  if (!existsSync(dir)) return [];
  const re = new RegExp('^' + base.split('*').map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$');
  return readdirSync(dir).filter((f) => re.test(f)).map((f) => path.join(dir, f));
}

const files = [];
for (const pattern of patterns) {
  const got = expand(pattern);
  if (got.length === 0) {
    // PER-PATTERN, not merely in aggregate: one dead pattern among several would otherwise be
    // masked by the others and the gate would quietly cover less than it was asked to.
    console.error(`check-plpgsql-parse FAIL: the pattern "${pattern}" matched NO file (resolved to "${toNativePath(pattern)}"). An empty scan is a red gate, never a green one.`);
    process.exit(1);
  }
  for (const f of got) files.push(f);
}

// ── the splitter: PostgreSQL's own quoting rules, so the real lexer's view is reproduced ─────────
// It reports a LONE `$` rather than skipping it, because that is not a delimiter and PostgreSQL
// raises on it — the exact bug 6d7cb2d shipped past a grep-based selftest.
function split(src) {
  const out = [];
  out.loneDollar = [];
  out.unterminated = [];
  let i = 0, start = 0, line = 1, startLine = 1;
  const push = (end) => {
    const text = src.slice(start, end);
    if (text.trim()) out.push({ text, line: startLine });
  };
  while (i < src.length) {
    const c = src[i];
    if (c === '\n') { line++; i++; continue; }
    if (c === '\\' && (i === 0 || src[i - 1] === '\n')) {           // psql meta-command
      const nl = src.indexOf('\n', i);
      i = nl === -1 ? src.length : nl;
      start = i; startLine = line;
      continue;
    }
    if (c === '-' && src[i + 1] === '-') {
      const nl = src.indexOf('\n', i);
      i = nl === -1 ? src.length : nl;
      continue;
    }
    if (c === '/' && src[i + 1] === '*') {
      let depth = 1; i += 2;
      while (i < src.length && depth > 0) {
        if (src[i] === '\n') line++;
        if (src[i] === '/' && src[i + 1] === '*') { depth++; i += 2; }
        else if (src[i] === '*' && src[i + 1] === '/') { depth--; i += 2; }
        else i++;
      }
      continue;
    }
    if (c === "'") {
      const open = line;
      i++;
      let closed = false;
      while (i < src.length) {
        if (src[i] === '\n') line++;
        if (src[i] === "'" && src[i + 1] === "'") { i += 2; continue; }
        if (src[i] === "'") { i++; closed = true; break; }
        i++;
      }
      if (!closed) out.unterminated.push({ line: open, what: "single-quoted string" });
      continue;
    }
    if (c === '"') {
      const open = line;
      i++;
      let closed = false;
      while (i < src.length) { if (src[i] === '\n') line++; if (src[i] === '"') { i++; closed = true; break; } i++; }
      if (!closed) out.unterminated.push({ line: open, what: 'quoted identifier' });
      continue;
    }
    if (c === '$') {
      const m = /^\$([A-Za-z_-￿][A-Za-z0-9_-￿]*)?\$/.exec(src.slice(i));
      if (!m) {
        if (!/^\$\d/.test(src.slice(i))) out.loneDollar.push(line);   // $1, $2 … are parameters
        i++; continue;
      }
      const tag = m[0];
      const close = src.indexOf(tag, i + tag.length);
      if (close === -1) { out.unterminated.push({ line, what: `dollar quote ${tag}` }); i += tag.length; continue; }
      for (let k = i; k < close + tag.length; k++) if (src[k] === '\n') line++;
      i = close + tag.length;
      continue;
    }
    if (c === ';') { push(i + 1); i++; start = i; startLine = line; continue; }
    i++;
  }
  push(src.length);
  return out;
}

// ── (B) block-nesting delta of a hunk text ───────────────────────────────────────────────────────
// Comments and string literals are stripped first, so a keyword inside a message can never be
// counted. `end if` / `end loop` / `end case` are matched before the bare `end`, and `case` used as
// an EXPRESSION (`case when … end`) is counted by the same `end` that closes it, so an expression
// case nets to zero on both sides of a pair and cannot make a balanced hunk look unbalanced.
function stripCodeNoise(t) {
  let out = '';
  let i = 0;
  while (i < t.length) {
    if (t[i] === '-' && t[i + 1] === '-') { const nl = t.indexOf('\n', i); i = nl === -1 ? t.length : nl; continue; }
    if (t[i] === "'") {
      i++;
      while (i < t.length) { if (t[i] === "'" && t[i + 1] === "'") { i += 2; continue; } if (t[i] === "'") { i++; break; } i++; }
      out += " '' ";
      continue;
    }
    out += t[i]; i++;
  }
  return out;
}
function depthDelta(text) {
  const t = ' ' + stripCodeNoise(text).toLowerCase().replace(/\s+/g, ' ') + ' ';
  // `end if` / `end loop` are TWO-WORD closers with no expression form, which is exactly why only
  // those two are counted. A bare `end` is ambiguous — it closes a BEGIN block, a statement CASE and
  // an expression `case when … end` alike — so CASE and BEGIN are deliberately OUT OF SCOPE: 0351
  // hunk [3] adds two `case when … end` EXPRESSIONS inside a function call, which a naive
  // case/end-case counter reads as +2 unbalanced, and a false red on a correct hunk would train
  // people to ignore this gate. IF and LOOP are what surgeries actually get wrong.
  // THE \b ANCHORS ARE LOAD-BEARING. Without them `/if/` matches inside identifiers and, worse, a
  // mangled anchor makes BOTH sides of the comparison count zero — which is a gate that cannot
  // fail. That happened once while this file was being written and was caught only by running the
  // gate against a deliberately re-broken migration; do that again after touching these four lines.
  const endIf   = (t.match(/\bend\s+if\b/g)   || []).length;
  const endLoop = (t.match(/\bend\s+loop\b/g) || []).length;
  // strip the closers first so their own keywords cannot be re-counted as openers.
  const t2 = t.replace(/\bend\s+if\b/g, ' ').replace(/\bend\s+loop\b/g, ' ');
  // `elsif` / `elseif` are single keywords, so \bif\b cannot match inside them and there is nothing
  // to subtract; a two-word `else if` really is a nested IF needing its own `end if`.
  const openIf   = (t2.match(/\bif\b/g)   || []).length;
  const openLoop = (t2.match(/\bloop\b/g) || []).length;
  return {
    if:   openIf   - endIf,
    loop: openLoop - endLoop,
    _raw: { openIf, endIf, openLoop, endLoop },
  };
}

// ── (B) pull every (old_t, new_t) hunk pair out of a surgery migration's VALUES list ─────────────
// The house shape is `(<idx>, '<fname>', $hNo$ … $hNo$, $hNn$ … $hNn$)`. The tags are matched
// generically, so a migration that names them differently is still covered.
function extractHunks(src) {
  const hunks = [];
  const re = /\(\s*(\d+)\s*,\s*'([a-z0-9_]+)'\s*,\s*\$([A-Za-z_][A-Za-z0-9_]*)\$/g;
  let m;
  while ((m = re.exec(src)) !== null) {
    const [, idx, fname, oldTag] = m;
    const oldOpen = m.index + m[0].length;
    const oldClose = src.indexOf(`$${oldTag}$`, oldOpen);
    if (oldClose === -1) continue;
    const rest = src.slice(oldClose + oldTag.length + 2);
    const nm = /^\s*,\s*\$([A-Za-z_][A-Za-z0-9_]*)\$/.exec(rest);
    if (!nm) continue;
    const newTag = nm[1];
    const newOpen = oldClose + oldTag.length + 2 + nm[0].length;
    const newClose = src.indexOf(`$${newTag}$`, newOpen);
    if (newClose === -1) continue;
    hunks.push({
      idx: Number(idx), fname,
      line: src.slice(0, m.index).split('\n').length,
      oldTag, newTag,
      old_t: src.slice(oldOpen, oldClose),
      new_t: src.slice(newOpen, newClose),
    });
    re.lastIndex = newClose;
  }
  return hunks;
}

// ── (C) ASSEMBLE THE SURGERY CHAIN AND COMPILE THE RESULT ────────────────────────────────────────
// THIS IS THE CHECK THAT ACTUALLY CATCHES THIS CLASS, and (A) and (B) both missed the defect it was
// written for. 0351 hunk [6] put a BARE `case when … then … end` inside an IF condition. plpgsql
// does not parse an IF condition as SQL and then look for THEN — it scans forward for the first
// THEN token at parenthesis depth 0. The CASE supplies one, the condition is cut off early, every
// statement after it shifts, and the function ends with the parser still inside a construct:
// `syntax error at end of input`, 90k characters from the cause, at APPLY time. The file parses.
// The hunk is perfectly if/end-if balanced. Only the ASSEMBLED body shows it.
//
// The chain's own law (0350 assert (f)) makes assembly possible offline: after the last FULL textual
// re-create of a function, every later migration only does SURGERY over the deployed text. So this
// walks the migrations in version order, resets the body on a top-level `create or replace`, applies
// every later hunk, and compiles the result.
//
// SELF-VALIDATING: every needle must match EXACTLY ONCE, which is what the migrations themselves
// assert at apply time. If the reconstruction had drifted from what the chain really produces, a
// needle would miss and this reports that instead of quietly compiling a body nobody will ever run.
//
// WHAT IT MODELS, PRECISELY: the DISPOSABLE-CHAIN apply, which builds from these same files in this
// same order — so a green here predicts CI's apply. It does NOT model PRODUCTION, whose deployed
// body can legitimately differ from the repo-derived one (0351's own header says a difference there
// is a review signal, not a failure). It is not a substitute for the disposable matrix.
function assembleTargets(migDir) {
  const files = readdirSync(migDir).filter((f) => f.endsWith('.sql')).sort();
  const parsed = files.map((f) => ({ f, src: readFileSync(path.join(migDir, f), 'utf8') }));
  // every function the chain performs surgery on
  const targets = new Set();
  for (const { src } of parsed) for (const h of extractHunks(src)) targets.add(h.fname);

  const out = [];
  for (const target of [...targets].sort()) {
    let body = null, base = null, origin = null, applied = 0;
    let broken = null;
    for (const { f, src } of parsed) {
      for (const st of split(src)) {
        // NOTE: split() yields {text, line} objects, not strings.
        const s = st.text.replace(/^(\s*--[^\n]*\n)+/, '').trim();
        // BOTH the schema-qualified and the bare form. Matching only `public.<name>(` made the
        // reconstruction of reward_grant start from a body 300 migrations stale, and the resulting
        // "does not compile" was the tool's fault rather than the repo's.
        if (!new RegExp(`^create\\s+or\\s+replace\\s+function\\s+(?:public\\.)?${target}\\s*\\(`, 'i').test(s)) continue;
        const dm = /\bas\s+(\$[A-Za-z_][A-Za-z0-9_]*\$|\$\$)/i.exec(s);
        if (!dm) continue;
        const bOpen = dm.index + dm[0].length;
        const bClose = s.indexOf(dm[1], bOpen);
        if (bClose === -1) continue;
        body = s.slice(bOpen, bClose); base = body; origin = f; applied = 0;
      }
      if (body === null) continue;
      for (const h of extractHunks(src).filter((h) => h.fname === target).sort((a, b) => a.idx - b.idx)) {
        const n = body.split(h.old_t).length - 1;
        if (n !== 1) { broken = `${f} hunk [${h.idx}] needle matches ${n} time(s) (want exactly 1)`; break; }
        body = body.replace(h.old_t, h.new_t); applied++;
      }
      if (broken) break;
    }
    out.push({ target, body, base, origin, applied, broken });
  }
  return out;
}

// ═══ RUN ═════════════════════════════════════════════════════════════════════════════════════════
// Check (B) is pure text and always runs. Check (A) needs a real PostgreSQL, which is
// @electric-sql/pglite (a devDependency — WASM, no Docker, no server). If it cannot be resolved the
// gate does NOT quietly become half a gate: it says so, and it FAILS whenever --require-blocks was
// asked for. A skipped check that still exits 0 is the vacuity this file exists to refuse.
let db = null, compileSkipped = null;
try {
  const { PGlite } = await import('@electric-sql/pglite');
  db = await new PGlite();
} catch (e) {
  compileSkipped = String(e.message).split('\n')[0];
  console.log(`  WARN check (A) SKIPPED — could not start the WASM PostgreSQL: ${compileSkipped}`);
  console.log('       `npm i` should provide @electric-sql/pglite (devDependency). Only the surgery-hunk balance check (B) ran.');
}

let failures = 0, nBlocks = 0, nHunks = 0, nFiles = 0, nSchemaSkipped = 0;
const schemaSkips = [];
const say = (s) => { if (!opts.quiet) console.log(s); };

for (const file of files) {
  const src = readFileSync(file, 'utf8');
  const base = path.basename(file);
  nFiles++;
  const stmts = split(src);
  let fileFail = 0;

  for (const ln of stmts.loneDollar) {
    fileFail++;
    console.log(`  FAIL ${base}:${ln}  lone "$" — not a valid dollar-quote delimiter (a delimiter is $, an optional tag, then $). PostgreSQL raises: syntax error at or near "$"`);
  }
  for (const u of stmts.unterminated) {
    fileFail++;
    console.log(`  FAIL ${base}:${u.line}  unterminated ${u.what} — the parser reaches EOF still inside it`);
  }

  // (A) compile every plpgsql block
  let k = 0;
  for (const { text, line } of stmts) {
    const s = text.replace(/^(\s*--[^\n]*\n)+/, '').trim();
    const doM = /^do\s+(\$[A-Za-z0-9_]*\$)([\s\S]*)\1\s*;?$/i.exec(s);
    const fnM = /^create\s+(or\s+replace\s+)?function\s+([\s\S]*?)\s+as\s+(\$[A-Za-z0-9_]*\$)([\s\S]*)\3\s*;?$/i.exec(s);
    if (doM && db) {
      k++; nBlocks++;
      const tag = `$plchk${k}$`;
      const body = doM[2].split(tag).join('$plchk_esc$');
      try {
        await db.exec(`create or replace function pg_temp._chk${k}() returns void language plpgsql as ${tag}${body}${tag};`);
      } catch (e) {
        const msg = String(e.message).split('\n')[0];
        // ── THE ONE EXEMPTION, AND ITS BOUNDARY ─────────────────────────────────────────────────
        // A DECLARE of a TABLE-COMPOSITE type (`t_bat public.module_types;`) or a `tbl%ROWTYPE` /
        // `tbl.col%TYPE` needs
        // the real schema, which this gate deliberately does not have: plpgsql resolves declared
        // TYPES at compile time even though it resolves table REFERENCES lazily, so these raise on
        // a perfectly good block. The exemption is pinned to that exact message and is COUNTED and
        // PRINTED, never silent — if it ever starts absorbing many blocks the gate is measuring
        // less than it claims, and the count is what says so.
        if (/(?:type|relation) "[^"]+" does not exist/.test(msg)) { nSchemaSkipped++; schemaSkips.push(`${base}:${line} ${msg}`); continue; }
        fileFail++;
        console.log(`  FAIL ${base}:${line}  do-block: ${msg}`);
      }
    } else if (fnM && db && /language\s+plpgsql/i.test(fnM[2])) {
      k++; nBlocks++;
      try { await db.exec(s.endsWith(';') ? s : s + ';'); }
      catch (e) {
        const msg = String(e.message).split('\n')[0];
        // same exemption, same boundary — see the do-block branch above.
        if (/(?:type|relation) "[^"]+" does not exist/.test(msg)) { nSchemaSkipped++; schemaSkips.push(`${base}:${line} ${msg}`); continue; }
        fileFail++;
        console.log(`  FAIL ${base}:${line}  plpgsql function: ${msg}`);
      }
    }
    // `language sql` bodies are fully ANALYZED at create time (real tables required), so they are
    // not compiled here. Their dollar-quoting was still validated by the splitter above.
  }

  // (B) surgery hunk balance
  for (const h of extractHunks(src)) {
    nHunks++;
    const a = depthDelta(h.old_t), b = depthDelta(h.new_t);
    for (const kind of ['if', 'loop']) {
      const K = kind[0].toUpperCase() + kind.slice(1);
      if (a[kind] !== b[kind]) {
        fileFail++;
        console.log(
          `  FAIL ${base}:${h.line}  hunk [${h.idx}] on public.${h.fname} changes ${kind.toUpperCase()} nesting: ` +
          `pre-image net ${a[kind] >= 0 ? '+' : ''}${a[kind]}, replacement net ${b[kind] >= 0 ? '+' : ''}${b[kind]}. ` +
          `A replacement must leave the enclosing block depth exactly where it found it, or the function it is ` +
          `spliced into stops being balanced and the apply raises 42601 "syntax error at end of input". ` +
          `(openers/closers — pre-image ${a._raw['open' + K]}/${a._raw['end' + K]}, ` +
          `replacement ${b._raw['open' + K]}/${b._raw['end' + K]})`
        );
      }
    }
  }

  failures += fileFail;
  say(`  ${fileFail === 0 ? 'ok  ' : 'FAIL'} ${base}: ${k} plpgsql block(s), ${extractHunks(src).length} surgery hunk(s)`);
}

// ── (C) ASSEMBLE + COMPILE ───────────────────────────────────────────────────────────────────────
let nAssembled = 0;
if (opts.assembleDir) {
  const dir = toNativePath(opts.assembleDir);
  if (!existsSync(dir)) {
    console.log(`  FAIL --assemble directory "${opts.assembleDir}" does not exist (resolved "${dir}")`);
    failures++;
  } else if (!db) {
    console.log('  FAIL --assemble was asked for but the WASM PostgreSQL could not start, so the assembled bodies were never compiled.');
    failures++;
  } else {
    for (const a of assembleTargets(dir)) {
      if (a.broken) { console.log(`  FAIL assemble public.${a.target}: ${a.broken} — a hunk that will not apply is an apply-time failure in its own right`); failures++; continue; }
      if (a.body === null || a.applied === 0) continue;   // surgery on a body no repo file re-creates
      // ── BLAME THE HUNKS ONLY IF THE BASE WAS SOUND ──────────────────────────────────────────────
      // The BASE (the newest full re-create, before any hunk) is compiled first. If IT does not
      // compile in this schema-less harness, the reconstruction is what is suspect, not the repo:
      // reward_grant's newest re-create is from 20260617000040 and uses constructs this gate cannot
      // resolve, and reporting that as "the chain will not apply" would be a FALSE RED — the thing
      // that trains people to stop reading a gate. Such targets are counted as a coverage gap.
      // This costs nothing on the case that matters: 0351's base compiled clean and the hunk broke
      // it, which is exactly the shape this check is here to catch.
      const neutralise = (b) => b
        .replace(/^(\s*[a-z_][a-z0-9_]*\s+)[a-z_][a-z0-9_."]*%rowtype\s*;/gim, '$1record;')
        .replace(/^(\s*[a-z_][a-z0-9_]*\s+)[a-z_][a-z0-9_."]*%type\s*;/gim, '$1text;');
      let baseOk = true;
      try {
        await db.exec(`create or replace function pg_temp.__base${nAssembled}() returns integer language plpgsql as $ASMBASE$${neutralise(a.base)}$ASMBASE$;`);
      } catch (e) {
        baseOk = false;
        nSchemaSkipped++;
        schemaSkips.push(`assembled public.${a.target}: BASE (${a.origin}, pre-hunk) does not compile here — ${String(e.message).split('\n')[0]} — so this target's assembly is a coverage gap, not a verdict`);
      }
      if (!baseOk) continue;
      // Neutralise SCHEMA-DEPENDENT DECLARATIONS, and only those. plpgsql resolves declared TYPES at
      // compile time, so `e combat_encounters%rowtype` would fail here and mask the syntax error we
      // are hunting. Rewriting DECLARATIONS to record/text keeps every executable statement exactly
      // as written — the parse stays honest, only the schema dependency goes.
      nAssembled++;
      try {
        await db.exec(`create or replace function pg_temp.__asm${nAssembled}() returns integer language plpgsql as $ASMBODY$${neutralise(a.body)}$ASMBODY$;`);
        say(`  ok   assembled public.${a.target}: ${a.applied} hunk(s) over ${a.origin}, ${a.body.length} chars, COMPILES`);
      } catch (e) {
        const msg = String(e.message).split('\n')[0];
        // the SAME schema boundary check (A) honours: a declared type/relation this gate has no
        // schema for. Counted and listed, never silently swallowed.
        if (/(?:type|relation) "[^"]+" does not exist/.test(msg)) {
          nSchemaSkipped++; schemaSkips.push(`assembled public.${a.target}: ${msg}`); nAssembled--; continue;
        }
        failures++;
        console.log(`  FAIL assembled public.${a.target} does not COMPILE: ${msg}`);
        console.log(`       (${a.applied} hunk(s) applied over ${a.origin}, ${a.body.length} chars.) This is the body the disposable chain will build, so this is an APPLY-TIME failure. Neither the per-file parse nor the hunk-balance check can see it: a bare \`case when … then … end\` inside an IF condition, for instance, is perfectly balanced and still truncates the condition at its own THEN.`);
      }
    }
  }
}

// ── NON-VACUITY FLOORS ───────────────────────────────────────────────────────────────────────────
const floor = (got, want, what) => {
  if (want > 0 && got < want) {
    console.log(`  FAIL non-vacuity: scanned ${got} ${what} but --require-${what.split(' ')[0]} says at least ${want}. A scan that quietly stops finding things must be RED, not green.`);
    return 1;
  }
  return 0;
};
failures += floor(nFiles, opts.requireFiles, 'files');
failures += floor(nHunks, opts.requireHunks, 'hunks');
failures += floor(nAssembled, opts.requireAssembled, 'assembled functions');
if (compileSkipped && opts.requireBlocks > 0) {
  console.log(`  FAIL check (A) was SKIPPED but --require-blocks ${opts.requireBlocks} was asked for. The parse/compile half of this gate did not run, so its silence means nothing: ${compileSkipped}`);
  failures++;
} else {
  failures += floor(nBlocks, opts.requireBlocks, 'blocks');
}

// ── EXIT VIA process.exitCode, NEVER process.exit(), AND THAT IS NOT A STYLE CHOICE ─────────────
// With the WASM PostgreSQL loaded, calling process.exit() makes libuv on Windows abort during
// teardown — `Assertion failed: !(handle->flags & UV_HANDLE_CLOSING)` — AFTER the verdict has
// already been printed, and the process leaves with 127. A gate whose exit code contradicts its own
// output is worse than no gate: CI would have read this as failing on a clean tree, and (in the
// other direction) any wrapper that only looked at stdout would have read a red run as green.
// Measured on this machine: close()+exit() 127, exit() 127, close()+exitCode 0, exitCode 0.
if (db) { try { await db.close(); } catch { /* teardown only; the verdict is already decided */ } }

if (nSchemaSkipped > 0) {
  console.log(`  note: ${nSchemaSkipped} block(s) declare a type/rowtype this schema-less gate cannot resolve, so they were NOT compiled — counted and listed rather than hidden. This is the gate's coverage boundary, not a clean bill of health for those blocks:`);
  for (const sk of schemaSkips) console.log(`        · ${sk}`);
}
if (failures > 0) {
  console.log(`check-plpgsql-parse FAIL: ${failures} problem(s) across ${nFiles} file(s).`);
  process.exitCode = 1;
} else {
  console.log(`check-plpgsql-parse OK: ${nFiles} file(s), ${compileSkipped ? '0 (check A SKIPPED)' : nBlocks} plpgsql block(s) compiled against a real PostgreSQL, ${nHunks} surgery hunk(s) balance-checked, ${nAssembled} surgery-assembled function body(ies) compiled.`);
  process.exitCode = 0;
}
