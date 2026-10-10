-- =====================================================================
--  Mise à jour n°5 : annuaire des membres (nom, téléphone, lâchers)
--  Visible par tous les membres validés. L'adresse et la personne à
--  prévenir restent réservées aux instructeurs et administrateurs.
-- =====================================================================
create or replace function public.member_directory()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id, 'full_name', p.full_name, 'phone', p.phone, 'avatar_url', p.avatar_url,
             'role', p.role,
             'types', coalesce((select jsonb_agg(pt.aircraft_type order by pt.aircraft_type)
                                from public.pilot_types pt where pt.user_id = p.id), '[]'::jsonb))
           order by lower(p.full_name))
    from public.profiles p
    where p.role <> 'pending'), '[]'::jsonb);
end;
$$;

revoke execute on function public.member_directory() from public, anon;
grant execute on function public.member_directory() to authenticated;

-- Rafraîchit l'API
notify pgrst, 'reload schema';
