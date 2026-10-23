\set ON_ERROR_STOP on
set client_min_messages = warning;

-- Quiz : le chef pilote gère les questions, un membre ne les lit pas
select set_config('t.cp', (select id::text from public.profiles where is_chief_pilot and anonymized_at is null limit 1), false);
select set_config('t.m', (select id::text from public.profiles where role = 'member' and not is_chief_pilot and not is_compliance
                            and not is_treasurer and anonymized_at is null order by email limit 1), false);
select set_config('t.answered', coalesce((select question_id::text from public.quiz_answers limit 1), ''), false);
set role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.cp'), false);
insert into public.quiz_questions (question, option_a, option_b, option_c, option_d, correct, explanation, category)
values ('Question test 33 ?', 'A', 'B', 'C', 'D', 'c', 'Parce que.', 'securite');
update public.quiz_questions set active = false where question = 'Question test 33 ?';
do $$ begin assert (select count(*) from public.quiz_questions where question = 'Question test 33 ?') = 1, 'chef pilote lit tout'; end $$;
-- suppression : possible pour une question sans réponse, refusée si des membres y ont répondu
delete from public.quiz_questions where question = 'Question test 33 ?';
do $$ begin
  assert (select count(*) from public.quiz_questions where question = 'Question test 33 ?') = 0, 'supprimée';
  if current_setting('t.answered') <> '' then
    begin
      delete from public.quiz_questions where id = current_setting('t.answered')::int;
      raise exception 'ATTENDU';
    exception when foreign_key_violation then null; end;
  end if;
end $$;
select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
do $$ begin
  assert (select count(*) from public.quiz_questions) = 0, 'membre ne lit pas les questions';
  begin
    insert into public.quiz_questions (question, option_a, option_b, option_c, option_d, correct) values ('x', 'a', 'b', 'c', 'd', 'a');
    raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; end;
  delete from public.quiz_questions;  -- ne voit rien, donc ne supprime rien
end $$;
reset role;

-- Les données d'exemple ne sont jamais reposées
do $$ begin
  assert not public._seed_once('centrage-26'), 'déjà posé';
  assert not public._seed_once('bar-22'), 'déjà posé';
end $$;

select 'test_migration33 OK';
