-- SP only. Keep the existing quiz path until generation is enabled in Supabase.
begin;

create table sp_quiz.generation_settings (
  singleton boolean primary key default true check (singleton),
  enabled boolean not null default false
);
insert into sp_quiz.generation_settings default values;

-- Source material and validation rules. Questions are generated per attempt.
create table sp_quiz.generation_topics (
  id text primary key,
  team_id text not null references sp_teams.catalog(id),
  kind text not null check (kind in ('campus','classroom')),
  source_url text,
  evidence text not null check (length(evidence) between 1 and 1000),
  rules jsonb not null,
  enabled boolean not null default true,
  check (kind <> 'campus' or source_url like 'https://www.utrgv.edu/%')
);
alter table sp_quiz.generation_topics enable row level security;
alter table sp_quiz.generation_settings enable row level security;
revoke all on sp_quiz.generation_topics,sp_quiz.generation_settings from public,anon,authenticated;

alter table sp_quiz.attempts alter column question_id drop not null,
  alter column question_version drop not null, alter column prompt drop not null,
  alter column answer drop not null,
  add column generation_topic text references sp_quiz.generation_topics(id),
  add column worker_token uuid, add column worker_deadline timestamptz;
alter table sp_quiz.attempts drop constraint attempts_status_check,
  add constraint attempts_status_check
    check (status in ('active','answered','retired','generating','generation_failed')),
  add constraint attempts_ready_prompt_check
    check (status not in ('active','answered') or (prompt is not null and answer is not null));
create index quiz_generation_pending on sp_quiz.attempts(created_at)
  where status='generating';
create unique index quiz_generated_statement_per_player
  on sp_quiz.attempts(user_id, (regexp_replace(lower(prompt), '[^[:alnum:]]', '', 'g')))
  where generation_topic is not null and prompt is not null;

create policy sp_quiz_player_notifications on realtime.messages for select to authenticated
  using (extension='broadcast'
    and (select realtime.topic())='sp-quiz-player:' || (select auth.uid())::text);

create or replace function sp_quiz.version_location() returns trigger
language plpgsql set search_path='' as $$
begin
  new.revision:=old.revision+1;
  if new.latitude is distinct from old.latitude or new.longitude is distinct from old.longitude
    or new.enabled is distinct from old.enabled or new.question_id is distinct from old.question_id
    or new.entry_meters is distinct from old.entry_meters
    or new.exit_meters is distinct from old.exit_meters then
    new.play_version:=old.play_version+1;
    update sp_quiz.attempts set status='retired',worker_token=null,worker_deadline=null
    where location_id=old.id and status in ('active','generating','generation_failed');
  else
    new.play_version:=old.play_version;
  end if;
  return new;
end $$;

create or replace function public.sp_quiz_begin(location_id text,request_id uuid,
  latitude double precision,longitude double precision,accuracy_meters double precision,
  fix_at timestamptz) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  actor uuid:=sp_teams.require_player();
  team text;
  l sp_quiz.locations;
  q sp_quiz.questions;
  a sp_quiz.attempts;
  generate_live boolean;
begin
  if request_id is null then raise exception 'Request ID required.' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text,61117));
  select m.team_id into team from sp_teams.memberships m where m.user_id=actor;
  if team is null then raise exception 'Choose your permanent team first.' using errcode='42501'; end if;
  select * into l from sp_quiz.locations where id=location_id for update;
  perform sp_quiz.require_fix(location_id,latitude,longitude,accuracy_meters,fix_at);
  select enabled into generate_live from sp_quiz.generation_settings where singleton;
  select * into a from sp_quiz.attempts x
  where x.user_id=actor and x.request_id=sp_quiz_begin.request_id;
  if a.id is not null and a.location_id<>l.id then
    raise exception 'Request belongs to another location.' using errcode='22023';
  end if;
  if a.id is null then
    select * into a from sp_quiz.attempts x
    where x.user_id=actor and x.location_id=l.id
      and (x.status='answered' or (x.status in ('active','generating','generation_failed')
        and x.play_version=l.play_version))
    order by x.created_at desc,x.id desc limit 1;
    if a.status='answered' and
      a.answered_at+make_interval(secs=>l.repeat_after_seconds)<=clock_timestamp() then
      a:=null;
    end if;
  end if;
  if a.status='generation_failed' and generate_live then
    update sp_quiz.attempts set status='generating',worker_token=null,worker_deadline=null
    where id=a.id and status='generation_failed' returning * into a;
    if a.id is not null then
      perform realtime.send('{}'::jsonb,'quiz-request','sp-quiz-worker',true);
      return sp_quiz.attempt_payload(a.id);
    end if;
  elsif a.id is not null then
    return sp_quiz.attempt_payload(a.id);
  end if;
  if generate_live then
    insert into sp_quiz.attempts(user_id,team_id,location_id,request_id,play_version,status)
    values(actor,team,l.id,request_id,l.play_version,'generating') returning * into a;
    perform realtime.send('{}'::jsonb,'quiz-request','sp-quiz-worker',true);
  else
    select * into q from sp_quiz.questions where id=l.question_id and enabled;
    if q.id is null then raise exception 'No quiz question is available.' using errcode='55000'; end if;
    insert into sp_quiz.attempts(user_id,team_id,location_id,request_id,
      question_id,question_version,prompt,answer,play_version)
    values(actor,team,l.id,request_id,q.id,q.version,q.prompt,q.answer,l.play_version)
    returning * into a;
  end if;
  return sp_quiz.attempt_payload(a.id);
