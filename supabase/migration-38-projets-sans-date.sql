-- =====================================================================
--  Mise à jour n°38 : projets d'événement sans date
--  Une sortie avion, une activité ou un événement peut être proposé sans date
--  (« date à définir ») : les membres peuvent déjà s'y inscrire pour montrer leur
--  intérêt, et la date est fixée plus tard en modifiant l'événement.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. La date de départ devient facultative (le retour, lui, suppose un départ)
alter table public.outings alter column departure_at drop not null;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'outings_return_needs_departure'
                   and conrelid = 'public.outings'::regclass) then
    alter table public.outings add constraint outings_return_needs_departure
      check (departure_at is not null or return_at is null);
  end if;
end $$;

-- 2. Créer / modifier un événement : date facultative
create or replace function public.save_outing(p_id uuid, p_title text, p_destination text, p_description text,
  p_meeting_point text, p_departure_at timestamp with time zone, p_return_at timestamp with time zone,
  p_deadline timestamp with time zone, p_aircraft uuid[], p_instructor_aircraft uuid,
  p_kind text default 'vol'::text, p_max_participants integer default null::integer)
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
  -- sans date de départ : projet « date à définir »
  if p_departure_at is null and p_return_at is not null then
    raise exception 'Indiquez la date de départ avant la date de retour, ou laissez les deux vides.';
  end if;
  if p_return_at is not null and p_return_at < p_departure_at then
    raise exception 'Le retour doit être après le départ.';
  end if;
  if p_deadline is not null and p_departure_at is not null and p_deadline > p_departure_at then
    raise exception 'La date limite d''inscription doit précéder le départ.';
  end if;
  if v_kind not in ('vol', 'activite', 'evenement', 'formation') then raise exception 'Type d''événement inconnu.'; end if;
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

-- 3. Liste des événements : les projets sans date sont « à venir », après les événements datés
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
             case when p_past then null else t.departure_at end asc nulls last,
             case when p_past then t.departure_at end desc,
             t.created_at desc)
    from (
      select o.id, o.title, o.destination, o.departure_at, o.return_at,
             o.registration_deadline, o.status, o.created_at,
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
      where (o.approval = 'approved' or o.instructor_id = v_uid or public.is_staff())
        and case when p_past
                 then o.departure_at is not null and coalesce(o.return_at, o.departure_at) < now()
                 else o.departure_at is null or coalesce(o.return_at, o.departure_at) >= now() end
      limit 200
    ) t), '[]'::jsonb);
end;
$$;

-- 4. Suppression d'un compte : désinscription aussi des projets sans date
do $$
declare d text;
begin
  select pg_get_functiondef('public.anonymize_member(uuid)'::regprocedure) into d;
  if position('o.departure_at is null or o.departure_at > now()' in d) = 0 then
    d := replace(d, 'o.departure_at > now()', '(o.departure_at is null or o.departure_at > now())');
    execute d;
  end if;
end $$;

-- Vérification
select 'MISE A JOUR 38 OK' as resultat,
       (select is_nullable from information_schema.columns
         where table_schema = 'public' and table_name = 'outings' and column_name = 'departure_at') as date_facultative;
