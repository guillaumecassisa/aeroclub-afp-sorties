-- =====================================================================
--  Mise à jour n°3 : les lâchers se font par TYPE d'avion (DR400, PS28…)
--  et non plus par immatriculation.
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Chaque avion de la flotte reçoit un type (déduit du modèle, modifiable
--    ensuite dans la page Flotte) : "DR400-180" -> "DR400", "PS28 Cruiser" -> "PS28"
alter table public.aircraft add column if not exists type text;
update public.aircraft
   set type = upper(substring(btrim(model) from '^[^[:space:]-]+'))
 where type is null or btrim(type) = '';
alter table public.aircraft alter column type set not null;
grant update (type) on public.aircraft to authenticated;

-- 2. Lâchers par type
create table if not exists public.pilot_types (
  user_id        uuid not null references public.profiles (id) on delete cascade,
  aircraft_type  text not null check (length(btrim(aircraft_type)) > 0),
  created_at     timestamptz not null default now(),
  primary key (user_id, aircraft_type)
);

alter table public.pilot_types enable row level security;

drop policy if exists pilot_types_select on public.pilot_types;
create policy pilot_types_select on public.pilot_types for select to authenticated
  using (public.is_approved());

drop policy if exists pilot_types_insert on public.pilot_types;
create policy pilot_types_insert on public.pilot_types for insert to authenticated
  with check (public.is_approved() and (user_id = auth.uid() or public.is_staff()));

drop policy if exists pilot_types_delete on public.pilot_types;
create policy pilot_types_delete on public.pilot_types for delete to authenticated
  using (user_id = auth.uid() or public.is_staff());

revoke all on public.pilot_types from anon;
revoke update on public.pilot_types from authenticated;
grant select, insert, delete on public.pilot_types to authenticated;

-- 3. Reprise des lâchers déjà saisis par immatriculation, puis suppression
do $$
begin
  if to_regclass('public.pilot_aircraft') is not null then
    insert into public.pilot_types (user_id, aircraft_type)
    select distinct pa.user_id, a.type
    from public.pilot_aircraft pa join public.aircraft a on a.id = pa.aircraft_id
    on conflict do nothing;
    drop table public.pilot_aircraft;
  end if;
end $$;

-- 4. Détail d'une sortie : « lâché » = lâché sur le type de l'avion
create or replace function public.get_outing(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_staff  boolean := public.is_staff();
  v_outing public.outings;
  v_result jsonb;
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  select * into v_outing from public.outings where id = p_id;
  if not found then return null; end if;

  select jsonb_build_object(
    'id', o.id, 'title', o.title, 'destination', o.destination, 'description', o.description,
    'meeting_point', o.meeting_point, 'departure_at', o.departure_at, 'return_at', o.return_at,
    'registration_deadline', o.registration_deadline, 'status', o.status,
    'instructor_aircraft_id', o.instructor_aircraft_id,
    'instructor', jsonb_build_object('id', ip.id, 'full_name', ip.full_name,
                                     'phone', ip.phone, 'avatar_url', ip.avatar_url),
    'can_manage', v_staff,
    'aircraft', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', a.id, 'registration', a.registration, 'model', a.model, 'type', a.type, 'seats', a.seats,
               'instructor_onboard', a.id = o.instructor_aircraft_id,
               'capacity', greatest(a.seats - case when a.id = o.instructor_aircraft_id then 1 else 0 end, 0),
               'occupants', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'registration_id', r.id, 'user_id', p.id, 'full_name', p.full_name,
                          'avatar_url', p.avatar_url,
                          'released', exists (select 1 from public.pilot_types pt
                                              where pt.user_id = p.id and pt.aircraft_type = a.type),
                          'phone', case when v_staff or p.id = v_uid then p.phone end)
                        order by r.created_at, r.id)
                 from public.registrations r join public.profiles p on p.id = r.user_id
                 where r.outing_id = o.id and r.status = 'confirmed' and r.aircraft_id = a.id), '[]'::jsonb)
             ) order by oa.position, a.registration)
      from public.outing_aircraft oa join public.aircraft a on a.id = oa.aircraft_id
      where oa.outing_id = o.id), '[]'::jsonb),
    'waitlist', coalesce((
      select jsonb_agg(jsonb_build_object(
               'registration_id', w.id, 'user_id', w.user_id, 'full_name', w.full_name,
               'avatar_url', w.avatar_url, 'released', false,
               'phone', case when v_staff or w.user_id = v_uid then w.phone end,
               'position', w.pos) order by w.pos)
      from (select r.id, r.user_id, p.full_name, p.phone, p.avatar_url,
                   row_number() over (order by r.created_at, r.id) as pos
            from public.registrations r join public.profiles p on p.id = r.user_id
            where r.outing_id = o.id and r.status = 'waitlist') w), '[]'::jsonb),
    'my_registration', (
      select jsonb_build_object('id', r.id, 'status', r.status, 'aircraft_id', r.aircraft_id)
      from public.registrations r
      where r.outing_id = o.id and r.user_id = v_uid and r.status <> 'cancelled')
  ) into v_result
  from public.outings o join public.profiles ip on ip.id = o.instructor_id
  where o.id = p_id;

  return v_result;
end;
$$;

revoke execute on function public.get_outing(uuid) from public, anon;
grant execute on function public.get_outing(uuid) to authenticated;

-- Rafraîchit l'API
notify pgrst, 'reload schema';
