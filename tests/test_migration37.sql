\set ON_ERROR_STOP on
set client_min_messages = warning;

-- Membre qui n'a pas encore répondu aujourd'hui
select set_config('t.m', (select id::text from public.profiles p where role = 'member' and anonymized_at is null
                            and not exists (select 1 from public.quiz_answers a where a.user_id = p.id and a.answered_on = public.quiz_day())
                          order by email limit 1), false);
set role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
select set_config('t.set', public.quiz_today_set()::text, false);
reset role;

-- Le chef pilote ajoute des questions dans la journée : le tirage du jour ne bouge pas
insert into public.quiz_questions (question, option_a, option_b, option_c, option_d, correct, category, active)
select 'Question ajoutée en cours de journée n°' || g, 'a', 'b', 'c', 'd', 'a', 'general', true from generate_series(1, 7) g;

set role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
do $$
declare s0 jsonb := current_setting('t.set')::jsonb; s jsonb := public.quiz_today_set(); q jsonb; other int;
begin
  assert jsonb_array_length(s -> 'questions') = 3, 'trois questions';
  assert (select array_agg(x ->> 'id') from jsonb_array_elements(s -> 'questions') x)
       = (select array_agg(x ->> 'id') from jsonb_array_elements(s0 -> 'questions') x), 'tirage figé malgré les ajouts';
  for q in select * from jsonb_array_elements(s -> 'questions') loop
    perform public.quiz_answer((q ->> 'id')::int, 'a');
  end loop;
  -- une 4e réponse est refusée, quelle que soit la question
  select id into other from public.quiz_questions
   where active and not (id = any (select (x ->> 'id')::int from jsonb_array_elements(s -> 'questions') x)) limit 1;
  begin perform public.quiz_answer(other, 'a'); raise exception 'ATTENDU';
  exception when others then assert sqlerrm like '%questions du jour%', sqlerrm; end;
  -- après les 3 réponses, la page montre toujours les mêmes questions, corrigées
  s := public.quiz_today_set();
  for q in select * from jsonb_array_elements(s -> 'questions') loop
    assert (q ->> 'already_answered')::boolean and q ->> 'correct' is not null, 'questions répondues';
  end loop;
end $$;

-- Le tirage n'est pas lisible ni modifiable directement
do $$ begin
  begin perform 1 from public.quiz_daily_set; raise exception 'ATTENDU';
  exception when insufficient_privilege then null; end;
  begin perform public._quiz_day_ids(current_date + 5); raise exception 'ATTENDU';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ begin assert (select count(*) from public.quiz_answers where user_id = current_setting('t.m')::uuid and answered_on = public.quiz_day()) = 3, '3 réponses max'; end $$;
delete from public.quiz_questions where question like 'Question ajoutée en cours de journée%';
select 'TEST MIGRATION 37 OK';
