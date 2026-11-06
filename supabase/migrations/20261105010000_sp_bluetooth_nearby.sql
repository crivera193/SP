-- Target: SP / SProject_2.0 / bsvcnndqvjizxgnxhxkd only.
-- No coordinates, radius or GPS distance participate in encounter selection.
begin;
create schema sp_nearby;
revoke all on schema sp_nearby from public, anon, authenticated;

create table sp_nearby.settings (
 id boolean primary key default true check(id), enabled boolean not null,
 heartbeat_s integer not null check(heartbeat_s between 3 and 10),
 lease_s integer not null check(lease_s between 15 and 60),
 encounter_s integer not null check(encounter_s between 10 and 40),
 challenge_s integer not null check(challenge_s between 5 and 15),
 fix_s integer not null check(fix_s between 3 and 20),
 max_accuracy_m integer not null check(max_accuracy_m between 5 and 40),
 max_peers integer not null check(max_peers between 1 and 24),
 scan_s integer not null check(scan_s between 10 and 40),
 pause_s integer not null check(pause_s between 3 and 15),
 check(lease_s >= heartbeat_s*3), check(encounter_s >= heartbeat_s*2)
);
insert into sp_nearby.settings values(true,true,4,24,18,8,6,40,12,20,5);
create table sp_nearby.sessions (
 token uuid primary key default gen_random_uuid(),
 public_id uuid not null unique default gen_random_uuid(),
 user_id uuid not null unique references auth.users(id) on delete cascade,
 request_id uuid not null unique,
 seen_at timestamptz not null default clock_timestamp(),
 latitude double precision, longitude double precision,
 accuracy_m double precision, fix_at timestamptz,
 check(latitude between -90 and 90), check(longitude between -180 and 180),
 check(accuracy_m between 0 and 40)
);
create table sp_nearby.rounds (
 nonce uuid primary key default gen_random_uuid(),
 initiator uuid not null references sp_nearby.sessions(token) on delete cascade,
 recipient uuid not null references sp_nearby.sessions(token) on delete cascade,
 issued_at timestamptz not null default clock_timestamp(),
 completed_at timestamptz,
 check(initiator <> recipient)
);
create index nearby_round_recipient on sp_nearby.rounds(recipient,issued_at);
create index nearby_round_initiator on sp_nearby.rounds(initiator,issued_at);
alter table sp_nearby.settings enable row level security;
alter table sp_nearby.sessions enable row level security;
alter table sp_nearby.rounds enable row level security;
revoke all on all tables in schema sp_nearby from public,anon,authenticated;

create function sp_nearby.config() returns sp_nearby.settings
language plpgsql set search_path='' as $$
declare c sp_nearby.settings;
begin
 if auth.uid() is null or not exists(select 1 from auth.users u
  where u.id=auth.uid() and lower(u.email) ~ '^[^@[:space:]]+@utrgv\.edu$') then
  raise exception 'nearby_sign_in_required' using errcode='42501';
 end if;
 select * into c from sp_nearby.settings where id;
 if c.id is null or not c.enabled then raise exception 'nearby_unavailable'; end if;
 return c;
end $$;
create function sp_nearby.own_session(secret uuid,c sp_nearby.settings)
returns sp_nearby.sessions language plpgsql set search_path='' as $$
declare s sp_nearby.sessions;
begin
 select * into s from sp_nearby.sessions where token=secret and user_id=auth.uid();
 if s.token is null or s.seen_at <= clock_timestamp()-make_interval(secs=>c.lease_s) then
  raise exception 'nearby_session_expired';
 end if;
 return s;
end $$;

create function public.sp_nearby_open(request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c sp_nearby.settings:=sp_nearby.config(); s sp_nearby.sessions;
begin
 if request_id is null then raise exception 'nearby_invalid_request'; end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,51105));
 select * into s from sp_nearby.sessions x where x.user_id=auth.uid()
  and x.request_id=sp_nearby_open.request_id
  and x.seen_at>clock_timestamp()-make_interval(secs=>c.lease_s);
 if s.token is null then
  delete from sp_nearby.sessions where user_id=auth.uid()
   or seen_at<clock_timestamp()-make_interval(secs=>c.lease_s);
  insert into sp_nearby.sessions(user_id,request_id) values(auth.uid(),request_id) returning * into s;
 end if;
 return jsonb_build_object('token',s.token,'settings',to_jsonb(c));
end $$;

create function public.sp_nearby_heartbeat(session_token uuid, latitude double precision default null,
 longitude double precision default null, accuracy_m double precision default null, fix_at timestamptz default null)
returns void language plpgsql security definer set search_path='' as $$
declare c sp_nearby.settings:=sp_nearby.config(); s sp_nearby.sessions;
 valid_fix boolean;
