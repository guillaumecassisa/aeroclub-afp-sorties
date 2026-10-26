-- =====================================================================
--  Mise à jour n°43 : nouvelle gestion du bar (tableau de bord, relances)
--  Le trésorier obtient le nom et l'adresse email des membres qui ont une
--  ardoise (y compris les anciens membres), pour les relances et l'export.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

create or replace function public.bar_members()
returns table (id uuid, full_name text, email text, avatar_url text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_treasurer() then
    raise exception 'Réservé au trésorier.';
  end if;
  return query
    select p.id, p.full_name, case when p.anonymized_at is null then p.email end, p.avatar_url
      from public.profiles p
     where exists (select 1 from public.bar_consumptions c where c.user_id = p.id);
end;
$$;
revoke execute on function public.bar_members() from public, anon;
grant execute on function public.bar_members() to authenticated;

-- Vérification
select 'MISE A JOUR 43 OK' as resultat;
