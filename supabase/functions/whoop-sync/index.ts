// whoop-sync — Supabase Edge Function
// Refreshes the WHOOP OAuth token, pulls new/updated records, upserts into whoop.* tables.
// Modes:  ?mode=incremental (default, last 3 days)   ?mode=backfill (full history)
// Auth:   requires header  x-sync-secret: <SYNC_SECRET>

import { createClient } from "npm:@supabase/supabase-js@2";

const WHOOP_API = "https://api.prod.whoop.com/developer/v2";
const WHOOP_TOKEN = "https://api.prod.whoop.com/oauth/oauth2/token";

const env = (k: string) => {
  const v = Deno.env.get(k);
  if (!v) throw new Error(`Missing env ${k}`);
  return v;
};

const sb = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
  db: { schema: "whoop" },
});

// ---------- token handling ----------
async function getAccessToken(): Promise<string> {
  const { data: tok, error } = await sb.from("tokens").select("*").eq("id", 1).single();
  if (error || !tok) throw new Error("No WHOOP token stored. Run the authorize step first.");
  const expiresSoon = new Date(tok.expires_at).getTime() - Date.now() < 5 * 60 * 1000;
  if (!expiresSoon) return tok.access_token;

  const body = new URLSearchParams({
    grant_type: "refresh_token",
    refresh_token: tok.refresh_token,
    client_id: env("WHOOP_CLIENT_ID"),
    client_secret: env("WHOOP_CLIENT_SECRET"),
    scope: "offline",
  });
  const r = await fetch(WHOOP_TOKEN, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!r.ok) throw new Error(`Token refresh failed ${r.status}: ${await r.text()}`);
  const j = await r.json();
  const expires_at = new Date(Date.now() + (j.expires_in ?? 3600) * 1000).toISOString();
  await sb.from("tokens").upsert({
    id: 1,
    access_token: j.access_token,
    refresh_token: j.refresh_token ?? tok.refresh_token,
    expires_at,
    scope: j.scope,
    updated_at: new Date().toISOString(),
  });
  return j.access_token;
}

// ---------- paginated fetch ----------
async function* paginate(token: string, path: string, start?: string) {
  let nextToken: string | undefined;
  do {
    const url = new URL(`${WHOOP_API}${path}`);
    url.searchParams.set("limit", "25");
    if (start) url.searchParams.set("start", start);
    if (nextToken) url.searchParams.set("nextToken", nextToken);
    let r = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
    if (r.status === 429) {
      await new Promise((res) => setTimeout(res, 65_000));
      r = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
    }
    if (!r.ok) throw new Error(`${path} ${r.status}: ${await r.text()}`);
    const j = await r.json();
    for (const rec of j.records ?? []) yield rec;
    nextToken = j.next_token || undefined;
  } while (nextToken);
}

// ---------- mappers ----------
const num = (v: unknown) => (v === undefined || v === null ? null : Number(v));

const mapCycle = (c: any) => ({
  id: c.id, user_id: c.user_id, start_at: c.start, end_at: c.end ?? null,
  tz_offset: c.timezone_offset, score_state: c.score_state,
  strain: num(c.score?.strain), kilojoule: num(c.score?.kilojoule),
  avg_hr: c.score?.average_heart_rate ?? null, max_hr: c.score?.max_heart_rate ?? null,
  raw: c, updated_at: c.updated_at,
});

const mapRecovery = (r: any) => ({
  cycle_id: r.cycle_id, sleep_id: r.sleep_id, user_id: r.user_id,
  score_state: r.score_state, user_calibrating: r.score?.user_calibrating ?? null,
  recovery_score: num(r.score?.recovery_score), rhr: num(r.score?.resting_heart_rate),
  hrv_rmssd_ms: num(r.score?.hrv_rmssd_milli), spo2_pct: num(r.score?.spo2_percentage),
  skin_temp_c: num(r.score?.skin_temp_celsius),
  raw: r, created_at: r.created_at, updated_at: r.updated_at,
});

const mapSleep = (s: any) => {
  const st = s.score?.stage_summary ?? {};
  const need = s.score?.sleep_needed ?? {};
  return {
    id: s.id, cycle_id: s.cycle_id ?? null, user_id: s.user_id,
    start_at: s.start, end_at: s.end ?? null, tz_offset: s.timezone_offset,
    nap: s.nap, score_state: s.score_state,
    performance_pct: num(s.score?.sleep_performance_percentage),
    consistency_pct: num(s.score?.sleep_consistency_percentage),
    efficiency_pct: num(s.score?.sleep_efficiency_percentage),
    respiratory_rate: num(s.score?.respiratory_rate),
    in_bed_ms: st.total_in_bed_time_milli ?? null, awake_ms: st.total_awake_time_milli ?? null,
    light_ms: st.total_light_sleep_time_milli ?? null, sws_ms: st.total_slow_wave_sleep_time_milli ?? null,
    rem_ms: st.total_rem_sleep_time_milli ?? null, no_data_ms: st.total_no_data_time_milli ?? null,
    sleep_cycle_count: st.sleep_cycle_count ?? null, disturbance_count: st.disturbance_count ?? null,
    need_baseline_ms: need.baseline_milli ?? null, need_debt_ms: need.need_from_sleep_debt_milli ?? null,
    need_strain_ms: need.need_from_recent_strain_milli ?? null, need_nap_ms: need.need_from_recent_nap_milli ?? null,
    raw: s, updated_at: s.updated_at,
  };
};

