-- SP only. Login expiry governs online setup, not previously verified Bluetooth trust.
-- Offline clients learn remote removals on their next normal friend sync.
begin;
create or replace function public.sp_friend_directory_read() returns jsonb
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
  'server_now',clock_timestamp(),'valid_until',null,'trust_policy','until_friend_change','settings',to_jsonb(c));
end $$;

notify pgrst,'reload schema';
commit;
