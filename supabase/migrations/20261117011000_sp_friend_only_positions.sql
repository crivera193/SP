-- SP only. LOCAL, NOT APPLIED. Keep legacy discovery; return GPS only to accepted friends.
-- Production uses encrypted offline Bluetooth. This closes the old online RPC path too.
begin;
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
   case when f.accepted and x.fix_at>clock_timestamp()-make_interval(secs=>c.fix_s) and x.latitude is not null
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
revoke all on function public.sp_nearby_read(uuid) from public,anon,authenticated;
grant execute on function public.sp_nearby_read(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
