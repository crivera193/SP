-- SP / SProject_2.0 / bsvcnndqvjizxgnxhxkd. Additive; do not replay prior migrations.
begin;
create schema sp_friends;
revoke all on schema sp_friends from public, anon, authenticated;
alter table sp_nearby.settings add column friend_limit integer not null default 100
 check(friend_limit between 1 and 500);
alter table sp_nearby.settings add column communication_s integer not null default 30
 check(communication_s between 10 and 120);

create table sp_friends.identities (
 user_id uuid primary key references auth.users(id) on delete cascade,
 code uuid not null unique default gen_random_uuid()
);
create table sp_friends.relationships (
 id uuid primary key default gen_random_uuid(),
 first_user uuid not null references auth.users(id) on delete cascade,
 second_user uuid not null references auth.users(id) on delete cascade,
 requested_by uuid not null references auth.users(id) on delete cascade,
 accepted boolean not null default false,
 check(first_user < second_user),
 check(requested_by in (first_user,second_user)),
 unique(first_user,second_user)
);
create table sp_friends.channels (
 id uuid primary key, -- fresh random client request ID; also makes open retry safe
 first_session uuid not null references sp_nearby.sessions(token) on delete cascade,
 second_session uuid not null references sp_nearby.sessions(token) on delete cascade,
 opener uuid not null references auth.users(id) on delete cascade,
 relationship uuid not null references sp_friends.relationships(id) on delete cascade,
 key_hex text not null check(key_hex ~ '^[0-9a-f]{64}$'),
 expires_at timestamptz not null,
 check(first_session < second_session),
 unique(first_session,second_session)
);
alter table sp_friends.identities enable row level security;
alter table sp_friends.relationships enable row level security;
alter table sp_friends.channels enable row level security;
revoke all on all tables in schema sp_friends from public,anon,authenticated;

-- An encounter must still be fresh, independently of the friendship record.
create function sp_friends.encounter(a uuid,b uuid,c sp_nearby.settings) returns boolean
language sql stable set search_path='' as $$
 select exists(select 1 from sp_nearby.rounds r
 where ((r.initiator=a and r.recipient=b) or (r.initiator=b and r.recipient=a))
 and r.completed_at>clock_timestamp()-make_interval(secs=>c.encounter_s))
$$;

