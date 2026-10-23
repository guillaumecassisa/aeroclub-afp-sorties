-- =====================================================================
--  Mise à jour n°30 : sorties avion — lâchers et accompagnants (+1)
--  Un membre est placé dans un avion :
--   - s'il est lâché sur le type de cet avion (rubrique « Mon compte »),
--   - ou s'il est instructeur,
--   - ou si un instructeur est à bord de cet avion (organisateur instructeur
--     ou instructeur inscrit placé dans cet avion).
--  Sinon il reste en liste d'attente, même s'il reste des sièges ailleurs.
--  Les places sont toujours attribuées dans l'ordre d'inscription.
--  Le déplacement manuel (move_crew) applique la même règle, y compris
--  quand on déplace l'instructeur hors de son avion.
--  Accompagnants (+1), si l'organisateur les autorise sur l'événement :
--   - sortie avion : 1 accompagnant qui ne pilote pas (nom + poids), placé
--     sur un siège libre de n'importe quel avion ;
--   - activité / événement convivial : jusqu'à 5 accompagnants, pour que
--     l'organisateur connaisse le nombre exact de participants.
--  Un accompagnant n'a une place que si le membre qui l'amène en a une, et
--  il part avec lui s'il se désinscrit. Il compte dans les places.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 0. Accompagnants : colonnes ----------------------------------------------------
alter table public.outings
  add column if not exists guests_allowed boolean not null default false;

alter table public.registrations
  add column if not exists guest_of        uuid references public.registrations (id) on delete cascade,
  add column if not exists guest_name      text,
  add column if not exists guest_weight_kg numeric(5,1);

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'registrations_guest_check') then
    alter table public.registrations add constraint registrations_guest_check check (
      (guest_of is null and guest_name is null and guest_weight_kg is null)
      or (guest_of is not null and length(btrim(guest_name)) between 1 and 120
          and (guest_weight_kg is null or guest_weight_kg between 2 and 250)));
  end if;
end $$;

-- Un membre = une inscription active ; un accompagnant par inscription
drop index if exists public.registrations_one_active_per_user;
create unique index registrations_one_active_per_user on public.registrations (outing_id, user_id)
  where status <> 'cancelled' and guest_of is null;
-- (le nombre d'accompagnants par membre est contrôlé par add_guest / set_guest_count)
drop index if exists public.registrations_one_guest;
create index if not exists registrations_guest_of on public.registrations (guest_of) where guest_of is not null;

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
                    and r.guest_of is null and r.user_id <> p_user and public._is_instructor(r.user_id));
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
  v_ok       boolean;
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
      select reg.id, reg.status, reg.guest_of
      from public.registrations reg
      where reg.outing_id = p_outing and reg.status <> 'cancelled'
      order by reg.created_at, reg.id
    loop
      -- un accompagnant n'a une place que si le membre qui l'amène en a une
      if r.guest_of is not null and not (r.guest_of = any (v_keep)) then
        v_ok := false;
      elsif v_idx < v_total then
        v_idx := v_idx + 1;
        v_ok := true;
        if r.guest_of is null then v_keep := v_keep || r.id; end if;
      else
        v_ok := false;
      end if;
      if v_ok then
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

    -- 1) Les instructeurs inscrits, puis les autres membres, puis leurs accompagnants
    --    gardent leur avion si c'est encore possible
    for v_pass in 1 .. 3 loop
      for r in
        select reg.id, reg.user_id, reg.status, reg.aircraft_id, reg.guest_of
        from public.registrations reg
        where reg.outing_id = p_outing and reg.status = 'confirmed'
          and case v_pass
                when 1 then reg.guest_of is null and public._is_instructor(reg.user_id)
                when 2 then reg.guest_of is null and not public._is_instructor(reg.user_id)
                else reg.guest_of is not null and reg.guest_of = any (v_keep)
              end
        order by reg.created_at, reg.id
      loop
        v_i := array_position(v_ac, r.aircraft_id);
        if v_i is not null and v_used[v_i] < v_cap[v_i]
           and (v_pass <> 2 or v_instr[v_i] or public._is_released(r.user_id, v_type[v_i])) then
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
        select reg.id, reg.user_id, reg.guest_of
        from public.registrations reg
        where reg.id = any (v_place)
        order by reg.created_at, reg.id
      loop
        -- un accompagnant ne prend un siège que si le membre qui l'amène en a un
        if r.guest_of is not null and not (r.guest_of = any (v_keep) or v_assign ? r.guest_of::text) then
          v_left := v_left || r.id;
          continue;
        end if;
        v_is_instr := r.guest_of is null and public._is_instructor(r.user_id);
        v_slot := null;
        for v_i in 1 .. coalesce(array_length(v_ac, 1), 0) loop
          if v_used[v_i] < v_cap[v_i]
             and (r.guest_of is not null or v_is_instr or v_instr[v_i] or public._is_released(r.user_id, v_type[v_i])) then
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
  join public.profiles p on p.id = reg.user_id
  where reg.guest_of is null;

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

  if p_who <> 'organizer' and v_reg.guest_of is null then
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
            and r.guest_of is null
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
     and r.guest_of is null
     and not public._can_fly_in(r.user_id, a.id, p_outing)
   limit 1;
  if found then
    raise exception '% se retrouverait sans instructeur sur un % où il/elle n''est pas lâché(e) — déplacement refusé.', v_nom, v_ac_type;
  end if;
