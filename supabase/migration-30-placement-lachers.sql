-- =====================================================================
--  Mise à jour n°30 : placement automatique qui respecte les lâchers
--  Un membre est placé dans un avion :
--   - s'il est lâché sur le type de cet avion (rubrique « Mon compte »),
--   - ou s'il est instructeur,
--   - ou si un instructeur est à bord de cet avion (organisateur instructeur
--     ou instructeur inscrit placé dans cet avion).
--  Sinon il reste en liste d'attente, même s'il reste des sièges ailleurs.
--  Les places sont toujours attribuées dans l'ordre d'inscription.
--  Le déplacement manuel (move_crew) applique la même règle, y compris
--  quand on déplace l'instructeur hors de son avion.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

create or replace function public._is_instructor(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select p.is_instructor or p.role = 'instructor' from public.profiles p where p.id = p_user), false);
$$;

create or replace function public._is_released(p_user uuid, p_type text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_type is null
      or exists (select 1 from public.pilot_types pt where pt.user_id = p_user and pt.aircraft_type = p_type);
$$;

-- Peut voler dans cet avion pour cette sortie, compte tenu de qui est à bord actuellement
create or replace function public._can_fly_in(p_user uuid, p_aircraft uuid, p_outing uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public._is_instructor(p_user)
      or public._is_released(p_user, (select a.type from public.aircraft a where a.id = p_aircraft))
      or exists (select 1 from public.outings o
                  where o.id = p_outing and o.instructor_aircraft_id = p_aircraft
                    and public._is_instructor(o.instructor_id))
      or exists (select 1 from public.registrations r
                  where r.outing_id = p_outing and r.status = 'confirmed' and r.aircraft_id = p_aircraft
                    and r.user_id <> p_user and public._is_instructor(r.user_id));
$$;

revoke execute on function public._is_instructor(uuid), public._is_released(uuid, text),
  public._can_fly_in(uuid, uuid, uuid) from public, anon, authenticated;

create or replace function public._rebalance_outing(p_outing uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_outing   public.outings;
  v_ac       uuid[]    := '{}';
  v_type     text[]    := '{}';
  v_cap      int[]     := '{}';
  v_used     int[]     := '{}';
  v_instr    boolean[] := '{}';   -- un instructeur est à bord
  v_total    int := 0;
  v_idx      int := 0;
  v_keep     uuid[] := '{}';      -- gardent leur avion
  v_place    uuid[] := '{}';      -- à placer
  v_left     uuid[] := '{}';      -- pas de siège compatible pour l'instant
  v_assign   jsonb := '{}'::jsonb; -- registration_id -> aircraft_id
  v_changes  jsonb := '[]'::jsonb;
  v_i        int;
  v_slot     int;
  v_pass     int;
  v_progress boolean;
  v_is_instr boolean;
  r          record;
begin
  select * into v_outing from public.outings where id = p_outing;
  if not found or v_outing.status = 'cancelled' then
    return v_changes;
  end if;

  -- Activité / événement / formation sans avion : les N premiers inscrits sont confirmés
  if coalesce(v_outing.kind, 'vol') <> 'vol' then
    v_total := coalesce(v_outing.max_participants, 1000000);
    for r in
      select reg.id, reg.status
      from public.registrations reg
      where reg.outing_id = p_outing and reg.status <> 'cancelled'
      order by reg.created_at, reg.id
    loop
      v_idx := v_idx + 1;
      if v_idx <= v_total then
        if r.status <> 'confirmed' then
          update public.registrations set status = 'confirmed', aircraft_id = null where id = r.id;
          v_changes := v_changes || jsonb_build_object('registration_id', r.id, 'change', 'promoted');
        end if;
      elsif r.status <> 'waitlist' then
        update public.registrations set status = 'waitlist', aircraft_id = null where id = r.id;
        v_changes := v_changes || jsonb_build_object('registration_id', r.id, 'change', 'demoted');
      end if;
    end loop;
  else
    -- Avions de la sortie
    for r in
      select oa.aircraft_id, a.type,
             greatest(a.seats - case when v_outing.instructor_aircraft_id = oa.aircraft_id then 1 else 0 end, 0) as cap
      from public.outing_aircraft oa
      join public.aircraft a on a.id = oa.aircraft_id
      where oa.outing_id = p_outing
      order by oa.position, a.registration
    loop
      v_ac    := v_ac || r.aircraft_id;
      v_type  := v_type || r.type;
      v_cap   := v_cap || r.cap;
      v_used  := v_used || 0;
      v_instr := v_instr || (v_outing.instructor_aircraft_id = r.aircraft_id
                             and public._is_instructor(v_outing.instructor_id));
      v_total := v_total + r.cap;
    end loop;

    -- 1) Les instructeurs inscrits, puis tous les autres, gardent leur avion si c'est encore possible
    for v_pass in 1 .. 2 loop
      for r in
        select reg.id, reg.user_id, reg.status, reg.aircraft_id
        from public.registrations reg
        where reg.outing_id = p_outing and reg.status = 'confirmed'
          and public._is_instructor(reg.user_id) = (v_pass = 1)
        order by reg.created_at, reg.id
      loop
        v_i := array_position(v_ac, r.aircraft_id);
        if v_i is not null and v_used[v_i] < v_cap[v_i]
           and (v_pass = 1 or v_instr[v_i] or public._is_released(r.user_id, v_type[v_i])) then
          v_used[v_i] := v_used[v_i] + 1;
          if v_pass = 1 then v_instr[v_i] := true; end if;
          v_keep := v_keep || r.id;
        end if;
      end loop;
    end loop;

    -- 2) Les autres sont placés dans l'ordre d'inscription, dans le premier avion compatible.
    --    Plusieurs tours : un instructeur placé plus tard peut rendre un avion accessible.
    select coalesce(array_agg(reg.id order by reg.created_at, reg.id), '{}') into v_place
    from public.registrations reg
    where reg.outing_id = p_outing and reg.status <> 'cancelled' and not (reg.id = any (v_keep));

    loop
      v_progress := false;
      v_left := '{}';
      for r in
        select reg.id, reg.user_id
        from public.registrations reg
        where reg.id = any (v_place)
        order by reg.created_at, reg.id
      loop
        v_is_instr := public._is_instructor(r.user_id);
        v_slot := null;
        for v_i in 1 .. coalesce(array_length(v_ac, 1), 0) loop
          if v_used[v_i] < v_cap[v_i]
             and (v_is_instr or v_instr[v_i] or public._is_released(r.user_id, v_type[v_i])) then
            -- un instructeur va de préférence là où il n'y a pas encore d'instructeur
            if v_is_instr and v_instr[v_i] and v_slot is null then
              v_slot := -v_i;  -- repli possible, on continue de chercher mieux
              continue;
            end if;
            v_slot := v_i;
            exit;
          end if;
        end loop;
        if v_slot is not null and v_slot < 0 then v_slot := -v_slot; end if;

        if v_slot is null then
          v_left := v_left || r.id;
        else
          v_used[v_slot] := v_used[v_slot] + 1;
          if v_is_instr then v_instr[v_slot] := true; end if;
          v_assign := v_assign || jsonb_build_object(r.id::text, v_ac[v_slot]);
          v_progress := true;
        end if;
      end loop;
      v_place := v_left;
      exit when not v_progress or coalesce(array_length(v_place, 1), 0) = 0;
    end loop;

    -- 3) Application et liste des changements
    for r in
      select reg.id, reg.status, reg.aircraft_id
      from public.registrations reg
      where reg.outing_id = p_outing and reg.status <> 'cancelled'
    loop
      if r.id = any (v_keep) then
        continue;
      elsif v_assign ? r.id::text then
        update public.registrations
           set status = 'confirmed', aircraft_id = (v_assign ->> r.id::text)::uuid
         where id = r.id;
        if r.status = 'waitlist' then
          v_changes := v_changes || jsonb_build_object('registration_id', r.id, 'change', 'promoted');
        end if;
      elsif r.status <> 'waitlist' or r.aircraft_id is not null then
        update public.registrations set status = 'waitlist', aircraft_id = null where id = r.id;
        if r.status = 'confirmed' then
          v_changes := v_changes || jsonb_build_object('registration_id', r.id, 'change', 'demoted');
        end if;
      end if;
    end loop;
  end if;

  -- Enrichit avec les coordonnées (pour l'envoi des emails côté serveur)
  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id', p.id, 'email', p.email, 'full_name', p.full_name,
           'change', c ->> 'change')), '[]'::jsonb)
    into v_changes
  from jsonb_array_elements(v_changes) c
  join public.registrations reg on reg.id = (c ->> 'registration_id')::uuid
  join public.profiles p on p.id = reg.user_id;

  return v_changes;
