-- SP / bsvcnndqvjizxgnxhxkd only. LOCAL, NOT APPLIED.
-- Adapted from GOTest's private questions, immutable attempts, idempotent receipts
-- and point locks. No HP, football, test-project accounts or profile migrations.
begin;
create schema sp_quiz;
revoke all on schema sp_quiz from public,anon,authenticated;
create table sp_quiz.questions (
 id text primary key, prompt text not null check(length(trim(prompt)) between 5 and 500),
 answer boolean not null, version bigint not null default 1,
 enabled boolean not null default true
);
insert into sp_quiz.questions values('placeholder-true-false','Placeholder: 2 + 2 = 4.',true,1,true);
create table sp_quiz.locations (
 id text primary key, name text not null check(length(trim(name)) between 1 and 80),
 description text not null default '', latitude double precision not null check(latitude between -90 and 90),
 longitude double precision not null check(longitude between -180 and 180),
 animation text not null check(animation in ('horse','plant','cats')),
 art_offsets jsonb not null default '[{"longitude":0,"latitude":0}]'::jsonb
  check(jsonb_typeof(art_offsets)='array' and jsonb_array_length(art_offsets) between 1 and 8),
 entry_meters double precision not null default 25 check(entry_meters between 1 and 100),
 exit_meters double precision not null default 40 check(exit_meters>entry_meters and exit_meters<=150),
 question_id text not null references sp_quiz.questions(id),
 enabled boolean not null default true,
 repeat_after_seconds integer not null default 600 check(repeat_after_seconds between 30 and 86400),
 tie_policy text not null default 'first_to_score' check(tie_policy='first_to_score'),
 owner_team_id text references sp_teams.catalog(id),
 revision bigint not null default 0, play_version bigint not null default 0
);
-- Existing SP artwork anchors, kept as editable data rather than a client list.
insert into sp_quiz.locations(id,name,description,latitude,longitude,animation,question_id) values
 ('kitty-island','Kitty Island','Stop on a safe outdoor path to answer the campus quiz.',26.307804,-98.171621,'cats','placeholder-true-false'),
 ('monstera','Monstera Plant','A large Monstera plant on campus.',26.307521,-98.174994,'plant','placeholder-true-false'),
 ('stallion','Bronco Point','Bucky the Bronco!',26.3063611,-98.1753889,'horse','placeholder-true-false');
update sp_quiz.locations set art_offsets='[{"longitude":-0.000059,"latitude":-0.000024},{"longitude":0,"latitude":0.000072},{"longitude":0.000051,"latitude":0.000026}]'
 where id='kitty-island';
create sequence sp_quiz.score_order;
create table sp_quiz.scores (
 location_id text not null references sp_quiz.locations(id),
 team_id text not null references sp_teams.catalog(id), correct bigint not null default 0 check(correct>=0),
 reached_order bigint not null default nextval('sp_quiz.score_order'),
 primary key(location_id,team_id)
);
create table sp_quiz.attempts (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id),
 team_id text not null references sp_teams.catalog(id), location_id text not null references sp_quiz.locations(id),
 request_id uuid not null, question_id text not null references sp_quiz.questions(id),
 question_version bigint not null, prompt text not null, answer boolean not null,
 play_version bigint not null,
 status text not null default 'active' check(status in ('active','answered','retired')),
 selected boolean, correct boolean, command_id uuid,
 created_at timestamptz not null default clock_timestamp(), answered_at timestamptz,
 unique(user_id,request_id), unique(user_id,command_id)
);
create index quiz_attempt_history on sp_quiz.attempts(user_id,location_id,created_at desc);
create function sp_quiz.version_question() returns trigger language plpgsql set search_path='' as $$
begin new.version:=old.version+1; return new; end $$;
create trigger quiz_question_version before update on sp_quiz.questions for each row execute function sp_quiz.version_question();
create function sp_quiz.version_location() returns trigger language plpgsql set search_path='' as $$
begin
 new.revision:=old.revision+1;
 if new.latitude is distinct from old.latitude or new.longitude is distinct from old.longitude
 or new.enabled is distinct from old.enabled or new.question_id is distinct from old.question_id
 or new.entry_meters is distinct from old.entry_meters or new.exit_meters is distinct from old.exit_meters then
  new.play_version:=old.play_version+1;
  update sp_quiz.attempts set status='retired' where location_id=old.id and status='active';
 else new.play_version:=old.play_version; end if;
 return new;
