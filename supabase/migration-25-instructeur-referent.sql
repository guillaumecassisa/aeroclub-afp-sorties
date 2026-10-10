-- =====================================================================
--  Mise à jour n°25 : instructeur référent pour les sorties proposées
--                     par un membre non-instructeur.
--  - Ajoute la colonne `referent_instructor_id` sur `outings`.
--  - Modifie `review_outing()` pour accepter un instructeur référent
--    optionnel lors de la validation.
--  - Met à jour `get_outing()` pour exposer l'info dans la réponse JSON.
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Colonne optionnelle sur outings
alter table public.outings
  add column if not exists referent_instructor_id uuid references public.profiles(id);

-- 2. Modifier review_outing pour accepter p_referent
create or replace function public.review_outing(
  p_id       uuid,
  p_approve  boolean,
  p_reason   text   default null,
  p_referent uuid   default null   -- nouvel instructeur référent (optionnel)
)
returns table(email text, full_name text, title text, departure_at text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_row  public.outings;
  v_prof public.profiles;
begin
  if v_uid is null then raise exception 'Vous devez être connecté.'; end if;
  if not public.is_staff() then raise exception 'Réservé aux instructeurs et administrateurs.'; end if;

  select * into v_row from public.outings where id = p_id for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  if v_row.approval = 'approved' then raise exception 'Cette sortie est déjà publiée.'; end if;

  -- Valider que p_referent est bien un instructeur (si fourni)
  if p_referent is not null then
    if not exists (
      select 1 from public.profiles
       where id = p_referent and role in ('instructor', 'ca', 'admin')
    ) then
      raise exception 'L''instructeur référent choisi n''a pas le bon rôle.';
    end if;
  end if;

  if p_approve then
    update public.outings
       set approval = 'approved',
           rejection_reason = null,
           referent_instructor_id = coalesce(p_referent, referent_instructor_id)
     where id = p_id;
  else
    update public.outings
       set approval = 'rejected',
           rejection_reason = p_reason
     where id = p_id;
  end if;

  -- Notifier l'auteur
  select * into v_prof from public.profiles where id = v_row.instructor_id;
  return query
    select v_prof.email, v_prof.full_name,
           v_row.title,
           to_char(v_row.departure_at at time zone 'Europe/Paris', 'DD/MM/YYYY à HH24h') as departure_at;
end;
$$;
revoke execute on function public.review_outing(uuid, boolean, text, uuid) from public, anon;
grant execute on function public.review_outing(uuid, boolean, text, uuid) to authenticated;

-- 3. Mettre à jour get_outing pour exposer le référent
create or replace function public.get_outing(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_staff boolean := public.is_staff();
  v_row   public.outings;
  v_org   public.profiles;
  v_ref   public.profiles;
  v_kind  text;
  v_ac    jsonb;
  v_wait  jsonb;
  v_part  jsonb;
  v_mine  jsonb;
  v_org_w numeric;
begin
  select * into v_row from public.outings where id = p_id;
  if not found then return null; end if;

  v_kind := coalesce(v_row.kind, 'vol');

  -- Vérifications de visibilité
  if v_row.approval <> 'approved' and v_row.status <> 'cancelled' then
    if not (v_staff or v_row.instructor_id = v_uid) then return null; end if;
  end if;
  if v_row.status = 'cancelled' then
    if not (v_staff or v_row.instructor_id = v_uid
            or exists (select 1 from public.registrations where outing_id = p_id and user_id = v_uid)) then
      return null;
    end if;
  end if;

  select * into v_org from public.profiles where id = v_row.instructor_id;

  -- Référent (si défini)
  if v_row.referent_instructor_id is not null then
    select * into v_ref from public.profiles where id = v_row.referent_instructor_id;
  end if;

  -- Poids de l'organisateur (visible par lui-même seulement)
  if v_row.instructor_id = v_uid then
    select weight_kg into v_org_w from public.pilot_weights where user_id = v_uid order by weighed_at desc limit 1;
  end if;

  -- Avions
  if v_kind = 'vol' then
    select coalesce(jsonb_agg(ac_data order by ac_reg), '[]') into v_ac
    from (
      select
        a.registration as ac_reg,
        jsonb_build_object(
          'id', a.id,
          'registration', a.registration,
          'model', a.model,
          'type', a.type,
          'seats', a.seats,
          'instructor_onboard', v_row.instructor_aircraft_id = a.id,
          'capacity', greatest(a.seats - case when v_row.instructor_aircraft_id = a.id then 1 else 0 end, 0),
          'occupants', coalesce((
            select jsonb_agg(jsonb_build_object(
              'registration_id', r.id,
              'user_id', r.user_id,
              'full_name', p.full_name,
              'avatar_url', p.avatar_url,
              'released', exists (
                select 1 from public.pilot_types pt
                 where pt.user_id = r.user_id and pt.aircraft_type = a.type
              ),
              'phone', case when v_staff or v_row.instructor_id = v_uid then p.phone end,
              'weight_kg', case when v_row.instructor_id = v_uid then pw.weight_kg end
            ) order by r.created_at)
            from public.registrations r
            join public.profiles p on p.id = r.user_id
            left join public.pilot_weights pw on pw.user_id = r.user_id
              and pw.weighed_at = (select max(weighed_at) from public.pilot_weights where user_id = r.user_id)
            where r.outing_id = p_id and r.status = 'confirmed' and r.aircraft_id = a.id
          ), '[]')
        ) as ac_data
      from public.outing_aircraft oa
      join public.aircraft a on a.id = oa.aircraft_id
      where oa.outing_id = p_id
    ) sub;
  else
    v_ac := '[]';
  end if;

  -- Liste d'attente
  select coalesce(jsonb_agg(jsonb_build_object(
    'registration_id', r.id,
    'user_id', r.user_id,
    'full_name', p.full_name,
    'avatar_url', p.avatar_url,
    'released', false,
    'phone', case when v_staff or v_row.instructor_id = v_uid then p.phone end,
    'weight_kg', case when v_row.instructor_id = v_uid then pw.weight_kg end,
    'position', row_number() over (order by r.created_at)
  ) order by r.created_at), '[]') into v_wait
  from public.registrations r
  join public.profiles p on p.id = r.user_id
  left join public.pilot_weights pw on pw.user_id = r.user_id
    and pw.weighed_at = (select max(weighed_at) from public.pilot_weights where user_id = r.user_id)
  where r.outing_id = p_id and r.status = 'waitlist';

  -- Participants (activités non-vol)
  if v_kind <> 'vol' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'registration_id', r.id,
      'user_id', r.user_id,
      'full_name', p.full_name,
      'avatar_url', p.avatar_url,
      'released', false,
      'phone', case when v_staff or v_row.instructor_id = v_uid then p.phone end
    ) order by r.created_at), '[]') into v_part
    from public.registrations r
    join public.profiles p on p.id = r.user_id
    where r.outing_id = p_id and r.status = 'confirmed';
  else
    v_part := '[]';
  end if;

  -- Mon inscription
  select jsonb_build_object('id', r.id, 'status', r.status, 'aircraft_id', r.aircraft_id) into v_mine
  from public.registrations r
  where r.outing_id = p_id and r.user_id = v_uid
  limit 1;

  return jsonb_build_object(
    'id',                    v_row.id,
    'title',                 v_row.title,
    'destination',           v_row.destination,
    'description',           v_row.description,
    'meeting_point',         v_row.meeting_point,
    'departure_at',          v_row.departure_at,
    'return_at',             v_row.return_at,
    'registration_deadline', v_row.registration_deadline,
    'max_participants',      v_row.max_participants,
    'kind',                  v_kind,
    'status',                v_row.status,
    'instructor_aircraft_id',v_row.instructor_aircraft_id,
    'instructor', jsonb_build_object(
      'id',          v_org.id,
      'full_name',   v_org.full_name,
      'phone',       case when v_staff or v_row.instructor_id = v_uid then v_org.phone end,
      'avatar_url',  v_org.avatar_url
    ),
    'referent_instructor', case
      when v_row.referent_instructor_id is not null then jsonb_build_object(
        'id',         v_ref.id,
        'full_name',  v_ref.full_name,
        'phone',      case when v_staff or v_row.instructor_id = v_uid then v_ref.phone end,
        'avatar_url', v_ref.avatar_url
      )
      else null
    end,
    'can_manage',            v_staff,
    'is_organizer',          v_row.instructor_id = v_uid,
    'organizer_weight_kg',   v_org_w,
    'approval',              v_row.approval,
    'rejection_reason',      v_row.rejection_reason,
    'can_edit',              v_staff or (v_row.instructor_id = v_uid and v_row.approval <> 'approved'),
    'aircraft',              v_ac,
    'waitlist',              v_wait,
    'participants',          v_part,
    'my_registration',       v_mine
  );
end;
$$;
revoke execute on function public.get_outing(uuid) from public, anon;
grant execute on function public.get_outing(uuid) to authenticated;

notify pgrst, 'reload schema';
