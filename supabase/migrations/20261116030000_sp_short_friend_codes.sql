-- SP only. Short public lookup codes; Bluetooth identities/keys stay unchanged.
begin;
-- A prefix must identify exactly one account. A collision fails closed rather
-- than resolving a code to the wrong player. Existing identities are preserved.
create unique index identities_friend_code_unique on sp_friends.identities
 ((upper(left(replace(code::text,'-',''),8))));

create function public.sp_friend_directory_request_code(friend_code text)
returns uuid language plpgsql security definer set search_path='' as $$
declare normalized text:=upper(replace(btrim(friend_code),'-','')); peer uuid;
begin
 perform sp_nearby.config();
 if normalized is null or normalized !~ '^[0-9A-F]{8}$' then
  raise exception 'friend_code_invalid';
 end if;
 select code into peer from sp_friends.identities
  where upper(left(replace(code::text,'-',''),8))=normalized;
 if peer is null then raise exception 'friend_code_not_found'; end if;
 return public.sp_friend_directory_request(peer);
end $$;
revoke all on function public.sp_friend_directory_request_code(text)
 from public,anon,authenticated;
grant execute on function public.sp_friend_directory_request_code(text)
 to authenticated;
notify pgrst,'reload schema';
commit;
