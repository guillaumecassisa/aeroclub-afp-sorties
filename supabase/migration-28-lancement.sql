-- =====================================================================
--  Mise à jour n°28 : corrections avant la mise en service
--  - Aligne le dépôt sur la base réelle (colonnes du shop, tables du quiz,
--    colonne referent_instructor_id) : sans effet si c'est déjà le cas.
--  - Shop : annulation par le membre et passage « livrée » avec débit de
--    l'ardoise, par des fonctions sécurisées (les tables restent protégées).
--  - Quiz : la bonne réponse n'est plus lisible avant d'avoir répondu, les
--    réponses ne sont plus lisibles sans être connecté ; question du jour,
--    réponse et classement passent par des fonctions.
--  - Stats bar + shop pour les administrateurs et le trésorier.
--  - Stockage : seuls les administrateurs déposent les images du shop
--    (images uniquement, 5 Mo maximum).
--  - Petits durcissements signalés par l'outil de sécurité de Supabase.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 0. Alignement du dépôt sur la base réelle --------------------------------
alter table public.outings
  add column if not exists referent_instructor_id uuid references public.profiles (id);

alter table public.shop_orders
  add column if not exists item_name       text,
  add column if not exists price_cents     int,
  add column if not exists ardoise_charged boolean not null default false;

create table if not exists public.quiz_questions (
  id          serial primary key,
  question    text not null,
  option_a    text not null,
  option_b    text not null,
  option_c    text not null,
  option_d    text not null,
  correct     char(1) not null check (correct in ('a', 'b', 'c', 'd')),
  explanation text,
  category    text,
  active      boolean not null default true
);
create table if not exists public.quiz_answers (
  id          serial primary key,
  user_id     uuid not null references auth.users (id) on delete cascade,
  question_id int  not null references public.quiz_questions (id),
  answered_on date not null,
  is_correct  boolean not null,
  unique (user_id, answered_on)
);
alter table public.quiz_questions enable row level security;
alter table public.quiz_answers  enable row level security;

