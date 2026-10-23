-- =====================================================================
--  Mise à jour n°37 : les 3 questions du jour ne changent plus dans la journée
--  Avant : le tirage du jour dépendait du nombre de questions actives. Ajouter,
--  retirer ou réactiver une question dans la journée changeait le tirage, et un
--  membre pouvait alors répondre à 3 nouvelles questions.
--  Désormais :
--   - le tirage est enregistré au premier affichage de la journée et ne bouge plus ;
--   - un membre ne peut jamais répondre à plus de 3 questions par jour.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Tirage figé de chaque jour (commun à tous les membres)
create table if not exists public.quiz_daily_set (
  day        date primary key,
  ids        int[] not null,
  created_at timestamptz not null default now()
);
alter table public.quiz_daily_set enable row level security;
-- aucune policy : lecture et écriture uniquement via les fonctions ci-dessous
revoke all on public.quiz_daily_set from anon, authenticated;

-- Le tirage d'aujourd'hui est figé avec les questions déjà proposées aujourd'hui
-- (celles auxquelles des membres ont répondu en priorité, pour ne léser personne).
insert into public.quiz_daily_set (day, ids)
select public.quiz_day(), public._quiz_set(public.quiz_day())
on conflict (day) do nothing;

-- Questions d'un jour : lues dans le tirage enregistré, sinon tirées puis enregistrées
create or replace function public._quiz_day_ids(p_day date)
returns int[]
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_ids int[];
begin
  select ids into v_ids from public.quiz_daily_set where day = p_day;
  if v_ids is not null then return v_ids; end if;
  v_ids := public._quiz_set(p_day);
  if coalesce(array_length(v_ids, 1), 0) = 0 then return v_ids; end if;
  insert into public.quiz_daily_set (day, ids) values (p_day, v_ids)
  on conflict (day) do nothing;
  select ids into v_ids from public.quiz_daily_set where day = p_day;
  return v_ids;
end;
$$;
revoke execute on function public._quiz_day_ids(date) from public, anon, authenticated;

-- 2. Questions du jour (sans la bonne réponse tant que le membre n'a pas répondu)
create or replace function public.quiz_today_set()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_ids int[];
begin
  if not public.is_approved() then return null; end if;
  v_ids := public._quiz_day_ids(public.quiz_day());
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
volatile
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

-- 3. Enregistrer une réponse : question du tirage du jour, 3 réponses par jour au maximum
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
  -- verrou par membre : deux réponses envoyées en même temps ne passent pas la limite
  perform pg_advisory_xact_lock(hashtext('quiz:' || auth.uid()::text));
  if exists (select 1 from public.quiz_answers
              where user_id = auth.uid() and answered_on = public.quiz_day() and question_id = p_question) then
    raise exception 'Vous avez déjà répondu à cette question.';
  end if;
  if (select count(*) from public.quiz_answers
       where user_id = auth.uid() and answered_on = public.quiz_day()) >= public.quiz_per_day() then
    raise exception 'Vous avez déjà répondu à vos % questions du jour. Rendez-vous demain !', public.quiz_per_day();
  end if;
  if not (p_question = any (public._quiz_day_ids(public.quiz_day()))) then
    raise exception 'Cette question ne fait plus partie des questions du jour : rechargez la page.';
  end if;
  select * into v_q from public.quiz_questions where id = p_question;
  v_ok := v_q.correct = v_ans;
  insert into public.quiz_answers (user_id, question_id, answered_on, is_correct, answer)
  values (auth.uid(), p_question, public.quiz_day(), v_ok, v_ans)
  on conflict (user_id, answered_on, question_id) do nothing;
  return jsonb_build_object('correct', v_ok, 'answer', v_q.correct, 'explanation', v_q.explanation);
end;
$$;

revoke execute on function public.quiz_today_set(), public.quiz_today(), public.quiz_answer(int, text)
  from public, anon;
grant execute on function public.quiz_today_set(), public.quiz_today(), public.quiz_answer(int, text)
  to authenticated;

-- Vérification
select 'MISE A JOUR 37 OK' as resultat,
       (select ids from public.quiz_daily_set where day = public.quiz_day()) as questions_du_jour;