begin
 s:=sp_nearby.own_session(session_token,c);
 valid_fix:=coalesce(latitude between -90 and 90 and longitude between -180 and 180
  and accuracy_m between 0 and c.max_accuracy_m
  and fix_at>clock_timestamp()-make_interval(secs=>c.fix_s)
  and fix_at<=clock_timestamp()+interval '2 seconds',false);
 update sp_nearby.sessions x set seen_at=clock_timestamp(),
  latitude=case when valid_fix then sp_nearby_heartbeat.latitude end,
  longitude=case when valid_fix then sp_nearby_heartbeat.longitude end,
  accuracy_m=case when valid_fix then sp_nearby_heartbeat.accuracy_m end,
  fix_at=case when valid_fix then sp_nearby_heartbeat.fix_at end
 where x.token=s.token and x.user_id=auth.uid()
  and (sp_nearby_heartbeat.fix_at is null or x.fix_at is null or sp_nearby_heartbeat.fix_at>=x.fix_at);
 -- Old/out-of-order GPS cannot replace the last position, but still renew activity.
 if not found then update sp_nearby.sessions set seen_at=clock_timestamp() where token=s.token and user_id=auth.uid(); end if;
 delete from sp_nearby.rounds where issued_at<clock_timestamp()-make_interval(secs=>c.encounter_s+c.challenge_s);
 delete from sp_nearby.sessions where seen_at<clock_timestamp()-make_interval(secs=>c.lease_s);
end $$;

-- The peer's opaque token is obtained by a fresh GATT read, never a GPS query.
create function public.sp_nearby_challenge(session_token uuid,peer_token uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare c sp_nearby.settings:=sp_nearby.config(); s sp_nearby.sessions; n uuid;
begin
 s:=sp_nearby.own_session(session_token,c);
 if not exists(select 1 from sp_nearby.sessions p where p.token=peer_token and p.user_id<>auth.uid()
  and p.seen_at>clock_timestamp()-make_interval(secs=>c.lease_s)) then return null; end if;
 if (select count(*) from sp_nearby.rounds where initiator=s.token
  and issued_at>clock_timestamp()-make_interval(secs=>c.heartbeat_s))>=c.max_peers then return null; end if;
 insert into sp_nearby.rounds(initiator,recipient) values(s.token,peer_token) returning nonce into n;
 return n;
end $$;

-- Only the intended recipient can confirm a nonce delivered in a BLE write.
-- Replaying a completed nonce never renews its expiry.
create function public.sp_nearby_confirm(session_token uuid,nonce uuid) returns boolean
language plpgsql security definer set search_path='' as $$
declare c sp_nearby.settings:=sp_nearby.config(); s sp_nearby.sessions; r sp_nearby.rounds;
begin
 s:=sp_nearby.own_session(session_token,c);
 select * into r from sp_nearby.rounds x where x.nonce=sp_nearby_confirm.nonce
  and x.recipient=s.token for update;
 if r.nonce is null then return false; end if;
 if r.completed_at is not null then return false; end if;
 if r.issued_at<=clock_timestamp()-make_interval(secs=>c.challenge_s)
  or not exists(select 1 from sp_nearby.sessions p where p.token=r.initiator
   and p.user_id<>auth.uid() and p.seen_at>clock_timestamp()-make_interval(secs=>c.lease_s)) then return false; end if;
 update sp_nearby.rounds set completed_at=clock_timestamp() where rounds.nonce=r.nonce;
 return true;
end $$;

create function public.sp_nearby_read(session_token uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c sp_nearby.settings:=sp_nearby.config(); s sp_nearby.sessions; peers jsonb;
begin
 s:=sp_nearby.own_session(session_token,c);
 select coalesce(jsonb_agg(to_jsonb(p)),'[]'::jsonb) into peers from (
  select x.public_id as id,'Player '||left(x.public_id::text,4) as label,
   least(x.seen_at+make_interval(secs=>c.lease_s),s.seen_at+make_interval(secs=>c.lease_s),
    r.last_encounter+make_interval(secs=>c.encounter_s)) as expires_at,
   case when x.fix_at>clock_timestamp()-make_interval(secs=>c.fix_s) and x.latitude is not null
    then jsonb_build_object('latitude',x.latitude,'longitude',x.longitude,'accuracy_m',x.accuracy_m,
     'expires_at',x.fix_at+make_interval(secs=>c.fix_s)) end as position
  from (select case when initiator=s.token then recipient else initiator end as peer,
    max(completed_at) as last_encounter from sp_nearby.rounds
   where completed_at>clock_timestamp()-make_interval(secs=>c.encounter_s)
    and (initiator=s.token or recipient=s.token) group by 1) r
  join sp_nearby.sessions x on x.token=r.peer
  where x.user_id<>auth.uid() and x.seen_at>clock_timestamp()-make_interval(secs=>c.lease_s)
  order by r.last_encounter desc limit c.max_peers
 ) p;
 return jsonb_build_object('players',peers,'settings',to_jsonb(c),'server_now',clock_timestamp());
end $$;

create function public.sp_nearby_close(session_token uuid) returns void
language sql security definer set search_path='' as $$
 delete from sp_nearby.sessions where token=session_token and user_id=auth.uid();
$$;
revoke all on all functions in schema sp_nearby from public,anon,authenticated;
revoke all on function public.sp_nearby_open(uuid),public.sp_nearby_heartbeat(uuid,double precision,double precision,double precision,timestamptz),
 public.sp_nearby_challenge(uuid,uuid),public.sp_nearby_confirm(uuid,uuid),public.sp_nearby_read(uuid),public.sp_nearby_close(uuid) from public,anon,authenticated;
grant execute on function public.sp_nearby_open(uuid),public.sp_nearby_heartbeat(uuid,double precision,double precision,double precision,timestamptz),
 public.sp_nearby_challenge(uuid,uuid),public.sp_nearby_confirm(uuid,uuid),public.sp_nearby_read(uuid),public.sp_nearby_close(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
