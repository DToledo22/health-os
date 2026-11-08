# Health OS

Personal WHOOP dashboard. Static page (GitHub Pages) reading from a private Supabase project.

- **Data pipeline:** WHOOP API v2 → Supabase Edge Function `whoop-sync` (pg_cron, every 6h) → Postgres tables `whoop.*`
- **Access:** Supabase Auth magic link; row-level security allows reads only for signed-in users. The key in `index.html` is the public *publishable* key — safe to commit.
- **Dashboard:** `index.html` — Chart.js, no build step.

Source for the sync function and schema lives in the Supabase project (`supabase/` folder in this repo).

## Why the spiral

The Health OS mark is a golden spiral, drawn from the golden ratio.

The golden ratio is a proportion that shows up all over nature — in seashells, flowers, and the human body. Its defining quality is balance: every part is in proportion to the whole. Nothing is too much, nothing is too little, and the spiral grows turn by turn without ever losing its shape.

We chose it because that is how health works.

**Health is a whole, not a single number.** Sleep, recovery, training, and stress all affect one another. Push too hard on one and another pays for it. Progress comes from keeping them in proportion, not from maxing out any one of them.

**The right proportion is personal.** Every seashell follows the same ratio, but no two are the same size. In the same way, your sleep need, your recovery pace, and how much training you can absorb are specific to you. That's why Health OS measures you against your own baseline — not an average, and not anyone else.

The spiral is the reminder: look at the whole picture, find the balance that fits your body, and let it grow one turn at a time.
