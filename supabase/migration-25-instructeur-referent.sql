-- =====================================================================
--  Mise à jour n°25 : instructeur référent + alignement sur la base en service
--  - Ajoute la colonne `referent_instructor_id` sur `outings` (réservée pour
--    un usage futur : la validation d'une proposition ne la renseigne pas).
--  - Reprend les versions de get_outing() et move_crew() réellement en
--    service : poids lu sur pilot_weights.updated_at, et contrôle du lâcher
--    (une personne non lâchée sur le type ne peut monter dans un avion que
--    si un instructeur est à bord).
--  La version précédente de ce fichier ne pouvait pas s'exécuter (rôle « ca »
--  inexistant, colonne weighed_at inexistante) : elle est remplacée.
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

alter table public.outings
  add column if not exists referent_instructor_id uuid references public.profiles(id);

CREATE OR REPLACE FUNCTION public.get_outing(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_staff boolean := public.is_staff();
  v_row   public.outings;
  v_org   public.profiles;
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

  if v_row.instructor_id = v_uid then
    select weight_kg into v_org_w from public.pilot_weights where user_id = v_uid order by updated_at desc limit 1;
  end if;

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
              and pw.updated_at = (select max(updated_at) from public.pilot_weights where user_id = r.user_id)
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

  select coalesce(jsonb_agg(w order by w_created), '[]') into v_wait
  from (
    select jsonb_build_object(
      'registration_id', r.id,
      'user_id', r.user_id,
      'full_name', p.full_name,
      'avatar_url', p.avatar_url,
      'released', false,
      'phone', case when v_staff or v_row.instructor_id = v_uid then p.phone end,
      'weight_kg', case when v_row.instructor_id = v_uid then pw.weight_kg end,
      'position', row_number() over (order by r.created_at)
    ) as w,
    r.created_at as w_created
    from public.registrations r
    join public.profiles p on p.id = r.user_id
    left join public.pilot_weights pw on pw.user_id = r.user_id
      and pw.updated_at = (select max(updated_at) from public.pilot_weights where user_id = r.user_id)
    where r.outing_id = p_id and r.status = 'waitlist'
  ) sub;

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
$function$
;

CREATE OR REPLACE FUNCTION public.move_crew(p_outing uuid, p_who text, p_aircraft uuid, p_with text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid           uuid := auth.uid();
  v_outing        public.outings;
  v_from          uuid;
  v_reg           public.registrations;
  v_other         public.registrations;
  v_cap           int;
  v_used          int;
  v_person_uid    uuid;
  v_ac_type       text;
  v_nom           text;
  v_has_instructor boolean;
  v_is_instructor  boolean;
begin
  if v_uid is null then raise exception 'Vous devez être connecté.'; end if;
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;

  select * into v_outing from public.outings where id = p_outing for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  if not (public.can_organize() or v_outing.instructor_id = v_uid) then
    raise exception 'Seul un organisateur peut répartir les équipages.';
  end if;
  if v_outing.status = 'cancelled' then raise exception 'Cette sortie est annulée.'; end if;
  if coalesce(v_outing.kind, 'vol') <> 'vol' then raise exception 'Cet événement n''a pas d''avions.'; end if;
  if not exists (select 1 from public.outing_aircraft where outing_id = p_outing and aircraft_id = p_aircraft) then
    raise exception 'Cet avion ne fait pas partie de la sortie.';
  end if;

  if p_who = 'organizer' then
    if v_outing.instructor_aircraft_id is null then raise exception 'L''organisateur n''est pas à bord.'; end if;
    v_from := v_outing.instructor_aircraft_id;
  else
    select * into v_reg from public.registrations
     where id = p_who::uuid and outing_id = p_outing and status = 'confirmed' for update;
    if not found then raise exception 'Cette personne n''a pas de place confirmée dans cette sortie.'; end if;
    v_from := v_reg.aircraft_id;
  end if;
  if v_from = p_aircraft then return; end if;

  if p_who <> 'organizer' then
    v_person_uid := v_reg.user_id;
    select a.type into v_ac_type from public.aircraft a where a.id = p_aircraft;
    select coalesce(pr.is_instructor, false) into v_is_instructor
      from public.profiles pr where pr.id = v_person_uid;
    if not v_is_instructor then
      v_has_instructor := (v_outing.instructor_aircraft_id = p_aircraft)
        or exists (
          select 1 from public.registrations r
          join public.profiles pr on pr.id = r.user_id
          where r.outing_id = p_outing
            and r.status = 'confirmed'
            and r.aircraft_id = p_aircraft
            and pr.is_instructor = true
        );
      if v_ac_type is not null and not v_has_instructor then
        if not exists (
          select 1 from public.pilot_types pt
          where pt.user_id = v_person_uid and pt.aircraft_type = v_ac_type
        ) then
          select pr.full_name into v_nom from public.profiles pr where pr.id = v_person_uid;
          raise exception '% n''est pas lâché(e) sur % — déplacement refusé.', v_nom, v_ac_type;
        end if;
      end if;
    end if;
  end if;

  if p_with is null then
    select greatest(a.seats - case when v_outing.instructor_aircraft_id = a.id then 1 else 0 end, 0)
      into v_cap from public.aircraft a where a.id = p_aircraft;
    select count(*) into v_used from public.registrations
     where outing_id = p_outing and status = 'confirmed' and aircraft_id = p_aircraft;
    if p_who = 'organizer' then v_cap := v_cap - 1; end if;
    if v_used >= v_cap then
      raise exception 'Cet avion est complet : déposez la personne sur un membre de l''équipage pour échanger leurs places.';
    end if;
    if p_who = 'organizer' then
      update public.outings set instructor_aircraft_id = p_aircraft where id = p_outing;
    else
      update public.registrations set aircraft_id = p_aircraft where id = v_reg.id;
    end if;
  else
    if p_with = p_who then return; end if;
    if p_with = 'organizer' then
      if v_outing.instructor_aircraft_id is distinct from p_aircraft then
        raise exception 'L''organisateur n''est pas dans cet avion.';
      end if;
      update public.outings set instructor_aircraft_id = v_from where id = p_outing;
      update public.registrations set aircraft_id = p_aircraft where id = v_reg.id;
    else
      select * into v_other from public.registrations
       where id = p_with::uuid and outing_id = p_outing and status = 'confirmed' and aircraft_id = p_aircraft for update;
      if not found then raise exception 'Cette personne n''est pas dans cet avion.'; end if;
      update public.registrations set aircraft_id = v_from where id = v_other.id;
      if p_who = 'organizer' then
        update public.outings set instructor_aircraft_id = p_aircraft where id = p_outing;
      else
        update public.registrations set aircraft_id = p_aircraft where id = v_reg.id;
      end if;
    end if;
  end if;

  if exists (
    select 1
    from public.outing_aircraft oa
    join public.aircraft a on a.id = oa.aircraft_id
    join public.outings o on o.id = oa.outing_id
    where oa.outing_id = p_outing
      and (select count(*) from public.registrations r
            where r.outing_id = p_outing and r.status = 'confirmed' and r.aircraft_id = oa.aircraft_id)
          > greatest(a.seats - case when o.instructor_aircraft_id = a.id then 1 else 0 end, 0)
  ) then
    raise exception 'Ce déplacement dépasserait le nombre de places d''un avion.';
  end if;
end;
$function$;

revoke execute on function public.get_outing(uuid) from public, anon;
grant execute on function public.get_outing(uuid) to authenticated;
revoke execute on function public.move_crew(uuid, text, uuid, text) from public, anon;
grant execute on function public.move_crew(uuid, text, uuid, text) to authenticated;

notify pgrst, 'reload schema';