end;
$$;
revoke execute on function public._rebalance_outing(uuid) from public, anon, authenticated;

-- Déplacement manuel : même règle
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
    v_is_instructor := public._is_instructor(v_person_uid);
    if not v_is_instructor then
      v_has_instructor := (v_outing.instructor_aircraft_id = p_aircraft and public._is_instructor(v_outing.instructor_id))
        or exists (
          select 1 from public.registrations r
          where r.outing_id = p_outing
            and r.status = 'confirmed'
            and r.aircraft_id = p_aircraft
            and r.id <> v_reg.id
            and public._is_instructor(r.user_id)
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

  -- Contrôle final des lâchers : personne ne doit se retrouver sans instructeur sur un type
  -- où il n'est pas lâché (cas d'un instructeur qu'on déplace hors de son avion, ou d'un échange)
  select pr.full_name, a.type into v_nom, v_ac_type
    from public.registrations r
    join public.aircraft a on a.id = r.aircraft_id
    join public.profiles pr on pr.id = r.user_id
    join public.outings o on o.id = r.outing_id
   where r.outing_id = p_outing and r.status = 'confirmed'
     and r.aircraft_id in (v_from, p_aircraft)
     and not public._can_fly_in(r.user_id, a.id, p_outing)
   limit 1;
  if found then
    raise exception '% se retrouverait sans instructeur sur un % où il/elle n''est pas lâché(e) — déplacement refusé.', v_nom, v_ac_type;
  end if;
end;
$function$;

notify pgrst, 'reload schema';

select exists (select 1 from pg_proc where proname = '_can_fly_in') as "MISE A JOUR 30 OK";
