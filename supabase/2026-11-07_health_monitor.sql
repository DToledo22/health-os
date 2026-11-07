-- Personal settings the API can't provide (single row, editable from the dashboard)
create table if not exists whoop.settings (
  id int primary key default 1 check (id = 1),
  birth_date date, sex text check (sex in ('male','female')),
  lean_mass_kg numeric, steps_per_day int,
  updated_at timestamptz default now()
);
alter table whoop.settings enable row level security;
do $$ begin
  create policy "auth read" on whoop.settings for select to authenticated using (true);
  create policy "auth write" on whoop.settings for insert to authenticated with check (true);
  create policy "auth update" on whoop.settings for update to authenticated using (true) with check (true);
exception when duplicate_object then null; end $$;
grant select, insert, update on whoop.settings to authenticated; grant all on whoop.settings to service_role;
insert into whoop.settings (id) values (1) on conflict do nothing;

-- Health Monitor: each morning's vitals vs the person's own prior-30-day typical range.
-- status: 'ok' unless the value is past the prior-30-day p95 (or p5 for HRV/SpO2) in the unhealthy direction = 'watch'; > 2.5 sd in that direction = 'alert'.
create or replace view whoop.health_monitor as
with base as (
  select day, rhr, hrv_rmssd_ms, respiratory_rate, spo2_pct, skin_temp_c, recovery_score from whoop.daily where recovery_score is not null or rhr is not null
), w as (
  select b.*,
    percentile_cont(0.5) within group (order by p.rhr) as rhr_med, percentile_cont(0.05) within group (order by p.rhr) as rhr_lo, percentile_cont(0.95) within group (order by p.rhr) as rhr_hi, stddev_samp(p.rhr) as rhr_sd,
    percentile_cont(0.5) within group (order by p.hrv_rmssd_ms) as hrv_med, percentile_cont(0.05) within group (order by p.hrv_rmssd_ms) as hrv_lo, percentile_cont(0.95) within group (order by p.hrv_rmssd_ms) as hrv_hi, stddev_samp(p.hrv_rmssd_ms) as hrv_sd,
    percentile_cont(0.5) within group (order by p.respiratory_rate) as rr_med, percentile_cont(0.05) within group (order by p.respiratory_rate) as rr_lo, percentile_cont(0.95) within group (order by p.respiratory_rate) as rr_hi, stddev_samp(p.respiratory_rate) as rr_sd,
    percentile_cont(0.5) within group (order by p.spo2_pct) as spo2_med, percentile_cont(0.05) within group (order by p.spo2_pct) as spo2_lo, percentile_cont(0.95) within group (order by p.spo2_pct) as spo2_hi, stddev_samp(p.spo2_pct) as spo2_sd,
    percentile_cont(0.5) within group (order by p.skin_temp_c) as st_med, percentile_cont(0.05) within group (order by p.skin_temp_c) as st_lo, percentile_cont(0.95) within group (order by p.skin_temp_c) as st_hi, stddev_samp(p.skin_temp_c) as st_sd,
    count(p.day) as n_base
  from base b left join base p on p.day < b.day and p.day >= b.day - 30
  group by b.day, b.rhr, b.hrv_rmssd_ms, b.respiratory_rate, b.spo2_pct, b.skin_temp_c, b.recovery_score
), s as (
  select *,
    case when n_base < 10 or rhr is null then null when rhr_sd > 0 and (rhr - rhr_med)/rhr_sd > 2.5 then 'alert' when rhr > rhr_hi then 'watch' else 'ok' end as rhr_status,
    case when n_base < 10 or hrv_rmssd_ms is null then null when hrv_sd > 0 and (hrv_med - hrv_rmssd_ms)/hrv_sd > 2.5 then 'alert' when hrv_rmssd_ms < hrv_lo then 'watch' else 'ok' end as hrv_status,
    case when n_base < 10 or respiratory_rate is null then null when rr_sd > 0 and (respiratory_rate - rr_med)/rr_sd > 2.5 then 'alert' when respiratory_rate > rr_hi then 'watch' else 'ok' end as rr_status,
    case when n_base < 10 or spo2_pct is null then null when spo2_sd > 0 and (spo2_med - spo2_pct)/spo2_sd > 2.5 then 'alert' when spo2_pct < spo2_lo then 'watch' else 'ok' end as spo2_status,
    case when n_base < 10 or skin_temp_c is null then null when st_sd > 0 and (skin_temp_c - st_med)/st_sd > 2.5 then 'alert' when skin_temp_c > st_hi then 'watch' else 'ok' end as st_status
  from w
)
select *,
  -- illness signature: unhealthy-direction deviations in ≥3 of the 5 vitals on the same morning
  (case when rhr > rhr_hi then 1 else 0 end + case when hrv_rmssd_ms < hrv_lo then 1 else 0 end + case when respiratory_rate > rr_hi then 1 else 0 end + case when spo2_pct < spo2_lo then 1 else 0 end + case when skin_temp_c > st_hi then 1 else 0 end) as deviations,
  case when (case when rhr_status='alert' then 1 else 0 end + case when hrv_status='alert' then 1 else 0 end + case when rr_status='alert' then 1 else 0 end + case when spo2_status='alert' then 1 else 0 end + case when st_status='alert' then 1 else 0 end) >= 1 then 'alert'
       when (case when rhr > rhr_hi then 1 else 0 end + case when hrv_rmssd_ms < hrv_lo then 1 else 0 end + case when respiratory_rate > rr_hi then 1 else 0 end + case when spo2_pct < spo2_lo then 1 else 0 end + case when skin_temp_c > st_hi then 1 else 0 end) >= 3 then 'alert'
       when (case when rhr_status in ('watch','alert') then 1 else 0 end + case when hrv_status in ('watch','alert') then 1 else 0 end + case when rr_status in ('watch','alert') then 1 else 0 end + case when spo2_status in ('watch','alert') then 1 else 0 end + case when st_status in ('watch','alert') then 1 else 0 end) >= 1 then 'watch'
       else 'ok' end as overall
from s;
grant select on whoop.health_monitor to authenticated;
alter table whoop.settings add column if not exists goals jsonb not null default '[]'::jsonb, add column if not exists event_name text, add column if not exists event_date date;
