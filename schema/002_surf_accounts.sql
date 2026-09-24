-- Token Surfers accounts and hosted creations.
--
--   surf_users    handle + bcrypt password (the same login in the app and on the web)
--   surf_apps     one row per published creation: the whole index.html lives here
--   surf_upvotes  one row per (app, user); surf_apps.upvotes is the count
--
-- Apply:  supabase db query --linked -f apps/tokensurfers/schema/002_surf_accounts.sql
-- Verify: ./scripts/db "select handle, created_at from surf_users order by created_at desc limit 5"
--
-- Additive. Service-role only (RLS on, no policies).

create table if not exists surf_users (
  id            uuid primary key default gen_random_uuid(),
  handle        text not null unique,
  password_hash text not null,
  created_at    timestamptz not null default now()
);

create table if not exists surf_apps (
  id          uuid primary key default gen_random_uuid(),
  slug        text not null unique,
  owner_id    uuid not null references surf_users(id) on delete cascade,
  client_id   text not null,                     -- the project's id on the device: re-publishing updates the row
  title       text not null,
  emoji       text not null default '✨',
  prompt      text not null default '',
  html        text not null,
  remix_of    uuid references surf_apps(id) on delete set null,
  upvotes     integer not null default 0,
  published   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create unique index if not exists surf_apps_owner_client_idx on surf_apps (owner_id, client_id);
create index if not exists surf_apps_top_idx on surf_apps (published, upvotes desc, created_at desc);
create index if not exists surf_apps_new_idx on surf_apps (published, created_at desc);
create index if not exists surf_apps_remix_idx on surf_apps (remix_of);

create table if not exists surf_upvotes (
  app_id     uuid not null references surf_apps(id) on delete cascade,
  user_id    uuid not null references surf_users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (app_id, user_id)
);

alter table surf_users   enable row level security;
alter table surf_apps    enable row level security;
alter table surf_upvotes enable row level security;

-- Toggle one user's upvote and keep the counter exact, in one statement.
create or replace function surf_toggle_upvote(p_app uuid, p_user uuid)
returns table (voted boolean, upvotes integer)
language plpgsql
as $$
declare
  v_voted boolean;
  v_count integer;
begin
  if exists (select 1 from surf_upvotes where app_id = p_app and user_id = p_user) then
    delete from surf_upvotes where app_id = p_app and user_id = p_user;
    v_voted := false;
  else
    insert into surf_upvotes (app_id, user_id) values (p_app, p_user);
    v_voted := true;
  end if;
  select count(*) into v_count from surf_upvotes where app_id = p_app;
  update surf_apps set upvotes = v_count where id = p_app;
  return query select v_voted, v_count;
end;
$$;
