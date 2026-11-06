-- WHOOP → Supabase schema
-- Raw payloads are kept in jsonb; frequently-charted fields are promoted to columns.

create extension if not exists pg_cron;
create extension if not exists pg_net;

create schema if not exists whoop;

-- OAuth tokens (single-user). Service role only.
create table if not exists whoop.tokens (
  id            int primary key default 1 check (id = 1),
  access_token  text not null,
  refresh_token text not null,
  expires_at    timestamptz not null,
  scope         text,
  updated_at    timestamptz not null default now()
);

create table if not exists whoop.profile (
  user_id     bigint primary key,
  email       text,
  first_name  text,
  last_name   text,
  height_m    numeric,
  weight_kg   numeric,
  max_hr      int,
  updated_at  timestamptz not null default now()
);

create table if not exists whoop.cycles (
  id            bigint primary key,
  user_id       bigint,
  start_at      timestamptz not null,
  end_at        timestamptz,
  tz_offset     text,
  score_state   text,
  strain        numeric,
  kilojoule     numeric,
  avg_hr        int,
  max_hr        int,
  raw           jsonb not null,
  updated_at    timestamptz not null,
  synced_at     timestamptz not null default now()
);
create index if not exists cycles_start_idx on whoop.cycles (start_at desc);

create table if not exists whoop.recovery (
  cycle_id          bigint primary key,
  sleep_id          uuid,
  user_id           bigint,
  score_state       text,
  user_calibrating  boolean,
  recovery_score    numeric,
  rhr               numeric,
  hrv_rmssd_ms      numeric,
  spo2_pct          numeric,
  skin_temp_c       numeric,
  raw               jsonb not null,
  created_at        timestamptz,
  updated_at        timestamptz not null,
  synced_at         timestamptz not null default now()
);

create table if not exists whoop.sleep (
  id                    uuid primary key,
  cycle_id              bigint,
  user_id               bigint,
  start_at              timestamptz not null,
  end_at                timestamptz,
  tz_offset             text,
  nap                   boolean,
  score_state           text,
  performance_pct       numeric,
  consistency_pct       numeric,
  efficiency_pct        numeric,
  respiratory_rate      numeric,
  in_bed_ms             bigint,
  awake_ms              bigint,
  light_ms              bigint,
  sws_ms                bigint,
  rem_ms                bigint,
  no_data_ms            bigint,
  sleep_cycle_count     int,
  disturbance_count     int,
  need_baseline_ms      bigint,
  need_debt_ms          bigint,
  need_strain_ms        bigint,
  need_nap_ms           bigint,
  raw                   jsonb not null,
  updated_at            timestamptz not null,
  synced_at             timestamptz not null default now()
);
create index if not exists sleep_start_idx on whoop.sleep (start_at desc);

create table if not exists whoop.workouts (
  id            uuid primary key,
  user_id       bigint,
  start_at      timestamptz not null,
  end_at        timestamptz,
  tz_offset     text,
  sport_id      int,
  sport_name    text,
  score_state   text,
  strain        numeric,
  avg_hr        int,
  max_hr        int,
  kilojoule     numeric,
  distance_m    numeric,
  altitude_gain_m numeric,
  zone_zero_ms  bigint,
  zone_one_ms   bigint,
  zone_two_ms   bigint,
  zone_three_ms bigint,
  zone_four_ms  bigint,
  zone_five_ms  bigint,
  raw           jsonb not null,
  updated_at    timestamptz not null,
  synced_at     timestamptz not null default now()
);
create index if not exists workouts_start_idx on whoop.workouts (start_at desc);

create table if not exists whoop.sync_log (
  id          bigserial primary key,
  ran_at      timestamptz not null default now(),
  mode        text,
  cycles      int, recovery int, sleep int, workouts int,
  ok          boolean,
  error       text
);