end $$;

create function public.sp_quiz_read(attempt_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=sp_teams.require_player();
begin
  if not exists (select 1 from sp_quiz.attempts where id=attempt_id and user_id=actor) then
    raise exception 'Quiz attempt unavailable.' using errcode='42501';
  end if;
  return sp_quiz.attempt_payload(attempt_id);
end $$;

create function public.sp_quiz_generation_claim() returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  a sp_quiz.attempts;
  t sp_quiz.generation_topics;
begin
  if not exists (select 1 from sp_quiz.generation_settings where singleton and enabled) then
    return null;
  end if;
  select * into a from sp_quiz.attempts
  where status='generating' and (worker_deadline is null or worker_deadline<=clock_timestamp())
  order by created_at for update skip locked limit 1;
  if a.id is null then return null; end if;
  select candidate.* into t from sp_quiz.generation_topics candidate
  where candidate.team_id=a.team_id and candidate.enabled
  order by (candidate.id=a.generation_topic) desc nulls last,
    (select max(previous.created_at) from sp_quiz.attempts previous
      where previous.user_id=a.user_id and previous.generation_topic=candidate.id
        and previous.id<>a.id and previous.prompt is not null) nulls first,
    random()
  limit 1;
  update sp_quiz.attempts
  set generation_topic=t.id,worker_token=gen_random_uuid(),
    worker_deadline=clock_timestamp()+interval '12 seconds'
  where id=a.id returning * into a;
  return jsonb_build_object('id',a.id,'token',a.worker_token,'team_id',a.team_id,
    'topic',case when t.id is null then null else to_jsonb(t) end);
end $$;

create function public.sp_quiz_generation_finish(attempt_id uuid,claim_token uuid,
  statement text,expected boolean) returns boolean
language plpgsql security definer set search_path='' as $$
declare a sp_quiz.attempts;
begin
  if (statement is null)<>(expected is null)
    or (statement is not null and length(trim(statement)) not between 5 and 500) then
    raise exception 'Invalid generated result.' using errcode='22023';
  end if;
  update sp_quiz.attempts
  set prompt=trim(statement),answer=expected,
    status=case when statement is null then 'generation_failed' else 'active' end,
    worker_token=null,worker_deadline=null
  where id=attempt_id and status='generating' and worker_token=claim_token
    and worker_deadline>clock_timestamp()
  returning * into a;
  if a.id is null then return false; end if;
  -- Broadcast only the player payload. The private attempt row holds the answer.
  perform realtime.send(sp_quiz.attempt_payload(a.id),'quiz-ready',
    'sp-quiz-player:' || a.user_id::text,true);
  return true;
exception when unique_violation then return false;
end $$;

revoke all on function public.sp_quiz_read(uuid),
  public.sp_quiz_generation_claim(),public.sp_quiz_generation_finish(uuid,uuid,text,boolean)
  from public,anon,authenticated;
grant execute on function public.sp_quiz_read(uuid) to authenticated;
grant execute on function public.sp_quiz_generation_claim(),
  public.sp_quiz_generation_finish(uuid,uuid,text,boolean) to service_role;
notify pgrst,'reload schema';
commit;
