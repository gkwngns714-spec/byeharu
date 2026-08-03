import { test, expect } from '@playwright/test'
import {
  resolveRepositionCourse,
  COURSE_RUNNING_STATUSES,
  type RepositionCourseInput,
} from '../src/features/combat/repositionCourse'

// ── 0337: A REPOSITION IS A MOVE, AND THE CLIENT SAYS SO ──────────────────────────────────────────
// The server half of this slice deletes 0311's instant jump: command_ship_group_go now only RECORDS
// combat_encounters.reposition_x/reposition_y, and the combat tick walks the fleet there at the
// fleet's own speed over several ticks. These specs pin the client half — that a course in flight is
// STATED, that it never claims an arrival, and that every way of not having one degrades to silence
// rather than to a guess.

const base: RepositionCourseInput = {
  status: 'active',
  engagement_x: 100,
  engagement_y: 200,
  reposition_x: 130,
  reposition_y: 240,
}

test('a standing course is read off the encounter: destination, origin and remaining distance', () => {
  const c = resolveRepositionCourse(base)
  expect(c).not.toBeNull()
  expect(c!.destination).toEqual({ x: 130, y: 240 })
  expect(c!.from).toEqual({ x: 100, y: 200 })
  // 3-4-5 triangle scaled by 10 — the distance is measured, not approximated.
  expect(c!.remaining).toBeCloseTo(50, 10)
})

test('the sentence is PRESENT TENSE — it states a journey, never an arrival', () => {
  const text = resolveRepositionCourse(base)!.text
  expect(text).toBe('Moving to (130, 240) — 50 units to go. The fight moves with the fleet.')
  // THE REGRESSION THIS EXISTS TO CATCH. 0311 teleported the fleet and the UI said "moved to X".
  // 0337 deleted the teleport; a surface that still announces an arrival is the teleport surviving
  // in the copy, which is exactly the shape the owner reported ("i move, i teleport").
  expect(text).not.toContain('moved')
  expect(text).not.toContain('arrived')
  expect(text).not.toContain('jump')
  // and it is not a retreat: a reposition never breaks off the fight.
  expect(text.toLowerCase()).not.toContain('retreat')
})

test('the course is per FLEET — one destination, one distance, whatever the hull count', () => {
  // The owner: "why are there four ships? because i have 4 ships in fleet? no, show only fleet. it
  // is as a whole." The resolver's whole input is the ENCOUNTER row, which is per fleet by
  // construction, so there is no shape in which a hull count could produce a second course. This
  // spec pins that by contract: the input type carries no unit list at all.
  const c = resolveRepositionCourse(base)!
  expect(Object.keys(c).sort()).toEqual(['destination', 'from', 'remaining', 'text'])
})

test('no course recorded → null (renders nothing), not a zero-length course', () => {
  expect(resolveRepositionCourse({ ...base, reposition_x: null, reposition_y: null })).toBeNull()
  expect(resolveRepositionCourse({ status: 'active', engagement_x: 1, engagement_y: 2 })).toBeNull()
})

test('a pre-0337 server omits the columns entirely → null, never a guess', () => {
  // combatApi reads select('*'), so an older server simply does not send these keys. Absence must
  // fail closed for the same reason the engagement anchor does.
  const older = { status: 'active', engagement_x: 100, engagement_y: 200 } as RepositionCourseInput
  expect(resolveRepositionCourse(older)).toBeNull()
})

test('a RETREATING fight states no course, even though the row still carries one', () => {
  // 0337 deliberately clears NOTHING when a retreat is armed: the tick's reposition step re-reads
  // status = 'active', so the recorded destination is unreachable by construction and there is no
  // clearing write to forget. The client must apply the SAME rule — reporting a course the engine has
  // already stopped honouring would tell the player their fleet is still manoeuvring while it is in
  // fact breaking off.
  expect(resolveRepositionCourse({ ...base, status: 'retreating' })).toBeNull()
  for (const status of ['victory', 'defeat', 'escaped', 'completed']) {
    expect(resolveRepositionCourse({ ...base, status })).toBeNull()
  }
  expect([...COURSE_RUNNING_STATUSES]).toEqual(['active'])
})

test('a broken anchor or a non-finite coordinate yields null — never NaN on screen', () => {
  expect(resolveRepositionCourse({ ...base, engagement_x: null })).toBeNull()
  expect(resolveRepositionCourse({ ...base, engagement_y: undefined })).toBeNull()
  expect(resolveRepositionCourse({ ...base, reposition_x: Number.NaN })).toBeNull()
  expect(resolveRepositionCourse({ ...base, reposition_y: Number.POSITIVE_INFINITY })).toBeNull()
  expect(resolveRepositionCourse(null)).toBeNull()
  expect(resolveRepositionCourse(undefined)).toBeNull()
})

test('the tick that lands can be observed before the NULL: 0 remaining is a course, not an error', () => {
  // The order is consumed by the very tick that arrives, so a poll landing between the two is
  // possible. It must read as "there", not blow up or print a negative distance.
  const c = resolveRepositionCourse({ ...base, reposition_x: 100, reposition_y: 200 })
  expect(c).not.toBeNull()
  expect(c!.remaining).toBe(0)
  expect(c!.text).toContain('0 units to go')
})
