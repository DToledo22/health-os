-- Coach's notes (weekly prose), readable by signed-in users, written by service role / Claude
create table if not exists whoop.notes (
  id          bigserial primary key,
  week_start  date not null unique,
  title       text,
  body_md     text not null,
  highlights  jsonb,
  author      text default 'claude',
  created_at  timestamptz not null default now()
);
alter table whoop.notes enable row level security;
do $$ begin create policy "auth read" on whoop.notes for select to authenticated using (true); exception when duplicate_object then null; end $$;
grant select on whoop.notes to authenticated; grant all on whoop.notes to service_role; grant usage, select on sequence whoop.notes_id_seq to service_role;

-- Chat transcript log (optional, for later review)
create table if not exists whoop.chat_log (
  id bigserial primary key, asked_at timestamptz default now(), question text, answer text, queries jsonb, model text, input_tokens int, output_tokens int
);
alter table whoop.chat_log enable row level security;
do $$ begin create policy "auth read" on whoop.chat_log for select to authenticated using (true); exception when duplicate_object then null; end $$;
grant select on whoop.chat_log to authenticated; grant all on whoop.chat_log to service_role; grant usage, select on sequence whoop.chat_log_id_seq to service_role;

-- Read-only SQL runner for the chat tool. Only service_role may call it; it refuses anything but a single SELECT/WITH,
-- runs with a short timeout, and caps rows.
create or replace function whoop.run_readonly(q text, max_rows int default 200)
returns jsonb language plpgsql security definer set search_path = whoop, public as $$
declare out jsonb; s text := btrim(q);
begin
  if s ~* '^(select|with)\s' is not true then raise exception 'only SELECT/WITH queries are allowed'; end if;
  if position(';' in rtrim(s, '; ')) > 0 then raise exception 'single statement only'; end if;
  if s ~* '\m(insert|update|delete|drop|alter|create|grant|revoke|truncate|copy|vacuum|pg_sleep|dblink|lo_|pg_read|set\s)\M' then raise exception 'statement not allowed'; end if;
  perform set_config('statement_timeout', '8000', true);
  perform set_config('transaction_read_only', 'on', true);
  execute format('select coalesce(jsonb_agg(t), ''[]''::jsonb) from (%s) t limit 1', rtrim(s, '; ') || ' limit ' || max_rows) into out;
  return out;
end $$;
revoke all on function whoop.run_readonly(text, int) from public, anon, authenticated;
grant execute on function whoop.run_readonly(text, int) to service_role;
