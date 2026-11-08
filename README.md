# Health OS

Personal WHOOP dashboard. Static page (GitHub Pages) reading from a private Supabase project.

- **Data pipeline:** WHOOP API v2 → Supabase Edge Function `whoop-sync` (pg_cron, every 6h) → Postgres tables `whoop.*`
- **Access:** Supabase Auth magic link; row-level security allows reads only for signed-in users. The key in `index.html` is the public *publishable* key — safe to commit.
- **Dashboard:** `index.html` — Chart.js, no build step.

Source for the sync function and schema lives in the Supabase project (`supabase/` folder in this repo).

## Why the spiral

The Health OS mark is a golden spiral — the curve you get when you cut a square off a golden rectangle, then a square off what's left, and keep going. Every turn is the same shape as the last, just bigger.

That's the idea the app is built on, in three parts:

1. **Proportion, not maximums.** The golden ratio is the one split where the whole relates to the big part exactly as the big part relates to the small one — nothing dominates, nothing is wasted. Health works the same way: not the most training, not the most rest, but the right proportion of strain to sleep to recovery, measured against *your* baseline rather than a population average.
2. **Growth without distortion.** A nautilus adds a chamber and stays a nautilus. That's healthspan — getting older without getting worse — and it's how the dashboard works: one more night, one more session, compounding on what came before.
3. **It's never finished.** The spiral has no last turn. There's always the next morning's number, which is why the mark is a curve and not a closed shape.

The same mark appears everywhere — home-screen icon, app header, sign-in screen and the printed report — so the thing you tap and the thing you read are visibly one system.
