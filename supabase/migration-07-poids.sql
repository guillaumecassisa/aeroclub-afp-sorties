-- =====================================================================
--  Mise à jour n°7 : poids des pilotes (facultatif)
--  Stocké à part : chaque membre ne voit que le sien ; seul l'organisateur
--  (instructeur référent) d'une sortie voit le poids de ses participants.
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

create table if not exists public.pilot_weights (
  user_id    uuid primary key references public.profiles (id) on delete cascade,
  weight_kg  numeric(5,1) check (weight_kg between 20 and 250),
  updated_at timestamptz not null default now()
);

alter table public.pilot_weights enable row level security;

drop policy if exists pilot_weights_own on public.pilot_weights;
create policy pilot_weights_own on public.pilot_weights for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

revoke all on public.pilot_weights from anon;
grant select, insert, update, delete on public.pilot_weights to authenticated;

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
  if v_outing.approval <> 'approved' and v_outing.instructor_id <> v_uid and not v_staff then
    return null;
  end if;

  select jsonb_build_object(
    'id', o.id, 'title', o.title, 'destination', o.destination, 'description', o.description,
    'meeting_point', o.meeting_point, 'departure_at', o.departure_at, 'return_at', o.return_at,
    'registration_deadline', o.registration_deadline, 'status', o.status,
    'instructor_aircraft_id', o.instructor_aircraft_id,
    'instructor', jsonb_build_object('id', ip.id, 'full_name', ip.full_name,
                                     'phone', ip.phone, 'avatar_url', ip.avatar_url),
    'can_manage', v_staff,
    'is_organizer', o.instructor_id = v_uid,
    'organizer_weight_kg', case when o.instructor_id = v_uid then
                             (select pw.weight_kg from public.pilot_weights pw where pw.user_id = o.instructor_id) end,
    'approval', o.approval, 'rejection_reason', o.rejection_reason,
    'can_edit', v_staff or (o.instructor_id = v_uid and o.approval <> 'approved'),
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
                          'phone', case when v_staff or p.id = v_uid then p.phone end,
                          'weight_kg', case when o.instructor_id = v_uid then
                                         (select pw.weight_kg from public.pilot_weights pw where pw.user_id = p.id) end)
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
               'weight_kg', case when o.instructor_id = v_uid then
                              (select pw.weight_kg from public.pilot_weights pw where pw.user_id = w.user_id) end,
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

notify pgrst, 'reload schema';
