-- SP only. Online account setup for the separate internet-free Bluetooth path.
begin;
-- Three independent CSPRNG UUIDs supply more than 256 bits of entropy. Hashing
-- them produces one fixed-length pair key without a new extension dependency.
alter table sp_friends.relationships add column offline_key_hex text not null
 default encode(sha256(convert_to(gen_random_uuid()::text||gen_random_uuid()::text||gen_random_uuid()::text,'UTF8')),'hex')
 check(offline_key_hex ~ '^[0-9a-f]{64}$');

create function public.sp_friend_directory_read() returns jsonb
language plpgsql security definer set search_path='' as $$
declare c sp_nearby.settings:=sp_nearby.config(); own_code uuid; entries jsonb;
 until_at timestamptz:=to_timestamp((auth.jwt()->>'exp')::bigint);
begin
 if until_at is null or until_at<=clock_timestamp() then
  raise exception 'friend_refresh_required'; end if;
 insert into sp_friends.identities(user_id) values(auth.uid()) on conflict do nothing;
 select code into own_code from sp_friends.identities where user_id=auth.uid();
 select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'code',i.code,
  'label','Player '||left(i.code::text,8),
  'status',case when r.accepted then 'accepted' when r.requested_by=auth.uid()
   then 'outgoing' else 'incoming' end,
  'key_hex',case when r.accepted then r.offline_key_hex else null end)),'[]'::jsonb)
 into entries from sp_friends.relationships r
 join sp_friends.identities i on i.user_id=case when r.first_user=auth.uid()
  then r.second_user else r.first_user end
 where auth.uid() in (r.first_user,r.second_user);
 return jsonb_build_object('self_code',own_code,'entries',entries,
  'server_now',clock_timestamp(),'valid_until',until_at,'settings',to_jsonb(c));
end $$;

create function public.sp_friend_directory_request(peer_code uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare c sp_nearby.settings:=sp_nearby.config(); peer_user uuid; r sp_friends.relationships;
begin
 select user_id into peer_user from sp_friends.identities where code=peer_code and user_id<>auth.uid();
 if peer_user is null then raise exception 'friend_code_not_found'; end if;
 perform 1 from auth.users where id in (auth.uid(),peer_user) order by id for update;
 select * into r from sp_friends.relationships
  where first_user=least(auth.uid(),peer_user) and second_user=greatest(auth.uid(),peer_user);
 if r.id is not null then return r.id; end if;
 if exists(select 1 from unnest(array[auth.uid(),peer_user]) u(id)
  where (select count(*) from sp_friends.relationships where u.id in (first_user,second_user))>=c.friend_limit)
 then raise exception 'friend_limit_reached'; end if;
 insert into sp_friends.identities(user_id) values(auth.uid()) on conflict do nothing;
 insert into sp_friends.relationships(first_user,second_user,requested_by)
 values(least(auth.uid(),peer_user),greatest(auth.uid(),peer_user),auth.uid()) returning * into r;
 return r.id;
end $$;

create function public.sp_friend_directory_respond(relationship_id uuid,action text) returns void
language plpgsql security definer set search_path='' as $$
declare c sp_nearby.settings:=sp_nearby.config(); r sp_friends.relationships;
begin
 select * into r from sp_friends.relationships where id=relationship_id
  and auth.uid() in (first_user,second_user) for update;
 if r.id is null then raise exception 'friend_not_found'; end if;
 if action='accept' then
  if not r.accepted and r.requested_by=auth.uid() then raise exception 'friend_recipient_only'; end if;
  update sp_friends.relationships set accepted=true where id=r.id;
 elsif action='remove' then delete from sp_friends.relationships where id=r.id;
 else raise exception 'friend_invalid_action'; end if;
end $$;

revoke all on function public.sp_friend_directory_read(),
 public.sp_friend_directory_request(uuid),public.sp_friend_directory_respond(uuid,text)
 from public,anon,authenticated;
grant execute on function public.sp_friend_directory_read(),
 public.sp_friend_directory_request(uuid),public.sp_friend_directory_respond(uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
