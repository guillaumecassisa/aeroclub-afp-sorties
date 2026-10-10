-- =====================================================================
--  Mise à jour n°2 : photo de profil, coordonnées, avions « lâchés »
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Nouvelles informations de profil ----------------------------------
alter table public.profiles
  add column if not exists avatar_url      text,
  add column if not exists address         text,
  add column if not exists emergency_name  text,
  add column if not exists emergency_phone text;

grant update (full_name, phone, avatar_url, address, emergency_name, emergency_phone)
  on public.profiles to authenticated;

-- 2. Avions sur lesquels chaque pilote est lâché ------------------------
create table if not exists public.pilot_aircraft (
  user_id      uuid not null references public.profiles (id) on delete cascade,
  aircraft_id  uuid not null references public.aircraft (id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (user_id, aircraft_id)
);

alter table public.pilot_aircraft enable row level security;

drop policy if exists pilot_aircraft_select on public.pilot_aircraft;
create policy pilot_aircraft_select on public.pilot_aircraft for select to authenticated
  using (public.is_approved());

drop policy if exists pilot_aircraft_insert on public.pilot_aircraft;
create policy pilot_aircraft_insert on public.pilot_aircraft for insert to authenticated
  with check (public.is_approved() and (user_id = auth.uid() or public.is_staff()));

drop policy if exists pilot_aircraft_delete on public.pilot_aircraft;
create policy pilot_aircraft_delete on public.pilot_aircraft for delete to authenticated
  using (user_id = auth.uid() or public.is_staff());

revoke all on public.pilot_aircraft from anon;
revoke update on public.pilot_aircraft from authenticated;
grant select, insert, delete on public.pilot_aircraft to authenticated;

-- 3. Stockage des photos (dossier « avatars », une photo par membre) ---
-- Protégé : si Supabase refuse une étape (droits), le reste de la mise à jour continue.
do $$
begin
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('avatars', 'avatars', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
  on conflict (id) do update set public = true;
exception when others then raise notice 'bucket avatars : %', sqlerrm;
end $$;

do $$
begin
  execute 'drop policy if exists avatars_select on storage.objects';
  execute 'create policy avatars_select on storage.objects for select to authenticated using (bucket_id = ''avatars'')';
  execute 'drop policy if exists avatars_insert on storage.objects';
  execute 'create policy avatars_insert on storage.objects for insert to authenticated with check (bucket_id = ''avatars'' and (storage.foldername(name))[1] = auth.uid()::text)';
  execute 'drop policy if exists avatars_update on storage.objects';
  execute 'create policy avatars_update on storage.objects for update to authenticated using (bucket_id = ''avatars'' and (storage.foldername(name))[1] = auth.uid()::text)';
  execute 'drop policy if exists avatars_delete on storage.objects';
  execute 'create policy avatars_delete on storage.objects for delete to authenticated using (bucket_id = ''avatars'' and (storage.foldername(name))[1] = auth.uid()::text)';
exception when others then raise notice 'règles photos : %', sqlerrm;
end $$;

-- 4. Détail d'une sortie : photo des participants + indication « lâché » -
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
               'id', a.id, 'registration', a.registration, 'model', a.model, 'seats', a.seats,
               'instructor_onboard', a.id = o.instructor_aircraft_id,
               'capacity', greatest(a.seats - case when a.id = o.instructor_aircraft_id then 1 else 0 end, 0),
               'occupants', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'registration_id', r.id, 'user_id', p.id, 'full_name', p.full_name,
                          'avatar_url', p.avatar_url,
                          'released', exists (select 1 from public.pilot_aircraft pa
                                              where pa.user_id = p.id and pa.aircraft_id = a.id),
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
