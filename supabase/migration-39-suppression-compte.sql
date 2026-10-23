-- =====================================================================
--  Mise à jour n°39 : suppression de l'identifiant de connexion d'un membre
--  Avant : supprimer un utilisateur dans Supabase (Authentication → Users) échouait
--  (« Database error deleting user ») ou, pire, aurait effacé avec lui son historique
--  (bar, commandes, inscriptions) que la comptabilité doit conserver.
--  Désormais :
--   - la fiche du membre n'est plus liée à son identifiant de connexion : supprimer
--     l'identifiant garde la fiche « Ancien membre » et son historique comptable ;
--   - si l'identifiant est supprimé sans anonymisation préalable, la fiche est
--     anonymisée automatiquement (aucune donnée personnelle ne reste).
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Anonymisation interne (sans contrôle de droits) : utilisée par l'admin et à la suppression
create or replace function public._anonymize_profile(p_user uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare r record;
begin
  -- Désinscription des événements à venir (les places libérées sont réattribuées)
  for r in
    select distinct g.outing_id from public.registrations g join public.outings o on o.id = g.outing_id
    where g.user_id = p_user and g.status <> 'cancelled' and (o.departure_at is null or o.departure_at > now())
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
    anonymized_at = coalesce(anonymized_at, now())
  where id = p_user;
end;
$$;
revoke execute on function public._anonymize_profile(uuid) from public, anon, authenticated;

create or replace function public.anonymize_member(p_user uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
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
  perform public._anonymize_profile(p_user);
end;
$$;
revoke execute on function public.anonymize_member(uuid) from public, anon;
grant execute on function public.anonymize_member(uuid) to authenticated;

-- 2. La fiche survit à la suppression de l'identifiant de connexion
alter table public.profiles drop constraint if exists profiles_id_fkey;

-- 3. Suppression d'un identifiant : la fiche est anonymisée si elle ne l'était pas déjà
create or replace function public._on_auth_user_deleted()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.profiles where id = old.id and anonymized_at is null) then
    perform public._anonymize_profile(old.id);
  end if;
  return old;
end;
$$;
revoke execute on function public._on_auth_user_deleted() from public, anon, authenticated;

drop trigger if exists on_auth_user_deleted on auth.users;
create trigger on_auth_user_deleted
  before delete on auth.users
  for each row execute function public._on_auth_user_deleted();

-- Vérification
select 'MISE A JOUR 39 OK' as resultat,
       not exists (select 1 from pg_constraint where conname = 'profiles_id_fkey') as fiche_independante,
       exists (select 1 from pg_trigger where tgname = 'on_auth_user_deleted') as anonymisation_auto;
