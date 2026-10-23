-- =====================================================================
--  Mise à jour n°34 : quiz à 3 questions par jour et banque de questions
--  - Chaque membre a désormais 3 questions par jour (au lieu d'une).
--  - Les réponses fausses ou ambiguës des questions d'origine sont corrigées
--    (seulement si elles n'ont pas déjà été modifiées depuis le site).
--  - Environ 900 nouvelles questions (QCM à 4 réponses) sont ajoutées, une seule
--    fois : le chef pilote peut ensuite les modifier, les retirer ou les supprimer.
--    Une grande partie s'appuie sur le « Guide de l'instructeur VFR » de l'ENAC
--    (édition 3, amendement 2, 12-2021, licence CC BY-NC-ND), les autres sur le
--    programme théorique LAPL/PPL.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Plusieurs réponses par jour ---------------------------------------------------
alter table public.quiz_answers add column if not exists answer char(1);
do $$
declare r record;
begin
  -- l'ancienne règle « une réponse par membre et par jour » disparaît
  for r in
    select c.conname from pg_constraint c
     where c.conrelid = 'public.quiz_answers'::regclass and c.contype = 'u'
       and (select array_agg(a.attname::text order by a.attname) from pg_attribute a
             where a.attrelid = c.conrelid and a.attnum = any (c.conkey)) = array['answered_on', 'user_id']
  loop
    execute format('alter table public.quiz_answers drop constraint %I', r.conname);
  end loop;
end $$;
create unique index if not exists quiz_answers_user_day_question
  on public.quiz_answers (user_id, answered_on, question_id);

-- Nombre de questions par jour
create or replace function public.quiz_per_day() returns int
language sql immutable set search_path = '' as $$ select 3 $$;

-- Les questions d'un jour : mélange stable (md5 de l'identifiant) pour varier les thèmes,
-- puis 3 questions consécutives de ce mélange par jour.
create or replace function public._quiz_set(p_day date)
returns int[]
language sql
stable
set search_path = ''
as $$
  with q as (
    select id, (row_number() over (order by md5(id::text), id) - 1) as rn, count(*) over () as n
      from public.quiz_questions
     where active
  ), k as (
    select q.id, min(g.k) as k
      from generate_series(0, public.quiz_per_day() - 1) as g(k)
      join q on q.rn = ((((p_day - date '2026-01-01') * public.quiz_per_day() + g.k) % q.n) + q.n) % q.n
     group by q.id
  )
  select coalesce(array_agg(id order by k), '{}') from k;
$$;
revoke execute on function public._quiz_set(date) from public, anon, authenticated;

-- Questions du jour (sans la bonne réponse tant que le membre n'a pas répondu)
create or replace function public.quiz_today_set()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ids int[];
begin
  if not public.is_approved() then return null; end if;
  v_ids := public._quiz_set(public.quiz_day());
  if coalesce(array_length(v_ids, 1), 0) = 0 then return null; end if;
  return jsonb_build_object(
    'day', public.quiz_day(),
    'questions', (
      select jsonb_agg(jsonb_build_object(
               'id', q.id, 'question', q.question, 'category', q.category,
               'option_a', q.option_a, 'option_b', q.option_b, 'option_c', q.option_c, 'option_d', q.option_d,
               'already_answered', a.id is not null,
               'my_answer', a.answer,
               'is_correct', a.is_correct,
               'correct', case when a.id is not null then q.correct end,
               'explanation', case when a.id is not null then q.explanation end)
             order by s.ord)
        from unnest(v_ids) with ordinality as s(id, ord)
        join public.quiz_questions q on q.id = s.id
        left join public.quiz_answers a
          on a.user_id = auth.uid() and a.answered_on = public.quiz_day() and a.question_id = q.id)
  );
end;
$$;

-- Ancien format (une seule question) : première question du jour pas encore répondue
create or replace function public.quiz_today()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_set jsonb := public.quiz_today_set();
  v_q   jsonb;
begin
  if v_set is null then return null; end if;
  select x into v_q from jsonb_array_elements(v_set->'questions') x
   where not (x->>'already_answered')::boolean limit 1;
  return coalesce(v_q, v_set->'questions'->0);
end;
$$;

-- Enregistre une réponse : la question doit faire partie des questions du jour
create or replace function public.quiz_answer(p_question int, p_answer text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_q   public.quiz_questions;
  v_ok  boolean;
  v_ans text := lower(btrim(coalesce(p_answer, '')));
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  if v_ans not in ('a', 'b', 'c', 'd') then raise exception 'Réponse invalide.'; end if;
  if not (p_question = any (public._quiz_set(public.quiz_day()))) then
    raise exception 'Cette question ne fait plus partie des questions du jour : rechargez la page.';
  end if;
  if exists (select 1 from public.quiz_answers
              where user_id = auth.uid() and answered_on = public.quiz_day() and question_id = p_question) then
    raise exception 'Vous avez déjà répondu à cette question.';
  end if;
  select * into v_q from public.quiz_questions where id = p_question;
  v_ok := v_q.correct = v_ans;
  insert into public.quiz_answers (user_id, question_id, answered_on, is_correct, answer)
  values (auth.uid(), p_question, public.quiz_day(), v_ok, v_ans)
  on conflict (user_id, answered_on, question_id) do nothing;
  return jsonb_build_object('correct', v_ok, 'answer', v_q.correct, 'explanation', v_q.explanation);
end;
$$;

-- Mes réponses récentes (3 par jour : on en garde 60) et mon total
create or replace function public.quiz_my_history()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'question_id', a.question_id, 'answered_on', a.answered_on, 'is_correct', a.is_correct,
           'question', q.question, 'category', q.category) order by a.answered_on desc, a.id desc), '[]'::jsonb)
  from (select * from public.quiz_answers where user_id = auth.uid() order by answered_on desc, id desc limit 60) a
  join public.quiz_questions q on q.id = a.question_id;
$$;

create or replace function public.quiz_my_stats()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('total', count(*), 'correct', count(*) filter (where is_correct))
    from public.quiz_answers where user_id = auth.uid();
$$;

revoke execute on function public.quiz_today_set(), public.quiz_today(), public.quiz_answer(int, text),
  public.quiz_my_history(), public.quiz_my_stats(), public.quiz_per_day() from public, anon;
grant execute on function public.quiz_today_set(), public.quiz_today(), public.quiz_answer(int, text),
  public.quiz_my_history(), public.quiz_my_stats(), public.quiz_per_day() to authenticated;

