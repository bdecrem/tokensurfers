-- Token Surfers: comments on gallery creations, and the inbox that tells an
-- owner about new upvotes and comments in the app.
--
--   surf_comments           one row per comment (author, creation, text)
--   surf_apps.comments      the count, kept exact by surf_add_comment / surf_delete_comment
--   surf_users.notify_*     what the owner wants to hear about (the two toggles)
--   surf_users.inbox_seen_at  everything on the owner's creations after this is "new";
--                             the app's × on the card moves it to now()
--
-- There is no notifications table: the inbox is derived from surf_upvotes and
-- surf_comments rows newer than inbox_seen_at (src/lib/surf/inbox.ts).
--
-- Apply:  supabase db query --linked -f apps/tokensurfers/schema/005_surf_comments.sql
-- Verify: ./scripts/db "select count(*) from surf_comments"
--
-- Additive. Service-role only (RLS on, no policies).

create table if not exists surf_comments (
  id          uuid primary key default gen_random_uuid(),
  app_id      uuid not null references surf_apps(id) on delete cascade,
  user_id     uuid not null references surf_users(id) on delete cascade,
  body        text not null,
  created_at  timestamptz not null default now()
);

create index if not exists surf_comments_app_idx  on surf_comments (app_id, created_at desc);
create index if not exists surf_comments_user_idx on surf_comments (user_id, created_at desc);

alter table surf_comments enable row level security;

alter table surf_apps add column if not exists comments integer not null default 0;

alter table surf_users add column if not exists notify_upvotes  boolean     not null default true;
alter table surf_users add column if not exists notify_comments boolean     not null default true;
alter table surf_users add column if not exists inbox_seen_at   timestamptz not null default now();

-- the inbox reads "upvotes on my creations since inbox_seen_at"
create index if not exists surf_upvotes_recent_idx on surf_upvotes (app_id, created_at desc);

-- Insert a comment and keep the creation's counter exact, in one statement.
create or replace function surf_add_comment(p_app uuid, p_user uuid, p_body text)
returns table (id uuid, created_at timestamptz, comments integer)
language plpgsql
as $$
declare
  v_id uuid;
  v_at timestamptz;
  v_count integer;
begin
  insert into surf_comments (app_id, user_id, body) values (p_app, p_user, p_body)
    returning surf_comments.id, surf_comments.created_at into v_id, v_at;
  select count(*) into v_count from surf_comments where app_id = p_app;
  update surf_apps set comments = v_count where surf_apps.id = p_app;
  return query select v_id, v_at, v_count;
end;
$$;

-- Delete a comment (the caller checks who may) and keep the counter exact.
create or replace function surf_delete_comment(p_comment uuid)
returns integer
language plpgsql
as $$
declare
  v_app uuid;
  v_count integer;
begin
  delete from surf_comments where id = p_comment returning app_id into v_app;
  if v_app is null then return null; end if;
  select count(*) into v_count from surf_comments where app_id = v_app;
  update surf_apps set comments = v_count where id = v_app;
  return v_count;
end;
$$;

revoke all on function surf_add_comment(uuid, uuid, text) from public, anon, authenticated;
revoke all on function surf_delete_comment(uuid) from public, anon, authenticated;
grant execute on function surf_add_comment(uuid, uuid, text) to service_role;
grant execute on function surf_delete_comment(uuid) to service_role;
