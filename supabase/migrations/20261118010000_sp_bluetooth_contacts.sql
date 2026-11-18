-- Applied November 18, 2026 to SP / bsvcnndqvjizxgnxhxkd / SProject_2.0. Do not replay.
-- BLE reports sync after discovery; HTTP never establishes a nearby encounter.
begin;
create schema sp_contacts;
revoke all on schema sp_contacts from public,anon,authenticated;
create table sp_contacts.settings (
 id boolean primary key default true check(id),
 seconds_per_level integer not null default 600 check(seconds_per_level between 30 and 86400),
 bonus_from_level integer not null default 10 check(bonus_from_level between 1 and 1000000),
 base_quiz_points integer not null default 1 check(base_quiz_points between 1 and 100),
 bonus_quiz_points integer not null default 2 check(bonus_quiz_points between base_quiz_points and 100),
 report_age_days integer not null default 30 check(report_age_days between 1 and 365),
 clock_skew_seconds integer not null default 30 check(clock_skew_seconds between 0 and 120)
);
insert into sp_contacts.settings(id) values(true);
create table sp_contacts.reports (
 user_id uuid not null references auth.users(id), id uuid not null,
 own_session uuid not null, peer_session uuid not null,
 peer_code uuid, peer_user_id uuid references auth.users(id), contact_id uuid,
 started_at timestamptz not null, ended_at timestamptz not null,
 duration_ms integer not null check(duration_ms>=0), credited_period tstzrange,
 received_at timestamptz not null default clock_timestamp(),
 primary key(user_id,id), check(own_session<>peer_session), check(ended_at>=started_at)
);
create index contact_matches on sp_contacts.reports(contact_id,user_id,peer_user_id,own_session,peer_session)
 where credited_period is not null;
create table sp_contacts.progress (
 user_id uuid primary key references auth.users(id),
 periods tstzmultirange not null default '{}'
);

create function sp_contacts.progress_payload(actor uuid) returns jsonb
language sql stable set search_path='' as $$
 with duration as (
  select floor(coalesce(sum(extract(epoch from upper(p)-lower(p))),0))::bigint seconds
  from sp_contacts.progress s cross join lateral unnest(s.periods) p where s.user_id=actor
 ) select jsonb_build_object('level',1+seconds/c.seconds_per_level,
  'quiz_points',case when 1+seconds/c.seconds_per_level>=c.bonus_from_level
   then c.bonus_quiz_points else c.base_quiz_points end,
  'friend_seconds',seconds,'seconds_per_level',c.seconds_per_level,
  'seconds_into_level',seconds%c.seconds_per_level,'server_now',clock_timestamp())
 from duration cross join sp_contacts.settings c where c.id;
$$;
create function public.sp_contacts_read() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=sp_teams.require_player();
begin return sp_contacts.progress_payload(actor); end $$;

