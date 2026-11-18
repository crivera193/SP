-- Applied November 18, 2026 to SP / bsvcnndqvjizxgnxhxkd / SProject_2.0. Do not replay.
-- Apply after 20261118010000_sp_bluetooth_contacts.sql.
begin;
alter table sp_quiz.scores add column points bigint not null default 0 check(points>=0);
update sp_quiz.scores set points=correct;
alter table sp_quiz.attempts add column awarded_points integer check(awarded_points>=0);
alter table sp_quiz.attempts add column reward_level bigint check(reward_level>=1);
-- Historical results stay immutable; their original one-point awards remain.
update sp_quiz.attempts set awarded_points=case when correct then 1 else 0 end,reward_level=1
 where status='answered';

create or replace function sp_quiz.location_payload(lid text) returns jsonb
language sql stable set search_path='' as $$
 select (to_jsonb(l)-'question_id'-'owner_team_id') || jsonb_build_object(
 'owner',(select to_jsonb(t) from sp_teams.catalog t where t.id=l.owner_team_id),
 'scores',coalesce((select jsonb_agg(jsonb_build_object('team',to_jsonb(t),
  'correct',coalesce(s.correct,0),'points',coalesce(s.points,0))
 order by coalesce(s.points,0) desc,s.reached_order asc nulls last,t.sort_order,t.id)
 from sp_teams.catalog t left join sp_quiz.scores s on s.team_id=t.id and s.location_id=l.id
 where t.enabled or s.team_id is not null or t.id=l.owner_team_id),'[]'::jsonb))
 from sp_quiz.locations l where l.id=lid;
$$;
create or replace function sp_quiz.attempt_payload(aid uuid) returns jsonb
language sql volatile set search_path='' as $$
 select jsonb_build_object('id',a.id,'prompt',a.prompt,'status',a.status,
 'selected',a.selected,'correct',a.correct,'awarded_points',a.awarded_points,'reward_level',a.reward_level,
 'server_now',clock_timestamp(),
 'retry_at',case when a.answered_at is not null
 then a.answered_at+make_interval(secs=>l.repeat_after_seconds) end,
 'location',sp_quiz.location_payload(a.location_id))
 from sp_quiz.attempts a join sp_quiz.locations l on l.id=a.location_id where a.id=aid;
$$;
create or replace function public.sp_quiz_answer(attempt_id uuid,command_id uuid,selected boolean,
 latitude double precision,longitude double precision,accuracy_meters double precision,fix_at timestamptz) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=sp_teams.require_player(); a sp_quiz.attempts; l sp_quiz.locations;
 lid text; winner text; is_correct boolean; progress jsonb; award integer; player_level bigint;
begin
 if command_id is null or selected is null then raise exception 'Answer and command ID required.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(actor::text,61117));
 select x.location_id into lid from sp_quiz.attempts x where x.id=attempt_id and x.user_id=actor;
 if lid is null then raise exception 'Quiz attempt unavailable.' using errcode='42501'; end if;
 select * into l from sp_quiz.locations where id=lid for update;
 select * into a from sp_quiz.attempts where id=attempt_id for update;
 if a.status='answered' then
  if a.command_id<>sp_quiz_answer.command_id or a.selected<>sp_quiz_answer.selected then
   raise exception 'This question was already answered.' using errcode='PT409'; end if;
  return sp_quiz.attempt_payload(a.id);
 end if;
 if a.status<>'active' or not l.enabled or a.play_version<>l.play_version then
  raise exception 'This quiz changed. Close and reopen the location.' using errcode='PT409'; end if;
 perform sp_quiz.require_fix(lid,latitude,longitude,accuracy_meters,fix_at);
 progress:=sp_contacts.progress_payload(actor);
 player_level:=(progress->>'level')::bigint;
 if player_level is null or (progress->>'quiz_points')::integer is null then
  raise exception 'Quiz reward configuration unavailable.' using errcode='55000'; end if;
 is_correct:=selected=a.answer;
 award:=case when is_correct then (progress->>'quiz_points')::integer else 0 end;
 update sp_quiz.attempts set status='answered',selected=sp_quiz_answer.selected,correct=is_correct,
  command_id=sp_quiz_answer.command_id,answered_at=clock_timestamp(),
  awarded_points=award,reward_level=player_level where id=a.id;
 if is_correct then
  insert into sp_quiz.scores(location_id,team_id,correct,points) values(l.id,a.team_id,1,award)
  on conflict(location_id,team_id) do update set correct=sp_quiz.scores.correct+1,
   points=sp_quiz.scores.points+excluded.points,reached_order=nextval('sp_quiz.score_order');
  select s.team_id into winner from sp_quiz.scores s where s.location_id=l.id
   order by s.points desc,s.reached_order asc limit 1;
  update sp_quiz.locations set owner_team_id=winner where id=l.id;
 end if;
 return sp_quiz.attempt_payload(a.id);
end $$;

revoke all on function sp_quiz.location_payload(text),sp_quiz.attempt_payload(uuid) from public,anon,authenticated;
revoke all on function public.sp_quiz_answer(uuid,uuid,boolean,double precision,double precision,double precision,timestamptz) from public,anon,authenticated;
grant execute on function public.sp_quiz_answer(uuid,uuid,boolean,double precision,double precision,double precision,timestamptz) to authenticated;
notify pgrst,'reload schema';
commit;
