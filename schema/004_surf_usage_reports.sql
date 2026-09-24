-- Token Surfers: the global daily token budget behind /api/surf/llm, and
-- reports on gallery creations (Apple's guideline 1.2 wants a way to report
-- user-generated content before a public TestFlight).
--
--   surf_usage    one row per UTC day: calls, input and output tokens
--                 (SURF_DAILY_TOKENS caps input + output — src/lib/surf/usage.ts)
--   surf_reports  one row per report: which creation, who (if signed in), why
--
-- Apply:  supabase db query --linked -f apps/tokensurfers/schema/004_surf_usage_reports.sql
-- Verify: ./scripts/db "select * from surf_usage order by day desc limit 5"
--
-- Additive. Service-role only (RLS on, no policies).

create table if not exists surf_usage (
  day           date   primary key,
  calls         bigint not null default 0,
  input_tokens  bigint not null default 0,
  output_tokens bigint not null default 0
);

alter table surf_usage enable row level security;

-- Atomic upsert-increment, one statement per finished LLM call.
create or replace function surf_add_usage(p_day date, p_calls bigint, p_input bigint, p_output bigint)
returns void
language sql
as $$
  insert into surf_usage (day, calls, input_tokens, output_tokens)
  values (p_day, p_calls, p_input, p_output)
  on conflict (day) do update
    set calls         = surf_usage.calls         + excluded.calls,
        input_tokens  = surf_usage.input_tokens  + excluded.input_tokens,
        output_tokens = surf_usage.output_tokens + excluded.output_tokens;
$$;

revoke all on function surf_add_usage(date, bigint, bigint, bigint) from public, anon, authenticated;
grant execute on function surf_add_usage(date, bigint, bigint, bigint) to service_role;

create table if not exists surf_reports (
  id          uuid primary key default gen_random_uuid(),
  app_id      uuid not null references surf_apps(id) on delete cascade,
  reporter_id uuid references surf_users(id) on delete set null,
  reason      text not null default '',
  created_at  timestamptz not null default now()
);

create index if not exists surf_reports_app_idx on surf_reports (app_id, created_at desc);

alter table surf_reports enable row level security;
