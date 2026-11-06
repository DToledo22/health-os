# Health OS

Personal WHOOP dashboard. Static page (GitHub Pages) reading from a private Supabase project.

- **Data pipeline:** WHOOP API v2 → Supabase Edge Function `whoop-sync` (pg_cron, every 6h) → Postgres tables `whoop.*`
- **Access:** Supabase Auth magic link; row-level security allows reads only for signed-in users. The key in `index.html` is the public *publishable* key — safe to commit.
- **Dashboard:** `index.html` — Chart.js, no build step.

Source for the sync function and schema lives in the Supabase project (`supabase/` folder in this repo).
