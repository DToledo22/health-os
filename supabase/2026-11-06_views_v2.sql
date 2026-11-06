drop view if exists whoop.weekly; drop view if exists whoop.daily_with_baselines; drop view if exists whoop.daily;

create view whoop.daily as
select
  c.id as cycle_id,
  coalesce((s.end_at + t.tz)::date, (c.start_at + t.tz + interval '8 hours')::date) as day,
  c.start_at, c.end_at, c.tz_offset,
  s.start_at as sleep_start_at, s.end_at as sleep_end_at,
  -- local clock minutes of sleep onset, measured from 18:00 so post-midnight bedtimes sort after pre-midnight ones
  case when s.start_at is null then null else
    ((extract(hour from (s.start_at + t.tz))::int*60 + extract(minute from (s.start_at + t.tz))::int - 18*60 + 1440) % 1440) end as bedtime_min,
  case when s.end_at is null then null else
    (extract(hour from (s.end_at + t.tz))::int*60 + extract(minute from (s.end_at + t.tz))::int) end as waketime_min,
  c.strain, c.kilojoule, c.avg_hr, c.max_hr,
  r.recovery_score, r.rhr, r.hrv_rmssd_ms, r.spo2_pct, r.skin_temp_c,
  s.id as sleep_id,
  s.performance_pct, s.consistency_pct, s.efficiency_pct, s.respiratory_rate,
  s.in_bed_ms, s.awake_ms, s.light_ms, s.sws_ms, s.rem_ms,
  (coalesce(s.light_ms,0)+coalesce(s.sws_ms,0)+coalesce(s.rem_ms,0)) as asleep_ms,
  s.need_baseline_ms, s.need_debt_ms, s.need_strain_ms, s.need_nap_ms, s.disturbance_count, s.sleep_cycle_count,
  (select count(*) from whoop.workouts w where w.start_at >= c.start_at and w.start_at < coalesce(c.end_at, now())) as workout_count
from whoop.cycles c
cross join lateral (select case when c.tz_offset is null or c.tz_offset='Z' then interval '0' else (c.tz_offset||':00')::interval end as tz) t
left join whoop.recovery r on r.cycle_id = c.id
left join whoop.sleep s on s.cycle_id = c.id and coalesce(s.nap,false) = false;

create view whoop.daily_with_baselines as
select d.*,
  avg(hrv_rmssd_ms)   over (order by day rows between 6 preceding and current row)  as hrv_7d,
  avg(hrv_rmssd_ms)   over (order by day rows between 29 preceding and current row) as hrv_30d,
  avg(rhr)            over (order by day rows between 6 preceding and current row)  as rhr_7d,
  avg(rhr)            over (order by day rows between 29 preceding and current row) as rhr_30d,
  avg(recovery_score) over (order by day rows between 6 preceding and current row)  as recovery_7d,
  avg(recovery_score) over (order by day rows between 29 preceding and current row) as recovery_30d,
  avg(strain)         over (order by day rows between 6 preceding and current row)  as strain_7d,
  avg(asleep_ms)      over (order by day rows between 6 preceding and current row)  as asleep_7d
from whoop.daily d;

create view whoop.weekly as
select date_trunc('week', day)::date as week_start, count(*) as days,
  round(avg(recovery_score),1) as avg_recovery, round(avg(hrv_rmssd_ms),1) as avg_hrv, round(avg(rhr),1) as avg_rhr,
  round(avg(strain),2) as avg_strain, round(sum(strain),1) as total_strain,
  round(avg(asleep_ms)/3600000.0,2) as avg_sleep_hours, round(avg(performance_pct),1) as avg_sleep_perf, sum(workout_count) as workouts
from whoop.daily group by 1 order by 1 desc;

grant select on whoop.daily, whoop.daily_with_baselines, whoop.weekly to authenticated;