create function public.sp_friends_read(session_token uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c sp_nearby.settings:=sp_nearby.config(); entries jsonb;
begin
 perform sp_nearby.own_session(session_token,c);
 select coalesce(jsonb_agg(jsonb_build_object('id',r.id,
  'code',i.code,'label','Player '||left(i.code::text,8),
  'status',case when r.accepted then 'accepted'
   when r.requested_by=auth.uid() then 'outgoing' else 'incoming' end)),'[]'::jsonb)
 into entries from sp_friends.relationships r
 join sp_friends.identities i on i.user_id=case when r.first_user=auth.uid()
  then r.second_user else r.first_user end
 where auth.uid() in (r.first_user,r.second_user);
 return jsonb_build_object('entries',entries);
end $$;

create function public.sp_friends_request(session_token uuid,peer_id uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare c sp_nearby.settings:=sp_nearby.config(); s sp_nearby.sessions;
 p sp_nearby.sessions; r sp_friends.relationships;
begin
 s:=sp_nearby.own_session(session_token,c);
 select * into p from sp_nearby.sessions where public_id=peer_id
  and user_id<>auth.uid() and seen_at>clock_timestamp()-make_interval(secs=>c.lease_s);
 if p.token is null or not sp_friends.encounter(s.token,p.token,c) then
  raise exception 'friend_nearby_required'; end if;
 -- Consistent row locks serialize cross-requests and enforce each user's limit.
 perform 1 from auth.users where id in (s.user_id,p.user_id) order by id for update;
 select * into r from sp_friends.relationships
  where first_user=least(s.user_id,p.user_id) and second_user=greatest(s.user_id,p.user_id);
 if r.id is not null then return r.id; end if; -- a cross-request does not silently accept
 if exists(select 1 from unnest(array[s.user_id,p.user_id]) u(id)
  where (select count(*) from sp_friends.relationships where u.id in (first_user,second_user))>=c.friend_limit)
 then raise exception 'friend_limit_reached'; end if;
 insert into sp_friends.identities(user_id) values(s.user_id),(p.user_id) on conflict do nothing;
 insert into sp_friends.relationships(first_user,second_user,requested_by)
 values(least(s.user_id,p.user_id),greatest(s.user_id,p.user_id),s.user_id) returning * into r;
 return r.id;
end $$;

create function public.sp_friends_respond(session_token uuid,relationship_id uuid,action text) returns void
language plpgsql security definer set search_path='' as $$
declare c sp_nearby.settings:=sp_nearby.config(); r sp_friends.relationships;
begin
 perform sp_nearby.own_session(session_token,c);
 select * into r from sp_friends.relationships where id=relationship_id
  and auth.uid() in (first_user,second_user) for update;
 if r.id is null then raise exception 'friend_not_found'; end if;
 if action='accept' then
  if not r.accepted and r.requested_by=auth.uid() then raise exception 'friend_recipient_only'; end if;
  update sp_friends.relationships set accepted=true where id=r.id;
 elsif action='remove' then
  delete from sp_friends.relationships where id=r.id; -- cascades all channel keys
 else raise exception 'friend_invalid_action'; end if;
end $$;

-- Tickets are returned only through authenticated RPCs, never in BLE advertisements.
-- Both devices independently call this guard, including before accepting messages.
create function sp_friends.ticket(session_token uuid,channel_id uuid) returns jsonb
language plpgsql set search_path='' as $$
declare c sp_nearby.settings:=sp_nearby.config(); s sp_nearby.sessions;
 p sp_nearby.sessions; ch sp_friends.channels; r sp_friends.relationships; until_at timestamptz;
begin
 s:=sp_nearby.own_session(session_token,c);
 select * into ch from sp_friends.channels where id=channel_id
  and session_token in (first_session,second_session);
 if ch.id is null or ch.expires_at<=clock_timestamp() then return null; end if;
 select * into p from sp_nearby.sessions
  where token=case when ch.first_session=s.token then ch.second_session else ch.first_session end
  and seen_at>clock_timestamp()-make_interval(secs=>c.lease_s);
 select * into r from sp_friends.relationships where id=ch.relationship and accepted for share;
 if p.token is null or r.id is null or not sp_friends.encounter(s.token,p.token,c)
  or least(s.user_id,p.user_id)<>r.first_user or greatest(s.user_id,p.user_id)<>r.second_user
 then return null; end if;
 until_at:=least(clock_timestamp()+make_interval(secs=>c.communication_s),
  s.seen_at+make_interval(secs=>c.lease_s),p.seen_at+make_interval(secs=>c.lease_s),
  (select max(completed_at)+make_interval(secs=>c.encounter_s) from sp_nearby.rounds
   where (initiator=s.token and recipient=p.token) or (initiator=p.token and recipient=s.token)));
 update sp_friends.channels set expires_at=until_at where id=ch.id;
 return jsonb_build_object('id',ch.id,'relationship_id',ch.relationship,'peer_token',p.token,'peer_id',p.public_id,
  'label','Player '||left((select code::text from sp_friends.identities where user_id=p.user_id),8),
  'key_hex',ch.key_hex,'first',s.token=ch.first_session,
  'server_now',clock_timestamp(),'expires_at',until_at);
end $$;

create function public.sp_friend_channel_open(session_token uuid,peer_id uuid,request_id uuid,key_hex text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c sp_nearby.settings:=sp_nearby.config(); s sp_nearby.sessions; p sp_nearby.sessions;
 r sp_friends.relationships; ch sp_friends.channels;
begin
 s:=sp_nearby.own_session(session_token,c);
 if request_id is null or key_hex is null or key_hex !~ '^[0-9a-f]{64}$' then
  raise exception 'friend_invalid_channel'; end if;
 select * into p from sp_nearby.sessions where public_id=peer_id and user_id<>auth.uid()
  and seen_at>clock_timestamp()-make_interval(secs=>c.lease_s);
 if p.token is null or not sp_friends.encounter(s.token,p.token,c) then
  raise exception 'friend_nearby_required'; end if;
 perform 1 from sp_nearby.sessions where token in (s.token,p.token) order by token for update;
 select * into r from sp_friends.relationships where first_user=least(s.user_id,p.user_id)
  and second_user=greatest(s.user_id,p.user_id) and accepted for share;
 if r.id is null then raise exception 'friend_verification_required'; end if;
 delete from sp_friends.channels where expires_at<=clock_timestamp();
 select * into ch from sp_friends.channels
  where first_session=least(s.token,p.token) and second_session=greatest(s.token,p.token);
 if ch.id is not null and (ch.id<>request_id or ch.opener<>auth.uid()) then
  raise exception 'friend_channel_already_open'; end if;
 if ch.id is null then
  insert into sp_friends.channels(id,first_session,second_session,opener,relationship,key_hex,expires_at)
  values(request_id,least(s.token,p.token),greatest(s.token,p.token),auth.uid(),r.id,
   sp_friend_channel_open.key_hex,clock_timestamp()+make_interval(secs=>c.communication_s));
 end if;
 return sp_friends.ticket(s.token,request_id);
end $$;

create function public.sp_friend_channel_check(session_token uuid,channel_id uuid) returns jsonb
language sql security definer set search_path='' as $$
 select sp_friends.ticket(session_token,channel_id)
$$;
create function public.sp_friend_channel_close(session_token uuid,channel_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare c sp_nearby.settings:=sp_nearby.config();
begin
 perform sp_nearby.own_session(session_token,c);
 delete from sp_friends.channels where id=channel_id and session_token in (first_session,second_session);
end $$;

-- Discovery remains available for nonfriends. Only relationship metadata is added;
-- map positions retain the existing fresh Bluetooth receipt and GPS requirements.
create or replace function public.sp_nearby_read(session_token uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c sp_nearby.settings:=sp_nearby.config(); s sp_nearby.sessions; peers jsonb;
begin
 s:=sp_nearby.own_session(session_token,c);
 select coalesce(jsonb_agg(to_jsonb(p)),'[]'::jsonb) into peers from (
  select x.public_id as id,
   case when f.accepted then 'Player '||left(i.code::text,8)
    else 'Player '||left(x.public_id::text,4) end as label,
   f.id as relationship_id,
   case when f.accepted then 'accepted' when f.requested_by=auth.uid() then 'outgoing'
    when f.id is not null then 'incoming' else 'none' end as friendship,
   least(x.seen_at+make_interval(secs=>c.lease_s),s.seen_at+make_interval(secs=>c.lease_s),
    e.last_encounter+make_interval(secs=>c.encounter_s)) as expires_at,
   case when x.fix_at>clock_timestamp()-make_interval(secs=>c.fix_s) and x.latitude is not null
    then jsonb_build_object('latitude',x.latitude,'longitude',x.longitude,'accuracy_m',x.accuracy_m,
     'expires_at',x.fix_at+make_interval(secs=>c.fix_s)) end as position
  from (select case when initiator=s.token then recipient else initiator end as peer,
    max(completed_at) as last_encounter from sp_nearby.rounds
   where completed_at>clock_timestamp()-make_interval(secs=>c.encounter_s)
    and (initiator=s.token or recipient=s.token) group by 1) e
  join sp_nearby.sessions x on x.token=e.peer
  left join sp_friends.relationships f on f.first_user=least(s.user_id,x.user_id)
   and f.second_user=greatest(s.user_id,x.user_id)
  left join sp_friends.identities i on i.user_id=x.user_id
  where x.user_id<>auth.uid() and x.seen_at>clock_timestamp()-make_interval(secs=>c.lease_s)
  order by e.last_encounter desc limit c.max_peers
 ) p;
 return jsonb_build_object('players',peers,'settings',to_jsonb(c),'server_now',clock_timestamp());
end $$;

revoke all on all functions in schema sp_friends from public,anon,authenticated;
revoke all on function public.sp_friends_read(uuid),public.sp_friends_request(uuid,uuid),
 public.sp_friends_respond(uuid,uuid,text),public.sp_friend_channel_open(uuid,uuid,uuid,text),
 public.sp_friend_channel_check(uuid,uuid),public.sp_friend_channel_close(uuid,uuid) from public,anon,authenticated;
grant execute on function public.sp_friends_read(uuid),public.sp_friends_request(uuid,uuid),
 public.sp_friends_respond(uuid,uuid,text),public.sp_friend_channel_open(uuid,uuid,uuid,text),
 public.sp_friend_channel_check(uuid,uuid),public.sp_friend_channel_close(uuid,uuid) to authenticated;
notify pgrst,'reload schema';
commit;
