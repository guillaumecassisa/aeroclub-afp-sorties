\set ON_ERROR_STOP on
set client_min_messages = warning;

-- Corrections des questions d'origine
do $$ begin
  assert (select correct from public.quiz_questions where question = 'Quelle est la définition du QNH ?') = 'a', 'QNH corrigé';
  assert (select option_c from public.quiz_questions where question = 'Quelle est la fréquence de la tour d''Aix-les-Milles (LFMA) ?') = '118,755 MHz', 'fréquence LFMA';
  assert (select correct from public.quiz_questions where question like 'La prise de pression totale (Pitot)%') = 'a', 'Pitot corrigé';
  assert (select explanation from public.quiz_questions where question = 'Le circuit de piste standard se fait :') = 'retouchée', 'question retouchée préservée';
  assert (select count(*) from public.quiz_questions) >= 900, 'banque de questions';
  assert (select count(*) from public.quiz_questions where correct = 'a') between 200 and 300, 'réponses réparties';
  assert not exists (select 1 from public.quiz_questions group by lower(btrim(question)) having count(*) > 1), 'pas de doublon';
end $$;

-- Mélange stable, 3 questions différentes par jour
do $$ declare d1 int[] := public._quiz_set(date '2026-11-02'); d2 int[] := public._quiz_set(date '2026-11-03');
begin
  assert array_length(d1, 1) = 3, '3 questions';
  assert d1 = public._quiz_set(date '2026-11-02'), 'stable dans la journée';
  assert not (d1 && d2), 'pas les mêmes questions le lendemain';
  assert (select count(distinct x) from unnest(d1) x) = 3, 'distinctes';
end $$;

select set_config('t.m2', (select id::text from public.profiles where role = 'member' and anonymized_at is null
                             and not exists (select 1 from public.quiz_answers a where a.user_id = profiles.id)
                           order by email limit 1), false);
select set_config('t.other', (select x::text from unnest(public._quiz_set(public.quiz_day() + 1)) x limit 1), false);
set role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.m2'), false);
do $$
declare s jsonb := public.quiz_today_set(); q jsonb; r jsonb; i int := 0; other int;
begin
  assert s is not null and jsonb_array_length(s -> 'questions') = 3, 'trois questions du jour';
  for q in select * from jsonb_array_elements(s -> 'questions') loop
    assert q ->> 'correct' is null and q ->> 'explanation' is null, 'réponse cachée';
    assert not (q ->> 'already_answered')::boolean, 'pas encore répondu';
  end loop;
  -- ancienne interface : première question non répondue
  assert (public.quiz_today() ->> 'id') = (s -> 'questions' -> 0 ->> 'id'), 'quiz_today compatible';
  r := public.quiz_answer((s -> 'questions' -> 0 ->> 'id')::int, 'A');
  assert r ? 'answer' and r ? 'correct', 'correction';
  assert (public.quiz_today() ->> 'id') = (s -> 'questions' -> 1 ->> 'id'), 'passe à la suivante';
  begin perform public.quiz_answer((s -> 'questions' -> 0 ->> 'id')::int, 'b'); raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; assert sqlerrm like '%déjà répondu%', sqlerrm; end;
  begin perform public.quiz_answer((s -> 'questions' -> 1 ->> 'id')::int, 'z'); raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; assert sqlerrm like '%invalide%', sqlerrm; end;
  other := current_setting('t.other')::int;
  begin perform public.quiz_answer(other, 'a'); raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; assert sqlerrm like '%questions du jour%', sqlerrm; end;
  perform public.quiz_answer((s -> 'questions' -> 1 ->> 'id')::int, 'b');
  perform public.quiz_answer((s -> 'questions' -> 2 ->> 'id')::int, 'c');
  s := public.quiz_today_set();
  for q in select * from jsonb_array_elements(s -> 'questions') loop
    i := i + 1;
    assert (q ->> 'already_answered')::boolean and q ->> 'correct' is not null, 'correction visible après réponse';
    assert q ->> 'my_answer' in ('a', 'b', 'c'), 'ma réponse mémorisée';
  end loop;
  assert i = 3, 'trois';
  assert (public.quiz_my_stats() ->> 'total')::int = 3, 'stats';
  assert jsonb_array_length(public.quiz_my_history()) = 3, 'historique';
end $$;
reset role;

-- Hors connexion : rien
set role anon;
do $$ begin
  begin perform public.quiz_today_set(); raise exception 'ATTENDU';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

select 'test_migration34 OK';
