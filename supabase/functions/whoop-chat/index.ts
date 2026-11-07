// whoop-chat — "Ask" panel backend. Verifies the Supabase session, then lets Claude answer questions
// about the whoop.* data with a guarded read-only SQL tool. Requires secret ANTHROPIC_API_KEY.
import { createClient } from "npm:@supabase/supabase-js@2";

const env = (k: string, d?: string) => Deno.env.get(k) ?? d ?? (() => { throw new Error(`Missing env ${k}`); })();
const ALLOWED_ORIGINS = ["https://dtoledo22.github.io", "http://localhost:8765", "http://localhost:5173"];
const MODEL = Deno.env.get("ANTHROPIC_MODEL") || "claude-sonnet-5-5";
const MAX_TURNS = 8;

const admin = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), { db: { schema: "whoop" } });

function cors(req: Request) {
  const o = req.headers.get("origin") || "";
  const allow = ALLOWED_ORIGINS.includes(o) ? o : ALLOWED_ORIGINS[0];
  return { "Access-Control-Allow-Origin": allow, "Access-Control-Allow-Headers": "authorization, content-type, apikey", "Access-Control-Allow-Methods": "POST, OPTIONS", "Vary": "Origin" };
}

const SYSTEM = `You are the analyst behind "Health OS", a personal dashboard built on one person's WHOOP data (David, in America/Los_Angeles).
You answer questions about his sleep, recovery, strain, HRV, resting heart rate and workouts by querying his database with the run_sql tool, then explaining what the numbers say and what to do about it. Be specific, quantitative and concise. Prefer short paragraphs and small lists. Never invent numbers — if you state a figure, it came from a query. Use plain language; you are a sharp coach, not a doctor (no diagnoses; suggest a clinician for medical concerns).

DATA MODEL (schema "whoop", query views directly, no schema prefix needed):
- daily_with_baselines: one row per WHOOP cycle, labeled by wake-up date. Columns: day (date), cycle_id, start_at, end_at, tz_offset, sleep_start_at, sleep_end_at, bedtime_min (minutes after 18:00 local; 360 = midnight, 420 = 1am), waketime_min (minutes after local midnight), strain (0-21), kilojoule, avg_hr, max_hr, recovery_score (0-100; green>=67, yellow 34-66, red<34), rhr (bpm), hrv_rmssd_ms, spo2_pct, skin_temp_c, performance_pct (sleep performance), consistency_pct, efficiency_pct, respiratory_rate, in_bed_ms, awake_ms, light_ms, sws_ms (deep), rem_ms, asleep_ms (light+deep+rem), need_baseline_ms, need_debt_ms, need_strain_ms, need_nap_ms (NEGATIVE when a nap reduced need), disturbance_count, sleep_cycle_count, workout_count, plus rolling baselines hrv_7d, hrv_30d, rhr_7d, rhr_30d, recovery_7d, recovery_30d, strain_7d, asleep_7d. Total sleep need = need_baseline_ms + need_debt_ms + need_strain_ms + need_nap_ms. Durations are milliseconds (divide by 3600000 for hours).
- weekly: week_start, days, avg_recovery, avg_hrv, avg_rhr, avg_strain, total_strain, avg_sleep_hours, avg_sleep_perf, workouts.
- workouts: id, start_at, end_at, tz_offset, sport_name, score_state, strain, avg_hr, max_hr, kilojoule, distance_m, altitude_gain_m, zone_zero_ms..zone_five_ms. A workout belongs to the cycle whose [start_at, end_at) contains its start_at.
- notes: week_start, title, body_md, highlights (prior coach's notes).
WHOOP semantics: a cycle starts at sleep onset and ends at the next sleep onset; the recovery score is computed from the sleep at the START of the cycle, so "day" = the morning he woke up. The newest row is "today" (it may still be open: end_at null). Compare like with like: use the person's own baselines, not population norms.
SQL rules: Postgres, single SELECT/WITH statement, no semicolons, at most 200 rows (aggregate rather than dumping rows). Local time = start_at + tz_offset interval. Round numbers sensibly. Today's date (UTC): ${new Date().toISOString().slice(0, 10)}.`;

const TOOLS = [{
  name: "run_sql",
  description: "Run one read-only SQL SELECT against the whoop schema and get rows back as JSON (max 200 rows).",
  input_schema: { type: "object", properties: { sql: { type: "string", description: "A single Postgres SELECT or WITH query." }, purpose: { type: "string", description: "One short phrase: what this query answers." } }, required: ["sql"] },
}];

