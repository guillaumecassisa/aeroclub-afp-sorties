-- =====================================================================
--  Aéroclub — Organisation des sorties
--  Schéma Supabase (PostgreSQL). À exécuter une fois dans
--  Supabase > SQL Editor > New query > coller > Run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------
create type public.user_role as enum ('pending', 'member', 'instructor', 'admin');
create type public.outing_status as enum ('open', 'cancelled');
create type public.registration_status as enum ('confirmed', 'waitlist', 'cancelled');

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------

-- Profil de chaque membre (créé automatiquement à l'inscription).
-- 'pending' = compte créé mais pas encore validé par un administrateur.
create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  full_name   text not null default '',
  email       text not null,
  phone       text,
  role        public.user_role not null default 'pending',
  created_at  timestamptz not null default now()
);

-- Flotte du club
create table public.aircraft (
  id            uuid primary key default gen_random_uuid(),
  registration  text not null unique,             -- immatriculation, ex. F-GXYZ
  model         text not null,                    -- ex. DR400-180
  seats         smallint not null check (seats in (2, 4)),
  active        boolean not null default true,
  notes         text,
  created_at    timestamptz not null default now()
);

-- Sorties
create table public.outings (
  id                      uuid primary key default gen_random_uuid(),
  title                   text not null check (length(btrim(title)) > 0),
  destination             text,
  description             text,
  meeting_point           text,
  departure_at            timestamptz not null,
  return_at               timestamptz,
  registration_deadline   timestamptz,
  instructor_id           uuid not null references public.profiles (id),
  -- Si renseigné : l'instructeur vole à bord de cet avion et y occupe un siège
  instructor_aircraft_id  uuid references public.aircraft (id),
  status                  public.outing_status not null default 'open',
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  check (return_at is null or return_at >= departure_at)
);

-- Avions affectés à une sortie
create table public.outing_aircraft (
  outing_id    uuid not null references public.outings (id) on delete cascade,
  aircraft_id  uuid not null references public.aircraft (id) on delete restrict,
  position     smallint not null default 0,
  primary key (outing_id, aircraft_id)
);

-- Inscriptions. L'ordre d'inscription (created_at) fait foi pour la liste d'attente.
create table public.registrations (
  id            uuid primary key default gen_random_uuid(),
  outing_id     uuid not null references public.outings (id) on delete cascade,
  user_id       uuid not null references public.profiles (id) on delete cascade,
  status        public.registration_status not null,
  aircraft_id   uuid references public.aircraft (id),
  created_at    timestamptz not null default clock_timestamp(),
  cancelled_at  timestamptz,
  created_by    uuid references public.profiles (id)
);

create unique index registrations_one_active_per_user
  on public.registrations (outing_id, user_id)
  where status <> 'cancelled';
create index registrations_outing_order on public.registrations (outing_id, created_at, id);
create index outings_departure on public.outings (departure_at);

-- ---------------------------------------------------------------------
-- Création automatique du profil à l'inscription
-- ---------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email, full_name, phone)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    nullif(new.raw_user_meta_data ->> 'phone', '')
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- Fonctions utilitaires de droits
-- ---------------------------------------------------------------------
create or replace function public.app_role()
returns public.user_role
language sql stable security definer set search_path = ''
as $$ select role from public.profiles where id = auth.uid() $$;

create or replace function public.is_staff()
returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce(public.app_role() in ('instructor', 'admin'), false) $$;

create or replace function public.is_approved()
returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce(public.app_role() <> 'pending', false) $$;

