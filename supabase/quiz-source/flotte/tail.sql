notify pgrst, 'reload schema';

-- Vérification
select
  (select count(*) from public.quiz_questions where category = 'flotte') as "questions Flotte",
  exists (select 1 from public._seeds where name = 'quiz-flotte-35') as "MISE A JOUR 35 OK";
