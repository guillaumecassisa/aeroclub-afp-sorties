\set ON_ERROR_STOP on
do $$ begin
  assert (select count(*) from public.quiz_questions where category = 'flotte') = 50, 'Flotte : 50 questions';
  assert exists (select 1 from public.quiz_questions where category = 'culture' and question = 'Le Cessna 152 est :'), 'question déplacée en Culture';
  assert exists (select 1 from public.quiz_questions where category = 'general' and question = 'Qu''est-ce qu''un avion à train classique ?'), 'question déplacée en Général';
  assert not public._seed_once('quiz-flotte-35'), 'posée une seule fois';
end $$;
select 'test_migration35 OK';
