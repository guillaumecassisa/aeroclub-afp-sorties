-- =====================================================================
--  Mise à jour n°9 : responsable maintenance.
--  La flotte (ajout d'avion, disponibilité, types) est réservée aux
--  administrateurs et aux responsables maintenance.
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

alter table public.profiles add column if not exists is_maintenance boolean not null default false;
alter table public.aircraft add column if not exists available boolean not null default true;
alter table public.aircraft add column if not exists unavailable_reason text;

create or replace function public.can_manage_fleet()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select role = 'admin' or (is_maintenance and role <> 'pending')
                   from public.profiles where id = auth.uid()), false)
$$;

create or replace function public.set_maintenance(p_user uuid, p_value boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  update public.profiles set is_maintenance = p_value where id = p_user;
end;
$$;

drop policy if exists aircraft_insert on public.aircraft;
create policy aircraft_insert on public.aircraft for insert to authenticated
  with check (public.can_manage_fleet());
drop policy if exists aircraft_update on public.aircraft;
create policy aircraft_update on public.aircraft for update to authenticated
  using (public.can_manage_fleet()) with check (public.can_manage_fleet());
drop policy if exists aircraft_delete on public.aircraft;
create policy aircraft_delete on public.aircraft for delete to authenticated
  using (public.can_manage_fleet());

-- Disponibilité d'un avion (renvoie une erreur claire si refusé)
create or replace function public.set_aircraft_availability(p_id uuid, p_available boolean, p_reason text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.can_manage_fleet() then
    raise exception 'Réservé aux administrateurs et aux responsables maintenance.';
  end if;
  update public.aircraft
     set available = p_available,
         unavailable_reason = case when p_available then null else nullif(btrim(coalesce(p_reason, '')), '') end
   where id = p_id;
  if not found then raise exception 'Avion introuvable.'; end if;
end;
$$;

revoke execute on function public.set_maintenance(uuid, boolean) from public, anon;
grant execute on function public.set_maintenance(uuid, boolean) to authenticated;
revoke execute on function public.set_aircraft_availability(uuid, boolean, text) from public, anon;
grant execute on function public.set_aircraft_availability(uuid, boolean, text) to authenticated;
grant execute on function public.can_manage_fleet() to authenticated;

notify pgrst, 'reload schema';
