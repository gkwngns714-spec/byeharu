import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// WORLD EDITOR V1.5 — STRUCTURAL GUARDS for the client-side OWNER gate on /dev/world. Source-text proofs
// (the repo runs pure-Node specs, no React render harness): the editor + History surface renders ONLY for
// an authenticated OWNER with the flag lit; a non-owner or any owner-lookup failure fails closed; owner
// status reuses the ONE authoritative deployed is_owner() RPC (no second ownership concept, no
// email/metadata/flag inference); the backend boundary is untouched.

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const read = (p: string): string => readFileSync(join(ROOT, p), 'utf8')

test('owner status reuses the deployed is_owner() RPC and is fail-closed (never inferred client-side)', () => {
  const cat = read('src/lib/catalog.ts')
  expect(cat).toContain('export async function fetchIsOwner')
  expect(cat).toContain("supabase.rpc('is_owner')") // the ONE authoritative predicate (0243), reused
  // fail-closed on transport error
  const body = /export async function fetchIsOwner\(\): Promise<boolean> \{([\s\S]*?)\n\}/.exec(cat)?.[1] ?? ''
  expect(body).toContain('if (error) return false')
  expect(body).toContain('data === true')
  // MUST NOT infer ownership from email / user metadata / the feature flag / route knowledge
  expect(body).not.toMatch(/email|user_metadata|app_metadata|dev_zone_editor|raw_user/i)
})

test('WorldEditor gates the whole surface on owner status before rendering (fail-closed, ordered)', () => {
  const we = read('src/features/worldeditor/WorldEditor.tsx')
  expect(we).toContain('fetchIsOwner')
  expect(we).toMatch(/const \[isOwner, setIsOwner\] = useState<boolean \| null>\(null\)/)
  // the render gate, in fail-closed order: flag → owner-resolving → non-owner
  expect(we).toContain('if (enabled !== true) return null')
  expect(we).toContain('if (isOwner === null) return null')
  expect(we).toContain('if (isOwner !== true)')
  // map data is fetched ONLY for an owner with the flag lit
  expect(we).toMatch(/if \(on && owner\)/)
})

test('the History panel (and the editor) never mount before the owner gate resolves in favor of the owner', () => {
  const we = read('src/features/worldeditor/WorldEditor.tsx')
  const gateIdx = we.indexOf('if (isOwner !== true)')
  const panelIdx = we.indexOf('<WorldEditorHistoryPanel')
  const editorReturnIdx = we.indexOf('const k = view.k') // the main render begins after the gates
  expect(gateIdx).toBeGreaterThan(0)
  expect(panelIdx).toBeGreaterThan(gateIdx) // panel mount is AFTER the owner gate
  expect(editorReturnIdx).toBeGreaterThan(gateIdx) // the whole editor render is AFTER the owner gate
})

test('no second ownership model + backend boundary untouched (client only CALLS the RPC, never redefines it)', () => {
  const cat = read('src/lib/catalog.ts')
  // the client does not define/replace is_owner — it only invokes the deployed function
  expect(cat).not.toMatch(/function is_owner|create (or replace )?function/i)
  // the existing auth gate is preserved: /dev/world stays behind RequireAuth
  const app = read('src/app/App.tsx')
  expect(app).toContain('/dev/world')
  expect(app).toMatch(/<RequireAuth>[\s\S]*WorldEditor[\s\S]*<\/RequireAuth>/)
})
