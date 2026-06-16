# Byeharu — Dev Log

Running record of **requests**, **work done**, **bugs**, and **fixes**.
Newest entries at the top. Dates are absolute (YYYY-MM-DD).

---

## 2026-06-16 — Rename to Byeharu

**Request**
Change the game name to **Byeharu** (the initial scaffold used "Byeolharu"; user
confirmed the shorter spelling).

**Work done**
- Renamed project folder `byeolharu` → `byeharu`.
- Updated `package.json` / `package-lock.json` name, `index.html` title, README,
  the migration comment, the Supabase client warning tag, and the AuthPage /
  Dashboard headings from "Byeolharu" to "Byeharu".
- Updated saved project memory.

**Bugs / fixes**
- _(none)_

---

## 2026-06-16 — Milestone 1: Scaffold + auth

**Request**
Rebuild the PvE space-strategy game from scratch as a clean web-first project named
**Byeolharu**. Stack: React + TypeScript + Vite, Tailwind, Zustand, Supabase
(Postgres + Auth + RLS + RPC + pg_cron). Server-authoritative, modular systems,
milestone-by-milestone. First milestone: scaffold + basic auth structure.

**Work done**
- Created Vite React+TS project at `C:\Users\디폴리스\byeharu`.
- Installed `zustand`, `@supabase/supabase-js`, `react-router-dom`, and
  `tailwindcss` + `@tailwindcss/vite` (Tailwind v4).
- Wired Tailwind via the Vite plugin (`vite.config.ts`) and `@import 'tailwindcss'`
  in `src/index.css`.
- Supabase client at `src/lib/supabase.ts`; env typing in `src/vite-env.d.ts`;
  `.env.example` with `VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY`.
- Auth: Zustand store `src/store/authStore.ts` (session, signIn/signUp/signOut,
  `init()` listener); `src/features/auth/AuthPage.tsx` (login/signup);
  `src/app/RequireAuth.tsx` route guard; routing in `src/app/App.tsx`.
- Placeholder `src/features/dashboard/Dashboard.tsx`.
- DB: migration `supabase/migrations/20260616000001_init_profiles.sql` —
  `profiles` table, RLS (own-row read/update), auto-create-profile trigger on
  `auth.users` (SECURITY DEFINER).
- CI: `.github/workflows/deploy-migrations.yml` to `supabase db push` on push to
  `main`.
- Removed default Vite demo files (`App.tsx`/`App.css`/sample assets); updated
  `index.html` title and `.gitignore` for env files.

**Bugs / fixes**
- _(none yet)_

**Open follow-ups**
- User must create a Supabase project and fill `.env.local`.
- For CI: add repo secrets `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_ID`,
  `SUPABASE_DB_PASSWORD`.
- Run `npm run build` / typecheck once `.env.local` exists to confirm green.

---
