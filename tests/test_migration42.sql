\set ON_ERROR_STOP on
set client_min_messages = warning;
do $$ begin
  assert (select count(*) from public.quiz_questions where explanation like '%(Règlement intérieur AFPA%' and category = 'general') = 50, '50 questions règlement';
  assert not exists (select 1 from public.quiz_questions group by lower(btrim(question)) having count(*) > 1), 'pas de doublon';
end $$;
select 'TEST MIGRATION 42 OK';