async function callClaude(messages: unknown[], key: string) {
  const r = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({ model: MODEL, max_tokens: 1500, system: SYSTEM, tools: TOOLS, messages }),
  });
  const j = await r.json();
  if (!r.ok) throw new Error(`Anthropic ${r.status}: ${j?.error?.message || JSON.stringify(j).slice(0, 300)}`);
  return j;
}

Deno.serve(async (req) => {
  const headers = { ...cors(req), "Content-Type": "application/json" };
  if (req.method === "OPTIONS") return new Response("ok", { headers });
  if (req.method !== "POST") return new Response(JSON.stringify({ error: "POST only" }), { status: 405, headers });

  // 1) who is asking — must be a signed-in user of this project
  const auth = req.headers.get("authorization") || "";
  const token = auth.replace(/^Bearer\s+/i, "");
  const { data: u, error: uerr } = await admin.auth.getUser(token);
  if (uerr || !u?.user) return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers });

  const key = Deno.env.get("ANTHROPIC_API_KEY");
  if (!key) return new Response(JSON.stringify({ error: "not_configured", message: "Add ANTHROPIC_API_KEY to this project's Edge Function secrets to enable Ask." }), { status: 503, headers });

  let body: { messages?: { role: string; content: string }[] };
  try { body = await req.json(); } catch { return new Response(JSON.stringify({ error: "bad json" }), { status: 400, headers }); }
  const history = (body.messages || []).slice(-12).filter(m => m.role === "user" || m.role === "assistant").map(m => ({ role: m.role, content: String(m.content).slice(0, 4000) }));
  if (!history.length || history[history.length - 1].role !== "user") return new Response(JSON.stringify({ error: "no question" }), { status: 400, headers });

  // 2) light context so simple questions need no query
  const { data: recent } = await admin.from("daily_with_baselines").select("day,recovery_score,hrv_rmssd_ms,rhr,strain,asleep_ms,performance_pct,hrv_7d,hrv_30d,rhr_7d,rhr_30d,recovery_7d,recovery_30d").order("day", { ascending: false }).limit(7);
  const messages: unknown[] = [...history];
  (messages[messages.length - 1] as { content: string }).content += `\n\n[context: last 7 rows of daily_with_baselines: ${JSON.stringify(recent)}]`;

  // 3) agent loop
  const queries: { sql: string; purpose?: string; rows?: number; error?: string }[] = [];
  let answer = "", usage = { input_tokens: 0, output_tokens: 0 };
  try {
    for (let turn = 0; turn < MAX_TURNS; turn++) {
      const res = await callClaude(messages, key);
      usage.input_tokens += res.usage?.input_tokens || 0; usage.output_tokens += res.usage?.output_tokens || 0;
      const toolUses = (res.content || []).filter((c: { type: string }) => c.type === "tool_use");
      const text = (res.content || []).filter((c: { type: string }) => c.type === "text").map((c: { text: string }) => c.text).join("\n");
      if (!toolUses.length || res.stop_reason !== "tool_use") { answer = text; break; }
      messages.push({ role: "assistant", content: res.content });
      const results = [];
      for (const tu of toolUses) {
        const sql = String(tu.input?.sql || ""); const q = { sql, purpose: tu.input?.purpose } as typeof queries[number];
        const { data, error } = await admin.rpc("run_readonly", { q: sql, max_rows: 200 });
        if (error) { q.error = error.message; results.push({ type: "tool_result", tool_use_id: tu.id, content: `ERROR: ${error.message}`, is_error: true }); }
        else { const rows = Array.isArray(data) ? data : []; q.rows = rows.length; results.push({ type: "tool_result", tool_use_id: tu.id, content: JSON.stringify(rows).slice(0, 20000) }); }
        queries.push(q);
      }
      messages.push({ role: "user", content: results });
      if (turn === MAX_TURNS - 1) answer = text || "I ran out of steps before finishing — try a narrower question.";
    }
  } catch (e) {
    return new Response(JSON.stringify({ error: "upstream", message: String(e instanceof Error ? e.message : e) }), { status: 502, headers });
  }
  const question = history[history.length - 1].content.replace(/\n\n\[context:.*$/s, "");
  await admin.from("chat_log").insert({ question, answer, queries, model: MODEL, ...usage });
  return new Response(JSON.stringify({ answer, queries, model: MODEL, usage }), { headers });
});