end;
$function$;

-- Fonctions des sorties adaptées aux accompagnants
CREATE OR REPLACE FUNCTION public.register_for_outing(p_outing uuid, p_user uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid     uuid := auth.uid();
  v_target  uuid;
  v_outing  public.outings;
  v_reg     public.registrations;
  v_changes jsonb;
  v_pos     int;
begin
  if v_uid is null then raise exception 'Vous devez être connecté.'; end if;
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;

  v_target := coalesce(p_user, v_uid);
  if v_target <> v_uid and not public.can_organize() then
    raise exception 'Seul un organisateur peut inscrire un autre membre.';
  end if;

  select * into v_outing from public.outings where id = p_outing for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  if v_outing.status = 'cancelled' then raise exception 'Cette sortie est annulée.'; end if;
  if v_outing.approval <> 'approved' then raise exception 'Cette sortie n''a pas encore été validée par un instructeur.'; end if;
  if v_outing.departure_at <= now() then raise exception 'Cette sortie a déjà eu lieu.'; end if;
  if v_outing.registration_deadline is not null and now() > v_outing.registration_deadline
     and not public.can_organize() then
    raise exception 'Les inscriptions sont closes pour cette sortie.';
  end if;
  if not exists (select 1 from public.profiles where id = v_target and role <> 'pending') then
    raise exception 'Ce membre n''existe pas ou n''est pas encore validé.';
  end if;
  if v_target = v_outing.instructor_id and v_outing.instructor_aircraft_id is not null then
    raise exception 'L''instructeur de la sortie occupe déjà un siège.';
  end if;
  if exists (select 1 from public.registrations
             where outing_id = p_outing and user_id = v_target and status <> 'cancelled' and guest_of is null) then
    raise exception 'Déjà inscrit à cette sortie.';
  end if;

  insert into public.registrations (outing_id, user_id, status, created_by)
  values (p_outing, v_target, 'waitlist', v_uid)
  returning * into v_reg;

  v_changes := public._rebalance_outing(p_outing);

  select * into v_reg from public.registrations where id = v_reg.id;
  if v_reg.status = 'waitlist' then
    select count(*) into v_pos from public.registrations
     where outing_id = p_outing and status = 'waitlist'
       and (created_at, id) <= (v_reg.created_at, v_reg.id);
  end if;

  return jsonb_build_object(
    'registration_id', v_reg.id,
    'status', v_reg.status,
    'waitlist_position', v_pos,
    'changes', coalesce((select jsonb_agg(c) from jsonb_array_elements(v_changes) c
                         where (c ->> 'user_id')::uuid <> v_target), '[]'::jsonb)
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.list_outings(p_past boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;

  return coalesce((
    select jsonb_agg(row_to_json(t) order by
             case when p_past then null else t.departure_at end asc,
             case when p_past then t.departure_at end desc)
    from (
      select o.id, o.title, o.destination, o.departure_at, o.return_at,
             o.registration_deadline, o.status,
             ip.full_name as instructor_name,
             (o.instructor_aircraft_id is not null) as instructor_flies,
             case when coalesce(o.kind, 'vol') = 'vol' then
             (select coalesce(sum(greatest(a.seats - case when a.id = o.instructor_aircraft_id then 1 else 0 end, 0)), 0)
                from public.outing_aircraft oa join public.aircraft a on a.id = oa.aircraft_id
               where oa.outing_id = o.id)
             else o.max_participants end as total_capacity,
             coalesce(o.kind, 'vol') as kind, o.max_participants, o.meeting_point,
             (select count(*) from public.registrations r
               where r.outing_id = o.id and r.status = 'confirmed') as confirmed_count,
             (select count(*) from public.registrations r
               where r.outing_id = o.id and r.status = 'waitlist') as waitlist_count,
             (select string_agg(a.registration || ' (' || a.seats || 'pl.)', ', ' order by oa.position)
                from public.outing_aircraft oa join public.aircraft a on a.id = oa.aircraft_id
               where oa.outing_id = o.id) as aircraft_summary,
             (select r.status from public.registrations r
               where r.outing_id = o.id and r.user_id = v_uid and r.status <> 'cancelled'
                 and r.guest_of is null) as my_status,
             (o.instructor_id = v_uid) as i_am_instructor,
             o.approval, o.rejection_reason
      from public.outings o
      join public.profiles ip on ip.id = o.instructor_id
      where (o.approval = 'approved' or o.instructor_id = v_uid or public.can_organize())
        and case when p_past
                 then coalesce(o.return_at, o.departure_at) < now()
                 else coalesce(o.return_at, o.departure_at) >= now() end
      limit 200
    ) t), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION public.cancel_registration(p_registration uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid    uuid := auth.uid();
  v_reg    public.registrations;
  v_outing public.outings;
begin
  if v_uid is null then raise exception 'Vous devez être connecté.'; end if;

  select * into v_reg from public.registrations where id = p_registration;
  if not found then raise exception 'Inscription introuvable.'; end if;

  -- verrouille la sortie pour sérialiser les modifications
  select * into v_outing from public.outings where id = v_reg.outing_id for update;
  select * into v_reg from public.registrations where id = p_registration;

  if v_reg.user_id <> v_uid and not public.is_staff() then
    raise exception 'Vous ne pouvez pas annuler l''inscription d''un autre membre.';
  end if;
  if v_reg.status = 'cancelled' then raise exception 'Inscription déjà annulée.'; end if;
  if v_outing.departure_at <= now() and not public.is_staff() then
    raise exception 'La sortie a déjà commencé : contactez l''instructeur.';
  end if;

  -- le membre et son accompagnant éventuel
  update public.registrations
     set status = 'cancelled', aircraft_id = null, cancelled_at = now()
   where (id = p_registration or guest_of = p_registration) and status <> 'cancelled';

  if v_outing.departure_at <= now() then
    return jsonb_build_object('changes', '[]'::jsonb);
  end if;
  return jsonb_build_object('changes', public._rebalance_outing(v_outing.id));
end;
$function$;

CREATE OR REPLACE FUNCTION public.cancel_outing(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_outing public.outings;
begin
  select * into v_outing from public.outings where id = p_id for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  -- un membre peut retirer sa propre proposition non publiée
  if not public.can_organize() and not (v_outing.instructor_id = auth.uid() and v_outing.approval <> 'approved') then
    raise exception 'Action réservée aux organisateurs.';
  end if;
  if v_outing.status = 'cancelled' then raise exception 'Sortie déjà annulée.'; end if;

  update public.outings set status = 'cancelled', updated_at = now() where id = p_id;

  return jsonb_build_object('recipients', coalesce((
    select jsonb_agg(jsonb_build_object('user_id', p.id, 'email', p.email, 'full_name', p.full_name))
    from public.registrations r join public.profiles p on p.id = r.user_id
    where r.outing_id = p_id and r.status <> 'cancelled' and r.guest_of is null), '[]'::jsonb));
end;
$function$;

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
  v_guest jsonb;
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
              'full_name', coalesce(r.guest_name, p.full_name),
              'avatar_url', case when r.guest_of is null then p.avatar_url end,
              'is_guest', r.guest_of is not null,
              'host_name', case when r.guest_of is not null then p.full_name end,
              'released', r.guest_of is not null or public._is_instructor(r.user_id) or exists (
                select 1 from public.pilot_types pt
                 where pt.user_id = r.user_id and pt.aircraft_type = a.type
              ),
              'phone', case when r.guest_of is null and (v_staff or v_row.instructor_id = v_uid) then p.phone end,
              'weight_kg', case when v_row.instructor_id = v_uid or r.user_id = v_uid
                                then case when r.guest_of is null then pw.weight_kg else r.guest_weight_kg end end
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
      'full_name', coalesce(r.guest_name, p.full_name),
      'avatar_url', case when r.guest_of is null then p.avatar_url end,
      'is_guest', r.guest_of is not null,
      'host_name', case when r.guest_of is not null then p.full_name end,
      'released', false,
      'phone', case when r.guest_of is null and (v_staff or v_row.instructor_id = v_uid) then p.phone end,
      'weight_kg', case when v_row.instructor_id = v_uid or r.user_id = v_uid
                        then case when r.guest_of is null then pw.weight_kg else r.guest_weight_kg end end,
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
      'full_name', coalesce(r.guest_name, p.full_name),
      'avatar_url', case when r.guest_of is null then p.avatar_url end,
      'is_guest', r.guest_of is not null,
      'host_name', case when r.guest_of is not null then p.full_name end,
      'released', false,
      'phone', case when r.guest_of is null and (v_staff or v_row.instructor_id = v_uid) then p.phone end
    ) order by r.created_at), '[]') into v_part
    from public.registrations r
    join public.profiles p on p.id = r.user_id
    where r.outing_id = p_id and r.status = 'confirmed';
  else
    v_part := '[]';
  end if;

  select jsonb_build_object('id', r.id, 'status', r.status, 'aircraft_id', r.aircraft_id) into v_mine
  from public.registrations r
  where r.outing_id = p_id and r.user_id = v_uid and r.guest_of is null and r.status <> 'cancelled'
  limit 1;

  select jsonb_build_object('id', g.id, 'name', g.guest_name, 'weight_kg', g.guest_weight_kg,
                            'status', g.status, 'aircraft_id', g.aircraft_id) into v_guest
  from public.registrations g
  join public.registrations h on h.id = g.guest_of
  where g.outing_id = p_id and h.user_id = v_uid and g.status <> 'cancelled'
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
    'my_registration',       v_mine,
    'my_guest',              v_guest,
    'my_guest_count',        (select count(*) from public.registrations g
                               join public.registrations h on h.id = g.guest_of
                              where g.outing_id = p_id and h.user_id = v_uid and g.status <> 'cancelled'),
    'guests_allowed',        coalesce(v_row.guests_allowed, false)
  );
end;
$function$;

-- Ajouter / retirer son accompagnant
create or replace function public.add_guest(p_outing uuid, p_name text, p_weight numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_outing  public.outings;
  v_host    public.registrations;
  v_guest   public.registrations;
  v_changes jsonb;
begin
  if v_uid is null then raise exception 'Vous devez être connecté.'; end if;
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  select * into v_outing from public.outings where id = p_outing for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  if coalesce(v_outing.kind, 'vol') <> 'vol' then raise exception 'Les accompagnants concernent les sorties avion.'; end if;
  if not v_outing.guests_allowed then raise exception 'L''organisateur n''autorise pas d''accompagnant sur cette sortie.'; end if;
  if v_outing.status = 'cancelled' or v_outing.approval <> 'approved' then raise exception 'Cette sortie n''est pas ouverte.'; end if;
  if v_outing.departure_at <= now() then raise exception 'Cette sortie a déjà eu lieu.'; end if;
  if v_outing.registration_deadline is not null and now() > v_outing.registration_deadline then
    raise exception 'Les inscriptions sont closes pour cette sortie.';
  end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'Indiquez le nom de votre accompagnant.'; end if;
  if p_weight is not null and (p_weight < 2 or p_weight > 250) then raise exception 'Poids invalide.'; end if;

  select * into v_host from public.registrations
   where outing_id = p_outing and user_id = v_uid and guest_of is null and status <> 'cancelled';
  if not found then raise exception 'Inscrivez-vous d''abord à la sortie.'; end if;
  if exists (select 1 from public.registrations where guest_of = v_host.id and status <> 'cancelled') then
    raise exception 'Vous avez déjà un accompagnant sur cette sortie.';
  end if;

  insert into public.registrations (outing_id, user_id, status, created_by, guest_of, guest_name, guest_weight_kg)
  values (p_outing, v_uid, 'waitlist', v_uid, v_host.id, left(btrim(p_name), 120), p_weight)
  returning * into v_guest;

  v_changes := public._rebalance_outing(p_outing);
  select * into v_guest from public.registrations where id = v_guest.id;
  return jsonb_build_object('registration_id', v_guest.id, 'status', v_guest.status,
    'changes', coalesce((select jsonb_agg(c) from jsonb_array_elements(v_changes) c
                         where (c ->> 'user_id')::uuid <> v_uid), '[]'::jsonb));
end;
$$;
revoke execute on function public.add_guest(uuid, text, numeric) from public, anon;
grant execute on function public.add_guest(uuid, text, numeric) to authenticated;

-- Événement sans avion : le membre indique combien de personnes il amène (0 à 5)
create or replace function public.set_guest_count(p_outing uuid, p_count int)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_outing  public.outings;
  v_host    public.registrations;
  v_name    text;
  v_current int;
  v_i       int;
  v_changes jsonb;
begin
  if v_uid is null then raise exception 'Vous devez être connecté.'; end if;
  if p_count is null or p_count < 0 or p_count > 5 then raise exception 'Entre 0 et 5 accompagnants.'; end if;
  select * into v_outing from public.outings where id = p_outing for update;
  if not found then raise exception 'Événement introuvable.'; end if;
  if coalesce(v_outing.kind, 'vol') = 'vol' then raise exception 'Pour une sortie avion, ajoutez votre accompagnant avec son nom et son poids.'; end if;
  if p_count > 0 and not v_outing.guests_allowed then raise exception 'L''organisateur n''autorise pas d''accompagnant sur cet événement.'; end if;
  if v_outing.status = 'cancelled' then raise exception 'Cet événement est annulé.'; end if;
  if v_outing.departure_at <= now() then raise exception 'Cet événement a déjà eu lieu.'; end if;

  select * into v_host from public.registrations
   where outing_id = p_outing and user_id = v_uid and guest_of is null and status <> 'cancelled';
  if not found then raise exception 'Inscrivez-vous d''abord à l''événement.'; end if;
  select split_part(btrim(full_name), ' ', 1) into v_name from public.profiles where id = v_uid;

  select count(*) into v_current from public.registrations where guest_of = v_host.id and status <> 'cancelled';
  if p_count > v_current then
    for v_i in v_current + 1 .. p_count loop
      insert into public.registrations (outing_id, user_id, status, created_by, guest_of, guest_name)
      values (p_outing, v_uid, 'waitlist', v_uid, v_host.id, 'Accompagnant ' || v_i || ' de ' || coalesce(v_name, 'membre'));
    end loop;
  elsif p_count < v_current then
    -- on retire d'abord les derniers ajoutés
    update public.registrations set status = 'cancelled', aircraft_id = null, cancelled_at = now()
     where id in (select id from public.registrations
                   where guest_of = v_host.id and status <> 'cancelled'
                   order by created_at desc, id desc limit v_current - p_count);
  end if;

  v_changes := public._rebalance_outing(p_outing);
  return jsonb_build_object(
    'changes', v_changes,
    'confirmed', (select count(*) from public.registrations where guest_of = v_host.id and status = 'confirmed'),
    'waitlist',  (select count(*) from public.registrations where guest_of = v_host.id and status = 'waitlist'));
end;
$$;
revoke execute on function public.set_guest_count(uuid, int) from public, anon;
grant execute on function public.set_guest_count(uuid, int) to authenticated;

-- L'organisateur autorise ou non les accompagnants (s'il les interdit, ceux déjà inscrits sont retirés)
create or replace function public.set_guests_allowed(p_outing uuid, p_allowed boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_outing public.outings;
  v_removed jsonb := '[]'::jsonb;
begin
  select * into v_outing from public.outings where id = p_outing for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  if not (public.can_organize() or v_outing.instructor_id = auth.uid()) then
    raise exception 'Action réservée aux organisateurs.';
  end if;
  if coalesce(v_outing.guests_allowed, false) = coalesce(p_allowed, false) then
    return jsonb_build_object('changes', '[]'::jsonb, 'removed', '[]'::jsonb);
  end if;
  update public.outings set guests_allowed = coalesce(p_allowed, false), updated_at = now() where id = p_outing;
  if not coalesce(p_allowed, false) then
    select coalesce(jsonb_agg(jsonb_build_object('email', p.email, 'full_name', p.full_name, 'guest', g.guest_name)), '[]'::jsonb)
      into v_removed
    from public.registrations g join public.profiles p on p.id = g.user_id
    where g.outing_id = p_outing and g.guest_of is not null and g.status <> 'cancelled';
    update public.registrations set status = 'cancelled', aircraft_id = null, cancelled_at = now()
     where outing_id = p_outing and guest_of is not null and status <> 'cancelled';
  end if;
  return jsonb_build_object('changes', public._rebalance_outing(p_outing), 'removed', v_removed);
end;
$$;
revoke execute on function public.set_guests_allowed(uuid, boolean) from public, anon;
grant execute on function public.set_guests_allowed(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';

select exists (select 1 from pg_proc where proname = '_can_fly_in')
   and exists (select 1 from pg_proc where proname = 'add_guest')
   and exists (select 1 from pg_proc where proname = 'set_guest_count') as "MISE A JOUR 30 OK";