-- 1. Shop --------------------------------------------------------------------
create or replace function public.cancel_shop_order(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.shop_orders;
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  select * into v_order from public.shop_orders where id = p_id for update;
  if not found then raise exception 'Commande introuvable.'; end if;
  if v_order.user_id <> auth.uid() and public.app_role() <> 'admin' then
    raise exception 'Ce n''est pas votre commande.';
  end if;
  if v_order.status <> 'pending' and public.app_role() <> 'admin' then
    raise exception 'Cette commande est déjà en préparation : contactez le club pour l''annuler.';
  end if;
  if v_order.status in ('delivered', 'cancelled') then raise exception 'Cette commande est déjà clôturée.'; end if;
  update public.shop_orders set status = 'cancelled', updated_at = now() where id = p_id;
end;
$$;

-- Change le statut d'une commande ; « delivered » débite l'ardoise du membre une seule fois.
create or replace function public.set_shop_order_status(p_id uuid, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order   public.shop_orders;
  v_label   text;
  v_variant text;
  v_charged boolean := false;
begin
  if public.app_role() is distinct from 'admin' then raise exception 'Réservé aux administrateurs.'; end if;
  if p_status not in ('pending', 'confirmed', 'ready', 'delivered', 'cancelled') then
    raise exception 'Statut inconnu.';
  end if;
  select * into v_order from public.shop_orders where id = p_id for update;
  if not found then raise exception 'Commande introuvable.'; end if;

  if p_status = 'delivered' and not v_order.ardoise_charged and coalesce(v_order.price_cents, 0) > 0 then
    v_variant := concat_ws(' / ', nullif(v_order.size, ''), nullif(v_order.color, ''));
    v_label := 'Shop – ' || coalesce(v_order.item_name, 'Article')
               || case when v_variant <> '' then ' (' || v_variant || ')' else '' end;
    insert into public.bar_consumptions (user_id, product_id, product_name, unit_price_cents, quantity, created_by)
    values (v_order.user_id, null, v_label, v_order.price_cents, v_order.quantity, auth.uid());
    v_charged := true;
  end if;

  update public.shop_orders
     set status = p_status,
         ardoise_charged = ardoise_charged or v_charged,
         updated_at = now()
   where id = p_id;
  return jsonb_build_object('charged', v_charged);
end;
$$;

revoke execute on function public.cancel_shop_order(uuid) from public, anon;
revoke execute on function public.set_shop_order_status(uuid, text) from public, anon;
grant execute on function public.cancel_shop_order(uuid) to authenticated;
grant execute on function public.set_shop_order_status(uuid, text) to authenticated;

-- Fonction de déclencheur : n'a pas à être appelable depuis l'API
do $$ begin
  if exists (select 1 from pg_proc where proname = 'touch_shop_order' and pronamespace = 'public'::regnamespace) then
    execute 'revoke execute on function public.touch_shop_order() from public, anon, authenticated';
  end if;
end $$;

-- 2. Quiz --------------------------------------------------------------------
drop policy if exists quiz_answers_all_read on public.quiz_answers;
drop policy if exists quiz_answers_own_read on public.quiz_answers;
drop policy if exists quiz_answers_own_insert on public.quiz_answers;
drop policy if exists quiz_questions_read on public.quiz_questions;
-- Plus aucun accès direct : tout passe par les fonctions ci-dessous
revoke all on public.quiz_questions, public.quiz_answers from anon, authenticated;

-- Jour du quiz = date à Paris
create or replace function public.quiz_day() returns date
language sql stable set search_path = ''
as $$ select (now() at time zone 'Europe/Paris')::date $$;

-- Question du jour, sans la bonne réponse (et la réponse du membre s'il a déjà joué)
create or replace function public.quiz_today()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_n   int;
  v_q   public.quiz_questions;
  v_ans public.quiz_answers;
begin
  if not public.is_approved() then return null; end if;
  select count(*) into v_n from public.quiz_questions where active;
  if v_n = 0 then return null; end if;
  select * into v_q from public.quiz_questions where active order by id
   offset ((public.quiz_day() - date '2026-01-01') % v_n + v_n) % v_n limit 1;
  select * into v_ans from public.quiz_answers where user_id = auth.uid() and answered_on = public.quiz_day();
  return jsonb_build_object(
    'id', v_q.id, 'question', v_q.question, 'category', v_q.category,
    'option_a', v_q.option_a, 'option_b', v_q.option_b, 'option_c', v_q.option_c, 'option_d', v_q.option_d,
    'already_answered', v_ans.id is not null,
    -- après avoir répondu, on peut revoir la correction
    'correct', case when v_ans.id is not null then v_q.correct end,
    'explanation', case when v_ans.id is not null then v_q.explanation end
  );
end;
$$;

-- Enregistre la réponse du jour (une seule par jour) et renvoie la correction
create or replace function public.quiz_answer(p_question int, p_answer text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today jsonb := public.quiz_today();
  v_q     public.quiz_questions;
  v_ok    boolean;
begin
  if v_today is null then raise exception 'Pas de question aujourd''hui.'; end if;
  if (v_today->>'id')::int <> p_question then raise exception 'Ce n''est plus la question du jour : rechargez la page.'; end if;
  if (v_today->>'already_answered')::boolean then raise exception 'Vous avez déjà répondu aujourd''hui.'; end if;
  select * into v_q from public.quiz_questions where id = p_question;
  v_ok := v_q.correct = lower(btrim(p_answer));
  insert into public.quiz_answers (user_id, question_id, answered_on, is_correct)
  values (auth.uid(), p_question, public.quiz_day(), v_ok)
  on conflict (user_id, answered_on) do nothing;
  return jsonb_build_object('correct', v_ok, 'answer', v_q.correct, 'explanation', v_q.explanation);
end;
$$;

-- Classement : membres validés, non anonymisés
create or replace function public.quiz_leaderboard()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  return coalesce((
    select jsonb_agg(x order by x.correct desc, x.total desc, x.full_name)
    from (
      select p.id as user_id, p.full_name, p.avatar_url,
             count(*)::int as total, count(*) filter (where a.is_correct)::int as correct
      from public.quiz_answers a
      join public.profiles p on p.id = a.user_id
      where p.role <> 'pending' and p.anonymized_at is null
      group by p.id, p.full_name, p.avatar_url
      order by 5 desc, 4 desc
      limit 50
    ) x), '[]'::jsonb);
end;
$$;

-- Mes 30 dernières réponses
create or replace function public.quiz_my_history()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'question_id', a.question_id, 'answered_on', a.answered_on, 'is_correct', a.is_correct,
           'question', q.question, 'category', q.category) order by a.answered_on desc), '[]'::jsonb)
  from (select * from public.quiz_answers where user_id = auth.uid() order by answered_on desc limit 30) a
  join public.quiz_questions q on q.id = a.question_id;
$$;

revoke execute on function public.quiz_today(), public.quiz_answer(int, text), public.quiz_leaderboard(),
  public.quiz_my_history(), public.quiz_day() from public, anon;
grant execute on function public.quiz_today(), public.quiz_answer(int, text), public.quiz_leaderboard(),
  public.quiz_my_history(), public.quiz_day() to authenticated;

-- 3. Stats bar + shop (administrateurs et trésorier) -------------------------
create or replace function public.revenue_stats(p_months int default 12)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_from date := (date_trunc('month', now() at time zone 'Europe/Paris') - make_interval(months => greatest(p_months, 1) - 1))::date;
begin
  if not (public.app_role() = 'admin' or public.is_treasurer()) then
    raise exception 'Réservé aux administrateurs et au trésorier.';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('month', to_char(m, 'YYYY-MM'), 'bar', bar, 'shop', shop) order by m)
    from (
      select m::date,
             (select coalesce(sum(c.unit_price_cents * c.quantity), 0) from public.bar_consumptions c
               where c.product_id is not null   -- les lignes « Shop – … » débitées sur l'ardoise sont comptées côté shop
                 and date_trunc('month', c.created_at at time zone 'Europe/Paris') = m)::bigint as bar,
             (select coalesce(sum(o.price_cents * o.quantity), 0) from public.shop_orders o
               where o.status = 'delivered'
                 and date_trunc('month', o.created_at at time zone 'Europe/Paris') = m)::bigint as shop
      from generate_series(v_from, (now() at time zone 'Europe/Paris')::date, interval '1 month') as m
    ) t), '[]'::jsonb);