end $$;
create trigger quiz_location_version before update on sp_quiz.locations for each row execute function sp_quiz.version_location();

create function sp_quiz.location_payload(lid text) returns jsonb
language sql stable set search_path='' as $$
 select (to_jsonb(l)-'question_id'-'owner_team_id') || jsonb_build_object(
 'owner',(select to_jsonb(t) from sp_teams.catalog t where t.id=l.owner_team_id),
 'scores',coalesce((select jsonb_agg(jsonb_build_object('team',to_jsonb(t),'correct',coalesce(s.correct,0))
 order by coalesce(s.correct,0) desc,s.reached_order asc nulls last,t.sort_order,t.id)
 from sp_teams.catalog t left join sp_quiz.scores s on s.team_id=t.id and s.location_id=l.id
 where t.enabled or s.team_id is not null or t.id=l.owner_team_id),'[]'::jsonb))
 from sp_quiz.locations l where l.id=lid;
$$;
create function sp_quiz.attempt_payload(aid uuid) returns jsonb
language sql volatile set search_path='' as $$
 select jsonb_build_object('id',a.id,'prompt',a.prompt,'status',a.status,
 'selected',a.selected,'correct',a.correct,'server_now',clock_timestamp(),
 'retry_at',case when a.answered_at is not null
 then a.answered_at+make_interval(secs=>l.repeat_after_seconds) end,
 'location',sp_quiz.location_payload(a.location_id))
 from sp_quiz.attempts a join sp_quiz.locations l on l.id=a.location_id where a.id=aid;
$$;
create function sp_quiz.require_fix(lid text, latitude double precision,longitude double precision,
 accuracy_meters double precision,fix_at timestamptz) returns void language plpgsql set search_path='' as $$
declare l sp_quiz.locations; distance_m double precision;
begin
 select * into l from sp_quiz.locations where id=lid;
 if l.id is null or not l.enabled then raise exception 'This quiz location is unavailable.' using errcode='PT409'; end if;
 if latitude is null or longitude is null or not(latitude between -90 and 90) or not(longitude between -180 and 180)
 or accuracy_meters is null or not(accuracy_meters between 0 and 15) or fix_at is null
 or fix_at>clock_timestamp()+interval '2 seconds' or fix_at<clock_timestamp()-interval '10 seconds' then
  raise exception 'A fresh, accurate GPS position is required.' using errcode='42501'; end if;
 distance_m:=6371000*2*asin(least(1,sqrt(power(sin(radians(latitude-l.latitude)/2),2)
 +cos(radians(latitude))*cos(radians(l.latitude))*power(sin(radians(longitude-l.longitude)/2),2))));
 if distance_m+accuracy_meters>l.entry_meters then
  raise exception 'Move inside this location proximity to answer.' using errcode='42501'; end if;
end $$;

create function public.sp_quiz_catalog() returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=sp_teams.require_player(); result jsonb;
begin
 select coalesce(jsonb_agg(sp_quiz.location_payload(l.id) order by l.id),'[]'::jsonb)
 into result from sp_quiz.locations l where l.enabled;
 return result;
end $$;
create function public.sp_quiz_begin(location_id text,request_id uuid,latitude double precision,
 longitude double precision,accuracy_meters double precision,fix_at timestamptz) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=sp_teams.require_player(); team text; l sp_quiz.locations; q sp_quiz.questions; a sp_quiz.attempts;
