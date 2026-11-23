-- Preserve published attempts and let the existing worker try another topic.
begin;

alter table sp_quiz.attempts
  add column generation_rejected_topics text[] not null default '{}';

create or replace function public.sp_quiz_generation_claim() returns jsonb
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

  select candidate.* into t
  from sp_quiz.generation_topics candidate
  cross join lateral (
    select max(previous.created_at) as last_used, count(distinct previous.answer) as truth_values
    from sp_quiz.attempts previous
    where previous.user_id=a.user_id and previous.generation_topic=candidate.id
      and previous.id<>a.id and previous.prompt is not null
  ) history
  where candidate.team_id=a.team_id and candidate.enabled
    and not (candidate.id=any(a.generation_rejected_topics))
    -- A fact has one true and one false claim. A paraphrase repeats the claim.
    and (candidate.rules->>'form'<>'fact' or history.truth_values<2)
  order by (a.worker_deadline is not null and candidate.id=a.generation_topic) desc nulls last,
    history.last_used nulls first, random()
  limit 1;

  update sp_quiz.attempts
  set generation_topic=t.id,worker_token=gen_random_uuid(),
    worker_deadline=clock_timestamp()+interval '12 seconds'
  where id=a.id returning * into a;
  return jsonb_build_object('id',a.id,'token',a.worker_token,'team_id',a.team_id,
    'topic',case when t.id is null then null else to_jsonb(t) end);
end $$;

create or replace function public.sp_quiz_generation_finish(attempt_id uuid,claim_token uuid,
  statement text,expected boolean) returns boolean
language plpgsql security definer set search_path='' as $$
declare
  a sp_quiz.attempts;
begin
  if (statement is null)<>(expected is null)
    or (statement is not null and length(trim(statement)) not between 5 and 500) then
    raise exception 'Invalid generated result.' using errcode='22023';
  end if;

  select * into a from sp_quiz.attempts
  where id=attempt_id and status='generating' and worker_token=claim_token
    and worker_deadline>clock_timestamp()
  for update;
  if a.id is null then return false; end if;

  if statement is null and a.generation_topic is not null then
    update sp_quiz.attempts
    set generation_rejected_topics=array_append(generation_rejected_topics,generation_topic),
      worker_token=null,worker_deadline=null
    where id=a.id;
    -- The worker immediately tries to claim again. Skip intermediate notifications.
    return true;
  end if;

  update sp_quiz.attempts
  set prompt=trim(statement),answer=expected,
    status=case when statement is null then 'generation_failed' else 'active' end,
    generation_rejected_topics='{}',worker_token=null,worker_deadline=null
  where id=a.id returning * into a;
  perform realtime.send(sp_quiz.attempt_payload(a.id),'quiz-ready',
    'sp-quiz-player:' || a.user_id::text,true);
  return true;
exception when unique_violation then return false;
end $$;

insert into sp_quiz.generation_topics(id,team_id,kind,source_url,evidence,rules) values
  ('science-whale-jaw','health_science','campus',
   'https://www.utrgv.edu/coastal-studies-lab/index.htm',
   'The jaw displayed in UTRGV Coastal Studies Laboratory was recovered from a sperm whale.',
   '{"form":"fact","correct":"sperm whale","decoy":"blue whale","wording":"UTRGV Coastal Studies Laboratory displays a jaw from a {value}.","pattern":"UTRGV(’s|''s)? Coastal Studies Lab(oratory)? (displays|exhibits) (a|the) jaw (from|of) a {value}[.]?"}'),
  ('science-oyster-hatchery','health_science','campus',
   'https://www.utrgv.edu/coastal-studies-lab/index.htm',
   'The UTRGV Coastal Studies Laboratory Bivalve Research Group runs an oyster hatchery.',
   '{"form":"fact","correct":"oysters","decoy":"lobsters","wording":"The UTRGV Coastal Studies Lab Bivalve Research Group runs a hatchery for {value}.","pattern":"(The )?UTRGV(’s|''s)? Coastal Studies Lab(oratory)?(’s|''s)? Bivalve Research Group (runs|operates) a hatchery for {value}[.]?"}'),
  ('science-beach-watch','health_science','campus',
   'https://www.utrgv.edu/coastal-studies-lab/public-service/texas-beach-watch/index.htm',
   'UTRGV Coastal Studies Laboratory monitors beach water quality under Texas Beach Watch.',
   '{"form":"fact","correct":"water quality","decoy":"sand temperature","wording":"UTRGV Coastal Studies Lab monitors {value} for Texas Beach Watch.","pattern":"UTRGV(’s|''s)? Coastal Studies Lab(oratory)? (monitors|tracks) (beach )?{value} (for|under) (the )?Texas Beach Watch( program)?[.]?"}'),
  ('science-antigravity-treadmill','health_science','campus',
   'https://www.utrgv.edu/cohp/schools-and-departments/department-of-health-human-performance/research/labs/index.htm',
   'UTRGV lists an anti-gravity treadmill in its Edinburg Exercise Physiology Lab.',
   '{"form":"fact","correct":"Edinburg","decoy":"South Padre Island","wording":"UTRGV lists an anti-gravity treadmill in its Exercise Physiology Lab in {value}.","pattern":"UTRGV (lists|has) an (anti[- ]gravity|antigravity) treadmill in (its|the) Exercise Physiology Lab(oratory)? (in|at|on) {value}[.]?"}'),
  ('science-ems-training','health_science','campus',
   'https://www.utrgv.edu/newsroom/2023/08/16/school%20of%20nursing-hosts-mass-casualty-simulation.htm',
   'UTRGV nursing students practiced responding to a simulated emergency alongside local medical first responders in August 2023.',
   '{"form":"fact","correct":"2023","decoy":"2020","wording":"UTRGV nursing students trained with local first responders in an emergency simulation in August {value}.","pattern":"UTRGV nursing students (trained|practiced|worked) (with|alongside) local first responders in (an emergency simulation|a simulated emergency) in August {value}[.]?"}'),
  ('science-adult-skeleton','health_science','classroom',
   'https://openstax.org/books/anatomy-and-physiology-2e/pages/7-1-divisions-of-the-skeletal-system',
   'A typical adult human skeleton contains 206 bones.',
   '{"form":"fact","correct":"206","decoy":"106","wording":"A typical adult human skeleton contains {value} bones.","pattern":"(A typical |A |The |The typical )?adult human skeleton (contains|has) {value} bones[.]?"}'),
  ('science-artery-direction','health_science','classroom',
   'https://openstax.org/books/anatomy-and-physiology/pages/20-1-structure-and-function-of-blood-vessels',
   'Arteries carry blood away from the heart.',
   '{"form":"fact","correct":"away from","decoy":"toward","wording":"Arteries carry blood {value} the heart.","pattern":"Arteries (carry|transport|conduct) blood {value} the heart[.]?"}');

commit;
