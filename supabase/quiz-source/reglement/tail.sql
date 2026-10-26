notify pgrst, 'reload schema';

-- Vérification
select
  (select count(*) from public.quiz_questions where explanation like '%(Règlement intérieur AFPA%') as "questions règlement intérieur",
  exists (select 1 from public._seeds where name = 'quiz-reglement-42') as "MISE A JOUR 42 OK";
