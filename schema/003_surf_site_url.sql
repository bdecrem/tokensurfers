-- Token Surfers: apps built by Claude Code on the mini live on Vercel, not as
-- a single html blob. site_url is the deployed app; html stays '' for those.
alter table surf_apps add column if not exists site_url text;
alter table surf_apps alter column html set default '';
