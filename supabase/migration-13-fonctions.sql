-- =====================================================================
--  Mise à jour n°13 : tout le monde est « Membre » ; Instructeur et
--  Administrateur deviennent des fonctions, comme Trésorier, Secrétaire,
--  Membre du CA et Responsable maintenance.
--  (La colonne role reste le niveau de droits calculé automatiquement.)
-- =====================================================================
alter table public.profiles add column if not exists is_instructor boolean not null default false;
update public.profiles set is_instructor = true where role = 'instructor' and not is_instructor;

create or replace function public.set_function(p_user uuid, p_function text, p_value boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v public.profiles%rowtype;
  v_admin boolean;
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  select * into v from public.profiles where id = p_user for update;
  if not found then raise exception 'Membre introuvable.'; end if;
  if v.role = 'pending' then
    raise exception 'Validez d''abord ce compte avant de lui attribuer une fonction.';
  end if;

  v_admin := v.role = 'admin';
  case p_function
    when 'admin' then
      if not p_value and p_user = auth.uid() then
        raise exception 'Vous ne pouvez pas retirer vos propres droits administrateur.';
      end if;
      v_admin := p_value;
      if not p_value then v.is_secretary := false; end if;
    when 'secretaire' then
      if not p_value and p_user = auth.uid() then
        raise exception 'Demandez à un autre administrateur de vous retirer le titre de secrétaire.';
      end if;
      v.is_secretary := p_value;
      if p_value then v_admin := true; end if;
    when 'instructeur' then v.is_instructor := p_value;
    when 'ca'          then v.is_board := p_value;
    when 'tresorier'   then v.is_treasurer := p_value;
    when 'maintenance' then v.is_maintenance := p_value;
    else raise exception 'Fonction inconnue : %', p_function;
  end case;

  update public.profiles set
    is_instructor  = v.is_instructor,
    is_board       = v.is_board,
    is_treasurer   = v.is_treasurer,
    is_maintenance = v.is_maintenance,
    is_secretary   = v.is_secretary,
    role = case when v_admin then 'admin'::public.user_role
                when v.is_instructor then 'instructor'::public.user_role
                else 'member'::public.user_role end
  where id = p_user;
end;
$$;
revoke execute on function public.set_function(uuid, text, boolean) from public, anon;
grant execute on function public.set_function(uuid, text, boolean) to authenticated;

-- Annuaire : le badge « Instructeur » suit la fonction
create or replace function public.member_directory()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id, 'full_name', p.full_name, 'phone', p.phone, 'avatar_url', p.avatar_url,
             'role', p.role, 'is_instructor', p.is_instructor,
             'types', coalesce((select jsonb_agg(pt.aircraft_type order by pt.aircraft_type)
                                from public.pilot_types pt where pt.user_id = p.id), '[]'::jsonb))
           order by lower(p.full_name))
    from public.profiles p
    where p.role <> 'pending'), '[]'::jsonb);
end;
$$;
revoke execute on function public.member_directory() from public, anon;
grant execute on function public.member_directory() to authenticated;

notify pgrst, 'reload schema';