-- ---------- Daily view: one row per physiological cycle (≈ one per day) ----------
create or replace view whoop.daily as
select
  c.id                                  as cycle_id,
  (c.start_at at time zone 'America/Los_Angeles')::date as day,
  c.start_at, c.end_at,
  c.strain, c.kilojoule, c.avg_hr, c.max_hr,
  r.recovery_score, r.rhr, r.hrv_rmssd_ms, r.spo2_pct, r.skin_temp_c,
  s.id as sleep_id,
  s.performance_pct, s.consistency_pct, s.efficiency_pct, s.respiratory_rate,
  s.in_bed_ms, s.awake_ms, s.light_ms, s.sws_ms, s.rem_ms,
  (coalesce(s.light_ms,0)+coalesce(s.sws_ms,0)+coalesce(s.rem_ms,0)) as asleep_ms,
  s.need_baseline_ms, s.need_debt_ms, s.disturbance_count, s.sleep_cycle_count,
  (select count(*) from whoop.workouts w where w.start_at >= c.start_at and w.start_at < coalesce(c.end_at, now())) as workout_count
from whoop.cycles c
left join whoop.recovery r on r.cycle_id = c.id
left join whoop.sleep s on s.cycle_id = c.id and coalesce(s.nap,false) = false;

-- ---------- Rolling baselines ----------
create or replace view whoop.daily_with_baselines as
select d.*,
  avg(hrv_rmssd_ms)   over (order by day rows between 6 preceding and current row)  as hrv_7d,
  avg(hrv_rmssd_ms)   over (order by day rows between 29 preceding and current row) as hrv_30d,
  avg(rhr)            over (order by day rows between 6 preceding and current row)  as rhr_7d,
  avg(rhr)            over (order by day rows between 29 preceding and current row) as rhr_30d,
  avg(recovery_score) over (order by day rows between 6 preceding and current row)  as recovery_7d,
  avg(strain)         over (order by day rows between 6 preceding and current row)  as strain_7d,
  avg(asleep_ms)      over (order by day rows between 6 preceding and current row)  as asleep_7d
from whoop.daily d;

-- ---------- Weekly rollup ----------
create or replace view whoop.weekly as
select date_trunc('week', day)::date as week_start,
  count(*) as days,
  round(avg(recovery_score),1) as avg_recovery,
  round(avg(hrv_rmssd_ms),1)   as avg_hrv,
  round(avg(rhr),1)            as avg_rhr,
  round(avg(strain),2)         as avg_strain,
  round(sum(strain),1)         as total_strain,
  round(avg(asleep_ms)/3600000.0,2) as avg_sleep_hours,
  round(avg(performance_pct),1) as avg_sleep_perf,
  sum(workout_count) as workouts
from whoop.daily
group by 1 order by 1 desc;

-- ---------- Security ----------
-- Expose the whoop schema to the API, read-only for signed-in users.
grant usage on schema whoop to authenticated, service_role;
grant select on all tables in schema whoop to authenticated;
revoke select on whoop.tokens from authenticated;
grant all on all tables in schema whoop to service_role;
grant usage, select on all sequences in schema whoop to service_role;

alter table whoop.tokens   enable row level security;
alter table whoop.profile  enable row level security;
alter table whoop.cycles   enable row level security;
alter table whoop.recovery enable row level security;
alter table whoop.sleep    enable row level security;
alter table whoop.workouts enable row level security;
alter table whoop.sync_log enable row level security;

do $$ begin
  create policy "auth read" on whoop.profile  for select to authenticated using (true);
  create policy "auth read" on whoop.cycles   for select to authenticated using (true);
  create policy "auth read" on whoop.recovery for select to authenticated using (true);
  create policy "auth read" on whoop.sleep    for select to authenticated using (true);
  create policy "auth read" on whoop.workouts for select to authenticated using (true);
  create policy "auth read" on whoop.sync_log for select to authenticated using (true);
exception when duplicate_object then null; end $$;
-- tokens: no policies → only service_role (bypasses RLS) can read.