-- ---------------------------------------------------------------------
-- Cœur du système : (ré)attribution des places
--   Toutes les inscriptions actives sont triées par ordre d'inscription.
--   Les N premières (N = total des sièges disponibles) sont confirmées,
--   les suivantes sont en liste d'attente. Un inscrit confirmé garde son
--   avion tant que c'est possible.
--   Retourne la liste des personnes dont le statut a changé
--   (promoted = sortie de liste d'attente, demoted = repassé en attente).
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- Inscription à une sortie (un instructeur peut inscrire un autre membre)
-- ---------------------------------------------------------------------
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
  if v_target <> v_uid and not public.is_staff() then
    raise exception 'Seul un instructeur peut inscrire un autre membre.';
  end if;

  select * into v_outing from public.outings where id = p_outing for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  if v_outing.status = 'cancelled' then raise exception 'Cette sortie est annulée.'; end if;
  if v_outing.departure_at <= now() then raise exception 'Cette sortie a déjà eu lieu.'; end if;
  if v_outing.registration_deadline is not null and now() > v_outing.registration_deadline
     and not public.is_staff() then
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

-- ---------------------------------------------------------------------
-- Désinscription (par le membre lui-même ou par un instructeur)
-- ---------------------------------------------------------------------
create or replace function public.cancel_registration(p_registration uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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

  update public.registrations
     set status = 'cancelled', aircraft_id = null, cancelled_at = now()
   where id = p_registration;

  if v_outing.departure_at <= now() then
    return jsonb_build_object('changes', '[]'::jsonb);
  end if;
  return jsonb_build_object('changes', public._rebalance_outing(v_outing.id));
end;
$$;

-- ---------------------------------------------------------------------
-- Création / modification d'une sortie (instructeurs et admins)
-- ---------------------------------------------------------------------
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
  p_instructor_aircraft  uuid
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
begin
  if not public.is_staff() then
    raise exception 'Action réservée aux instructeurs.';
  end if;
  if p_title is null or length(btrim(p_title)) = 0 then raise exception 'Le titre est obligatoire.'; end if;
  if p_departure_at is null then raise exception 'La date de départ est obligatoire.'; end if;
  if p_return_at is not null and p_return_at < p_departure_at then
    raise exception 'Le retour doit être après le départ.';
  end if;
  if p_deadline is not null and p_deadline > p_departure_at then
    raise exception 'La date limite d''inscription doit précéder le départ.';
  end if;
  if coalesce(array_length(p_aircraft, 1), 0) = 0 then
    raise exception 'Sélectionnez au moins un avion.';
  end if;
  if (select count(distinct x) from unnest(p_aircraft) x) <> array_length(p_aircraft, 1) then
    raise exception 'Un avion est sélectionné deux fois.';
  end if;
  if (select count(*) from public.aircraft where id = any (p_aircraft)) <> array_length(p_aircraft, 1) then
    raise exception 'Avion inconnu.';
  end if;
  if p_instructor_aircraft is not null and not (p_instructor_aircraft = any (p_aircraft)) then
    raise exception 'L''avion de l''instructeur doit faire partie des avions de la sortie.';
  end if;

  if p_id is null then
    insert into public.outings (title, destination, description, meeting_point, departure_at,
                                return_at, registration_deadline, instructor_id, instructor_aircraft_id)
    values (btrim(p_title), nullif(btrim(p_destination), ''), nullif(btrim(p_description), ''),
            nullif(btrim(p_meeting_point), ''), p_departure_at, p_return_at, p_deadline,
            v_uid, p_instructor_aircraft)
    returning * into v_outing;
  else
    select * into v_outing from public.outings where id = p_id for update;
    if not found then raise exception 'Sortie introuvable.'; end if;
    if v_outing.status = 'cancelled' then raise exception 'Sortie annulée : modification impossible.'; end if;

    update public.outings set
      title = btrim(p_title),
      destination = nullif(btrim(p_destination), ''),
      description = nullif(btrim(p_description), ''),
      meeting_point = nullif(btrim(p_meeting_point), ''),
      departure_at = p_departure_at,
      return_at = p_return_at,
      registration_deadline = p_deadline,
      instructor_aircraft_id = p_instructor_aircraft,
      updated_at = now()
    where id = p_id
    returning * into v_outing;

    delete from public.outing_aircraft
     where outing_id = p_id and not (aircraft_id = any (p_aircraft));
  end if;

  -- L'instructeur qui vole n'est pas aussi un "passager" inscrit
  if p_instructor_aircraft is not null then
    update public.registrations
       set status = 'cancelled', aircraft_id = null, cancelled_at = now()
     where outing_id = v_outing.id and user_id = v_outing.instructor_id and status <> 'cancelled';
  end if;

  for v_i in 1 .. array_length(p_aircraft, 1) loop
    insert into public.outing_aircraft (outing_id, aircraft_id, position)
    values (v_outing.id, p_aircraft[v_i], v_i)
    on conflict (outing_id, aircraft_id) do update set position = excluded.position;
  end loop;

  return jsonb_build_object('outing_id', v_outing.id,
                            'changes', public._rebalance_outing(v_outing.id));
end;
$$;

-- ---------------------------------------------------------------------
-- Annulation d'une sortie (retourne les inscrits à prévenir)
-- ---------------------------------------------------------------------
create or replace function public.cancel_outing(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_outing public.outings;
begin
  if not public.is_staff() then raise exception 'Action réservée aux instructeurs.'; end if;
  select * into v_outing from public.outings where id = p_id for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  if v_outing.status = 'cancelled' then raise exception 'Sortie déjà annulée.'; end if;

  update public.outings set status = 'cancelled', updated_at = now() where id = p_id;

  return jsonb_build_object('recipients', coalesce((
    select jsonb_agg(jsonb_build_object('user_id', p.id, 'email', p.email, 'full_name', p.full_name))
    from public.registrations r join public.profiles p on p.id = r.user_id
    where r.outing_id = p_id and r.status <> 'cancelled'), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------
-- Lecture : liste des sorties
-- ---------------------------------------------------------------------
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
             (select coalesce(sum(greatest(a.seats - case when a.id = o.instructor_aircraft_id then 1 else 0 end, 0)), 0)
                from public.outing_aircraft oa join public.aircraft a on a.id = oa.aircraft_id
               where oa.outing_id = o.id) as total_capacity,
             (select count(*) from public.registrations r
               where r.outing_id = o.id and r.status = 'confirmed') as confirmed_count,
             (select count(*) from public.registrations r
               where r.outing_id = o.id and r.status = 'waitlist') as waitlist_count,
             (select string_agg(a.registration || ' (' || a.seats || 'pl.)', ', ' order by oa.position)
                from public.outing_aircraft oa join public.aircraft a on a.id = oa.aircraft_id
               where oa.outing_id = o.id) as aircraft_summary,
             (select r.status from public.registrations r
               where r.outing_id = o.id and r.user_id = v_uid and r.status <> 'cancelled') as my_status,
             (o.instructor_id = v_uid) as i_am_instructor
      from public.outings o
      join public.profiles ip on ip.id = o.instructor_id
      where case when p_past
                 then coalesce(o.return_at, o.departure_at) < now()
                 else coalesce(o.return_at, o.departure_at) >= now() end
      limit 200
    ) t), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------
-- Lecture : détail d'une sortie (avions, occupants, liste d'attente)
-- ---------------------------------------------------------------------
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
                                     'phone', ip.phone),
    'can_manage', v_staff,
    'aircraft', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', a.id, 'registration', a.registration, 'model', a.model, 'seats', a.seats,
               'instructor_onboard', a.id = o.instructor_aircraft_id,
               'capacity', greatest(a.seats - case when a.id = o.instructor_aircraft_id then 1 else 0 end, 0),
               'occupants', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'registration_id', r.id, 'user_id', p.id, 'full_name', p.full_name,
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
               'phone', case when v_staff or w.user_id = v_uid then w.phone end,
               'position', w.pos) order by w.pos)
      from (select r.id, r.user_id, p.full_name, p.phone,
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

-- ---------------------------------------------------------------------
-- Gestion des membres
-- ---------------------------------------------------------------------
create or replace function public.set_user_role(p_user uuid, p_role public.user_role)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  if p_user = auth.uid() then
    raise exception 'Vous ne pouvez pas modifier votre propre rôle.';
  end if;
  update public.profiles set role = p_role where id = p_user;
end;
$$;

-- ---------------------------------------------------------------------
-- Sécurité : RLS + droits
-- ---------------------------------------------------------------------
alter table public.profiles        enable row level security;
alter table public.aircraft        enable row level security;
alter table public.outings         enable row level security;
alter table public.outing_aircraft enable row level security;
alter table public.registrations   enable row level security;

-- Profils : chacun voit le sien, les instructeurs voient tout le monde
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_staff());
create policy profiles_update_self on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
revoke update on public.profiles from authenticated, anon;
grant update (full_name, phone) on public.profiles to authenticated;

