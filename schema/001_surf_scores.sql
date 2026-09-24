-- Token Surfers: the global leaderboard behind /api/surf/scores.
-- Every finished run is a row; the leaderboard is each device's best run.
-- No accounts: a device id (UUID minted on first launch) plus a chosen handle.
--
-- Apply:  supabase db query --linked -f apps/tokensurfers/schema/001_surf_scores.sql
-- Verify: ./scripts/db "select * from surf_leaderboard order by score desc limit 10"
--
-- Additive: one table + one view. Service-role only (RLS on, no policies).

create table if not exists surf_scores (
  id          uuid primary key default gen_random_uuid(),
  device_id   text not null,
  handle      text not null,
  score       integer not null check (score >= 0),
  coins       integer not null default 0,
  distance    integer not null default 0,
  mode        text not null default 'solo',   -- 'solo' | 'build'
  app_version text,
  created_at  timestamptz not null default now()
);

create index if not exists surf_scores_score_idx  on surf_scores (score desc);
create index if not exists surf_scores_device_idx on surf_scores (device_id, score desc);

alter table surf_scores enable row level security;

-- Best run per device. The handle is whatever the device last sent (the API
-- rewrites a device's rows when the handle changes).
create or replace view surf_leaderboard as
  select distinct on (device_id)
    device_id, handle, score, coins, distance, mode, created_at
  from surf_scores
  order by device_id, score desc, created_at asc;