create function public.sp_contacts_sync(account_id uuid,events jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=sp_teams.require_player(); c sp_contacts.settings;
 item jsonb; r sp_contacts.reports; old sp_contacts.reports; peer uuid;
 eligible boolean; matched tstzmultirange; accepted jsonb:='[]';
 max_gap integer; stamp timestamptz:=clock_timestamp();
begin
 if account_id is distinct from actor then
  raise exception 'Contact account changed.' using errcode='42501';
 end if;
 if jsonb_typeof(events)<>'array' or jsonb_array_length(events)>50 then
  raise exception 'A batch of up to 50 contact records is required.' using errcode='22023';
 end if;
 select * into strict c from sp_contacts.settings where id;
 select encounter_s into strict max_gap from sp_nearby.settings where id;
 -- Take account locks in the same order for overlapping, concurrent batches.
 perform pg_advisory_xact_lock(hashtextextended(ids.id::text,61118)) from (
  select actor id union select i.user_id from jsonb_array_elements(events) e
  join sp_friends.identities i on i.code=(e->>'peer_code')::uuid
 ) ids order by ids.id;
 for item in select value from jsonb_array_elements(events) loop
  r:=null;
  r.user_id:=actor; r.id:=(item->>'id')::uuid;
  r.own_session:=(item->>'own_session')::uuid; r.peer_session:=(item->>'peer_session')::uuid;
  r.peer_code:=(item->>'peer_code')::uuid; r.contact_id:=(item->>'contact_id')::uuid;
  r.started_at:=(item->>'started_at')::timestamptz; r.ended_at:=(item->>'ended_at')::timestamptz;
  r.duration_ms:=(item->>'duration_ms')::integer;
  if r.id is null or r.own_session is null or r.peer_session is null or r.own_session=r.peer_session
   or r.started_at is null or r.ended_at is null or r.duration_ms is null
   or not isfinite(r.started_at) or not isfinite(r.ended_at)
   or r.ended_at<r.started_at or r.duration_ms<0 or r.duration_ms>max_gap*1000
   or r.duration_ms>floor(extract(epoch from r.ended_at-r.started_at)*1000) then
    raise exception 'Invalid contact timestamps or duration.' using errcode='22023';
  end if;
  select * into old from sp_contacts.reports x where x.user_id=actor and x.id=r.id;
  if old.id is not null then
   if (old.own_session,old.peer_session,old.peer_code,old.contact_id,old.started_at,old.ended_at,old.duration_ms)
    is distinct from (r.own_session,r.peer_session,r.peer_code,r.contact_id,r.started_at,r.ended_at,r.duration_ms) then
     raise exception 'Contact ID already used.' using errcode='22023';
   end if;
   accepted:=accepted||jsonb_build_array(r.id); continue;
  end if;
  select i.user_id into peer from sp_friends.identities i where i.code=r.peer_code;
  if peer=actor then raise exception 'Self contact is unavailable.' using errcode='22023'; end if;
  r.peer_user_id:=peer;
  -- Preserve a timestamp log when a phone clock is wrong, but never reward it.
  -- Accepting an uncredited report also avoids blocking valid offline records behind it.
  eligible:=r.contact_id is not null and r.duration_ms>0
   and r.ended_at<=stamp+make_interval(secs=>c.clock_skew_seconds)
   and r.started_at>=stamp-make_interval(days=>c.report_age_days) and exists(
   select 1 from sp_friends.relationships f where f.accepted
   and f.first_user=least(actor,peer) and f.second_user=greatest(actor,peer));
  if eligible then
   r.credited_period:=tstzrange(r.ended_at-r.duration_ms*interval '1 millisecond',r.ended_at,'[)');
  end if;
  insert into sp_contacts.reports(user_id,id,own_session,peer_session,peer_code,peer_user_id,contact_id,
   started_at,ended_at,duration_ms,credited_period) values(actor,r.id,r.own_session,r.peer_session,
   r.peer_code,peer,r.contact_id,r.started_at,r.ended_at,r.duration_ms,r.credited_period);
  if eligible then
   -- Both authenticated accounts must independently upload matching BLE sessions.
   -- Union intersections so reconnects, retries and multiple friends never multiply time.
   select range_agg(r.credited_period*x.credited_period) into matched from sp_contacts.reports x
    where x.user_id=peer and x.peer_user_id=actor and x.contact_id=r.contact_id
    and x.own_session=r.peer_session and x.peer_session=r.own_session
    and x.credited_period&&r.credited_period;
   if matched is not null then
    insert into sp_contacts.progress(user_id,periods) values(actor,matched),(peer,matched)
    on conflict(user_id) do update set periods=sp_contacts.progress.periods+excluded.periods;
   end if;
  end if;
  accepted:=accepted||jsonb_build_array(r.id);
 end loop;
 return jsonb_build_object('accepted',accepted,'progress',sp_contacts.progress_payload(actor));
end $$;

alter table sp_contacts.settings enable row level security;
alter table sp_contacts.reports enable row level security;
alter table sp_contacts.progress enable row level security;
revoke all on all tables in schema sp_contacts from public,anon,authenticated;
revoke all on all functions in schema sp_contacts from public,anon,authenticated;
revoke all on function public.sp_contacts_read(),public.sp_contacts_sync(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.sp_contacts_read(),public.sp_contacts_sync(uuid,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