end;
$$;
revoke execute on function public.revenue_stats(int) from public, anon;
grant execute on function public.revenue_stats(int) to authenticated;

-- 4. Stockage des images du shop ---------------------------------------------
do $$ begin
  if to_regclass('storage.buckets') is not null then
    update storage.buckets
       set file_size_limit = 5242880,
           allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
     where id = 'documents';
  end if;
end $$;
drop policy if exists "Authenticated users can upload shop images" on storage.objects;
drop policy if exists shop_images_insert on storage.objects;
create policy shop_images_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'documents' and name like 'shop/%' and public.app_role() = 'admin');
drop policy if exists shop_images_delete on storage.objects;
create policy shop_images_delete on storage.objects for delete to authenticated
  using (bucket_id = 'documents' and name like 'shop/%' and public.app_role() = 'admin');

-- 5. Durcissements signalés par Supabase ---------------------------------------
do $$ begin
  if exists (select 1 from pg_proc where proname = 'bar_month_of' and pronamespace = 'public'::regnamespace) then
    execute 'alter function public.bar_month_of(timestamptz) set search_path = ''''';
  end if;
  if exists (select 1 from pg_proc where proname = '_audit_immutable' and pronamespace = 'public'::regnamespace) then
    execute 'alter function public._audit_immutable() set search_path = ''''';
  end if;
end $$;

notify pgrst, 'reload schema';

-- Vérification
select
  exists (select 1 from pg_proc where proname = 'set_shop_order_status')
  and exists (select 1 from pg_proc where proname = 'quiz_today')
  and exists (select 1 from pg_proc where proname = 'revenue_stats')
  and not exists (select 1 from pg_policies where tablename = 'quiz_answers' and policyname = 'quiz_answers_all_read')
  as "MISE A JOUR 28 OK";