const mapWorkout = (w: any) => {
  const z = w.score?.zone_durations ?? {};
  return {
    id: w.id, user_id: w.user_id, start_at: w.start, end_at: w.end ?? null,
    tz_offset: w.timezone_offset, sport_id: w.sport_id ?? null, sport_name: w.sport_name ?? null,
    score_state: w.score_state, strain: num(w.score?.strain),
    avg_hr: w.score?.average_heart_rate ?? null, max_hr: w.score?.max_heart_rate ?? null,
    kilojoule: num(w.score?.kilojoule), distance_m: num(w.score?.distance_meter),
    altitude_gain_m: num(w.score?.altitude_gain_meter),
    zone_zero_ms: z.zone_zero_milli ?? null, zone_one_ms: z.zone_one_milli ?? null,
    zone_two_ms: z.zone_two_milli ?? null, zone_three_ms: z.zone_three_milli ?? null,
    zone_four_ms: z.zone_four_milli ?? null, zone_five_ms: z.zone_five_milli ?? null,
    raw: w, updated_at: w.updated_at,
  };
};

async function upsertBatch(table: string, rows: any[], pk: string) {
  for (let i = 0; i < rows.length; i += 200) {
    const { error } = await sb.from(table).upsert(rows.slice(i, i + 200), { onConflict: pk });
    if (error) throw new Error(`${table} upsert: ${error.message}`);
  }
}

async function syncCollection(token: string, path: string, table: string, pk: string, map: (x: any) => any, start?: string) {
  const rows: any[] = [];
  for await (const rec of paginate(token, path, start)) rows.push(map(rec));
  await upsertBatch(table, rows, pk);
  return rows.length;
}

async function syncProfile(token: string) {
  const h = { Authorization: `Bearer ${token}` };
  const [p, b] = await Promise.all([
    fetch(`${WHOOP_API}/user/profile/basic`, { headers: h }).then((r) => r.ok ? r.json() : null),
    fetch(`${WHOOP_API}/user/measurement/body`, { headers: h }).then((r) => r.ok ? r.json() : null),
  ]);
  if (!p) return;
  await sb.from("profile").upsert({
    user_id: p.user_id, email: p.email, first_name: p.first_name, last_name: p.last_name,
    height_m: b?.height_meter ?? null, weight_kg: b?.weight_kilogram ?? null, max_hr: b?.max_heart_rate ?? null,
    updated_at: new Date().toISOString(),
  });
}

// ---------- one-time authorize: exchange code → tokens ----------
async function authorize(code: string) {
  const body = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    client_id: env("WHOOP_CLIENT_ID"),
    client_secret: env("WHOOP_CLIENT_SECRET"),
    redirect_uri: env("WHOOP_REDIRECT_URI"),
  });
  const r = await fetch(WHOOP_TOKEN, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!r.ok) throw new Error(`Code exchange failed ${r.status}: ${await r.text()}`);
  const j = await r.json();
  if (!j.refresh_token) throw new Error("No refresh_token returned — was the 'offline' scope requested?");
  const { error } = await sb.from("tokens").upsert({
    id: 1,
    access_token: j.access_token,
    refresh_token: j.refresh_token,
    expires_at: new Date(Date.now() + (j.expires_in ?? 3600) * 1000).toISOString(),
    scope: j.scope,
    updated_at: new Date().toISOString(),
  });
  if (error) throw new Error(`token store: ${error.message}`);
  return j.scope;
}

// ---------- handler ----------
Deno.serve(async (req) => {
  if (req.headers.get("x-sync-secret") !== env("SYNC_SECRET")) {
    return new Response("unauthorized", { status: 401 });
  }
  const url = new URL(req.url);
  const mode = url.searchParams.get("mode") ?? "incremental";

  if (mode === "authorize") {
    try {
      const scope = await authorize(url.searchParams.get("code") ?? "");
      return Response.json({ ok: true, mode, scope });
    } catch (e) {
      return Response.json({ ok: false, mode, error: String(e) }, { status: 500 });
    }
  }
  // incremental: look back 3 days so late-scoring records get updated.
  const start = mode === "backfill" ? undefined : new Date(Date.now() - 3 * 86_400_000).toISOString();

  const counts = { cycles: 0, recovery: 0, sleep: 0, workouts: 0 };
  try {
    const token = await getAccessToken();
    await syncProfile(token);
    counts.cycles   = await syncCollection(token, "/cycle",            "cycles",   "id",       mapCycle,    start);
    counts.recovery = await syncCollection(token, "/recovery",         "recovery", "cycle_id", mapRecovery, start);
    counts.sleep    = await syncCollection(token, "/activity/sleep",   "sleep",    "id",       mapSleep,    start);
    counts.workouts = await syncCollection(token, "/activity/workout", "workouts", "id",       mapWorkout,  start);
    await sb.from("sync_log").insert({ mode, ...counts, ok: true });
    return Response.json({ ok: true, mode, ...counts });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    await sb.from("sync_log").insert({ mode, ...counts, ok: false, error: msg });
    return Response.json({ ok: false, mode, error: msg }, { status: 500 });
  }
});
