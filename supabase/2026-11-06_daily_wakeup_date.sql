create or replace view whoop.daily as
select
  c.id                                  as cycle_id,
  coalesce((s.end_at + t.tz)::date, (c.start_at + t.tz + interval '8 hours')::date) as day,
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
cross join lateral (select case when c.tz_offset is null or c.tz_offset='Z' then interval '0' else (c.tz_offset||':00')::interval end as tz) t
left join whoop.recovery r on r.cycle_id = c.id
left join whoop.sleep s on s.cycle_id = c.id and coalesce(s.nap,false) = false;
