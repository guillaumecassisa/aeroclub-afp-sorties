-- =====================================================================
--  Mise à jour n°32 : sécurisation et sauvegarde
--  - Aligne les fichiers du dépôt sur la base en service (catégorie
--    « Taxes » des bons plans, détails des tables du quiz et du shop,
--    version de review_outing) : une nouvelle installation est identique.
--  - Anonymisation RGPD plus complète (accompagnants, REX signés, messages,
--    notes de commande, nouvelles fonctions).
--  - Export complet des données du club pour les administrateurs
--    (page « Sauvegarde »).
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Alignement ---------------------------------------------------------------
alter table public.airfield_tips drop constraint if exists airfield_tips_category_check;
alter table public.airfield_tips add constraint airfield_tips_category_check
  check (category in ('resto', 'avitaillement', 'hebergement', 'visite', 'taxes', 'autre'));

update public.quiz_questions set category = 'general' where category is null;
alter table public.quiz_questions alter column category set default 'general';
alter table public.quiz_questions alter column category set not null;
alter table public.quiz_questions alter column active set default true;
alter table public.quiz_questions alter column active set not null;
alter table public.quiz_answers alter column id type bigint;
alter table public.quiz_answers alter column answered_on set default current_date;
create index if not exists quiz_answers_user_date on public.quiz_answers (user_id, answered_on);
create index if not exists quiz_answers_date on public.quiz_answers (answered_on);

update public.shop_orders o set item_name = coalesce(o.item_name, i.name, 'Article'),
                                price_cents = coalesce(o.price_cents, i.price_cents, 0)
  from public.shop_items i where i.id = o.item_id and (o.item_name is null or o.price_cents is null);
alter table public.shop_orders alter column item_name set not null;
alter table public.shop_orders alter column price_cents set not null;

-- Flotte : de 1 à 9 places (et plus seulement 2 ou 4), pour tout type d'avion
alter table public.aircraft drop constraint if exists aircraft_seats_check;
alter table public.aircraft add constraint aircraft_seats_check check (seats between 1 and 9);

drop function if exists public.review_outing(uuid, boolean, text);
CREATE OR REPLACE FUNCTION public.review_outing(p_id uuid, p_approve boolean, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_outing public.outings;
begin
  if not public.is_staff() then raise exception 'Action réservée aux instructeurs.'; end if;
  select * into v_outing from public.outings where id = p_id for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  if v_outing.approval = 'approved' then raise exception 'Cette sortie est déjà publiée.'; end if;

  update public.outings set
    approval = case when p_approve then 'approved' else 'rejected' end,
    rejection_reason = case when p_approve then null else nullif(btrim(p_reason), '') end,
    approved_by = case when p_approve then auth.uid() end,
    approved_at = case when p_approve then now() end,
    updated_at = now()
  where id = p_id;

  return (select jsonb_build_object(
                   'email', p.email,
                   'full_name', p.full_name,
                   'title', v_outing.title,
                   'departure_at', v_outing.departure_at)
          from public.profiles p where p.id = v_outing.instructor_id);
end;
$function$;

revoke execute on function public.review_outing(uuid, boolean, text) from public, anon;
grant execute on function public.review_outing(uuid, boolean, text) to authenticated;

-- 2. Anonymisation RGPD complète ------------------------------------------------
CREATE OR REPLACE FUNCTION public.anonymize_member(p_user uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r record;
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  if p_user = auth.uid() then
    raise exception 'Vous ne pouvez pas anonymiser votre propre compte.';
  end if;
  if not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'Membre introuvable.';
  end if;

  -- Désinscription des événements à venir (les places libérées sont réattribuées)
  for r in
    select distinct g.outing_id from public.registrations g join public.outings o on o.id = g.outing_id
    where g.user_id = p_user and g.status <> 'cancelled' and o.departure_at > now()
  loop
    update public.registrations set status = 'cancelled'
     where outing_id = r.outing_id and user_id = p_user and status <> 'cancelled';
    perform public._rebalance_outing(r.outing_id);
  end loop;

  delete from public.pilot_weights where user_id = p_user;
  -- accompagnants annoncés, REX signés, messages : plus rien ne le relie à une personne
  update public.registrations set guest_name = 'Accompagnant', guest_weight_kg = null
   where user_id = p_user and guest_of is not null;
  update public.rex_reports set author_id = null where author_id = p_user;
  update public.flight_share_seats set message = null where member_id = p_user;
  update public.shop_orders set note = null where user_id = p_user;
  delete from public.pilot_types where user_id = p_user;

  update public.profiles set
    full_name = 'Ancien membre',
    email = 'anonyme-' || left(p_user::text, 8) || '@invalid.local',
    phone = null, address = null, emergency_name = null, emergency_phone = null,
    avatar_url = null,
    role = 'pending',
    is_instructor = false, is_board = false, is_treasurer = false, is_secretary = false, is_maintenance = false,
    is_chief_pilot = false, is_compliance = false,
    notify_events = false, show_phone = false,
    anonymized_at = now()
  where id = p_user;
end;
$function$;

revoke execute on function public.anonymize_member(uuid) from public, anon;
grant execute on function public.anonymize_member(uuid) to authenticated;

-- 3. Export complet (sauvegarde) pour les administrateurs ------------------------
create or replace function public.admin_export()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_out jsonb := '{}'::jsonb;
  v_t   text;
  v_rows jsonb;
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Réservé aux administrateurs.';
  end if;
  for v_t in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' order by c.relname
  loop
    execute format('select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from public.%I t', v_t) into v_rows;
    v_out := v_out || jsonb_build_object(v_t, v_rows);
  end loop;
  return jsonb_build_object(
    'format', 'sauvegarde-aeroclub-v1',
    'exported_at', now(),
    'tables', v_out,
    'files', (select coalesce(jsonb_agg(jsonb_build_object('bucket', o.bucket_id, 'path', o.name) order by o.bucket_id, o.name), '[]'::jsonb)
                from storage.objects o)
  );
end;
$$;
revoke execute on function public.admin_export() from public, anon;
grant execute on function public.admin_export() to authenticated;

notify pgrst, 'reload schema';

select exists (select 1 from pg_proc where proname = 'admin_export') as "MISE A JOUR 32 OK";