-- Flotte : lecture par les membres validés, écriture par les instructeurs
create policy aircraft_select on public.aircraft for select to authenticated
  using (public.is_approved());
create policy aircraft_insert on public.aircraft for insert to authenticated
  with check (public.is_staff());
create policy aircraft_update on public.aircraft for update to authenticated
  using (public.is_staff()) with check (public.is_staff());
create policy aircraft_delete on public.aircraft for delete to authenticated
  using (public.is_staff());

-- Sorties / avions de sortie / inscriptions : lecture seule directe,
-- toutes les écritures passent par les fonctions ci-dessus.
create policy outings_select on public.outings for select to authenticated
  using (public.is_approved());
create policy outing_aircraft_select on public.outing_aircraft for select to authenticated
  using (public.is_approved());
create policy registrations_select on public.registrations for select to authenticated
  using (public.is_approved());

revoke all on public.outings, public.outing_aircraft, public.registrations from anon;
revoke insert, update, delete on public.outings, public.outing_aircraft, public.registrations from authenticated;
revoke all on public.profiles, public.aircraft from anon;

-- Fonctions : pas d'accès anonyme ; la fonction interne n'est pas exposée
revoke execute on function public._rebalance_outing(uuid) from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.register_for_outing(uuid, uuid) from public, anon;
revoke execute on function public.cancel_registration(uuid) from public, anon;
revoke execute on function public.save_outing(uuid, text, text, text, text, timestamptz, timestamptz, timestamptz, uuid[], uuid) from public, anon;
revoke execute on function public.cancel_outing(uuid) from public, anon;
revoke execute on function public.list_outings(boolean) from public, anon;
revoke execute on function public.get_outing(uuid) from public, anon;
revoke execute on function public.set_user_role(uuid, public.user_role) from public, anon;

grant execute on function public.register_for_outing(uuid, uuid) to authenticated;
grant execute on function public.cancel_registration(uuid) to authenticated;
grant execute on function public.save_outing(uuid, text, text, text, text, timestamptz, timestamptz, timestamptz, uuid[], uuid) to authenticated;
grant execute on function public.cancel_outing(uuid) to authenticated;
grant execute on function public.list_outings(boolean) to authenticated;
grant execute on function public.get_outing(uuid) to authenticated;
grant execute on function public.set_user_role(uuid, public.user_role) to authenticated;

-- =====================================================================
--  Comptes créés avant l'installation de la base : on leur crée un profil
-- =====================================================================
insert into public.profiles (id, email, full_name, phone)
select u.id, coalesce(u.email, ''), coalesce(u.raw_user_meta_data ->> 'full_name', ''),
       nullif(u.raw_user_meta_data ->> 'phone', '')
from auth.users u
on conflict (id) do nothing;

-- Premier administrateur
update public.profiles set role = 'admin' where email = 'guillaumecassisa@gmail.com';

select full_name, email, role from public.profiles;
