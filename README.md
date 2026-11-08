# Health OS

Personal WHOOP dashboard. Static page (GitHub Pages) reading from a private Supabase project.

- **Data pipeline:** WHOOP API v2 → Supabase Edge Function `whoop-sync` (pg_cron, every 6h) → Postgres tables `whoop.*`
- **Access:** Supabase Auth magic link; row-level security allows reads only for signed-in users. The key in `index.html` is the public *publishable* key — safe to commit.
- **Dashboard:** `index.html` — Chart.js, no build step.

Source for the sync function and schema lives in the Supabase project (`supabase/` folder in this repo).

## Why the spiral

The Health OS mark is a golden spiral. It comes from the golden ratio — a proportion found everywhere in nature, from seashells to sunflowers to the way our own bodies are built. What makes it special is balance: every part relates to the whole in exactly the right measure. Nothing is too much, nothing is too little, and each turn of the spiral grows from the one before it without ever losing its shape.

That's how we think about health.

Health isn't one number. Sleep, recovery, training, heart rate, stress — they all pull on each other, and pushing hard on one usually costs you somewhere else. Real progress comes from getting the proportions right, not from maxing out any single part.

And the right proportions are yours alone. The ratio is the same in every shell, but every shell is a different size. Your sleep need, your recovery rhythm, your tolerance for load are specific to you, so the only fair comparison is against your own baseline — never against an average, a leaderboard, or someone else's week.

So the spiral is a reminder, every time you open the app: look at the whole picture, find the balance that fits your body, and let it grow turn by turn.
