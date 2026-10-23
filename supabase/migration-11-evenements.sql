-- =====================================================================
--  Mise à jour n°11 : Événements
--  Trois types : sortie avion (avec avions), activité (sans avion : moto,
--  randonnée…), événement convivial (apéro, dîner, soirée).
--  Peuvent créer et gérer : administrateurs, instructeurs, membres du CA
--  et toute personne ayant une fonction (trésorier, secrétaire, maintenance).
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

alter table public.outings add column if not exists kind text not null default 'vol';
alter table public.outings drop constraint if exists outings_kind_check;
alter table public.outings add constraint outings_kind_check check (kind in ('vol', 'activite', 'evenement', 'formation')); -- 'formation' : n°29 (permet de rejouer le fichier)
alter table public.outings add column if not exists max_participants int check (max_participants is null or max_participants >= 1);
alter table public.profiles add column if not exists is_board boolean not null default false;

create or replace function public.can_organize()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select role in ('instructor', 'admin')
                          or (role <> 'pending' and (is_board or is_treasurer or is_secretary or is_maintenance))
                   from public.profiles where id = auth.uid()), false)
$$;
grant execute on function public.can_organize() to authenticated;

create or replace function public.set_board(p_user uuid, p_value boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  update public.profiles set is_board = p_value where id = p_user;
end;
$$;
revoke execute on function public.set_board(uuid, boolean) from public, anon;
grant execute on function public.set_board(uuid, boolean) to authenticated;

drop policy if exists outings_select on public.outings;
create policy outings_select on public.outings for select to authenticated
  using (public.is_approved() and (approval = 'approved' or instructor_id = auth.uid() or public.can_organize()));

drop function if exists public.save_outing(uuid, text, text, text, text, timestamptz, timestamptz, timestamptz, uuid[], uuid);

create or replace function public._rebalance_outing(p_outing uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_outing   public.outings;
  v_ac       uuid[] := '{}';
  v_cap      int[]  := '{}';
  v_used     int[]  := '{}';
  v_total    int := 0;
  v_idx      int := 0;
  v_pending  uuid[] := '{}';
  v_changes  jsonb := '[]'::jsonb;
  v_i        int;
  v_slot     int;
  r          record;
begin
  select * into v_outing from public.outings where id = p_outing;
  if not found or v_outing.status = 'cancelled' then
    return v_changes;
  end if;

  -- Activité / événement sans avion : les N premiers inscrits sont confirmés
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
    select coalesce(jsonb_agg(jsonb_build_object(
             'user_id', p.id, 'email', p.email, 'full_name', p.full_name,
             'change', c ->> 'change')), '[]'::jsonb)
      into v_changes
    from jsonb_array_elements(v_changes) c
    join public.registrations reg on reg.id = (c ->> 'registration_id')::uuid
    join public.profiles p on p.id = reg.user_id;
    return v_changes;
  end if;

  for r in
    select oa.aircraft_id,
           greatest(a.seats - case when v_outing.instructor_aircraft_id = oa.aircraft_id then 1 else 0 end, 0) as cap
    from public.outing_aircraft oa
    join public.aircraft a on a.id = oa.aircraft_id
    where oa.outing_id = p_outing
    order by oa.position, a.registration
  loop
    v_ac   := v_ac || r.aircraft_id;
    v_cap  := v_cap || r.cap;
    v_used := v_used || 0;
    v_total := v_total + r.cap;
  end loop;

  -- 1er passage : qui est confirmé, qui garde son avion, qui repasse en attente
  for r in
    select reg.id, reg.status, reg.aircraft_id
    from public.registrations reg
    where reg.outing_id = p_outing and reg.status <> 'cancelled'
    order by reg.created_at, reg.id
  loop
    v_idx := v_idx + 1;
    if v_idx <= v_total then
      v_i := array_position(v_ac, r.aircraft_id);
      if r.status = 'confirmed' and v_i is not null and v_used[v_i] < v_cap[v_i] then
        v_used[v_i] := v_used[v_i] + 1;
      else
        v_pending := v_pending || r.id;
      end if;
    elsif r.status <> 'waitlist' or r.aircraft_id is not null then
      update public.registrations set status = 'waitlist', aircraft_id = null where id = r.id;
      if r.status = 'confirmed' then
        v_changes := v_changes || jsonb_build_object('registration_id', r.id, 'change', 'demoted');
      end if;
    end if;
  end loop;

  -- 2e passage : placement dans les avions ayant des sièges libres
  for r in
    select reg.id, reg.status
    from public.registrations reg
    where reg.id = any (v_pending)
    order by reg.created_at, reg.id
  loop
    v_slot := null;
    for v_i in 1 .. coalesce(array_length(v_ac, 1), 0) loop
      if v_used[v_i] < v_cap[v_i] then
        v_slot := v_i;
        exit;
      end if;
    end loop;
    exit when v_slot is null; -- ne devrait pas arriver

    v_used[v_slot] := v_used[v_slot] + 1;
    update public.registrations
       set status = 'confirmed', aircraft_id = v_ac[v_slot]
     where id = r.id;
    if r.status = 'waitlist' then
      v_changes := v_changes || jsonb_build_object('registration_id', r.id, 'change', 'promoted');
    end if;
  end loop;

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

create or replace function public.save_outing(
  p_id                   uuid,
  p_title                text,
  p_destination          text,
  p_description          text,
  p_meeting_point        text,
  p_departure_at         timestamptz,
  p_return_at            timestamptz,
  p_deadline             timestamptz,
  p_aircraft             uuid[],
  p_instructor_aircraft  uuid,
  p_kind                 text default 'vol',
  p_max_participants     int  default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_outing public.outings;
  v_i      int;
  v_staff  boolean;
  v_notify jsonb := '[]'::jsonb;
  v_kind   text := coalesce(nullif(p_kind, ''), 'vol');
  v_ac     uuid[] := coalesce(p_aircraft, '{}');
  v_ins_ac uuid := p_instructor_aircraft;
  v_max    int := p_max_participants;
begin
  v_staff := public.can_organize();
  if not public.is_approved() then
    raise exception 'Votre compte n''est pas encore validé.';
  end if;
  if p_title is null or length(btrim(p_title)) = 0 then raise exception 'Le titre est obligatoire.'; end if;
  if p_departure_at is null then raise exception 'La date de départ est obligatoire.'; end if;
  if p_return_at is not null and p_return_at < p_departure_at then
    raise exception 'Le retour doit être après le départ.';
  end if;
  if p_deadline is not null and p_deadline > p_departure_at then
    raise exception 'La date limite d''inscription doit précéder le départ.';
  end if;
  if v_kind not in ('vol', 'activite', 'evenement') then raise exception 'Type d''événement inconnu.'; end if;
  if v_kind <> 'vol' then
    v_ac := '{}'; v_ins_ac := null;
    if v_max is not null and v_max < 1 then raise exception 'Le nombre de places doit être d''au moins 1.'; end if;
  else
    v_max := null;
  end if;
  if v_kind = 'vol' and coalesce(array_length(v_ac, 1), 0) = 0 then
    raise exception 'Sélectionnez au moins un avion.';
  end if;
  if (select count(distinct x) from unnest(v_ac) x) <> coalesce(array_length(v_ac, 1), 0) then
    raise exception 'Un avion est sélectionné deux fois.';
  end if;
  if (select count(*) from public.aircraft where id = any (v_ac)) <> coalesce(array_length(v_ac, 1), 0) then
    raise exception 'Avion inconnu.';
  end if;
  if v_ins_ac is not null and not (v_ins_ac = any (v_ac)) then
    raise exception 'L''avion de l''instructeur doit faire partie des avions de la sortie.';
  end if;

  if p_id is null then
    insert into public.outings (title, destination, description, meeting_point, departure_at,
                                return_at, registration_deadline, instructor_id, instructor_aircraft_id,
                                approval, approved_by, approved_at, kind, max_participants)
    values (btrim(p_title), nullif(btrim(p_destination), ''), nullif(btrim(p_description), ''),
            nullif(btrim(p_meeting_point), ''), p_departure_at, p_return_at, p_deadline,
            v_uid, v_ins_ac,
            case when v_staff then 'approved' else 'pending' end,
            case when v_staff then v_uid end, case when v_staff then now() end, v_kind, v_max)
    returning * into v_outing;
    -- Proposition d'un membre : on prévient les instructeurs et administrateurs
    if not v_staff then
      select coalesce(jsonb_agg(jsonb_build_object('email', email, 'full_name', full_name)), '[]'::jsonb)
        into v_notify from public.profiles where role in ('instructor', 'admin');
    end if;
  else
    select * into v_outing from public.outings where id = p_id for update;
    if not found then raise exception 'Sortie introuvable.'; end if;
    if v_outing.status = 'cancelled' then raise exception 'Sortie annulée : modification impossible.'; end if;
    if not v_staff and not (v_outing.instructor_id = v_uid and v_outing.approval <> 'approved') then
      raise exception 'Seul un organisateur (instructeur, administrateur, membre du CA…) peut modifier un événement publié.';
    end if;

    update public.outings set
      title = btrim(p_title),
      destination = nullif(btrim(p_destination), ''),
      description = nullif(btrim(p_description), ''),
      meeting_point = nullif(btrim(p_meeting_point), ''),
      departure_at = p_departure_at,
      return_at = p_return_at,
      registration_deadline = p_deadline,
      instructor_aircraft_id = v_ins_ac,
      kind = v_kind,
      max_participants = v_max,
      -- une proposition refusée puis corrigée repart en validation
      approval = case when approval = 'rejected' then 'pending' else approval end,
      updated_at = now()
    where id = p_id
    returning * into v_outing;

    delete from public.outing_aircraft
     where outing_id = p_id and not (aircraft_id = any (v_ac));
  end if;

  -- L'instructeur qui vole n'est pas aussi un "passager" inscrit
  if v_ins_ac is not null then
    update public.registrations
       set status = 'cancelled', aircraft_id = null, cancelled_at = now()
     where outing_id = v_outing.id and user_id = v_outing.instructor_id and status <> 'cancelled';
  end if;

  for v_i in 1 .. coalesce(array_length(v_ac, 1), 0) loop
    insert into public.outing_aircraft (outing_id, aircraft_id, position)
    values (v_outing.id, v_ac[v_i], v_i)
    on conflict (outing_id, aircraft_id) do update set position = excluded.position;
  end loop;

  return jsonb_build_object('outing_id', v_outing.id,
                            'approval', (select approval from public.outings where id = v_outing.id),
                            'notify_staff', v_notify,
                            'changes', public._rebalance_outing(v_outing.id));
end;
$$;

create or replace function public.register_for_outing(p_outing uuid, p_user uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
             where outing_id = p_outing and user_id = v_target and status <> 'cancelled') then
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
$$;

create or replace function public.list_outings(p_past boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
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
               where r.outing_id = o.id and r.user_id = v_uid and r.status <> 'cancelled') as my_status,
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
$$;

create or replace function public.get_outing(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_staff  boolean := public.can_organize();
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
    'kind', coalesce(o.kind, 'vol'),
    'max_participants', o.max_participants,
    'participants', coalesce((
      select jsonb_agg(jsonb_build_object(
               'registration_id', r.id, 'user_id', p.id, 'full_name', p.full_name,
               'avatar_url', p.avatar_url,
               'phone', case when v_staff or p.id = v_uid then p.phone end)
             order by r.created_at, r.id)
      from public.registrations r join public.profiles p on p.id = r.user_id
      where r.outing_id = o.id and r.status = 'confirmed' and r.aircraft_id is null
        and coalesce(o.kind, 'vol') <> 'vol'), '[]'::jsonb),
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

create or replace function public.cancel_outing(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
    where r.outing_id = p_id and r.status <> 'cancelled'), '[]'::jsonb));
end;
$$;

create or replace function public.review_outing(p_id uuid, p_approve boolean, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_outing public.outings;
begin
  if not public.can_organize() then raise exception 'Action réservée aux organisateurs.'; end if;
  select * into v_outing from public.outings where id = p_id for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  if v_outing.approval = 'approved' then raise exception 'Cette sortie est déjà publiée.'; end if;

  update public.outings set
    approval = case when p_approve then 'approved' else 'rejected' end,
    rejection_reason = case when p_approve then null else nullif(btrim(p_reason), '') end,
    approved_by = case when p_approve then auth.uid() end,
    approved_at = case when p_approve then now() end,
    updated_at = now()
  where id = p_id;

  return (select jsonb_build_object('email', p.email, 'full_name', p.full_name, 'title', v_outing.title,
                                    'departure_at', v_outing.departure_at)
          from public.profiles p where p.id = v_outing.instructor_id);
end;
$$;

revoke execute on function public.save_outing(uuid, text, text, text, text, timestamptz, timestamptz, timestamptz, uuid[], uuid, text, int) from public, anon;
grant execute on function public.save_outing(uuid, text, text, text, text, timestamptz, timestamptz, timestamptz, uuid[], uuid, text, int) to authenticated;
revoke execute on function public._rebalance_outing(uuid) from public, anon, authenticated;

notify pgrst, 'reload schema';