begin
 if request_id is null then raise exception 'Request ID required.' using errcode='22023'; end if;
 -- Same actor/point lock order as GOTest. Account choice is canonical in SP.
 perform pg_advisory_xact_lock(hashtextextended(actor::text,61117));
 select m.team_id into team from sp_teams.memberships m where m.user_id=actor;
 if team is null then raise exception 'Choose your permanent team first.' using errcode='42501'; end if;
 select * into l from sp_quiz.locations where id=location_id for update;
 perform sp_quiz.require_fix(location_id,latitude,longitude,accuracy_meters,fix_at);
 select * into a from sp_quiz.attempts x where x.user_id=actor and x.request_id=sp_quiz_begin.request_id;
 if a.id is not null then
  if a.location_id<>l.id then raise exception 'Request belongs to another location.' using errcode='22023'; end if;
  return sp_quiz.attempt_payload(a.id);
 end if;
 select * into q from sp_quiz.questions where id=l.question_id and enabled;
 if q.id is null then raise exception 'No quiz question is available.' using errcode='55000'; end if;
 select * into a from sp_quiz.attempts x where x.user_id=actor and x.location_id=l.id
 and (x.status='answered' or (x.status='active' and x.play_version=l.play_version))
 order by x.created_at desc,x.id desc limit 1;
 if a.id is not null and (a.status='active' or (a.status='answered' and
 a.answered_at+make_interval(secs=>l.repeat_after_seconds)>clock_timestamp())) then
  return sp_quiz.attempt_payload(a.id);
 end if;
 insert into sp_quiz.attempts(user_id,team_id,location_id,request_id,question_id,question_version,prompt,answer,play_version)
 values(actor,team,l.id,request_id,q.id,q.version,q.prompt,q.answer,l.play_version) returning * into a;
 return sp_quiz.attempt_payload(a.id);
end $$;
create function public.sp_quiz_answer(attempt_id uuid,command_id uuid,selected boolean,
 latitude double precision,longitude double precision,accuracy_meters double precision,fix_at timestamptz) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=sp_teams.require_player(); a sp_quiz.attempts; l sp_quiz.locations;
 lid text; winner text; is_correct boolean;
begin
 if command_id is null or selected is null then raise exception 'Answer and command ID required.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(actor::text,61117));
 select x.location_id into lid from sp_quiz.attempts x where x.id=attempt_id and x.user_id=actor;
 if lid is null then raise exception 'Quiz attempt unavailable.' using errcode='42501'; end if;
 select * into l from sp_quiz.locations where id=lid for update;
 select * into a from sp_quiz.attempts where id=attempt_id for update;
 -- A receipt retry returns its saved outcome, even after departure; no new credit.
 if a.status='answered' then
  if a.command_id<>sp_quiz_answer.command_id or a.selected<>sp_quiz_answer.selected then
   raise exception 'This question was already answered.' using errcode='PT409'; end if;
  return sp_quiz.attempt_payload(a.id);
 end if;
 if a.status<>'active' or not l.enabled or a.play_version<>l.play_version then
  raise exception 'This quiz changed. Close and reopen the location.' using errcode='PT409'; end if;
 perform sp_quiz.require_fix(lid,latitude,longitude,accuracy_meters,fix_at);
 is_correct:=selected=a.answer;
 update sp_quiz.attempts set status='answered',selected=sp_quiz_answer.selected,correct=is_correct,
 command_id=sp_quiz_answer.command_id,answered_at=clock_timestamp() where id=a.id;
 if is_correct then
  insert into sp_quiz.scores(location_id,team_id,correct) values(l.id,a.team_id,1)
  on conflict(location_id,team_id) do update set correct=sp_quiz.scores.correct+1,
   reached_order=nextval('sp_quiz.score_order');
  -- The location row lock serializes arrivals; the first team to reach a tied
  -- total wins. Updating reached_order on EACH correct answer avoids last-hit wins.
  select s.team_id into winner from sp_quiz.scores s where s.location_id=l.id
   order by s.correct desc,s.reached_order asc limit 1;
  update sp_quiz.locations set owner_team_id=winner where id=l.id;
 end if;
 return sp_quiz.attempt_payload(a.id);
end $$;

alter table sp_quiz.questions enable row level security;
alter table sp_quiz.locations enable row level security;
alter table sp_quiz.scores enable row level security;
alter table sp_quiz.attempts enable row level security;
revoke all on all tables in schema sp_quiz from public,anon,authenticated;
revoke all on all functions in schema sp_quiz from public,anon,authenticated;
revoke all on function public.sp_quiz_catalog(),
 public.sp_quiz_begin(text,uuid,double precision,double precision,double precision,timestamptz),
 public.sp_quiz_answer(uuid,uuid,boolean,double precision,double precision,double precision,timestamptz) from public,anon,authenticated;
grant execute on function public.sp_quiz_catalog(),
 public.sp_quiz_begin(text,uuid,double precision,double precision,double precision,timestamptz),
 public.sp_quiz_answer(uuid,uuid,boolean,double precision,double precision,double precision,timestamptz) to authenticated;
notify pgrst,'reload schema';
commit;
