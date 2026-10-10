-- =====================================================================
--  Mise à jour n°18 : documents des avions ajoutés / modifiés par toute
--  personne ayant une fonction (admin, instructeur, CA, trésorier,
--  secrétaire, resp. maintenance). Les simples membres les consultent.
-- =====================================================================
create or replace function public.can_manage_docs()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((
    select p.role <> 'pending'
       and (p.role in ('admin', 'instructor') or p.is_instructor or p.is_board or p.is_maintenance
            or p.is_treasurer or p.is_secretary)
    from public.profiles p where p.id = auth.uid()), false);
$$;
revoke execute on function public.can_manage_docs() from public, anon;
grant execute on function public.can_manage_docs() to authenticated;

notify pgrst, 'reload schema';
