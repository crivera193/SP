-- Target: SP / SProject_2.0 / bsvcnndqvjizxgnxhxkd only.
-- New isolated schema; does not import test-project accounts, profiles or rules.
begin;
create schema sp_teams;
revoke all on schema sp_teams from public, anon, authenticated;
create table sp_teams.catalog (
  id text primary key check (id ~ '^[a-z][a-z0-9_]{0,63}$'),
  display_name text not null check (length(trim(display_name)) between 1 and 80),
  color_name text not null check (length(trim(color_name)) between 1 and 40),
  color_hex text not null check (color_hex ~ '^#[0-9a-fA-F]{6}$'),
  description text not null check (length(trim(description)) between 1 and 500),
  sort_order integer not null default 0,
  enabled boolean not null default true
);
insert into sp_teams.catalog(id,display_name,color_name,color_hex,description,sort_order) values
 ('health_science','Health and Science','Blue','#77bfff','Stay curious. Explore life, wellbeing and the world around you.',0),
 ('math_engineering','Math and Engineering','Red','#ff9292','Think boldly. Find patterns, solve puzzles and build new possibilities.',1),
 ('art_stuff','Art and Stuff','Yellow','#ffdf7b','Make your mark. Bring imagination, expression and a fresh perspective.',2);
create table sp_teams.memberships (
  user_id uuid primary key references auth.users(id) on delete restrict,
  team_id text not null references sp_teams.catalog(id) on delete restrict on update restrict,
  chosen_at timestamptz not null default now()
);
alter table sp_teams.catalog enable row level security;
alter table sp_teams.memberships enable row level security;
revoke all on all tables in schema sp_teams from public, anon, authenticated;

create function sp_teams.require_player() returns uuid
language plpgsql set search_path='' as $$
declare actor uuid := auth.uid();
begin
  if actor is null or not exists(select 1 from auth.users u where u.id=actor
    and lower(u.email) ~ '^[^@[:space:]]+@utrgv\.edu$') then
    raise exception 'An authenticated UTRGV account is required.' using errcode='42501';
  end if;
  return actor;
end $$;
create function sp_teams.prevent_mutation() returns trigger
language plpgsql set search_path='' as $$
begin
  raise exception 'Account team membership is permanent.' using errcode='42501';
end $$;
create trigger membership_is_permanent before update or delete on sp_teams.memberships
for each row execute function sp_teams.prevent_mutation();

create function public.sp_teams_read() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid := sp_teams.require_player(); result jsonb;
begin
  select jsonb_build_object(
    'choices', coalesce((select jsonb_agg(to_jsonb(c) order by c.sort_order,c.id)
      from sp_teams.catalog c where c.enabled),'[]'::jsonb),
    'team', (select to_jsonb(c) from sp_teams.memberships m
      join sp_teams.catalog c on c.id=m.team_id where m.user_id=actor)
  ) into result;
  return result;
end $$;

create function public.sp_teams_choose(requested_team text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid := sp_teams.require_player(); saved text; result jsonb;
begin
  -- Serialize choices per account. A retry always returns the original winner,
  -- including when that team has since been disabled for new players.
  perform pg_advisory_xact_lock(hashtextextended(actor::text,61109));
  select m.team_id into saved from sp_teams.memberships m where m.user_id=actor;
  if saved is null then
    -- Lock the selected catalog row so disable/delete cannot race this choice.
    perform 1 from sp_teams.catalog c where c.id=requested_team and c.enabled for share;
    if not found then raise exception 'This team is unavailable. Retry the team check.' using errcode='22023'; end if;
    insert into sp_teams.memberships(user_id,team_id) values(actor,requested_team)
      on conflict(user_id) do nothing;
    select m.team_id into saved from sp_teams.memberships m where m.user_id=actor;
  end if;
  select to_jsonb(c) into result from sp_teams.catalog c where c.id=saved;
  if result is null then raise exception 'Membership could not be confirmed.' using errcode='40001'; end if;
  return result;
end $$;
revoke all on all functions in schema sp_teams from public, anon, authenticated;
revoke all on function public.sp_teams_read() from public, anon, authenticated;
revoke all on function public.sp_teams_choose(text) from public, anon, authenticated;
grant execute on function public.sp_teams_read(), public.sp_teams_choose(text) to authenticated;
notify pgrst, 'reload schema';
commit;
