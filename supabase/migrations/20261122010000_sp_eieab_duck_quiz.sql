-- SP / bsvcnndqvjizxgnxhxkd only. Local migration.
begin;

alter table sp_quiz.locations
  drop constraint locations_animation_check,
  add constraint locations_animation_check
    check (animation in ('horse', 'plant', 'cats', 'duck'));

insert into sp_quiz.locations (
  id, name, description, latitude, longitude, animation, question_id
) values (
  'eieab', 'Computer Science (EIEAB)', 'Campus quiz on the path north of EIEAB.',
  26.30637471, -98.17457576, 'duck', 'placeholder-true-false'
);

-- Older app builds reject an entire catalog that contains an unknown animation.
create or replace function public.sp_quiz_catalog() returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  actor uuid := sp_teams.require_player();
  supported text[] := string_to_array(
    nullif(current_setting('request.headers', true), '')::jsonb->>'x-sp-quiz-animations', ','
  );
  result jsonb;
begin
  select coalesce(jsonb_agg(sp_quiz.location_payload(l.id) order by l.id), '[]'::jsonb)
    into result
    from sp_quiz.locations l
    where l.enabled and l.animation = any(coalesce(supported, array['horse', 'plant', 'cats']));
  return result;
end $$;

commit;
