-- =====================================================================
--  INSTALLATION COMPLÈTE d'un nouveau site (projet Supabase vide)
--  = schéma de base + toutes les mises à jour (n°2 à n°41).
--  Supabase > SQL Editor > New query > coller tout le fichier > Run.
--  Ensuite (facultatif) : nouveau-club-vider-exemples.sql pour retirer
--  les données d'exemple (avions, bar, liens, bons plans, shop de l'AFPA).
--  Guide : docs/NOUVEAU-CLUB.md
--  Fichier généré par scripts/assembler-sql.sh : ne pas le modifier à la main.
-- =====================================================================

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
-- Base déjà en service : ses données d'exemple sont déjà en place, on ne les repose jamais.
do $boot$ begin
  if to_regclass('public._seeds') is null and exists (select 1 from public.profiles) then
    create table public._seeds (name text primary key, done_at timestamptz not null default now());
    insert into public._seeds (name)
    select unnest(array['bar-04', 'avions-08', 'bar-12', 'avions-19', 'liens-19', 'centrage-20', 'centrage-21',
                        'bar-22', 'bons-plans-23', 'shop-25', 'centrage-26']);
  end if;
end $boot$;


-- =====================================================================
-- migration-02-profil.sql
-- =====================================================================
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


-- =====================================================================
-- migration-03-lachers-par-type.sql
-- =====================================================================
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


-- =====================================================================
-- migration-04-bar.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°4 : le Bar de l'aéroclub
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- Données d'exemple : posées une seule fois, à la première installation.
-- Relancer ce fichier plus tard ne les recrée pas et ne touche pas aux données saisies sur le site.
create table if not exists public._seeds (name text primary key, done_at timestamptz not null default now());
alter table public._seeds enable row level security;
revoke all on public._seeds from public, anon, authenticated;
create or replace function public._seed_once(p_name text)
returns boolean language plpgsql set search_path = '' as $fn$
begin
  insert into public._seeds (name) values (p_name) on conflict (name) do nothing;
  return found;
end;
$fn$;
revoke execute on function public._seed_once(text) from public, anon, authenticated;

-- 1. Trésorier : un membre (de n'importe quel rôle) désigné par un admin --
alter table public.profiles add column if not exists is_treasurer boolean not null default false;

create or replace function public.is_treasurer()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select is_treasurer or role = 'admin' from public.profiles where id = auth.uid()), false)
$$;

create or replace function public.set_treasurer(p_user uuid, p_value boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  update public.profiles set is_treasurer = p_value where id = p_user;
end;
$$;

-- 2. Carte du bar ---------------------------------------------------------
create table if not exists public.bar_products (
  id           uuid primary key default gen_random_uuid(),
  name         text not null check (length(btrim(name)) > 0),
  price_cents  integer not null check (price_cents >= 0),
  active       boolean not null default true,
  position     smallint not null default 0,
  created_at   timestamptz not null default now()
);

do $seed$ begin
  if not public._seed_once('bar-04') then return; end if;
insert into public.bar_products (name, price_cents, position)
select * from (values ('Tourtel', 200, 1), ('Bière', 300, 2), ('Coca', 100, 3), ('Eau', 50, 4)) v(name, price, pos)
where not exists (select 1 from public.bar_products);
end $seed$;

-- 3. Consommations (le prix est figé au moment de la consommation) --------
create table if not exists public.bar_consumptions (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles (id) on delete cascade,
  product_id        uuid references public.bar_products (id) on delete set null,
  product_name      text not null,
  unit_price_cents  integer not null,
  quantity          smallint not null check (quantity between 1 and 50),
  created_at        timestamptz not null default now(),
  created_by        uuid references public.profiles (id)
);
create index if not exists bar_consumptions_user_date on public.bar_consumptions (user_id, created_at);
create index if not exists bar_consumptions_date on public.bar_consumptions (created_at);

-- 4. Règlements mensuels (coché par le trésorier) -------------------------
create table if not exists public.bar_settlements (
  user_id    uuid not null references public.profiles (id) on delete cascade,
  month      date not null check (extract(day from month) = 1),
  paid_at    timestamptz not null default now(),
  paid_by    uuid references public.profiles (id),
  primary key (user_id, month)
);

-- Mois "comptable" d'une consommation, à l'heure de Paris
create or replace function public.bar_month_of(ts timestamptz)
returns date language sql immutable
as $$ select date_trunc('month', ts at time zone 'Europe/Paris')::date $$;

-- 5. Droits ---------------------------------------------------------------
alter table public.bar_products     enable row level security;
alter table public.bar_consumptions enable row level security;
alter table public.bar_settlements  enable row level security;

drop policy if exists bar_products_select on public.bar_products;
create policy bar_products_select on public.bar_products for select to authenticated
  using (public.is_approved());
drop policy if exists bar_products_write on public.bar_products;
create policy bar_products_write on public.bar_products for all to authenticated
  using (public.is_treasurer()) with check (public.is_treasurer());

drop policy if exists bar_consumptions_select on public.bar_consumptions;
create policy bar_consumptions_select on public.bar_consumptions for select to authenticated
  using (user_id = auth.uid() or public.is_treasurer());

drop policy if exists bar_settlements_select on public.bar_settlements;
create policy bar_settlements_select on public.bar_settlements for select to authenticated
  using (user_id = auth.uid() or public.is_treasurer());

revoke all on public.bar_products, public.bar_consumptions, public.bar_settlements from anon;
revoke insert, update, delete on public.bar_consumptions, public.bar_settlements from authenticated;
grant select on public.bar_consumptions, public.bar_settlements to authenticated;
grant select, insert, update, delete on public.bar_products to authenticated;
revoke update on public.profiles from authenticated;
grant update (full_name, phone, avatar_url, address, emergency_name, emergency_phone)
  on public.profiles to authenticated;

-- 6. Enregistrer / annuler une consommation -------------------------------
create or replace function public.add_consumption(p_product uuid, p_quantity integer default 1, p_user uuid default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_target uuid := coalesce(p_user, auth.uid());
  v_prod   public.bar_products;
  v_id     uuid;
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  if v_target <> v_uid and not public.is_treasurer() then
    raise exception 'Seul le trésorier peut enregistrer pour un autre membre.';
  end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 50 then
    raise exception 'Quantité invalide.';
  end if;
  select * into v_prod from public.bar_products where id = p_product;
  if not found or not v_prod.active then raise exception 'Boisson indisponible.'; end if;

  insert into public.bar_consumptions (user_id, product_id, product_name, unit_price_cents, quantity, created_by)
  values (v_target, v_prod.id, v_prod.name, v_prod.price_cents, p_quantity, v_uid)
  returning id into v_id;
  return v_id;
end;
$$;

-- Un membre peut annuler une erreur dans les 30 minutes ; le trésorier toujours
-- (sauf si le mois est déjà réglé).
create or replace function public.cancel_consumption(p_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_c public.bar_consumptions;
begin
  select * into v_c from public.bar_consumptions where id = p_id;
  if not found then raise exception 'Consommation introuvable.'; end if;
  if not public.is_treasurer() then
    if v_c.user_id <> auth.uid() then raise exception 'Action non autorisée.'; end if;
    if v_c.created_at < now() - interval '30 minutes' then
      raise exception 'Trop tard pour annuler : demandez au trésorier.';
    end if;
  end if;
  if exists (select 1 from public.bar_settlements s
             where s.user_id = v_c.user_id and s.month = public.bar_month_of(v_c.created_at)) then
    raise exception 'Ce mois est déjà réglé : annulation impossible.';
  end if;
  delete from public.bar_consumptions where id = p_id;
end;
$$;

-- 7. Trésorerie : totaux du mois par membre -------------------------------
create or replace function public.bar_month_summary(p_month date)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_month date := date_trunc('month', p_month)::date;
begin
  if not public.is_treasurer() then raise exception 'Réservé au trésorier.'; end if;

  return jsonb_build_object(
    'month', v_month,
    'total_cents', coalesce((select sum(unit_price_cents * quantity) from public.bar_consumptions
                             where public.bar_month_of(created_at) = v_month), 0),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object('name', product_name, 'quantity', q, 'total_cents', t) order by product_name)
      from (select product_name, sum(quantity) q, sum(unit_price_cents * quantity) t
            from public.bar_consumptions where public.bar_month_of(created_at) = v_month
            group by product_name) x), '[]'::jsonb),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
               'user_id', p.id, 'full_name', p.full_name, 'email', p.email, 'avatar_url', p.avatar_url,
               'total_cents', m.total, 'items', m.items,
               'paid', s.user_id is not null, 'paid_at', s.paid_at) order by p.full_name)
      from (
        select user_id, sum(t) total,
               jsonb_object_agg(product_name, q order by product_name) items
        from (select user_id, product_name, sum(quantity) q, sum(unit_price_cents * quantity) t
              from public.bar_consumptions where public.bar_month_of(created_at) = v_month
              group by user_id, product_name) y
        group by user_id
      ) m
      join public.profiles p on p.id = m.user_id
      left join public.bar_settlements s on s.user_id = m.user_id and s.month = v_month), '[]'::jsonb)
  );
end;
$$;

create or replace function public.set_bar_paid(p_user uuid, p_month date, p_paid boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_month date := date_trunc('month', p_month)::date;
begin
  if not public.is_treasurer() then raise exception 'Réservé au trésorier.'; end if;
  if p_paid then
    insert into public.bar_settlements (user_id, month, paid_by) values (p_user, v_month, auth.uid())
    on conflict (user_id, month) do nothing;
  else
    delete from public.bar_settlements where user_id = p_user and month = v_month;
  end if;
end;
$$;

revoke execute on function public.set_treasurer(uuid, boolean) from public, anon;
revoke execute on function public.add_consumption(uuid, integer, uuid) from public, anon;
revoke execute on function public.cancel_consumption(uuid) from public, anon;
revoke execute on function public.bar_month_summary(date) from public, anon;
revoke execute on function public.set_bar_paid(uuid, date, boolean) from public, anon;
grant execute on function public.set_treasurer(uuid, boolean) to authenticated;
grant execute on function public.add_consumption(uuid, integer, uuid) to authenticated;
grant execute on function public.cancel_consumption(uuid) to authenticated;
grant execute on function public.bar_month_summary(date) to authenticated;
grant execute on function public.set_bar_paid(uuid, date, boolean) to authenticated;

-- Rafraîchit l'API
notify pgrst, 'reload schema';


-- =====================================================================
-- migration-05-annuaire.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°5 : annuaire des membres (nom, téléphone, lâchers)
--  Visible par tous les membres validés. L'adresse et la personne à
--  prévenir restent réservées aux instructeurs et administrateurs.
-- =====================================================================
create or replace function public.member_directory()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id, 'full_name', p.full_name, 'phone', p.phone, 'avatar_url', p.avatar_url,
             'role', p.role,
             'types', coalesce((select jsonb_agg(pt.aircraft_type order by pt.aircraft_type)
                                from public.pilot_types pt where pt.user_id = p.id), '[]'::jsonb))
           order by lower(p.full_name))
    from public.profiles p
    where p.role <> 'pending'), '[]'::jsonb);
end;
$$;

revoke execute on function public.member_directory() from public, anon;
grant execute on function public.member_directory() to authenticated;

-- Rafraîchit l'API
notify pgrst, 'reload schema';


-- =====================================================================
-- migration-06-propositions.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°6 : propositions de sorties par les membres
--  Un membre propose ; un instructeur ou un administrateur approuve
--  (ou refuse) avant publication.
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

alter table public.outings
  add column if not exists approval text not null default 'approved'
    check (approval in ('pending', 'approved', 'rejected')),
  add column if not exists rejection_reason text,
  add column if not exists approved_by uuid references public.profiles (id),
  add column if not exists approved_at timestamptz;

-- Les membres ne voient que les sorties publiées (et leurs propres propositions)
drop policy if exists outings_select on public.outings;
create policy outings_select on public.outings for select to authenticated
  using (public.is_approved() and (approval = 'approved' or instructor_id = auth.uid() or public.is_staff()));

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
  v_staff  boolean;
  v_notify jsonb := '[]'::jsonb;
begin
  v_staff := public.is_staff();
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
                                return_at, registration_deadline, instructor_id, instructor_aircraft_id,
                                approval, approved_by, approved_at)
    values (btrim(p_title), nullif(btrim(p_destination), ''), nullif(btrim(p_description), ''),
            nullif(btrim(p_meeting_point), ''), p_departure_at, p_return_at, p_deadline,
            v_uid, p_instructor_aircraft,
            case when v_staff then 'approved' else 'pending' end,
            case when v_staff then v_uid end, case when v_staff then now() end)
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
      raise exception 'Seul un instructeur peut modifier une sortie publiée.';
    end if;

    update public.outings set
      title = btrim(p_title),
      destination = nullif(btrim(p_destination), ''),
      description = nullif(btrim(p_description), ''),
      meeting_point = nullif(btrim(p_meeting_point), ''),
      departure_at = p_departure_at,
      return_at = p_return_at,
      registration_deadline = p_deadline,
      instructor_aircraft_id = p_instructor_aircraft,
      -- une proposition refusée puis corrigée repart en validation
      approval = case when approval = 'rejected' then 'pending' else approval end,
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
  if v_target <> v_uid and not public.is_staff() then
    raise exception 'Seul un instructeur peut inscrire un autre membre.';
  end if;

  select * into v_outing from public.outings where id = p_outing for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  if v_outing.status = 'cancelled' then raise exception 'Cette sortie est annulée.'; end if;
  if v_outing.approval <> 'approved' then raise exception 'Cette sortie n''a pas encore été validée par un instructeur.'; end if;
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
             (o.instructor_id = v_uid) as i_am_instructor,
             o.approval, o.rejection_reason
      from public.outings o
      join public.profiles ip on ip.id = o.instructor_id
      where (o.approval = 'approved' or o.instructor_id = v_uid or public.is_staff())
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
  if not public.is_staff() and not (v_outing.instructor_id = auth.uid() and v_outing.approval <> 'approved') then
    raise exception 'Action réservée aux instructeurs.';
  end if;
  if v_outing.status = 'cancelled' then raise exception 'Sortie déjà annulée.'; end if;

  update public.outings set status = 'cancelled', updated_at = now() where id = p_id;

  return jsonb_build_object('recipients', coalesce((
    select jsonb_agg(jsonb_build_object('user_id', p.id, 'email', p.email, 'full_name', p.full_name))
    from public.registrations r join public.profiles p on p.id = r.user_id
    where r.outing_id = p_id and r.status <> 'cancelled'), '[]'::jsonb));
end;
$$;

-- Validation par un instructeur / administrateur
create or replace function public.review_outing(p_id uuid, p_approve boolean, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_outing public.outings;
begin
  if not public.is_staff() then raise exception 'Action réservée aux instructeurs.'; end if;
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

revoke execute on function public.review_outing(uuid, boolean, text) from public, anon;
grant execute on function public.review_outing(uuid, boolean, text) to authenticated;

-- Rafraîchit l'API
notify pgrst, 'reload schema';


-- =====================================================================
-- migration-07-poids.sql
-- =====================================================================
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


-- =====================================================================
-- migration-08-roles-annonces.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°8 : trésorier (seul accès aux comptes du bar),
--  secrétaire (administrateur complet), annonces du club.
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- Données d'exemple : posées une seule fois, à la première installation.
-- Relancer ce fichier plus tard ne les recrée pas et ne touche pas aux données saisies sur le site.
create table if not exists public._seeds (name text primary key, done_at timestamptz not null default now());
alter table public._seeds enable row level security;
revoke all on public._seeds from public, anon, authenticated;
create or replace function public._seed_once(p_name text)
returns boolean language plpgsql set search_path = '' as $fn$
begin
  insert into public._seeds (name) values (p_name) on conflict (name) do nothing;
  return found;
end;
$fn$;
revoke execute on function public._seed_once(text) from public, anon, authenticated;

-- 1. Trésorier : seule la personne nommée voit les consommations de tous
create or replace function public.is_treasurer()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select is_treasurer from public.profiles where id = auth.uid() and role <> 'pending'), false)
$$;

-- 2. Secrétaire = administrateur complet, avec son titre
alter table public.profiles add column if not exists is_secretary boolean not null default false;

create or replace function public.set_secretary(p_user uuid, p_value boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  if p_value then
    update public.profiles set is_secretary = true, role = 'admin' where id = p_user;
  else
    update public.profiles set is_secretary = false where id = p_user;
  end if;
end;
$$;
revoke execute on function public.set_secretary(uuid, boolean) from public, anon;
grant execute on function public.set_secretary(uuid, boolean) to authenticated;

-- 3. Annonces
create table if not exists public.announcements (
  id          uuid primary key default gen_random_uuid(),
  title       text not null check (length(btrim(title)) between 1 and 120),
  body        text check (body is null or length(body) <= 2000),
  important   boolean not null default false,
  expires_at  timestamptz,
  created_by  uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at  timestamptz not null default now()
);
alter table public.announcements enable row level security;

drop policy if exists announcements_select on public.announcements;
create policy announcements_select on public.announcements for select to authenticated
  using (public.is_approved());
drop policy if exists announcements_insert on public.announcements;
create policy announcements_insert on public.announcements for insert to authenticated
  with check (public.is_staff());
drop policy if exists announcements_delete on public.announcements;
create policy announcements_delete on public.announcements for delete to authenticated
  using (public.is_staff());

revoke all on public.announcements from anon;
revoke update on public.announcements from authenticated;
grant select, insert, delete on public.announcements to authenticated;

-- 4. Disponibilité des avions (en maintenance, immobilisé…), distincte de « actif »
alter table public.aircraft add column if not exists available boolean not null default true;
alter table public.aircraft add column if not exists unavailable_reason text;
grant update (available, unavailable_reason) on public.aircraft to authenticated;

-- 5. Avions du club
do $seed$ begin
  if not public._seed_once('avions-08') then return; end if;
insert into public.aircraft (registration, model, type, seats, available) values
  ('F-HVXD', 'WT9 Dynamic', 'WT9', 2, false),
  ('F-HUIT', 'PS28 Cruiser', 'PS28', 2, false),
  ('F-HUFA', 'B23', 'B23', 2, false)
on conflict (registration) do update
  set model = excluded.model, type = excluded.type, seats = excluded.seats, active = true;
end $seed$;

notify pgrst, 'reload schema';


-- =====================================================================
-- migration-09-maintenance.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°9 : responsable maintenance.
--  La flotte (ajout d'avion, disponibilité, types) est réservée aux
--  administrateurs et aux responsables maintenance.
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

alter table public.profiles add column if not exists is_maintenance boolean not null default false;
alter table public.aircraft add column if not exists available boolean not null default true;
alter table public.aircraft add column if not exists unavailable_reason text;

create or replace function public.can_manage_fleet()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select role = 'admin' or (is_maintenance and role <> 'pending')
                   from public.profiles where id = auth.uid()), false)
$$;

create or replace function public.set_maintenance(p_user uuid, p_value boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  update public.profiles set is_maintenance = p_value where id = p_user;
end;
$$;

drop policy if exists aircraft_insert on public.aircraft;
create policy aircraft_insert on public.aircraft for insert to authenticated
  with check (public.can_manage_fleet());
drop policy if exists aircraft_update on public.aircraft;
create policy aircraft_update on public.aircraft for update to authenticated
  using (public.can_manage_fleet()) with check (public.can_manage_fleet());
drop policy if exists aircraft_delete on public.aircraft;
create policy aircraft_delete on public.aircraft for delete to authenticated
  using (public.can_manage_fleet());

-- Disponibilité d'un avion (renvoie une erreur claire si refusé)
create or replace function public.set_aircraft_availability(p_id uuid, p_available boolean, p_reason text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.can_manage_fleet() then
    raise exception 'Réservé aux administrateurs et aux responsables maintenance.';
  end if;
  update public.aircraft
     set available = p_available,
         unavailable_reason = case when p_available then null else nullif(btrim(coalesce(p_reason, '')), '') end
   where id = p_id;
  if not found then raise exception 'Avion introuvable.'; end if;
end;
$$;

revoke execute on function public.set_maintenance(uuid, boolean) from public, anon;
grant execute on function public.set_maintenance(uuid, boolean) to authenticated;
revoke execute on function public.set_aircraft_availability(uuid, boolean, text) from public, anon;
grant execute on function public.set_aircraft_availability(uuid, boolean, text) to authenticated;
grant execute on function public.can_manage_fleet() to authenticated;

notify pgrst, 'reload schema';


-- =====================================================================
-- migration-10-documents-avions.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°10 : documentation des avions (onglet « Flotte »).
--  Lecture : tous les membres validés.
--  Ajout / suppression : administrateurs et responsables maintenance.
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

create table if not exists public.aircraft_documents (
  id           uuid primary key default gen_random_uuid(),
  aircraft_id  uuid not null references public.aircraft (id) on delete cascade,
  category     text not null default 'autre'
               check (category in ('manuel','checklist','masse_centrage','performances','procedures','administratif','maintenance','autre')),
  title        text not null check (length(btrim(title)) between 1 and 200),
  file_path    text not null unique,
  file_name    text not null,
  mime_type    text,
  size_bytes   bigint,
  created_by   uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at   timestamptz not null default now()
);
create index if not exists aircraft_documents_aircraft on public.aircraft_documents (aircraft_id, category, title);

alter table public.aircraft_documents enable row level security;

drop policy if exists aircraft_documents_select on public.aircraft_documents;
create policy aircraft_documents_select on public.aircraft_documents for select to authenticated
  using (public.is_approved());
drop policy if exists aircraft_documents_insert on public.aircraft_documents;
create policy aircraft_documents_insert on public.aircraft_documents for insert to authenticated
  with check (public.can_manage_fleet());
drop policy if exists aircraft_documents_update on public.aircraft_documents;
create policy aircraft_documents_update on public.aircraft_documents for update to authenticated
  using (public.can_manage_fleet()) with check (public.can_manage_fleet());
drop policy if exists aircraft_documents_delete on public.aircraft_documents;
create policy aircraft_documents_delete on public.aircraft_documents for delete to authenticated
  using (public.can_manage_fleet());

revoke all on public.aircraft_documents from anon;
grant select, insert, update, delete on public.aircraft_documents to authenticated;

-- Fichiers : dossier privé « aircraft-docs » (50 Mo max par fichier)
do $$
begin
  insert into storage.buckets (id, name, public, file_size_limit)
  values ('aircraft-docs', 'aircraft-docs', false, 52428800)
  on conflict (id) do update set public = false, file_size_limit = 52428800;
exception when others then raise notice 'bucket aircraft-docs : %', sqlerrm;
end $$;

do $$
begin
  execute 'drop policy if exists aircraft_docs_select on storage.objects';
  execute 'create policy aircraft_docs_select on storage.objects for select to authenticated using (bucket_id = ''aircraft-docs'' and public.is_approved())';
  execute 'drop policy if exists aircraft_docs_insert on storage.objects';
  execute 'create policy aircraft_docs_insert on storage.objects for insert to authenticated with check (bucket_id = ''aircraft-docs'' and public.can_manage_fleet())';
  execute 'drop policy if exists aircraft_docs_update on storage.objects';
  execute 'create policy aircraft_docs_update on storage.objects for update to authenticated using (bucket_id = ''aircraft-docs'' and public.can_manage_fleet())';
  execute 'drop policy if exists aircraft_docs_delete on storage.objects';
  execute 'create policy aircraft_docs_delete on storage.objects for delete to authenticated using (bucket_id = ''aircraft-docs'' and public.can_manage_fleet())';
exception when others then raise notice 'règles documents : %', sqlerrm;
end $$;

notify pgrst, 'reload schema';


-- =====================================================================
-- migration-11-evenements.sql
-- =====================================================================
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


-- =====================================================================
-- migration-12-bar-sections.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°12 : carte du bar en deux sections (Boissons / Snacks).
--  Prix provisoires, modifiables par le trésorier (Mon compte → Trésorerie).
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- Données d'exemple : posées une seule fois, à la première installation.
-- Relancer ce fichier plus tard ne les recrée pas et ne touche pas aux données saisies sur le site.
create table if not exists public._seeds (name text primary key, done_at timestamptz not null default now());
alter table public._seeds enable row level security;
revoke all on public._seeds from public, anon, authenticated;
create or replace function public._seed_once(p_name text)
returns boolean language plpgsql set search_path = '' as $fn$
begin
  insert into public._seeds (name) values (p_name) on conflict (name) do nothing;
  return found;
end;
$fn$;
revoke execute on function public._seed_once(text) from public, anon, authenticated;

alter table public.bar_products add column if not exists category text not null default 'boissons';
alter table public.bar_products drop constraint if exists bar_products_category_check;
alter table public.bar_products add constraint bar_products_category_check check (category in ('boissons', 'snacks'));

do $seed$ begin
  if not public._seed_once('bar-12') then return; end if;
-- Carte : on ajoute ce qui manque (sans toucher aux prix déjà saisis)
insert into public.bar_products (name, price_cents, position, category)
select v.name, v.price, v.pos, v.cat
from (values
  ('Tourtel',       200,  1, 'boissons'),
  ('Panaché',       250,  2, 'boissons'),
  ('Desperados',    350,  3, 'boissons'),
  ('BrewDog IPA',   400,  4, 'boissons'),
  ('KitKat',        150, 11, 'snacks'),
  ('Kinder Bueno',  150, 12, 'snacks'),
  ('Mars',          150, 13, 'snacks'),
  ('Snickers',      150, 14, 'snacks')
) v(name, price, pos, cat)
where not exists (select 1 from public.bar_products p where lower(p.name) = lower(v.name));

update public.bar_products set category = 'snacks', active = true
 where lower(name) in ('kitkat', 'kinder bueno', 'mars', 'snickers');
update public.bar_products set category = 'boissons', active = true
 where lower(name) in ('tourtel', 'panaché', 'desperados', 'brewdog ipa');
-- Anciennes boissons retirées de la carte (l'historique des consommations est conservé)
update public.bar_products set active = false where lower(name) in ('bière', 'coca', 'eau');
end $seed$;

notify pgrst, 'reload schema';


-- =====================================================================
-- migration-13-fonctions.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°13 : tout le monde est « Membre » ; Instructeur et
--  Administrateur deviennent des fonctions, comme Trésorier, Secrétaire,
--  Membre du CA et Responsable maintenance.
--  (La colonne role reste le niveau de droits calculé automatiquement.)
-- =====================================================================
alter table public.profiles add column if not exists is_instructor boolean not null default false;
update public.profiles set is_instructor = true where role = 'instructor' and not is_instructor;

create or replace function public.set_function(p_user uuid, p_function text, p_value boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v public.profiles%rowtype;
  v_admin boolean;
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  select * into v from public.profiles where id = p_user for update;
  if not found then raise exception 'Membre introuvable.'; end if;
  if v.role = 'pending' then
    raise exception 'Validez d''abord ce compte avant de lui attribuer une fonction.';
  end if;

  v_admin := v.role = 'admin';
  case p_function
    when 'admin' then
      if not p_value and p_user = auth.uid() then
        raise exception 'Vous ne pouvez pas retirer vos propres droits administrateur.';
      end if;
      v_admin := p_value;
      if not p_value then v.is_secretary := false; end if;
    when 'secretaire' then
      if not p_value and p_user = auth.uid() then
        raise exception 'Demandez à un autre administrateur de vous retirer le titre de secrétaire.';
      end if;
      v.is_secretary := p_value;
      if p_value then v_admin := true; end if;
    when 'instructeur' then v.is_instructor := p_value;
    when 'ca'          then v.is_board := p_value;
    when 'tresorier'   then v.is_treasurer := p_value;
    when 'maintenance' then v.is_maintenance := p_value;
    else raise exception 'Fonction inconnue : %', p_function;
  end case;

  update public.profiles set
    is_instructor  = v.is_instructor,
    is_board       = v.is_board,
    is_treasurer   = v.is_treasurer,
    is_maintenance = v.is_maintenance,
    is_secretary   = v.is_secretary,
    role = case when v_admin then 'admin'::public.user_role
                when v.is_instructor then 'instructor'::public.user_role
                else 'member'::public.user_role end
  where id = p_user;
end;
$$;
revoke execute on function public.set_function(uuid, text, boolean) from public, anon;
grant execute on function public.set_function(uuid, text, boolean) to authenticated;

-- Annuaire : le badge « Instructeur » suit la fonction
create or replace function public.member_directory()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id, 'full_name', p.full_name, 'phone', p.phone, 'avatar_url', p.avatar_url,
             'role', p.role, 'is_instructor', p.is_instructor,
             'types', coalesce((select jsonb_agg(pt.aircraft_type order by pt.aircraft_type)
                                from public.pilot_types pt where pt.user_id = p.id), '[]'::jsonb))
           order by lower(p.full_name))
    from public.profiles p
    where p.role <> 'pending'), '[]'::jsonb);
end;
$$;
revoke execute on function public.member_directory() from public, anon;
grant execute on function public.member_directory() to authenticated;

notify pgrst, 'reload schema';


-- =====================================================================
-- migration-14-mail-evenements.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°14 : email à tous les membres quand un événement est
--  publié (chacun peut se désabonner dans « Mon compte »).
-- =====================================================================
alter table public.profiles add column if not exists notify_events boolean not null default true;

-- Destinataires : membres validés, abonnés, sauf la personne qui publie.
-- Réservé aux organisateurs, et seulement pour un événement publié.
create or replace function public.event_mail_recipients(p_outing uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.can_organize() then
    raise exception 'Action réservée aux organisateurs.';
  end if;
  if not exists (select 1 from public.outings where id = p_outing and approval = 'approved' and status = 'open') then
    return '[]'::jsonb;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('email', p.email, 'full_name', p.full_name))
    from public.profiles p
    where p.role <> 'pending' and p.notify_events and coalesce(p.email, '') <> ''
      and p.id is distinct from auth.uid()), '[]'::jsonb);
end;
$$;
revoke execute on function public.event_mail_recipients(uuid) from public, anon;
grant execute on function public.event_mail_recipients(uuid) to authenticated;

create or replace function public.set_event_notifications(p_value boolean)
returns void
language sql security definer set search_path = ''
as $$
  update public.profiles set notify_events = p_value where id = auth.uid();
$$;
revoke execute on function public.set_event_notifications(boolean) from public, anon;
grant execute on function public.set_event_notifications(boolean) to authenticated;

notify pgrst, 'reload schema';


-- =====================================================================
-- migration-15-droits-documents.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°15 : documents des avions (onglet Flotte) ajoutés ou
--  modifiés par les administrateurs, membres du CA, instructeurs et
--  responsables maintenance. Lecture : tous les membres validés.
-- =====================================================================
create or replace function public.can_manage_docs()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((
    select p.role <> 'pending'
       and (p.role in ('admin', 'instructor') or p.is_instructor or p.is_board or p.is_maintenance)
    from public.profiles p where p.id = auth.uid()), false);
$$;
revoke execute on function public.can_manage_docs() from public, anon;
grant execute on function public.can_manage_docs() to authenticated;

drop policy if exists aircraft_documents_insert on public.aircraft_documents;
create policy aircraft_documents_insert on public.aircraft_documents for insert to authenticated
  with check (public.can_manage_docs());
drop policy if exists aircraft_documents_update on public.aircraft_documents;
create policy aircraft_documents_update on public.aircraft_documents for update to authenticated
  using (public.can_manage_docs()) with check (public.can_manage_docs());
drop policy if exists aircraft_documents_delete on public.aircraft_documents;
create policy aircraft_documents_delete on public.aircraft_documents for delete to authenticated
  using (public.can_manage_docs());

do $$
begin
  execute 'drop policy if exists aircraft_docs_insert on storage.objects';
  execute 'create policy aircraft_docs_insert on storage.objects for insert to authenticated with check (bucket_id = ''aircraft-docs'' and public.can_manage_docs())';
  execute 'drop policy if exists aircraft_docs_update on storage.objects';
  execute 'create policy aircraft_docs_update on storage.objects for update to authenticated using (bucket_id = ''aircraft-docs'' and public.can_manage_docs())';
  execute 'drop policy if exists aircraft_docs_delete on storage.objects';
  execute 'create policy aircraft_docs_delete on storage.objects for delete to authenticated using (bucket_id = ''aircraft-docs'' and public.can_manage_docs())';
exception when others then
  raise notice 'Stockage : droits non modifiés (%)', sqlerrm;
end $$;

notify pgrst, 'reload schema';


-- =====================================================================
-- migration-16-securite-rgpd.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°16 : sécurité et RGPD
--   1. Verrouillage : plus aucune suppression définitive de données du club
--      (avions, carte du bar, documents archivés au lieu d'être effacés).
--   2. Journal des modifications inaltérable (lecture : administrateurs).
--   3. RGPD : masquer son téléphone, demande de suppression de compte,
--      anonymisation par un administrateur, informations légales du club.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Défense en profondeur
-- ---------------------------------------------------------------------
-- Les visiteurs non connectés n'exécutent aucune fonction du club
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig, has_function_privilege('authenticated', p.oid, 'execute') as auth_ok
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
      and p.proname not in ('get_club_info')
  loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    -- les membres connectés gardent exactement les mêmes droits qu'avant
    if f.auth_ok then execute format('grant execute on function %s to authenticated', f.sig); end if;
  end loop;
end $$;
-- Les helpers de droits restent utilisables par les membres connectés (RLS)
grant execute on function public.app_role() to authenticated;
grant execute on function public.is_approved() to authenticated;
grant execute on function public.is_staff() to authenticated;
grant execute on function public.is_treasurer() to authenticated;
grant execute on function public.can_manage_fleet() to authenticated;
grant execute on function public.can_organize() to authenticated;
grant execute on function public.can_manage_docs() to authenticated;
grant execute on function public.bar_month_of(timestamptz) to authenticated;

-- TRUNCATE (vidage de table) interdit à tous les comptes applicatifs
do $$
declare t record;
begin
  for t in select c.oid::regclass as tbl from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind = 'r'
  loop
    execute format('revoke truncate on %s from public, anon, authenticated', t.tbl);
  end loop;
end $$;

-- Avions : on ne supprime plus, on désactive (historique des sorties préservé)
drop policy if exists aircraft_delete on public.aircraft;

-- Carte du bar : le trésorier ajoute et modifie, mais ne supprime pas (il retire de la vente)
drop policy if exists bar_products_write on public.bar_products;
drop policy if exists bar_products_insert on public.bar_products;
create policy bar_products_insert on public.bar_products for insert to authenticated
  with check (public.is_treasurer());
drop policy if exists bar_products_update on public.bar_products;
create policy bar_products_update on public.bar_products for update to authenticated
  using (public.is_treasurer()) with check (public.is_treasurer());

-- ---------------------------------------------------------------------
-- 2. Documents des avions : archivage au lieu de suppression
-- ---------------------------------------------------------------------
alter table public.aircraft_documents add column if not exists archived_at timestamptz;
alter table public.aircraft_documents add column if not exists archived_by uuid references public.profiles (id) on delete set null;

drop policy if exists aircraft_documents_select on public.aircraft_documents;
create policy aircraft_documents_select on public.aircraft_documents for select to authenticated
  using (public.is_approved() and (archived_at is null or public.can_manage_docs()));
drop policy if exists aircraft_documents_delete on public.aircraft_documents;

create or replace function public.archive_document(p_id uuid, p_archive boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.can_manage_docs() then
    raise exception 'Action réservée aux administrateurs, instructeurs, membres du CA et responsables maintenance.';
  end if;
  update public.aircraft_documents
     set archived_at = case when p_archive then now() else null end,
         archived_by = case when p_archive then auth.uid() else null end
   where id = p_id;
  if not found then raise exception 'Document introuvable.'; end if;
end;
$$;
revoke execute on function public.archive_document(uuid, boolean) from public, anon;
grant execute on function public.archive_document(uuid, boolean) to authenticated;

-- Fichiers : seuls les administrateurs peuvent effacer un fichier du stockage
do $$
begin
  execute 'drop policy if exists aircraft_docs_delete on storage.objects';
  execute 'create policy aircraft_docs_delete on storage.objects for delete to authenticated using (bucket_id = ''aircraft-docs'' and public.app_role() = ''admin'')';
  execute 'drop policy if exists aircraft_docs_update on storage.objects';
  execute 'drop policy if exists avatars_delete_admin on storage.objects';
  execute 'create policy avatars_delete_admin on storage.objects for delete to authenticated using (bucket_id = ''avatars'' and public.app_role() = ''admin'')';
exception when others then
  raise notice 'Stockage : droits non modifiés (%)', sqlerrm;
end $$;

-- ---------------------------------------------------------------------
-- 3. Journal des modifications (inaltérable)
-- ---------------------------------------------------------------------
create table if not exists public.audit_log (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  actor       uuid,                       -- auth.uid() de l'auteur (nom affiché via profiles)
  action      text not null,              -- insert / update / delete
  table_name  text not null,
  row_id      text,
  details     jsonb
);
alter table public.audit_log enable row level security;
revoke all on public.audit_log from public, anon, authenticated;
grant select on public.audit_log to authenticated;
drop policy if exists audit_log_select on public.audit_log;
create policy audit_log_select on public.audit_log for select to authenticated
  using (public.app_role() = 'admin');

create or replace function public._audit_immutable()
returns trigger language plpgsql as $$
begin
  raise exception 'Le journal des modifications ne peut être ni modifié ni effacé.';
end;
$$;
drop trigger if exists audit_log_immutable on public.audit_log;
create trigger audit_log_immutable before update or delete on public.audit_log
  for each row execute function public._audit_immutable();
revoke execute on function public._audit_immutable() from public, anon, authenticated;

-- Journalise : pour une modification, seules les colonnes changées (ancienne → nouvelle valeur).
-- Pour les profils, seules les fonctions / droits sont journalisés (pas les données personnelles).
create or replace function public._audit()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_old jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_new jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_details jsonb;
  v_keys text[];
  k text;
begin
  if tg_table_name = 'profiles' then
    v_keys := array['role', 'is_instructor', 'is_board', 'is_treasurer', 'is_secretary', 'is_maintenance', 'anonymized_at'];
  end if;

  if tg_op = 'UPDATE' then
    v_details := '{}'::jsonb;
    for k in select jsonb_object_keys(v_new) loop
      if (v_keys is null or k = any (v_keys)) and (v_old -> k) is distinct from (v_new -> k) then
        v_details := v_details || jsonb_build_object(k, jsonb_build_object('avant', v_old -> k, 'apres', v_new -> k));
      end if;
    end loop;
    if v_details = '{}'::jsonb then return new; end if;
  elsif tg_op = 'DELETE' then
    v_details := case when v_keys is null then v_old else '{}'::jsonb end;
  else
    v_details := case when v_keys is null then v_new else '{}'::jsonb end;
  end if;

  insert into public.audit_log (actor, action, table_name, row_id, details)
  values (auth.uid(), lower(tg_op), tg_table_name,
          coalesce(v_new ->> 'id', v_old ->> 'id', v_new ->> 'user_id', v_old ->> 'user_id'), v_details);
  return coalesce(new, old);
end;
$$;
revoke execute on function public._audit() from public, anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['aircraft', 'aircraft_documents', 'announcements', 'bar_products',
                           'bar_consumptions', 'bar_settlements', 'outings', 'profiles']
  loop
    execute format('drop trigger if exists zz_audit on public.%I', t);
    if t = 'bar_consumptions' then
      -- consommations : on journalise les annulations (les ajouts sont déjà la donnée elle-même)
      execute format('create trigger zz_audit after delete on public.%I for each row execute function public._audit()', t);
    elsif t = 'profiles' then
      execute format('create trigger zz_audit after update on public.%I for each row execute function public._audit()', t);
    else
      execute format('create trigger zz_audit after insert or update or delete on public.%I for each row execute function public._audit()', t);
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 4. RGPD côté membre
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists show_phone boolean not null default true;
alter table public.profiles add column if not exists deletion_requested_at timestamptz;
alter table public.profiles add column if not exists anonymized_at timestamptz;

create or replace function public.set_phone_visibility(p_value boolean)
returns void language sql security definer set search_path = '' as $$
  update public.profiles set show_phone = p_value where id = auth.uid();
$$;
revoke execute on function public.set_phone_visibility(boolean) from public, anon;
grant execute on function public.set_phone_visibility(boolean) to authenticated;

create or replace function public.request_account_deletion(p_value boolean)
returns void language sql security definer set search_path = '' as $$
  update public.profiles set deletion_requested_at = case when p_value then now() else null end where id = auth.uid();
$$;
revoke execute on function public.request_account_deletion(boolean) from public, anon;
grant execute on function public.request_account_deletion(boolean) to authenticated;

-- Anonymisation (droit à l'effacement) : par un administrateur, jamais sur son propre compte.
-- Les données personnelles sont effacées ; l'historique comptable du bar et des sorties est
-- conservé sous le nom « Ancien membre ». Le compte ne peut plus se connecter au site.
create or replace function public.anonymize_member(p_user uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare r record;
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  if p_user = auth.uid() then
    raise exception 'Vous ne pouvez pas anonymiser votre propre compte.';
  end if;
  if not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'Membre introuvable.';
  end if;

  -- Désinscription des événements à venir (les places libérées sont réattribuées)
  for r in
    select distinct g.outing_id from public.registrations g join public.outings o on o.id = g.outing_id
    where g.user_id = p_user and g.status <> 'cancelled' and o.departure_at > now()
  loop
    update public.registrations set status = 'cancelled'
     where outing_id = r.outing_id and user_id = p_user and status <> 'cancelled';
    perform public._rebalance_outing(r.outing_id);
  end loop;

  delete from public.pilot_weights where user_id = p_user;
  delete from public.pilot_types where user_id = p_user;

  update public.profiles set
    full_name = 'Ancien membre',
    email = 'anonyme-' || left(p_user::text, 8) || '@invalid.local',
    phone = null, address = null, emergency_name = null, emergency_phone = null,
    avatar_url = null,
    role = 'pending',
    is_instructor = false, is_board = false, is_treasurer = false, is_secretary = false, is_maintenance = false,
    notify_events = false, show_phone = false,
    anonymized_at = now()
  where id = p_user;
end;
$$;
revoke execute on function public.anonymize_member(uuid) from public, anon;
grant execute on function public.anonymize_member(uuid) to authenticated;

-- Annuaire : respecte « masquer mon téléphone », exclut les comptes anonymisés
create or replace function public.member_directory()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id, 'full_name', p.full_name,
             'phone', case when p.show_phone or p.id = auth.uid() then p.phone end,
             'avatar_url', p.avatar_url,
             'role', p.role, 'is_instructor', p.is_instructor,
             'types', coalesce((select jsonb_agg(pt.aircraft_type order by pt.aircraft_type)
                                from public.pilot_types pt where pt.user_id = p.id), '[]'::jsonb))
           order by lower(p.full_name))
    from public.profiles p
    where p.role <> 'pending' and p.anonymized_at is null), '[]'::jsonb);
end;
$$;
revoke execute on function public.member_directory() from public, anon;
grant execute on function public.member_directory() to authenticated;

-- ---------------------------------------------------------------------
-- 5. Informations légales du club (mentions légales), modifiables par les admins
-- ---------------------------------------------------------------------
create table if not exists public.club_info (
  id                    int primary key default 1 check (id = 1),
  association_name      text not null default 'Aéroclub Air France Provence',
  legal_form            text default 'Association régie par la loi du 1er juillet 1901',
  address               text,
  registration_number   text,       -- n° RNA et/ou SIRET
  publication_director  text,       -- directeur de la publication (président)
  contact_email         text,
  contact_phone         text,
  updated_at            timestamptz not null default now()
);
insert into public.club_info (id) values (1) on conflict (id) do nothing;
alter table public.club_info enable row level security;
revoke all on public.club_info from public, anon, authenticated;

-- Lecture publique (page « Mentions légales » accessible sans connexion)
create or replace function public.get_club_info()
returns jsonb language sql stable security definer set search_path = '' as $$
  select to_jsonb(c) - 'id' from public.club_info c where c.id = 1;
$$;
revoke execute on function public.get_club_info() from public;
grant execute on function public.get_club_info() to anon, authenticated;

create or replace function public.set_club_info(p_info jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  update public.club_info set
    association_name     = coalesce(nullif(btrim(p_info ->> 'association_name'), ''), association_name),
    legal_form           = nullif(btrim(p_info ->> 'legal_form'), ''),
    address              = nullif(btrim(p_info ->> 'address'), ''),
    registration_number  = nullif(btrim(p_info ->> 'registration_number'), ''),
    publication_director = nullif(btrim(p_info ->> 'publication_director'), ''),
    contact_email        = nullif(btrim(p_info ->> 'contact_email'), ''),
    contact_phone        = nullif(btrim(p_info ->> 'contact_phone'), ''),
    updated_at           = now()
  where id = 1;
end;
$$;
revoke execute on function public.set_club_info(jsonb) from public, anon;
grant execute on function public.set_club_info(jsonb) to authenticated;

notify pgrst, 'reload schema';


-- =====================================================================
-- migration-17-annonces-fonctions.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°17 : annonces publiées par toute personne ayant une
--  fonction (admin, instructeur, CA, trésorier, secrétaire, resp.
--  maintenance). Les simples membres les lisent seulement.
-- =====================================================================
drop policy if exists announcements_insert on public.announcements;
create policy announcements_insert on public.announcements for insert to authenticated
  with check (public.can_organize());
drop policy if exists announcements_delete on public.announcements;
create policy announcements_delete on public.announcements for delete to authenticated
  using (public.can_organize());

notify pgrst, 'reload schema';


-- =====================================================================
-- migration-18-documents-fonctions.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°18 : documents des avions ajoutés / modifiés par toute
--  personne ayant une fonction (admin, instructeur, CA, trésorier,
--  secrétaire, resp. maintenance). Les simples membres les consultent.
-- =====================================================================
create or replace function public.can_manage_docs()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((
    select p.role <> 'pending'
       and (p.role in ('admin', 'instructor') or p.is_instructor or p.is_board or p.is_maintenance
            or p.is_treasurer or p.is_secretary)
    from public.profiles p where p.id = auth.uid()), false);
$$;
revoke execute on function public.can_manage_docs() from public, anon;
grant execute on function public.can_manage_docs() to authenticated;

notify pgrst, 'reload schema';


-- =====================================================================
-- migration-19-accueil-inside.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°19 : accueil façon « Inside AFPA »
--   1. Indisponibilité d'un avion avec période (du … au …)
--   2. Flotte complète du club (ajout des avions manquants)
--   3. Chiffres de l'accueil (membres actifs) et « Équipage de l'année »
--   4. Liens utiles (outils de vol, réseaux) modifiables par les admins
-- =====================================================================

-- Données d'exemple : posées une seule fois, à la première installation.
-- Relancer ce fichier plus tard ne les recrée pas et ne touche pas aux données saisies sur le site.
create table if not exists public._seeds (name text primary key, done_at timestamptz not null default now());
alter table public._seeds enable row level security;
revoke all on public._seeds from public, anon, authenticated;
create or replace function public._seed_once(p_name text)
returns boolean language plpgsql set search_path = '' as $fn$
begin
  insert into public._seeds (name) values (p_name) on conflict (name) do nothing;
  return found;
end;
$fn$;
revoke execute on function public._seed_once(text) from public, anon, authenticated;

-- 1. Période d'indisponibilité ----------------------------------------
alter table public.aircraft add column if not exists unavailable_from date;
alter table public.aircraft add column if not exists unavailable_until date;
grant update (unavailable_from, unavailable_until) on public.aircraft to authenticated;

drop function if exists public.set_aircraft_availability(uuid, boolean, text);
create or replace function public.set_aircraft_availability(
  p_id uuid, p_available boolean, p_reason text default null,
  p_from date default null, p_until date default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.can_manage_fleet() then
    raise exception 'Réservé aux administrateurs et aux responsables maintenance.';
  end if;
  if not p_available and p_from is not null and p_until is not null and p_until < p_from then
    raise exception 'La date de fin doit être après la date de début.';
  end if;
  update public.aircraft
     set available = p_available,
         unavailable_reason = case when p_available then null else nullif(btrim(coalesce(p_reason, '')), '') end,
         unavailable_from   = case when p_available then null else p_from end,
         unavailable_until  = case when p_available then null else p_until end
   where id = p_id;
  if not found then raise exception 'Avion introuvable.'; end if;
end;
$$;
revoke execute on function public.set_aircraft_availability(uuid, boolean, text, date, date) from public, anon;
grant execute on function public.set_aircraft_availability(uuid, boolean, text, date, date) to authenticated;

-- 2. Flotte du club (n'ajoute que les avions absents, ne modifie rien d'existant)
do $seed$ begin
  if not public._seed_once('avions-19') then return; end if;
insert into public.aircraft (registration, model, type, seats)
select v.reg, v.model, v.type, v.seats
from (values
  ('F-HSAA', 'PS28 Cruiser',  'PS28',  2),
  ('F-HNLR', 'PS28 Cruiser',  'PS28',  2),
  ('F-HUIT', 'PS28 Cruiser',  'PS28',  2),
  ('F-HSAC', 'PS28 Cruiser',  'PS28',  2),
  ('F-HPSA', 'PS28 Cruiser',  'PS28',  2),
  ('F-HSAG', 'PS28 Cruiser',  'PS28',  2),
  ('F-HVXD', 'Dynamic WT9',   'WT9',   2),
  ('F-HUFA', 'Bristell B23',  'B23',   2),
  ('F-HCLI', 'Robin DR400',   'DR400', 4),
  ('F-HXAF', 'Diamond DA40',  'DA40',  4)
) v(reg, model, type, seats)
where not exists (select 1 from public.aircraft a where upper(a.registration) = v.reg);
end $seed$;

-- 3. Chiffres de l'accueil ---------------------------------------------
alter table public.profiles add column if not exists show_in_bar_ranking boolean not null default true;

create or replace function public.club_stats()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  return jsonb_build_object(
    'active_members', (select count(*) from public.profiles
                        where role <> 'pending' and anonymized_at is null));
end;
$$;
revoke execute on function public.club_stats() from public, anon;
grant execute on function public.club_stats() to authenticated;

-- « Équipage de l'année » : les 3 plus fidèles clients du bar sur l'année civile
-- (prénom + initiale, nombre de consommations ; jamais les montants).
-- Chacun peut s'en retirer dans « Mon compte ».
create or replace function public.bar_ranking(p_year int default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_year int := coalesce(p_year, extract(year from (now() at time zone 'Europe/Paris'))::int);
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  return coalesce((
    select jsonb_agg(x order by x.rank)
    from (
      select row_number() over (order by sum(c.quantity) desc, min(c.created_at)) as rank,
             split_part(btrim(p.full_name), ' ', 1)
               || case when position(' ' in btrim(p.full_name)) > 0
                       then ' ' || upper(left(split_part(btrim(p.full_name), ' ', 2), 1)) || '.' else '' end as name,
             p.avatar_url,
             sum(c.quantity)::int as consos
      from public.bar_consumptions c
      join public.profiles p on p.id = c.user_id
      where extract(year from (c.created_at at time zone 'Europe/Paris')) = v_year
        and p.role <> 'pending' and p.anonymized_at is null and p.show_in_bar_ranking
      group by p.id, p.full_name, p.avatar_url
      order by sum(c.quantity) desc, min(c.created_at)
      limit 3
    ) x), '[]'::jsonb);
end;
$$;
revoke execute on function public.bar_ranking(int) from public, anon;
grant execute on function public.bar_ranking(int) to authenticated;

create or replace function public.set_bar_ranking_visibility(p_value boolean)
returns void language sql security definer set search_path = '' as $$
  update public.profiles set show_in_bar_ranking = p_value where id = auth.uid();
$$;
revoke execute on function public.set_bar_ranking_visibility(boolean) from public, anon;
grant execute on function public.set_bar_ranking_visibility(boolean) to authenticated;

-- 4. Liens utiles --------------------------------------------------------
create table if not exists public.club_links (
  id        uuid primary key default gen_random_uuid(),
  section   text not null check (section in ('outils', 'liens')),
  title     text not null check (length(btrim(title)) between 1 and 60),
  subtitle  text check (subtitle is null or length(subtitle) <= 80),
  url       text not null check (url ~* '^https?://'),
  icon      text check (icon is null or length(icon) <= 8),
  position  int not null default 0,
  created_at timestamptz not null default now()
);
alter table public.club_links enable row level security;
revoke truncate on public.club_links from public, anon, authenticated;
drop policy if exists club_links_select on public.club_links;
create policy club_links_select on public.club_links for select to authenticated using (public.is_approved());
drop policy if exists club_links_insert on public.club_links;
create policy club_links_insert on public.club_links for insert to authenticated with check (public.app_role() = 'admin');
drop policy if exists club_links_update on public.club_links;
create policy club_links_update on public.club_links for update to authenticated
  using (public.app_role() = 'admin') with check (public.app_role() = 'admin');
drop policy if exists club_links_delete on public.club_links;
create policy club_links_delete on public.club_links for delete to authenticated using (public.app_role() = 'admin');

do $seed$ begin
  if not public._seed_once('liens-19') then return; end if;
insert into public.club_links (section, title, subtitle, url, icon, position)
select v.section, v.title, v.subtitle, v.url, v.icon, v.pos
from (values
  ('outils', 'Aérogest Online', 'Réservation & planning', 'https://online.aerogest.fr/Connection/logon', '✈️', 1),
  ('outils', 'AéroGligli', 'Formation théorique', 'https://www.aerogligli.fr/', '📖', 2),
  ('outils', 'FlightProgress', 'Progression formation', 'https://www.f-prog.com/', '📈', 3),
  ('outils', 'NOTAM / SOFIA', 'Briefing pré-vol', 'https://sofia-briefing.aviation-civile.gouv.fr/', '📋', 4),
  ('outils', 'Aeroweb', 'Météo aéro Météo-France', 'https://aviation.meteo.fr/', '🌦️', 5),
  ('outils', 'SIA / OLIVIA', 'Cartes VAC, AIP', 'https://www.sia.aviation-civile.gouv.fr/', '🗺️', 6),
  ('liens', 'Site internet', 'af-provenceaviation.fr', 'https://af-provenceaviation.fr', '🌐', 1),
  ('liens', 'Facebook', '@AeroclubAirFranceProvence', 'https://www.facebook.com/AeroclubAirFranceProvence', '📘', 2),
  ('liens', 'Instagram', '@airfranceprovenceaviation', 'https://www.instagram.com/airfranceprovenceaviation', '📷', 3)
) v(section, title, subtitle, url, icon, pos)
where not exists (select 1 from public.club_links l where l.title = v.title);
end $seed$;

-- Journal : les liens aussi sont tracés
drop trigger if exists zz_audit on public.club_links;
create trigger zz_audit after insert or update or delete on public.club_links
  for each row execute function public._audit();

notify pgrst, 'reload schema';


-- =====================================================================
-- migration-20-masse-centrage.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°20 : masse et centrage par avion (d'après le manuel de vol
--  et la dernière fiche de pesée). Lecture : tous les membres validés.
--  Modification : administrateurs et responsables maintenance.
-- =====================================================================
-- Données d'exemple : posées une seule fois, à la première installation.
-- Relancer ce fichier plus tard ne les recrée pas et ne touche pas aux données saisies sur le site.
create table if not exists public._seeds (name text primary key, done_at timestamptz not null default now());
alter table public._seeds enable row level security;
revoke all on public._seeds from public, anon, authenticated;
create or replace function public._seed_once(p_name text)
returns boolean language plpgsql set search_path = '' as $fn$
begin
  insert into public._seeds (name) values (p_name) on conflict (name) do nothing;
  return found;
end;
$fn$;
revoke execute on function public._seed_once(text) from public, anon, authenticated;

create table if not exists public.aircraft_mb (
  aircraft_id     uuid primary key references public.aircraft (id) on delete cascade,
  serial          text,                               -- n° de série
  empty_mass      numeric(7,2) check (empty_mass is null or empty_mass > 0),      -- masse à vide (kg)
  empty_moment    numeric(9,3),                        -- moment à vide (kg.m)
  mtow            numeric(7,2) check (mtow is null or mtow > 0),                  -- masse max décollage (kg)
  mlw             numeric(7,2) check (mlw is null or mlw > 0),                    -- masse max atterrissage (kg), facultatif
  fuel_arm        numeric(6,3),                        -- bras du carburant (m)
  fuel_density    numeric(4,3) not null default 0.72 check (fuel_density between 0.5 and 1),
  fuel_capacity_l numeric(6,1) check (fuel_capacity_l is null or fuel_capacity_l > 0),
  stations        jsonb not null default '[]'::jsonb,  -- [{label, arm, max}]
  envelope        jsonb not null default '[]'::jsonb,  -- [{arm, mass}] polygone du domaine de centrage
  source          text,                                -- ex. « Manuel de vol rév. 3 — pesée du 12/03/2025 »
  updated_at      timestamptz not null default now(),
  updated_by      uuid references public.profiles (id) on delete set null default auth.uid()
);
alter table public.aircraft_mb enable row level security;
revoke truncate on public.aircraft_mb from public, anon, authenticated;

drop policy if exists aircraft_mb_select on public.aircraft_mb;
create policy aircraft_mb_select on public.aircraft_mb for select to authenticated using (public.is_approved());
drop policy if exists aircraft_mb_insert on public.aircraft_mb;
create policy aircraft_mb_insert on public.aircraft_mb for insert to authenticated with check (public.can_manage_fleet());
drop policy if exists aircraft_mb_update on public.aircraft_mb;
create policy aircraft_mb_update on public.aircraft_mb for update to authenticated
  using (public.can_manage_fleet()) with check (public.can_manage_fleet());
-- pas de suppression : on corrige les valeurs

drop trigger if exists zz_audit on public.aircraft_mb;
create trigger zz_audit after insert or update on public.aircraft_mb
  for each row execute function public._audit();

-- Pré-remplissage F-HSAA (valeurs relevées dans l'outil Inside AFPA : masse et moment à vide,
-- postes de chargement, MTOW). Le bras carburant et le domaine de centrage restent à saisir
-- depuis le manuel de vol avant que le calcul soit disponible.
do $seed$ begin
  if not public._seed_once('centrage-20') then return; end if;
insert into public.aircraft_mb (aircraft_id, serial, empty_mass, empty_moment, mtow, stations, source)
select a.id, 'C0502', 393.5, 169.8, 600,
       '[{"label":"Pilote","arm":0.70,"max":115},{"label":"Passager","arm":0.70,"max":115},{"label":"Bagages coffre AR","arm":1.31,"max":18}]'::jsonb,
       'Repris de l''outil Inside AFPA — à compléter (bras carburant, domaine de centrage)'
from public.aircraft a
where a.registration = 'F-HSAA'
  and not exists (select 1 from public.aircraft_mb m where m.aircraft_id = a.id);
end $seed$;

notify pgrst, 'reload schema';


-- =====================================================================
-- migration-21-documents-masse-centrage.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°21
--   1. Nouvelle catégorie de documents « Équipements & avionique »
--   2. Masse et centrage : masse max sans carburant (MZFW) et postes
--      « carburant » (réservoir supplémentaire en litres) / « aile »
--   3. Données de masse et centrage de la flotte, relevées dans les manuels
--      de vol et les fiches de pesée fournis (Inside, export du 25/09/2026)
-- =====================================================================

-- Données d'exemple : posées une seule fois, à la première installation.
-- Relancer ce fichier plus tard ne les recrée pas et ne touche pas aux données saisies sur le site.
create table if not exists public._seeds (name text primary key, done_at timestamptz not null default now());
alter table public._seeds enable row level security;
revoke all on public._seeds from public, anon, authenticated;
create or replace function public._seed_once(p_name text)
returns boolean language plpgsql set search_path = '' as $fn$
begin
  insert into public._seeds (name) values (p_name) on conflict (name) do nothing;
  return found;
end;
$fn$;
revoke execute on function public._seed_once(text) from public, anon, authenticated;

-- 1. Catégorie « equipements »
alter table public.aircraft_documents drop constraint if exists aircraft_documents_category_check;
alter table public.aircraft_documents add constraint aircraft_documents_category_check
  check (category in ('manuel','checklist','masse_centrage','performances','procedures','administratif','maintenance','equipements','autre'));

-- 2. Masse max sans carburant (ou sans carburant ni charge en aile)
alter table public.aircraft_mb add column if not exists mzfw numeric(7,2) check (mzfw is null or mzfw > 0);

-- 3. Données par avion. Ne remplace que des fiches jamais retouchées à la main
--    (vides, pré-remplies depuis Inside, ou issues de ce même import).
do $seed$ begin
  if not public._seed_once('centrage-21') then return; end if;
with src (reg, serial, empty_mass, empty_moment, mtow, mlw, mzfw, fuel_arm, fuel_capacity_l, stations, envelope, source) as (
  values
  -- PS-28 Cruiser : manuel de vol PS-POH-1-1-11 §2 et §6 ; domaine 420–525 mm (28–35 % MAC)
  ('F-HSAA', 'C0502', 393.5, 169.789, 600, 600, null, 0.180, 113,
   '[{"label":"Pilote","arm":0.70,"max":115},{"label":"Passager","arm":0.70,"max":115},{"label":"Bagages (coffre arrière)","arm":1.31,"max":18},{"label":"Casier aile gauche","arm":0.60,"max":10,"wing":true},{"label":"Casier aile droite","arm":0.60,"max":10,"wing":true}]',
   '[{"arm":0.420,"mass":300},{"arm":0.420,"mass":600},{"arm":0.525,"mass":600},{"arm":0.525,"mass":300}]',
   'Manuel de vol PS-28 Cruiser (PS-POH-1-1-11) §2 et §6 — fiche de pesée du 03/08/2026 [import 2026-09-25]'),
  ('F-HNLR', 'C0435', 386.5, 164.2625, 600, 600, null, 0.180, 113,
   '[{"label":"Pilote","arm":0.70,"max":115},{"label":"Passager","arm":0.70,"max":115},{"label":"Bagages (coffre arrière)","arm":1.31,"max":18},{"label":"Casier aile gauche","arm":0.60,"max":10,"wing":true},{"label":"Casier aile droite","arm":0.60,"max":10,"wing":true}]',
   '[{"arm":0.420,"mass":300},{"arm":0.420,"mass":600},{"arm":0.525,"mass":600},{"arm":0.525,"mass":300}]',
   'Manuel de vol PS-28 Cruiser (PS-POH-1-1-11) §2 et §6 — fiche de pesée du 16/10/2024 (S/N C0435) [import 2026-09-25]'),
  ('F-HUIT', 'C0409', 387.5, 173.212, 600, 600, null, 0.180, 113,
   '[{"label":"Pilote","arm":0.70,"max":115},{"label":"Passager","arm":0.70,"max":115},{"label":"Bagages (coffre arrière)","arm":1.31,"max":18},{"label":"Casier aile gauche","arm":0.60,"max":10,"wing":true},{"label":"Casier aile droite","arm":0.60,"max":10,"wing":true}]',
   '[{"arm":0.420,"mass":300},{"arm":0.420,"mass":600},{"arm":0.525,"mass":600},{"arm":0.525,"mass":300}]',
   'Manuel de vol PS-28 Cruiser (PS-POH-1-1-11) §2 et §6 — rapport de pesée du 15/12/2017 [import 2026-09-25]'),
  ('F-HSAC', 'C0531', 393.0, 170.0222, 600, 600, null, 0.180, 113,
   '[{"label":"Pilote","arm":0.70,"max":115},{"label":"Passager","arm":0.70,"max":115},{"label":"Bagages (coffre arrière)","arm":1.31,"max":18},{"label":"Casier aile gauche","arm":0.60,"max":10,"wing":true},{"label":"Casier aile droite","arm":0.60,"max":10,"wing":true}]',
   '[{"arm":0.420,"mass":300},{"arm":0.420,"mass":600},{"arm":0.525,"mass":600},{"arm":0.525,"mass":300}]',
   'Manuel de vol PS-28 Cruiser (PS-POH-1-1-11) §2 et §6 — fiche de pesée du 12/05/2015 [import 2026-09-25]'),
  ('F-HPSA', 'C0658', 402.7, 173.3057, 600, 600, null, 0.180, 113,
   '[{"label":"Pilote","arm":0.70,"max":115},{"label":"Passager","arm":0.70,"max":115},{"label":"Bagages (coffre arrière)","arm":1.31,"max":18},{"label":"Casier aile gauche","arm":0.60,"max":10,"wing":true},{"label":"Casier aile droite","arm":0.60,"max":10,"wing":true}]',
   '[{"arm":0.420,"mass":300},{"arm":0.420,"mass":600},{"arm":0.525,"mass":600},{"arm":0.525,"mass":300}]',
   'Manuel de vol PS-28 Cruiser (PS-POH-1-1-11) §2 et §6 — fiche de pesée PS-28 N Cruiser du 23/03/2022 [import 2026-09-25]'),
  ('F-HSAG', 'C0602', null, null, 600, 600, null, 0.180, 113,
   '[{"label":"Pilote","arm":0.70,"max":115},{"label":"Passager","arm":0.70,"max":115},{"label":"Bagages (coffre arrière)","arm":1.31,"max":18},{"label":"Casier aile gauche","arm":0.60,"max":10,"wing":true},{"label":"Casier aile droite","arm":0.60,"max":10,"wing":true}]',
   '[{"arm":0.420,"mass":300},{"arm":0.420,"mass":600},{"arm":0.525,"mass":600},{"arm":0.525,"mass":300}]',
   'Manuel de vol PS-28 Cruiser (PS-POH-1-1-11) §2 et §6 — fiche de pesée non fournie : masse et moment à vide à saisir [import 2026-09-25]'),
  -- WT9 Dynamic LSA/Club : POH AS-POH-10-508 §2.4, §6.4 (fig. 6-2) et §6.5 ; masse à vide de base (carburant inutilisable inclus)
  ('F-HVXD', 'DY-508/2014 LSA', 344.6, 911.16, 600, 600, null, 2.580, 119,
   '[{"label":"Pilote","arm":3.130,"max":120},{"label":"Passager","arm":3.130,"max":120},{"label":"Bagages (2 × 20 kg max)","arm":3.795,"max":40}]',
   '[{"arm":2.704,"mass":405},{"arm":2.704,"mass":542.5},{"arm":2.748,"mass":600},{"arm":2.824,"mass":600},{"arm":2.824,"mass":465.3},{"arm":2.810,"mass":445},{"arm":2.713,"mass":405}]',
   'POH WT9 Dynamic LSA/Club §2.4 et §6 (fig. 6-2) — pesée du 24/03/2020, masse à vide de base [import 2026-09-25]'),
  -- Bristell B23-915 : AFM ADXC-73-003 §2.7–2.8 et §6 ; MAC 1,343 m, bord d'attaque MAC 1,377 m
  ('F-HUFA', '0077', 469.5, 800.8, 750, 750, 660, 1.600, 112,
   '[{"label":"Pilote","arm":2.085,"max":null},{"label":"Passager","arm":2.085,"max":null},{"label":"Bagages arrière (bas)","arm":2.520,"max":15},{"label":"Bagages arrière (haut)","arm":2.800,"max":1},{"label":"Casier aile gauche","arm":2.025,"max":20,"wing":true},{"label":"Casier aile droite","arm":2.025,"max":20,"wing":true}]',
   '[{"arm":1.7128,"mass":519},{"arm":1.7128,"mass":600},{"arm":1.7934,"mass":750},{"arm":1.8403,"mass":750},{"arm":1.8403,"mass":600},{"arm":1.8067,"mass":519}]',
   'AFM Bristell B23-915 (ADXC-73-003) §2.7, §2.8 et §6 — pesée du 25/01/2023 ; MZFW = masse max sans carburant ni charge en aile [import 2026-09-25]'),
  -- Robin DR400/180 : manuel de vol éd. 20 §2 (plan de chargement) et §6 ; limites de la fiche de pesée (12 % à 25 % / 33 % de 1,71 m)
  ('F-HCLI', null, 644, 211.876, 1100, 1045, null, 1.120, 109,
   '[{"label":"Pilote (siège avant, bras moyen)","arm":0.41,"max":null},{"label":"Passager avant (bras moyen)","arm":0.41,"max":null},{"label":"Passagers arrière (total)","arm":1.19,"max":null},{"label":"Bagages","arm":1.90,"max":60},{"label":"Réservoirs d''ailes","arm":0.10,"max":80,"fuel":true}]',
   '[{"arm":0.2052,"mass":600},{"arm":0.2052,"mass":750},{"arm":0.428,"mass":1100},{"arm":0.564,"mass":1100},{"arm":0.564,"mass":600}]',
   'Manuel de vol DR400/180 éd. 20 §2 et §6 — rapport de pesée du 20/04/2018 ; catégorie Normale [import 2026-09-25]'),
  -- Diamond DA40 : AFM 6.01.01-E §2.7, §6.4 ; réservoirs standard. MTOW 1150 kg tant que la modification
  -- MÄM 40-227 (1200 kg) n'est pas confirmée : la case n'est pas cochée dans le manuel fourni.
  ('F-HXAF', null, 774.5, 1878.16, 1150, 1092, 1150, 2.630, 151,
   '[{"label":"Pilote","arm":2.30,"max":null},{"label":"Passager avant","arm":2.30,"max":null},{"label":"Passagers arrière (total)","arm":3.25,"max":null},{"label":"Bagages (compartiment standard)","arm":3.65,"max":30},{"label":"Tube à bagages (si installé)","arm":4.32,"max":5}]',
   '[{"arm":2.40,"mass":780},{"arm":2.40,"mass":980},{"arm":2.46,"mass":1150},{"arm":2.59,"mass":1150},{"arm":2.59,"mass":780}]',
   'AFM DA 40 (6.01.01-E rév. 8) §2.7 et §6.4 — rapport de pesée (correctif n°1) du 16/02/2018 ; MTOW 1150 kg (1200 kg seulement si MÄM 40-227 appliquée) ; MLW 1092 kg (jambe de train d''origine) [import 2026-09-25]')
)
insert into public.aircraft_mb as m
  (aircraft_id, serial, empty_mass, empty_moment, mtow, mlw, mzfw, fuel_arm, fuel_density, fuel_capacity_l, stations, envelope, source, updated_at, updated_by)
select a.id, s.serial, s.empty_mass::numeric, s.empty_moment::numeric, s.mtow::numeric, s.mlw::numeric, s.mzfw::numeric,
       s.fuel_arm::numeric, 0.72, s.fuel_capacity_l::numeric, s.stations::jsonb, s.envelope::jsonb, s.source, now(), null
from src s
join public.aircraft a on upper(a.registration) = s.reg
on conflict (aircraft_id) do update set
  serial          = coalesce(excluded.serial, m.serial),
  empty_mass      = coalesce(excluded.empty_mass, m.empty_mass),
  empty_moment    = coalesce(excluded.empty_moment, m.empty_moment),
  mtow = excluded.mtow, mlw = excluded.mlw, mzfw = excluded.mzfw,
  fuel_arm = excluded.fuel_arm, fuel_density = excluded.fuel_density, fuel_capacity_l = excluded.fuel_capacity_l,
  stations = excluded.stations, envelope = excluded.envelope, source = excluded.source, updated_at = now()
where m.source is null
   or m.source like 'Repris de l''outil Inside%'
   or m.source like '%[import 2026-09-25]';
end $seed$;

notify pgrst, 'reload schema';


-- =====================================================================
-- migration-22-carte-bar.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°22 : carte du bar (prix de septembre 2026)
--  Les produits existants sont renommés / mis à jour (l'historique des
--  consommations garde le nom et le prix de l'époque). Les produits qui ne
--  sont plus à la carte sont masqués, jamais supprimés.
-- =====================================================================
-- Données d'exemple : posées une seule fois, à la première installation.
-- Relancer ce fichier plus tard ne les recrée pas et ne touche pas aux données saisies sur le site.
create table if not exists public._seeds (name text primary key, done_at timestamptz not null default now());
alter table public._seeds enable row level security;
revoke all on public._seeds from public, anon, authenticated;
create or replace function public._seed_once(p_name text)
returns boolean language plpgsql set search_path = '' as $fn$
begin
  insert into public._seeds (name) values (p_name) on conflict (name) do nothing;
  return found;
end;
$fn$;
revoke execute on function public._seed_once(text) from public, anon, authenticated;

do $seed$ begin
  if not public._seed_once('bar-22') then return; end if;
with carte (name, aliases, price, pos, cat) as (values
  ('Tourtel',          array['tourtel'],                                150,  1, 'boissons'),
  ('Bud',              array['bud'],                                    200,  2, 'boissons'),
  ('1664 blanche',     array['1664 blanche','1664'],                    200,  3, 'boissons'),
  ('Heineken',         array['heineken'],                               200,  4, 'boissons'),
  ('Leffe 0° 25cl',    array['leffe 0° 25cl','leffe 0°','leffe'],       200,  5, 'boissons'),
  ('Brewdog Punk IPA', array['brewdog punk ipa','brewdog ipa'],         400,  6, 'boissons'),
  ('Panaché 33cl',     array['panaché 33cl','panaché','panache'],       150,  7, 'boissons'),
  ('Desperados 50cl',  array['desperados 50cl','desperados'],           400,  8, 'boissons'),
  ('Coca Cola',        array['coca cola','coca'],                       150,  9, 'boissons'),
  ('Coca Cola 0',      array['coca cola 0','coca zéro','coca zero'],    150, 10, 'boissons'),
  ('Ice tea',          array['ice tea'],                                150, 11, 'boissons'),
  ('Café',             array['café','cafe'],                             75, 12, 'boissons'),
  ('Thé / Infusion',   array['thé / infusion','thé','infusion'],         75, 13, 'boissons'),
  ('Glace Bounty',     array['glace bounty'],                           200, 21, 'snacks'),
  ('Glace Snickers',   array['glace snickers'],                         200, 22, 'snacks'),
  ('Glace Twix',       array['glace twix'],                             200, 23, 'snacks'),
  ('Kinder Bueno',     array['kinder bueno'],                           175, 24, 'snacks'),
  ('Kit Kat',          array['kit kat','kitkat'],                       175, 25, 'snacks'),
  ('Lion',             array['lion'],                                   175, 26, 'snacks'),
  ('Snickers',         array['snickers'],                               175, 27, 'snacks')
),
-- produit existant correspondant (priorité au nom exact, puis au produit actif)
match as (
  select distinct on (c.name) c.name, c.price, c.pos, c.cat, p.id as pid
  from carte c
  left join public.bar_products p on lower(p.name) = any (c.aliases)
  order by c.name, (lower(p.name) = lower(c.name)) desc nulls last, p.active desc nulls last
),
upd as (
  update public.bar_products p
     set name = m.name, price_cents = m.price, position = m.pos, category = m.cat, active = true
    from match m
   where p.id = m.pid
  returning p.id
),
ins as (
  insert into public.bar_products (name, price_cents, position, category, active)
  select m.name, m.price, m.pos, m.cat, true from match m where m.pid is null
  returning id
)
update public.bar_products p set active = false
 where p.active
   and p.id not in (select id from upd union all select id from ins);
end $seed$;

notify pgrst, 'reload schema';


-- =====================================================================
-- migration-23-bons-plans.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°23 : carte des « bons plans » sur les aérodromes
--  (restaurants, avitaillement, hébergement, visites…). Chaque membre
--  validé peut en ajouter ; l'auteur ou un administrateur peut le modifier
--  ou le retirer (archivage : rien n'est effacé).
-- =====================================================================
-- Données d'exemple : posées une seule fois, à la première installation.
-- Relancer ce fichier plus tard ne les recrée pas et ne touche pas aux données saisies sur le site.
create table if not exists public._seeds (name text primary key, done_at timestamptz not null default now());
alter table public._seeds enable row level security;
revoke all on public._seeds from public, anon, authenticated;
create or replace function public._seed_once(p_name text)
returns boolean language plpgsql set search_path = '' as $fn$
begin
  insert into public._seeds (name) values (p_name) on conflict (name) do nothing;
  return found;
end;
$fn$;
revoke execute on function public._seed_once(text) from public, anon, authenticated;

create table if not exists public.airfield_tips (
  id            uuid primary key default gen_random_uuid(),
  icao          text not null check (icao ~ '^[A-Z]{2}[A-Z0-9]{2}$'),
  airfield_name text not null check (length(btrim(airfield_name)) between 1 and 80),
  lat           numeric(8,5) not null check (lat between -90 and 90),
  lon           numeric(8,5) not null check (lon between -180 and 180),
  category      text not null default 'resto' check (category in ('resto','avitaillement','hebergement','visite','autre')),
  title         text not null check (length(btrim(title)) between 1 and 80),
  description   text check (description is null or length(description) <= 1000),
  on_field      boolean not null default true,
  contact       text check (contact is null or (length(contact) <= 200 and (contact ~* '^https?://' or contact ~ '^[0-9 +().-]{6,25}$'))),
  created_by    uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  archived_at   timestamptz
);
create index if not exists airfield_tips_icao on public.airfield_tips (icao) where archived_at is null;
alter table public.airfield_tips enable row level security;
revoke truncate on public.airfield_tips from public, anon, authenticated;

drop policy if exists airfield_tips_select on public.airfield_tips;
create policy airfield_tips_select on public.airfield_tips for select to authenticated using (public.is_approved());
drop policy if exists airfield_tips_insert on public.airfield_tips;
create policy airfield_tips_insert on public.airfield_tips for insert to authenticated
  with check (public.is_approved() and created_by = auth.uid() and archived_at is null);
drop policy if exists airfield_tips_update on public.airfield_tips;
create policy airfield_tips_update on public.airfield_tips for update to authenticated
  using (public.is_approved() and (created_by = auth.uid() or public.app_role() = 'admin'))
  with check (public.is_approved() and (created_by = auth.uid() or public.app_role() = 'admin'));
-- pas de suppression : on archive (archived_at)
revoke delete on public.airfield_tips from authenticated, anon;

drop trigger if exists zz_audit on public.airfield_tips;
create trigger zz_audit after insert or update on public.airfield_tips
  for each row execute function public._audit();

-- Premier bon plan (repris d'Inside)
do $seed$ begin
  if not public._seed_once('bons-plans-23') then return; end if;
insert into public.airfield_tips (icao, airfield_name, lat, lon, category, title, description, on_field, contact, created_by)
select 'LFTF', 'Cuers-Pierrefeu', 43.2476, 6.1267, 'resto', 'Le Saint Tex',
       'Un restaurant sympathique sur l''AD avec une carte restreinte composée de plats traditionnels faits maison (tartare, pâtes carbonara, entrecôte-frites).',
       true, 'https://www.facebook.com/lesainttex/', null
where not exists (select 1 from public.airfield_tips where icao = 'LFTF' and title = 'Le Saint Tex');
end $seed$;

notify pgrst, 'reload schema';


-- =====================================================================
-- migration-24-deplacer-equipage.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°24 : déplacer un membre d'équipage d'un avion à l'autre
--  (glisser-déposer sur la page d'une sortie avion).
--  - Déposer sur un avion qui a une place libre : la personne y est déplacée.
--  - Déposer sur une personne d'un autre avion : les deux échangent leur place.
--  - L'organisateur à bord peut aussi être déplacé ou échangé.
--  Réservé aux organisateurs (instructeurs, CA, fonctions, admin) et à
--  l'organisateur de la sortie.
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

create or replace function public.move_crew(
  p_outing   uuid,
  p_who      text,              -- id d'inscription, ou 'organizer'
  p_aircraft uuid,              -- avion de destination
  p_with     text default null  -- échange : id d'inscription, ou 'organizer'
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_outing public.outings;
  v_from   uuid;              -- avion de départ
  v_reg    public.registrations;
  v_other  public.registrations;
  v_cap    int;
  v_used   int;
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

  -- Qui bouge, et d'où ?
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

  if p_with is null then
    -- Déplacement simple : il faut une place libre à l'arrivée
    select greatest(a.seats - case when v_outing.instructor_aircraft_id = a.id then 1 else 0 end, 0)
      into v_cap from public.aircraft a where a.id = p_aircraft;
    select count(*) into v_used from public.registrations
     where outing_id = p_outing and status = 'confirmed' and aircraft_id = p_aircraft;
    -- l'organisateur occupe un siège de plus
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
    -- Échange de places avec quelqu'un de l'avion de destination
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

  -- Contrôle final : aucun avion ne dépasse sa capacité
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
$$;
revoke execute on function public.move_crew(uuid, text, uuid, text) from public, anon;
grant execute on function public.move_crew(uuid, text, uuid, text) to authenticated;

notify pgrst, 'reload schema';


-- =====================================================================
-- migration-25-instructeur-referent.sql
-- =====================================================================
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


-- =====================================================================
-- migration-25-shop.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°25 : Le Shop — articles, commandes
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- Données d'exemple : posées une seule fois, à la première installation.
-- Relancer ce fichier plus tard ne les recrée pas et ne touche pas aux données saisies sur le site.
create table if not exists public._seeds (name text primary key, done_at timestamptz not null default now());
alter table public._seeds enable row level security;
revoke all on public._seeds from public, anon, authenticated;
create or replace function public._seed_once(p_name text)
returns boolean language plpgsql set search_path = '' as $fn$
begin
  insert into public._seeds (name) values (p_name) on conflict (name) do nothing;
  return found;
end;
$fn$;
revoke execute on function public._seed_once(text) from public, anon, authenticated;

-- Table des articles du shop
create table if not exists public.shop_items (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  description text,
  price_cents int not null default 0,   -- prix en centimes (0 = gratuit/sur devis)
  category    text not null default 'vetement', -- vetement | accessoire
  image_url   text,
  sizes       text,                     -- 'XS,S,M,L,XL,XXL' séparés par virgule, ou null
  colors      text,                     -- 'Blanc,Marine,Rouge' séparés par virgule, ou null
  active      boolean not null default true,
  position    int not null default 0,
  created_at  timestamptz not null default now()
);

-- Table des commandes
create table if not exists public.shop_orders (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  item_id     uuid not null references public.shop_items(id) on delete restrict,
  quantity    int not null default 1,
  size        text,
  color       text,
  note        text,
  status      text not null default 'pending', -- pending | confirmed | ready | delivered | cancelled
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- RLS
alter table public.shop_items enable row level security;
alter table public.shop_orders enable row level security;

-- shop_items : lisibles par tous les membres, modifiables par admin
drop policy if exists "shop_items_read"   on public.shop_items;
drop policy if exists "shop_items_write"  on public.shop_items;

create policy "shop_items_read" on public.shop_items
  for select using (public.is_approved());

create policy "shop_items_write" on public.shop_items
  for all using (
    exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
  );

-- shop_orders : chaque membre voit ses commandes ; admin voit tout
drop policy if exists "shop_orders_self"   on public.shop_orders;
drop policy if exists "shop_orders_admin"  on public.shop_orders;
drop policy if exists "shop_orders_insert" on public.shop_orders;

create policy "shop_orders_insert" on public.shop_orders
  for insert with check (user_id = auth.uid() and public.is_approved());

create policy "shop_orders_self" on public.shop_orders
  for select using (user_id = auth.uid());

create policy "shop_orders_admin" on public.shop_orders
  for all using (
    exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
  );

-- Trigger updated_at
create or replace function public.touch_shop_order()
returns trigger language plpgsql security definer set search_path = '' as $$
begin new.updated_at := now(); return new; end; $$;

drop trigger if exists touch_shop_order on public.shop_orders;
create trigger touch_shop_order
  before update on public.shop_orders
  for each row execute function public.touch_shop_order();

-- Quelques articles d'exemple (à adapter / supprimer)
-- (seulement si le catalogue est vide, pour pouvoir relancer ce fichier sans créer de doublons)
do $seed$ begin
  if not public._seed_once('shop-25') then return; end if;
insert into public.shop_items (name, description, price_cents, category, sizes, colors, position)
select * from (values
  ('T-shirt club', 'T-shirt coton 100% aux couleurs du club, logo brodé au cœur', 2500, 'Vêtements', 'XS,S,M,L,XL,XXL', 'Blanc,Marine', 1),
  ('Polaire softshell', 'Veste softshell légère avec logo club, idéale pour les briefings sur le tarmac', 5500, 'Vêtements', 'S,M,L,XL,XXL', 'Marine,Gris', 2),
  ('Casquette brodée', 'Casquette ajustable avec logo club brodé', 2000, 'Accessoires', null, 'Marine,Blanc', 3),
  ('Mug "Pilote"', 'Mug céramique 350 ml, motif avion et indicatif LFMA', 1200, 'Accessoires', null, 'Blanc', 4),
  ('Sticker pack', 'Pack de 5 stickers vinyle : logo club, LFMA, avions de la flotte…', 500, 'Accessoires', null, null, 5)
) as v(name, description, price_cents, category, sizes, colors, position)
where not exists (select 1 from public.shop_items);
end $seed$;

-- Colonnes ajoutées depuis (nom et prix figés à la commande, débit de l'ardoise)
alter table public.shop_orders
  add column if not exists item_name       text,
  add column if not exists price_cents     int,
  add column if not exists ardoise_charged boolean not null default false;

notify pgrst, 'reload schema';


-- =====================================================================
-- migration-26-aircraft-mb-data.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°26 : données masse & centrage depuis les manuels de vol
--  et fiches de pesée de chaque appareil.
--  « Base toi sur les manuels de vol de chaque avion, n'invente rien. »
-- =====================================================================

-- Données d'exemple : posées une seule fois, à la première installation.
-- Relancer ce fichier plus tard ne les recrée pas et ne touche pas aux données saisies sur le site.
create table if not exists public._seeds (name text primary key, done_at timestamptz not null default now());
alter table public._seeds enable row level security;
revoke all on public._seeds from public, anon, authenticated;
create or replace function public._seed_once(p_name text)
returns boolean language plpgsql set search_path = '' as $fn$
begin
  insert into public._seeds (name) values (p_name) on conflict (name) do nothing;
  return found;
end;
$fn$;
revoke execute on function public._seed_once(text) from public, anon, authenticated;

-- -------------------------------------------------------------------------
-- PS-28 Cruiser × 5  (F-HNLR, F-HSAC, F-HUIT, F-HPSA, F-HSAA)
--
-- Sources : Manuel de vol PS-28 Cruiser (Czech Sport Aircraft)
--           + fiches de pesée individuelles
-- MTOW : 600 kg — MLW : 600 kg (avion LSA)
-- Datum : Rib #4 (nervure n°4) — d'après POH section 6.4
-- Réservoir principal : 2 × 57 L (total 114 L), bras 0.180 m
-- Postes (d'après tableau de chargement du POH) :
--   Pilote           0.700 m  max 115 kg
--   Passager         0.700 m  max 115 kg
--   Bagages coffre   1.310 m  max 18 kg
--   Casiers d'aile   0.600 m  max 20 kg  (10 kg par aile × 2, dans l'aile → exclus du MZFW)
--   Carburant        0.180 m  max 114 L  (fuel, density 0.72)
-- Domaine : rectangle 0.420–0.525 m × 400–600 kg
-- -------------------------------------------------------------------------

do $seed$ begin
  if not public._seed_once('centrage-26') then return; end if;
-- F-HNLR
insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow, mlw,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  null,             -- numéro de série non disponible dans les documents fournis
  386.5,            -- fiche de pesée F-HNLR
  164.2625,         -- fiche de pesée F-HNLR
  600, 600,
  0.180, 0.72, 114,
  '[
    {"label":"Pilote",         "arm":0.700,"max":115},
    {"label":"Passager",       "arm":0.700,"max":115},
    {"label":"Bagages coffre", "arm":1.310,"max":18},
    {"label":"Casiers aile",   "arm":0.600,"max":20, "wing":true},
    {"label":"Carburant",      "arm":0.180,"max":114,"fuel":true}
  ]'::jsonb,
  '[
    {"arm":0.420,"mass":400},
    {"arm":0.420,"mass":600},
    {"arm":0.525,"mass":600},
    {"arm":0.525,"mass":400}
  ]'::jsonb,
  'Manuel de vol PS-28 Cruiser (Czech Sport Aircraft) + fiche de pesée F-HNLR',
  now()
from public.aircraft a
where a.registration = 'F-HNLR'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = excluded.mlw,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- F-HSAC
insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow, mlw,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  null,
  393.0,            -- fiche de pesée F-HSAC
  170.022,          -- fiche de pesée F-HSAC
  600, 600,
  0.180, 0.72, 114,
  '[
    {"label":"Pilote",         "arm":0.700,"max":115},
    {"label":"Passager",       "arm":0.700,"max":115},
    {"label":"Bagages coffre", "arm":1.310,"max":18},
    {"label":"Casiers aile",   "arm":0.600,"max":20, "wing":true},
    {"label":"Carburant",      "arm":0.180,"max":114,"fuel":true}
  ]'::jsonb,
  '[
    {"arm":0.420,"mass":400},
    {"arm":0.420,"mass":600},
    {"arm":0.525,"mass":600},
    {"arm":0.525,"mass":400}
  ]'::jsonb,
  'Manuel de vol PS-28 Cruiser (Czech Sport Aircraft) + fiche de pesée F-HSAC',
  now()
from public.aircraft a
where a.registration = 'F-HSAC'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = excluded.mlw,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- F-HUIT
insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow, mlw,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  null,
  387.5,            -- fiche de pesée F-HUIT
  173.212,          -- fiche de pesée F-HUIT
  600, 600,
  0.180, 0.72, 114,
  '[
    {"label":"Pilote",         "arm":0.700,"max":115},
    {"label":"Passager",       "arm":0.700,"max":115},
    {"label":"Bagages coffre", "arm":1.310,"max":18},
    {"label":"Casiers aile",   "arm":0.600,"max":20, "wing":true},
    {"label":"Carburant",      "arm":0.180,"max":114,"fuel":true}
  ]'::jsonb,
  '[
    {"arm":0.420,"mass":400},
    {"arm":0.420,"mass":600},
    {"arm":0.525,"mass":600},
    {"arm":0.525,"mass":400}
  ]'::jsonb,
  'Manuel de vol PS-28 Cruiser (Czech Sport Aircraft) + fiche de pesée F-HUIT',
  now()
from public.aircraft a
where a.registration = 'F-HUIT'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = excluded.mlw,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- F-HPSA
insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow, mlw,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  null,
  402.7,            -- fiche de pesée F-HPSA
  173.3057,         -- fiche de pesée F-HPSA
  600, 600,
  0.180, 0.72, 114,
  '[
    {"label":"Pilote",         "arm":0.700,"max":115},
    {"label":"Passager",       "arm":0.700,"max":115},
    {"label":"Bagages coffre", "arm":1.310,"max":18},
    {"label":"Casiers aile",   "arm":0.600,"max":20, "wing":true},
    {"label":"Carburant",      "arm":0.180,"max":114,"fuel":true}
  ]'::jsonb,
  '[
    {"arm":0.420,"mass":400},
    {"arm":0.420,"mass":600},
    {"arm":0.525,"mass":600},
    {"arm":0.525,"mass":400}
  ]'::jsonb,
  'Manuel de vol PS-28 Cruiser (Czech Sport Aircraft) + fiche de pesée F-HPSA',
  now()
from public.aircraft a
where a.registration = 'F-HPSA'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = excluded.mlw,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- F-HSAA  (remplace l'entrée partielle de la migration-20)
insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow, mlw,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  'C0502',          -- numéro de série (figurait dans la migration-20)
  393.5,            -- fiche de pesée F-HSAA
  169.789,          -- fiche de pesée F-HSAA (169.8 arrondi précédent, valeur exacte)
  600, 600,
  0.180, 0.72, 114,
  '[
    {"label":"Pilote",         "arm":0.700,"max":115},
    {"label":"Passager",       "arm":0.700,"max":115},
    {"label":"Bagages coffre", "arm":1.310,"max":18},
    {"label":"Casiers aile",   "arm":0.600,"max":20, "wing":true},
    {"label":"Carburant",      "arm":0.180,"max":114,"fuel":true}
  ]'::jsonb,
  '[
    {"arm":0.420,"mass":400},
    {"arm":0.420,"mass":600},
    {"arm":0.525,"mass":600},
    {"arm":0.525,"mass":400}
  ]'::jsonb,
  'Manuel de vol PS-28 Cruiser (Czech Sport Aircraft) + fiche de pesée F-HSAA',
  now()
from public.aircraft a
where a.registration = 'F-HSAA'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = excluded.mlw,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- -------------------------------------------------------------------------
-- Diamond DA40 (F-HXAF)
--
-- Sources : DA40 POH + fiche de pesée F-HXAF
-- MTOW : 1150 kg — MLW : 1092 kg — MZFW : 1150 kg
-- Datum : bord d'attaque intrados (standard Diamond)
-- Réservoir : 2 × 64 L = 128 L usable, bras 2.630 m
-- Postes :
--   Sièges avant           2.300 m  pas de max individuel (limite structurelle combinée)
--   Sièges arrière         3.250 m  idem
--   Bagages standard       3.650 m  max 30 kg
--   Bagages tube            4.320 m  max 5 kg
-- -------------------------------------------------------------------------

insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow, mlw, mzfw,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  null,
  774.5,            -- fiche de pesée F-HXAF
  1878.16,          -- fiche de pesée F-HXAF  (en kg.m)
  1150, 1092, 1150,
  2.630, 0.72, 128,
  '[
    {"label":"Sièges avant",      "arm":2.300,"max":null},
    {"label":"Sièges arrière",    "arm":3.250,"max":null},
    {"label":"Bagages standard",  "arm":3.650,"max":30},
    {"label":"Bagages tube",      "arm":4.320,"max":5}
  ]'::jsonb,
  '[
    {"arm":2.40,"mass":780},
    {"arm":2.40,"mass":980},
    {"arm":2.46,"mass":1150},
    {"arm":2.59,"mass":1150},
    {"arm":2.59,"mass":780}
  ]'::jsonb,
  'Manuel de vol Diamond DA40 + fiche de pesée F-HXAF',
  now()
from public.aircraft a
where a.registration = 'F-HXAF'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = excluded.mlw,
  mzfw             = excluded.mzfw,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- -------------------------------------------------------------------------
-- Robin DR400-180 (F-HCLI)
--
-- Sources : Manuel de vol Robin DR400-180 + fiche de pesée F-HCLI
-- MTOW : 1100 kg — MLW : 1045 kg
-- Datum : bord d'attaque de la voilure rectangulaire
-- Pas de réservoir principal central (fuel_capacity_l = null) :
--   les réservoirs sont 2 postes de chargement en litres.
--   Le bras de référence carburant (fuel_arm) est celui du réservoir principal
--   utilisé comme bras par défaut pour le trip fuel.
-- Postes :
--   Sièges avant      0.410 m  max 154 kg (2 places)
--   Sièges arrière    1.190 m  max 154 kg (2 places)
--   Réservoir princ.  1.120 m  max 110 L  (fuel) — 78 kg / 0.72 = 108.3 L ≈ 110 L (fiche pesée confirme 79.2 kg = 110 L)
--   Réservoir ailes   0.100 m  max 80 L   (fuel, dans l'aile → wing)
--   Bagages           1.900 m  max 60 kg
-- Domaine : trapèze (d'après diagramme manuel DR400)
-- -------------------------------------------------------------------------

insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow, mlw,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  null,
  644.0,            -- fiche de pesée F-HCLI
  211.876,          -- fiche de pesée F-HCLI  (en kg.m)
  1100, 1045,
  1.120, 0.72, null,   -- pas de réservoir central ; bras = réservoir principal
  '[
    {"label":"Sièges avant",          "arm":0.410,"max":154},
    {"label":"Sièges arrière",        "arm":1.190,"max":154},
    {"label":"Réservoir principal",   "arm":1.120,"max":110,"fuel":true},
    {"label":"Réservoir ailes",       "arm":0.100,"max":80, "fuel":true,"wing":true},
    {"label":"Bagages",               "arm":1.900,"max":60}
  ]'::jsonb,
  '[
    {"arm":0.205,"mass":750},
    {"arm":0.328,"mass":1100},
    {"arm":0.564,"mass":1100},
    {"arm":0.428,"mass":750}
  ]'::jsonb,
  'Manuel de vol Robin DR400-180 + fiche de pesée F-HCLI',
  now()
from public.aircraft a
where a.registration = 'F-HCLI'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = excluded.mlw,
  mzfw             = null,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- -------------------------------------------------------------------------
-- Bristell B23-915 (F-HUFA)
--
-- Sources : Manuel de vol Bristell B23-915 (ADXC-73-003-AFM, Rév.B3, 24.11.2023)
--           + fiche de pesée F-HUFA (BRM-211, 07.07.2022)
-- MTOW : 750 kg (LSA)
-- S/N : 0077
-- Datum : flasque hélice (Propeller Flange)
-- Conversion %MAC → mètres : bras_m = MAC_LE + (%MAC/100) × MAC = 1.377 + (%MAC/100) × 1.343
-- Réservoir (§2.13) : 2 réservoirs × 60 L = 120 L total ; utilisable 2×56 = 112 L
--   Carburant approuvé : UL95/SP95, AVGAS UL91, AVGAS 100LL
--   bras : 1.600 m (§6.5 — "FUEL weight = qty×0.72 kg/liter, arm 1.600")
-- Postes (§6.5) :
--   Pilote & Passager           2.085 m  max 2×120 kg (voir §6.4 ; min 55 kg pilote)
--   Bagages derrière sièges     2.520 m  max 16 kg (lower 15 kg + upper 1 kg, §2.7)
--   Casiers aile (wing lockers) 2.025 m  max 40 kg (2×20 kg/côté, §2.7) — dans l'aile
--   Carburant                   1.600 m  max 120 L total (fuel)
-- Domaine CG (§2.8 — graphique en %MAC converti en mètres) :
--   %MAC 25%→34.5% (operating CG range)
--   Points clés :  (1.713,530) (1.713,600) (1.753,660) (1.793,750) (1.834,750) (1.840,600) (1.834,530)
-- -------------------------------------------------------------------------

insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  '0077',
  469.5,            -- fiche de pesée F-HUFA (07.07.2022)
  800.8,            -- fiche de pesée F-HUFA  (en kg.m)
  750,
  1.600, 0.72, 120,   -- §2.13 : 2×60 L = 120 L total
  '[
    {"label":"Pilote & Passager",       "arm":2.085,"max":240},
    {"label":"Bagages derrière sièges", "arm":2.520,"max":16},
    {"label":"Casiers aile",            "arm":2.025,"max":40,"wing":true},
    {"label":"Carburant",               "arm":1.600,"max":120,"fuel":true}
  ]'::jsonb,
  '[
    {"arm":1.713,"mass":530},
    {"arm":1.713,"mass":600},
    {"arm":1.753,"mass":660},
    {"arm":1.793,"mass":750},
    {"arm":1.834,"mass":750},
    {"arm":1.840,"mass":600},
    {"arm":1.834,"mass":530}
  ]'::jsonb,
  'Manuel de vol Bristell B23-915 (ADXC-73-003-AFM Rév.B3) + fiche de pesée F-HUFA (BRM-211 07.07.2022)',
  now()
from public.aircraft a
where a.registration = 'F-HUFA'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = null,
  mzfw             = null,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- -------------------------------------------------------------------------
-- WT9 Dynamic LSA (F-HVXD)
--
-- Sources : Manuel de vol WT9 Dynamic LSA (aerodynamika Žilina)
--           + fiche de pesée F-HVXD
-- MTOW : 600 kg (LSA)
-- Datum : 1.975 m en avant de la face intérieure du pare-feu (firewall)
-- Réservoir : 80 L usable, bras 2.580 m, densité 0.72
-- Postes (tableau Section 6 du POH) :
--   Pilote / Passager   3.130 m  max 120 kg combiné
--   Bagages             3.795 m  max 40 kg (2 × 20 kg)
-- Domaine CG (Section 6 du POH, graphique de centrage) :
--   polygone à 8 points lus sur le diagramme
-- Masse à vide : fiche de pesée F-HVXD (339.6 kg / 898.26 kg.m)
--   NB : le W&B Record du POH indique 344.6 kg / 911.16 kg.m après SB SBLSA-916-2019
--        (mars 2020) — la fiche de pesée individuelle fait foi.
-- -------------------------------------------------------------------------

insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  null,
  339.6,            -- fiche de pesée F-HVXD
  898.26,           -- fiche de pesée F-HVXD  (en kg.m)
  600,
  2.580, 0.72, 80,
  '[
    {"label":"Pilote / Passager", "arm":3.130,"max":120},
    {"label":"Bagages",           "arm":3.795,"max":40}
  ]'::jsonb,
  '[
    {"arm":2.704,"mass":405.0},
    {"arm":2.713,"mass":405.0},
    {"arm":2.730,"mass":412.0},
    {"arm":2.810,"mass":445.0},
    {"arm":2.824,"mass":465.3},
    {"arm":2.824,"mass":600.0},
    {"arm":2.748,"mass":600.0},
    {"arm":2.704,"mass":542.5}
  ]'::jsonb,
  'Manuel de vol WT9 Dynamic LSA (aerodynamika Žilina) + fiche de pesée F-HVXD',
  now()
from public.aircraft a
where a.registration = 'F-HVXD'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = null,
  mzfw             = null,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();
end $seed$;

notify pgrst, 'reload schema';


-- =====================================================================
-- migration-27-shareflight.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°27 : Shareflight — covoiturage aérien entre membres
--
--  Un pilote publie un projet de vol (départ, destination, date,
--  places libres, commentaire) ; d'autres membres peuvent s'inscrire
--  comme passagers. Le pilote ou un admin peut clore ou annuler le vol.
--  Les passagers peuvent se désinscrire tant que le vol n'est pas clôturé.
-- =====================================================================

-- Table principale : propositions de vols
create table if not exists public.flight_shares (
  id            uuid primary key default gen_random_uuid(),
  pilot_id      uuid not null references public.profiles (id) on delete cascade default auth.uid(),
  -- Aérodrome départ
  dep_icao      text not null check (dep_icao ~ '^[A-Z]{2}[A-Z0-9]{2}$'),
  dep_name      text not null check (length(btrim(dep_name)) between 1 and 80),
  dep_lat       numeric(8,5) not null,
  dep_lon       numeric(8,5) not null,
  -- Aérodrome arrivée
  arr_icao      text not null check (arr_icao ~ '^[A-Z]{2}[A-Z0-9]{2}$'),
  arr_name      text not null check (length(btrim(arr_name)) between 1 and 80),
  arr_lat       numeric(8,5) not null,
  arr_lon       numeric(8,5) not null,
  -- Vol
  flight_date   date not null,
  seats         smallint not null default 1 check (seats between 1 and 5),
  aircraft      text check (aircraft is null or length(btrim(aircraft)) <= 40),
  comment       text check (comment is null or length(comment) <= 600),
  -- Statut : open | closed | cancelled
  status        text not null default 'open' check (status in ('open','closed','cancelled')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  closed_at     timestamptz
);

create index if not exists flight_shares_date on public.flight_shares (flight_date) where status = 'open';
create index if not exists flight_shares_pilot on public.flight_shares (pilot_id);

alter table public.flight_shares enable row level security;
revoke truncate on public.flight_shares from public, anon, authenticated;

-- Lecture : tout membre approuvé
drop policy if exists flight_shares_select on public.flight_shares;
create policy flight_shares_select on public.flight_shares
  for select to authenticated using (public.is_approved());

-- Insertion : membre approuvé uniquement, pour soi-même
drop policy if exists flight_shares_insert on public.flight_shares;
create policy flight_shares_insert on public.flight_shares
  for insert to authenticated
  with check (public.is_approved() and pilot_id = auth.uid());

-- Mise à jour : pilote ou admin (statut, fermeture…)
drop policy if exists flight_shares_update on public.flight_shares;
create policy flight_shares_update on public.flight_shares
  for update to authenticated
  using (public.is_approved() and (pilot_id = auth.uid() or public.app_role() = 'admin'))
  with check (public.is_approved() and (pilot_id = auth.uid() or public.app_role() = 'admin'));

-- Pas de suppression physique
revoke delete on public.flight_shares from authenticated, anon;

-- Audit
drop trigger if exists zz_audit on public.flight_shares;
create trigger zz_audit after insert or update on public.flight_shares
  for each row execute function public._audit();


-- Table des passagers inscrits
create table if not exists public.flight_share_seats (
  id            uuid primary key default gen_random_uuid(),
  share_id      uuid not null references public.flight_shares (id) on delete cascade,
  member_id     uuid not null references public.profiles (id) on delete cascade,
  message       text check (message is null or length(message) <= 300),
  created_at    timestamptz not null default now(),
  unique (share_id, member_id)
);

create index if not exists flight_share_seats_share on public.flight_share_seats (share_id);

alter table public.flight_share_seats enable row level security;
revoke truncate on public.flight_share_seats from public, anon, authenticated;

-- Lecture : tout membre approuvé
drop policy if exists flight_share_seats_select on public.flight_share_seats;
create policy flight_share_seats_select on public.flight_share_seats
  for select to authenticated using (public.is_approved());

-- Inscription : pour soi-même, vol ouvert, pas déjà inscrit, place disponible
drop policy if exists flight_share_seats_insert on public.flight_share_seats;
create policy flight_share_seats_insert on public.flight_share_seats
  for insert to authenticated
  with check (
    public.is_approved()
    and member_id = auth.uid()
    and exists (
      select 1 from public.flight_shares fs
      where fs.id = share_id
        and fs.status = 'open'
        and fs.pilot_id <> auth.uid()
        and (
          select count(*) from public.flight_share_seats s2 where s2.share_id = fs.id
        ) < fs.seats
    )
  );

-- Désinscription : soi-même ou admin
drop policy if exists flight_share_seats_delete on public.flight_share_seats;
create policy flight_share_seats_delete on public.flight_share_seats
  for delete to authenticated
  using (public.is_approved() and (member_id = auth.uid() or public.app_role() = 'admin'));

notify pgrst, 'reload schema';


-- =====================================================================
-- migration-28-lancement.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°28 : corrections avant la mise en service
--  - Aligne le dépôt sur la base réelle (colonnes du shop, tables du quiz,
--    colonne referent_instructor_id) : sans effet si c'est déjà le cas.
--  - Shop : annulation par le membre et passage « livrée » avec débit de
--    l'ardoise, par des fonctions sécurisées (les tables restent protégées).
--  - Quiz : la bonne réponse n'est plus lisible avant d'avoir répondu, les
--    réponses ne sont plus lisibles sans être connecté ; question du jour,
--    réponse et classement passent par des fonctions.
--  - Stats bar + shop pour les administrateurs et le trésorier.
--  - Stockage : seuls les administrateurs déposent les images du shop
--    (images uniquement, 5 Mo maximum).
--  - Petits durcissements signalés par l'outil de sécurité de Supabase.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 0. Alignement du dépôt sur la base réelle --------------------------------
alter table public.outings
  add column if not exists referent_instructor_id uuid references public.profiles (id);

alter table public.shop_orders
  add column if not exists item_name       text,
  add column if not exists price_cents     int,
  add column if not exists ardoise_charged boolean not null default false;

create table if not exists public.quiz_questions (
  id          serial primary key,
  question    text not null,
  option_a    text not null,
  option_b    text not null,
  option_c    text not null,
  option_d    text not null,
  correct     char(1) not null check (correct in ('a', 'b', 'c', 'd')),
  explanation text,
  category    text,
  active      boolean not null default true
);
create table if not exists public.quiz_answers (
  id          serial primary key,
  user_id     uuid not null references auth.users (id) on delete cascade,
  question_id int  not null references public.quiz_questions (id),
  answered_on date not null,
  is_correct  boolean not null,
  unique (user_id, answered_on)
);
alter table public.quiz_questions enable row level security;
alter table public.quiz_answers  enable row level security;

-- 1. Shop --------------------------------------------------------------------
create or replace function public.cancel_shop_order(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.shop_orders;
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  select * into v_order from public.shop_orders where id = p_id for update;
  if not found then raise exception 'Commande introuvable.'; end if;
  if v_order.user_id <> auth.uid() and public.app_role() <> 'admin' then
    raise exception 'Ce n''est pas votre commande.';
  end if;
  if v_order.status <> 'pending' and public.app_role() <> 'admin' then
    raise exception 'Cette commande est déjà en préparation : contactez le club pour l''annuler.';
  end if;
  if v_order.status in ('delivered', 'cancelled') then raise exception 'Cette commande est déjà clôturée.'; end if;
  update public.shop_orders set status = 'cancelled', updated_at = now() where id = p_id;
end;
$$;

-- Change le statut d'une commande ; « delivered » débite l'ardoise du membre une seule fois.
create or replace function public.set_shop_order_status(p_id uuid, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order   public.shop_orders;
  v_label   text;
  v_variant text;
  v_charged boolean := false;
begin
  if public.app_role() is distinct from 'admin' then raise exception 'Réservé aux administrateurs.'; end if;
  if p_status not in ('pending', 'confirmed', 'ready', 'delivered', 'cancelled') then
    raise exception 'Statut inconnu.';
  end if;
  select * into v_order from public.shop_orders where id = p_id for update;
  if not found then raise exception 'Commande introuvable.'; end if;

  if p_status = 'delivered' and not v_order.ardoise_charged and coalesce(v_order.price_cents, 0) > 0 then
    v_variant := concat_ws(' / ', nullif(v_order.size, ''), nullif(v_order.color, ''));
    v_label := 'Shop – ' || coalesce(v_order.item_name, 'Article')
               || case when v_variant <> '' then ' (' || v_variant || ')' else '' end;
    insert into public.bar_consumptions (user_id, product_id, product_name, unit_price_cents, quantity, created_by)
    values (v_order.user_id, null, v_label, v_order.price_cents, v_order.quantity, auth.uid());
    v_charged := true;
  end if;

  update public.shop_orders
     set status = p_status,
         ardoise_charged = ardoise_charged or v_charged,
         updated_at = now()
   where id = p_id;
  return jsonb_build_object('charged', v_charged);
end;
$$;

revoke execute on function public.cancel_shop_order(uuid) from public, anon;
revoke execute on function public.set_shop_order_status(uuid, text) from public, anon;
grant execute on function public.cancel_shop_order(uuid) to authenticated;
grant execute on function public.set_shop_order_status(uuid, text) to authenticated;

-- Fonction de déclencheur : n'a pas à être appelable depuis l'API
do $$ begin
  if exists (select 1 from pg_proc where proname = 'touch_shop_order' and pronamespace = 'public'::regnamespace) then
    execute 'revoke execute on function public.touch_shop_order() from public, anon, authenticated';
  end if;
end $$;

-- 2. Quiz --------------------------------------------------------------------
drop policy if exists quiz_answers_all_read on public.quiz_answers;
drop policy if exists quiz_answers_own_read on public.quiz_answers;
drop policy if exists quiz_answers_own_insert on public.quiz_answers;
drop policy if exists quiz_questions_read on public.quiz_questions;
-- Plus aucun accès direct : tout passe par les fonctions ci-dessous
revoke all on public.quiz_questions, public.quiz_answers from anon, authenticated;

-- Jour du quiz = date à Paris
create or replace function public.quiz_day() returns date
language sql stable set search_path = ''
as $$ select (now() at time zone 'Europe/Paris')::date $$;

-- Question du jour, sans la bonne réponse (et la réponse du membre s'il a déjà joué)
create or replace function public.quiz_today()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_n   int;
  v_q   public.quiz_questions;
  v_ans public.quiz_answers;
begin
  if not public.is_approved() then return null; end if;
  select count(*) into v_n from public.quiz_questions where active;
  if v_n = 0 then return null; end if;
  select * into v_q from public.quiz_questions where active order by id
   offset ((public.quiz_day() - date '2026-01-01') % v_n + v_n) % v_n limit 1;
  select * into v_ans from public.quiz_answers where user_id = auth.uid() and answered_on = public.quiz_day();
  return jsonb_build_object(
    'id', v_q.id, 'question', v_q.question, 'category', v_q.category,
    'option_a', v_q.option_a, 'option_b', v_q.option_b, 'option_c', v_q.option_c, 'option_d', v_q.option_d,
    'already_answered', v_ans.id is not null,
    -- après avoir répondu, on peut revoir la correction
    'correct', case when v_ans.id is not null then v_q.correct end,
    'explanation', case when v_ans.id is not null then v_q.explanation end
  );
end;
$$;

-- Enregistre la réponse du jour (une seule par jour) et renvoie la correction
create or replace function public.quiz_answer(p_question int, p_answer text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today jsonb := public.quiz_today();
  v_q     public.quiz_questions;
  v_ok    boolean;
begin
  if v_today is null then raise exception 'Pas de question aujourd''hui.'; end if;
  if (v_today->>'id')::int <> p_question then raise exception 'Ce n''est plus la question du jour : rechargez la page.'; end if;
  if (v_today->>'already_answered')::boolean then raise exception 'Vous avez déjà répondu aujourd''hui.'; end if;
  select * into v_q from public.quiz_questions where id = p_question;
  v_ok := v_q.correct = lower(btrim(p_answer));
  insert into public.quiz_answers (user_id, question_id, answered_on, is_correct)
  values (auth.uid(), p_question, public.quiz_day(), v_ok)
  on conflict (user_id, answered_on) do nothing;
  return jsonb_build_object('correct', v_ok, 'answer', v_q.correct, 'explanation', v_q.explanation);
end;
$$;

-- Classement : membres validés, non anonymisés
create or replace function public.quiz_leaderboard()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  return coalesce((
    select jsonb_agg(x order by x.correct desc, x.total desc, x.full_name)
    from (
      select p.id as user_id, p.full_name, p.avatar_url,
             count(*)::int as total, count(*) filter (where a.is_correct)::int as correct
      from public.quiz_answers a
      join public.profiles p on p.id = a.user_id
      where p.role <> 'pending' and p.anonymized_at is null
      group by p.id, p.full_name, p.avatar_url
      order by 5 desc, 4 desc
      limit 50
    ) x), '[]'::jsonb);
end;
$$;

-- Mes 30 dernières réponses
create or replace function public.quiz_my_history()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'question_id', a.question_id, 'answered_on', a.answered_on, 'is_correct', a.is_correct,
           'question', q.question, 'category', q.category) order by a.answered_on desc), '[]'::jsonb)
  from (select * from public.quiz_answers where user_id = auth.uid() order by answered_on desc limit 30) a
  join public.quiz_questions q on q.id = a.question_id;
$$;

revoke execute on function public.quiz_today(), public.quiz_answer(int, text), public.quiz_leaderboard(),
  public.quiz_my_history(), public.quiz_day() from public, anon;
grant execute on function public.quiz_today(), public.quiz_answer(int, text), public.quiz_leaderboard(),
  public.quiz_my_history(), public.quiz_day() to authenticated;

-- 3. Stats bar + shop (administrateurs et trésorier) -------------------------
create or replace function public.revenue_stats(p_months int default 12)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_from date := (date_trunc('month', now() at time zone 'Europe/Paris') - make_interval(months => greatest(p_months, 1) - 1))::date;
begin
  if not (public.app_role() = 'admin' or public.is_treasurer()) then
    raise exception 'Réservé aux administrateurs et au trésorier.';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('month', to_char(m, 'YYYY-MM'), 'bar', bar, 'shop', shop) order by m)
    from (
      select m::date,
             (select coalesce(sum(c.unit_price_cents * c.quantity), 0) from public.bar_consumptions c
               where c.product_id is not null   -- les lignes « Shop – … » débitées sur l'ardoise sont comptées côté shop
                 and date_trunc('month', c.created_at at time zone 'Europe/Paris') = m)::bigint as bar,
             (select coalesce(sum(o.price_cents * o.quantity), 0) from public.shop_orders o
               where o.status = 'delivered'
                 and date_trunc('month', o.created_at at time zone 'Europe/Paris') = m)::bigint as shop
      from generate_series(v_from, (now() at time zone 'Europe/Paris')::date, interval '1 month') as m
    ) t), '[]'::jsonb);
end;
$$;
revoke execute on function public.revenue_stats(int) from public, anon;
grant execute on function public.revenue_stats(int) to authenticated;

-- 4. Stockage des images du shop ---------------------------------------------
do $$ begin
  if to_regclass('storage.buckets') is not null then
    update storage.buckets
       set file_size_limit = 5242880,
           allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
     where id = 'documents';
  end if;
end $$;
drop policy if exists "Authenticated users can upload shop images" on storage.objects;
drop policy if exists shop_images_insert on storage.objects;
create policy shop_images_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'documents' and name like 'shop/%' and public.app_role() = 'admin');
drop policy if exists shop_images_delete on storage.objects;
create policy shop_images_delete on storage.objects for delete to authenticated
  using (bucket_id = 'documents' and name like 'shop/%' and public.app_role() = 'admin');

-- 5. Durcissements signalés par Supabase ---------------------------------------
do $$ begin
  if exists (select 1 from pg_proc where proname = 'bar_month_of' and pronamespace = 'public'::regnamespace) then
    execute 'alter function public.bar_month_of(timestamptz) set search_path = ''''';
  end if;
  if exists (select 1 from pg_proc where proname = '_audit_immutable' and pronamespace = 'public'::regnamespace) then
    execute 'alter function public._audit_immutable() set search_path = ''''';
  end if;
end $$;

notify pgrst, 'reload schema';

-- Vérification
select
  exists (select 1 from pg_proc where proname = 'set_shop_order_status')
  and exists (select 1 from pg_proc where proname = 'quiz_today')
  and exists (select 1 from pg_proc where proname = 'revenue_stats')
  and not exists (select 1 from pg_policies where tablename = 'quiz_answers' and policyname = 'quiz_answers_all_read')
  as "MISE A JOUR 28 OK";


-- =====================================================================
-- migration-29-espace-pedagogique.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°29 : Espace pédagogique
--  - Deux nouvelles fonctions à attribuer dans « Gestion des droits » :
--    chef pilote et responsable conformité. Avec les administrateurs, ce
--    sont eux qui publient dans l'Espace pédagogique.
--  - Documents pédagogiques (stockage privé, réservé aux membres validés).
--  - Annonces pédagogiques.
--  - Retours d'expérience (REX) : tout membre peut en déposer, de façon
--    anonyme s'il le souhaite ; le chef pilote et le responsable conformité
--    les analysent et publient un résumé et les enseignements.
--    Volontairement non journalisés, pour préserver l'anonymat.
--  - Nouveau type d'événement « Formation » (briefings, soirées théoriques).
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Nouvelles fonctions -----------------------------------------------------
alter table public.profiles
  add column if not exists is_chief_pilot boolean not null default false,
  add column if not exists is_compliance  boolean not null default false;

-- Peut publier dans l'Espace pédagogique
create or replace function public.can_teach()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select p.role = 'admin' or (p.role <> 'pending' and (p.is_chief_pilot or p.is_compliance))
    from public.profiles p where p.id = auth.uid()), false);
$$;
revoke execute on function public.can_teach() from public, anon;
grant execute on function public.can_teach() to authenticated;

-- 2. Type d'événement « Formation » -------------------------------------------
alter table public.outings drop constraint if exists outings_kind_check;
alter table public.outings add constraint outings_kind_check
  check (kind in ('vol', 'activite', 'evenement', 'formation'));

-- 3. Documents pédagogiques ----------------------------------------------------
create table if not exists public.pedagogy_documents (
  id          uuid primary key default gen_random_uuid(),
  category    text not null default 'autre'
              check (category in ('cours', 'procedures', 'securite', 'reglementation', 'examens', 'autre')),
  title       text not null check (length(btrim(title)) between 1 and 200),
  description text check (description is null or length(description) <= 1000),
  file_path   text not null unique,
  file_name   text not null,
  mime_type   text,
  size_bytes  bigint,
  created_by  uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at  timestamptz not null default now(),
  archived_at timestamptz
);
alter table public.pedagogy_documents enable row level security;
revoke truncate on public.pedagogy_documents from public, anon, authenticated;
drop policy if exists pedagogy_documents_select on public.pedagogy_documents;
create policy pedagogy_documents_select on public.pedagogy_documents for select to authenticated
  using (public.is_approved() and (archived_at is null or public.can_teach()));
drop policy if exists pedagogy_documents_insert on public.pedagogy_documents;
create policy pedagogy_documents_insert on public.pedagogy_documents for insert to authenticated
  with check (public.can_teach());
drop policy if exists pedagogy_documents_update on public.pedagogy_documents;
create policy pedagogy_documents_update on public.pedagogy_documents for update to authenticated
  using (public.can_teach()) with check (public.can_teach());
drop trigger if exists zz_audit on public.pedagogy_documents;
create trigger zz_audit after insert or update on public.pedagogy_documents
  for each row execute function public._audit();

do $$ begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit)
    values ('pedagogy', 'pedagogy', false, 52428800)
    on conflict (id) do update set public = false, file_size_limit = 52428800;
  end if;
end $$;
drop policy if exists pedagogy_files_select on storage.objects;
create policy pedagogy_files_select on storage.objects for select to authenticated
  using (bucket_id = 'pedagogy' and public.is_approved());
drop policy if exists pedagogy_files_insert on storage.objects;
create policy pedagogy_files_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'pedagogy' and public.can_teach());
drop policy if exists pedagogy_files_delete on storage.objects;
create policy pedagogy_files_delete on storage.objects for delete to authenticated
  using (bucket_id = 'pedagogy' and public.can_teach());

-- 4. Annonces pédagogiques ------------------------------------------------------
create table if not exists public.pedagogy_posts (
  id          uuid primary key default gen_random_uuid(),
  title       text not null check (length(btrim(title)) between 1 and 200),
  body        text not null check (length(btrim(body)) between 1 and 5000),
  important   boolean not null default false,
  created_by  uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  archived_at timestamptz
);
alter table public.pedagogy_posts enable row level security;
revoke truncate on public.pedagogy_posts from public, anon, authenticated;
drop policy if exists pedagogy_posts_select on public.pedagogy_posts;
create policy pedagogy_posts_select on public.pedagogy_posts for select to authenticated
  using (public.is_approved() and (archived_at is null or public.can_teach()));
drop policy if exists pedagogy_posts_insert on public.pedagogy_posts;
create policy pedagogy_posts_insert on public.pedagogy_posts for insert to authenticated
  with check (public.can_teach());
drop policy if exists pedagogy_posts_update on public.pedagogy_posts;
create policy pedagogy_posts_update on public.pedagogy_posts for update to authenticated
  using (public.can_teach()) with check (public.can_teach());
drop trigger if exists zz_audit on public.pedagogy_posts;
create trigger zz_audit after insert or update on public.pedagogy_posts
  for each row execute function public._audit();

-- 5. Retours d'expérience (REX) -------------------------------------------------
create table if not exists public.rex_reports (
  id             uuid primary key default gen_random_uuid(),
  author_id      uuid references public.profiles (id) on delete set null,
  anonymous      boolean not null default false,
  occurred_on    date check (occurred_on is null or occurred_on <= current_date + 1),
  phase          text not null default 'autre'
                 check (phase in ('sol', 'roulage', 'decollage', 'montee', 'croisiere', 'navigation',
                                  'approche', 'atterrissage', 'radio', 'meteo', 'autre')),
  title          text not null check (length(btrim(title)) between 1 and 200),
  description    text not null check (length(btrim(description)) between 1 and 5000),
  status         text not null default 'nouveau' check (status in ('nouveau', 'en_analyse', 'publie', 'clos')),
  public_summary text check (public_summary is null or length(public_summary) <= 5000),
  lessons        text check (lessons is null or length(lessons) <= 5000),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  published_at   timestamptz,
  -- un REX anonyme ne garde aucune trace de son auteur
  check (not anonymous or author_id is null)
);
alter table public.rex_reports enable row level security;
revoke truncate on public.rex_reports from public, anon, authenticated;
drop policy if exists rex_select on public.rex_reports;
create policy rex_select on public.rex_reports for select to authenticated
  using (public.can_teach() or (author_id is not null and author_id = auth.uid()));
drop policy if exists rex_insert on public.rex_reports;
create policy rex_insert on public.rex_reports for insert to authenticated
  with check (
    public.is_approved() and status = 'nouveau' and public_summary is null and lessons is null
    and published_at is null
    and ((anonymous and author_id is null) or (not anonymous and author_id = auth.uid()))
  );
drop policy if exists rex_update on public.rex_reports;
create policy rex_update on public.rex_reports for update to authenticated
  using (public.can_teach()) with check (public.can_teach());

create or replace function public._rex_touch()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  if tg_op = 'UPDATE' then
    -- le texte du déclarant et l'auteur ne se modifient pas
    new.author_id := old.author_id;
    new.anonymous := old.anonymous;
    new.description := old.description;
    new.created_at := old.created_at;
  end if;
  if new.status = 'publie' then
    if coalesce(btrim(new.public_summary), '') = '' then
      raise exception 'Rédigez le résumé public avant de publier ce REX.';
    end if;
    new.published_at := coalesce(new.published_at, now());
  end if;
  return new;
end;
$$;
drop trigger if exists rex_touch on public.rex_reports;
create trigger rex_touch before insert or update on public.rex_reports
  for each row execute function public._rex_touch();

-- REX publiés, visibles par tous les membres : sans auteur ni récit d'origine
create or replace function public.rex_published()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', r.id, 'title', r.title, 'phase', r.phase,
             'month', to_char(coalesce(r.occurred_on, r.created_at::date), 'YYYY-MM'),
             'summary', r.public_summary, 'lessons', r.lessons, 'published_at', r.published_at)
           order by r.published_at desc)
    from public.rex_reports r where r.status = 'publie'), '[]'::jsonb);
end;
$$;

-- Emails des personnes à prévenir quand un REX est déposé
create or replace function public.rex_reviewers()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case when public.is_approved() then coalesce((
    select jsonb_agg(jsonb_build_object('email', p.email, 'full_name', p.full_name))
    from public.profiles p
    where p.role <> 'pending' and p.anonymized_at is null and (p.is_chief_pilot or p.is_compliance)
      and coalesce(p.email, '') <> ''), '[]'::jsonb) else '[]'::jsonb end;
$$;
revoke execute on function public.rex_published(), public.rex_reviewers() from public, anon;
grant execute on function public.rex_published(), public.rex_reviewers() to authenticated;

-- 6. Fonctions existantes mises à jour ------------------------------------------
--    (organiser des événements, gérer les documents des avions, attribuer les
--     nouvelles fonctions, annuaire, type « formation » dans save_outing)
CREATE OR REPLACE FUNCTION public.can_organize()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce((select role in ('instructor', 'admin')
                          or (role <> 'pending' and (is_board or is_treasurer or is_secretary or is_maintenance or is_chief_pilot or is_compliance))
                   from public.profiles where id = auth.uid()), false)
$function$;

CREATE OR REPLACE FUNCTION public.can_manage_docs()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce((
    select p.role <> 'pending'
       and (p.role in ('admin', 'instructor') or p.is_instructor or p.is_board or p.is_maintenance
            or p.is_treasurer or p.is_secretary or p.is_chief_pilot or p.is_compliance)
    from public.profiles p where p.id = auth.uid()), false);
$function$;

CREATE OR REPLACE FUNCTION public.set_function(p_user uuid, p_function text, p_value boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v public.profiles%rowtype;
  v_admin boolean;
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  select * into v from public.profiles where id = p_user for update;
  if not found then raise exception 'Membre introuvable.'; end if;
  if v.role = 'pending' then
    raise exception 'Validez d''abord ce compte avant de lui attribuer une fonction.';
  end if;

  v_admin := v.role = 'admin';
  case p_function
    when 'admin' then
      if not p_value and p_user = auth.uid() then
        raise exception 'Vous ne pouvez pas retirer vos propres droits administrateur.';
      end if;
      v_admin := p_value;
      if not p_value then v.is_secretary := false; end if;
    when 'secretaire' then
      if not p_value and p_user = auth.uid() then
        raise exception 'Demandez à un autre administrateur de vous retirer le titre de secrétaire.';
      end if;
      v.is_secretary := p_value;
      if p_value then v_admin := true; end if;
    when 'instructeur' then v.is_instructor := p_value;
    when 'ca'          then v.is_board := p_value;
    when 'tresorier'   then v.is_treasurer := p_value;
    when 'maintenance' then v.is_maintenance := p_value;
    when 'chef_pilote' then v.is_chief_pilot := p_value;
    when 'conformite'  then v.is_compliance := p_value;
    else raise exception 'Fonction inconnue : %', p_function;
  end case;

  update public.profiles set
    is_instructor  = v.is_instructor,
    is_board       = v.is_board,
    is_treasurer   = v.is_treasurer,
    is_maintenance = v.is_maintenance,
    is_secretary   = v.is_secretary,
    is_chief_pilot = v.is_chief_pilot,
    is_compliance  = v.is_compliance,
    role = case when v_admin then 'admin'::public.user_role
                when v.is_instructor then 'instructor'::public.user_role
                else 'member'::public.user_role end
  where id = p_user;
end;
$function$;

CREATE OR REPLACE FUNCTION public.member_directory()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id, 'full_name', p.full_name,
             'phone', case when p.show_phone or p.id = auth.uid() then p.phone end,
             'avatar_url', p.avatar_url,
             'role', p.role, 'is_instructor', p.is_instructor,
             'is_chief_pilot', p.is_chief_pilot, 'is_compliance', p.is_compliance,
             'types', coalesce((select jsonb_agg(pt.aircraft_type order by pt.aircraft_type)
                                from public.pilot_types pt where pt.user_id = p.id), '[]'::jsonb))
           order by lower(p.full_name))
    from public.profiles p
    where p.role <> 'pending' and p.anonymized_at is null), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION public.save_outing(p_id uuid, p_title text, p_destination text, p_description text, p_meeting_point text, p_departure_at timestamp with time zone, p_return_at timestamp with time zone, p_deadline timestamp with time zone, p_aircraft uuid[], p_instructor_aircraft uuid, p_kind text DEFAULT 'vol'::text, p_max_participants integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;

notify pgrst, 'reload schema';

select
  exists (select 1 from information_schema.columns where table_name = 'profiles' and column_name = 'is_chief_pilot')
  and to_regclass('public.pedagogy_documents') is not null
  and to_regclass('public.pedagogy_posts') is not null
  and to_regclass('public.rex_reports') is not null
  and exists (select 1 from pg_proc where proname = 'rex_published')
  as "MISE A JOUR 29 OK";


-- =====================================================================
-- migration-30-sorties-avion.sql
-- =====================================================================
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


-- =====================================================================
-- migration-31-placement-organisateur.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°31 : placement d'office par l'organisateur
--  L'organisateur d'une sortie avion (ou un organisateur du club) peut
--  placer dans un avion une personne en liste d'attente, même si elle
--  n'est pas lâchée sur ce type et sans instructeur à bord : c'est sa
--  décision. La personne garde alors sa place lors des recalculs ; le
--  badge « non lâché » reste affiché.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

alter table public.registrations
  add column if not exists forced_seat boolean not null default false;

create or replace function public.place_waitlisted(p_registration uuid, p_aircraft uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_reg    public.registrations;
  v_outing public.outings;
  v_cap    int;
  v_used   int;
begin
  if v_uid is null then raise exception 'Vous devez être connecté.'; end if;
  select * into v_reg from public.registrations where id = p_registration;
  if not found then raise exception 'Inscription introuvable.'; end if;
  select * into v_outing from public.outings where id = v_reg.outing_id for update;
  select * into v_reg from public.registrations where id = p_registration;

  if not (public.can_organize() or v_outing.instructor_id = v_uid) then
    raise exception 'Seul un organisateur peut placer quelqu''un dans un avion.';
  end if;
  if coalesce(v_outing.kind, 'vol') <> 'vol' then raise exception 'Cet événement n''a pas d''avions.'; end if;
  if v_outing.status = 'cancelled' then raise exception 'Cette sortie est annulée.'; end if;
  if v_reg.status <> 'waitlist' then raise exception 'Cette personne n''est pas en liste d''attente.'; end if;
  if not exists (select 1 from public.outing_aircraft where outing_id = v_outing.id and aircraft_id = p_aircraft) then
    raise exception 'Cet avion ne fait pas partie de la sortie.';
  end if;
  if v_reg.guest_of is not null
     and not exists (select 1 from public.registrations where id = v_reg.guest_of and status = 'confirmed') then
    raise exception 'Placez d''abord le membre qui amène cet accompagnant.';
  end if;

  select greatest(a.seats - case when v_outing.instructor_aircraft_id = a.id then 1 else 0 end, 0)
    into v_cap from public.aircraft a where a.id = p_aircraft;
  select count(*) into v_used from public.registrations
   where outing_id = v_outing.id and status = 'confirmed' and aircraft_id = p_aircraft;
  if v_used >= v_cap then raise exception 'Cet avion est complet.'; end if;

  update public.registrations
     set status = 'confirmed', aircraft_id = p_aircraft,
         forced_seat = (v_reg.guest_of is null and not public._can_fly_in(v_reg.user_id, p_aircraft, v_outing.id))
   where id = p_registration;

  return (select jsonb_build_object('user_id', p.id, 'email', p.email, 'full_name', p.full_name, 'change', 'promoted')
            from public.profiles p where p.id = v_reg.user_id and v_reg.guest_of is null);
end;
$$;
revoke execute on function public.place_waitlisted(uuid, uuid) from public, anon;
grant execute on function public.place_waitlisted(uuid, uuid) to authenticated;

-- Recalcul des places : une personne placée d'office garde son siège
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
        select reg.id, reg.user_id, reg.status, reg.aircraft_id, reg.guest_of, reg.forced_seat
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
           and (v_pass <> 2 or r.forced_seat or v_instr[v_i] or public._is_released(r.user_id, v_type[v_i])) then
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
        update public.registrations set status = 'waitlist', aircraft_id = null, forced_seat = false where id = r.id;
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

-- Déplacement manuel : une personne placée d'office se déplace librement
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

  -- (une personne placée d'office par l'organisateur peut être déplacée librement)
  if p_who <> 'organizer' and v_reg.guest_of is null and not v_reg.forced_seat then
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
     and not r.forced_seat
     and not public._can_fly_in(r.user_id, a.id, p_outing)
   limit 1;
  if found then
    raise exception '% se retrouverait sans instructeur sur un % où il/elle n''est pas lâché(e) — déplacement refusé.', v_nom, v_ac_type;
  end if;
end;
$function$;

notify pgrst, 'reload schema';

select exists (select 1 from pg_proc where proname = 'place_waitlisted') as "MISE A JOUR 31 OK";


-- =====================================================================
-- migration-32-securite-sauvegarde.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°32 : sécurisation et sauvegarde
--  - Aligne les fichiers du dépôt sur la base en service (catégorie
--    « Taxes » des bons plans, détails des tables du quiz et du shop,
--    version de review_outing) : une nouvelle installation est identique.
--  - Anonymisation RGPD plus complète (accompagnants, REX signés, messages,
--    notes de commande, nouvelles fonctions).
--  - Export complet des données du club pour les administrateurs
--    (page « Sauvegarde »).
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Alignement ---------------------------------------------------------------
alter table public.airfield_tips drop constraint if exists airfield_tips_category_check;
alter table public.airfield_tips add constraint airfield_tips_category_check
  check (category in ('resto', 'avitaillement', 'hebergement', 'visite', 'taxes', 'autre'));

update public.quiz_questions set category = 'general' where category is null;
alter table public.quiz_questions alter column category set default 'general';
alter table public.quiz_questions alter column category set not null;
alter table public.quiz_questions alter column active set default true;
alter table public.quiz_questions alter column active set not null;
alter table public.quiz_answers alter column id type bigint;
alter table public.quiz_answers alter column answered_on set default current_date;
create index if not exists quiz_answers_user_date on public.quiz_answers (user_id, answered_on);
create index if not exists quiz_answers_date on public.quiz_answers (answered_on);

update public.shop_orders o set item_name = coalesce(o.item_name, i.name, 'Article'),
                                price_cents = coalesce(o.price_cents, i.price_cents, 0)
  from public.shop_items i where i.id = o.item_id and (o.item_name is null or o.price_cents is null);
alter table public.shop_orders alter column item_name set not null;
alter table public.shop_orders alter column price_cents set not null;

-- Flotte : de 1 à 9 places (et plus seulement 2 ou 4), pour tout type d'avion
alter table public.aircraft drop constraint if exists aircraft_seats_check;
alter table public.aircraft add constraint aircraft_seats_check check (seats between 1 and 9);

drop function if exists public.review_outing(uuid, boolean, text);
CREATE OR REPLACE FUNCTION public.review_outing(p_id uuid, p_approve boolean, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_outing public.outings;
begin
  if not public.is_staff() then raise exception 'Action réservée aux instructeurs.'; end if;
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

  return (select jsonb_build_object(
                   'email', p.email,
                   'full_name', p.full_name,
                   'title', v_outing.title,
                   'departure_at', v_outing.departure_at)
          from public.profiles p where p.id = v_outing.instructor_id);
end;
$function$;

revoke execute on function public.review_outing(uuid, boolean, text) from public, anon;
grant execute on function public.review_outing(uuid, boolean, text) to authenticated;

-- 2. Anonymisation RGPD complète ------------------------------------------------
CREATE OR REPLACE FUNCTION public.anonymize_member(p_user uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r record;
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  if p_user = auth.uid() then
    raise exception 'Vous ne pouvez pas anonymiser votre propre compte.';
  end if;
  if not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'Membre introuvable.';
  end if;

  -- Désinscription des événements à venir (les places libérées sont réattribuées)
  for r in
    select distinct g.outing_id from public.registrations g join public.outings o on o.id = g.outing_id
    where g.user_id = p_user and g.status <> 'cancelled' and o.departure_at > now()
  loop
    update public.registrations set status = 'cancelled'
     where outing_id = r.outing_id and user_id = p_user and status <> 'cancelled';
    perform public._rebalance_outing(r.outing_id);
  end loop;

  delete from public.pilot_weights where user_id = p_user;
  -- accompagnants annoncés, REX signés, messages : plus rien ne le relie à une personne
  update public.registrations set guest_name = 'Accompagnant', guest_weight_kg = null
   where user_id = p_user and guest_of is not null;
  update public.rex_reports set author_id = null where author_id = p_user;
  update public.flight_share_seats set message = null where member_id = p_user;
  update public.shop_orders set note = null where user_id = p_user;
  delete from public.pilot_types where user_id = p_user;

  update public.profiles set
    full_name = 'Ancien membre',
    email = 'anonyme-' || left(p_user::text, 8) || '@invalid.local',
    phone = null, address = null, emergency_name = null, emergency_phone = null,
    avatar_url = null,
    role = 'pending',
    is_instructor = false, is_board = false, is_treasurer = false, is_secretary = false, is_maintenance = false,
    is_chief_pilot = false, is_compliance = false,
    notify_events = false, show_phone = false,
    anonymized_at = now()
  where id = p_user;
end;
$function$;

revoke execute on function public.anonymize_member(uuid) from public, anon;
grant execute on function public.anonymize_member(uuid) to authenticated;

-- 3. Export complet (sauvegarde) pour les administrateurs ------------------------
create or replace function public.admin_export()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_out jsonb := '{}'::jsonb;
  v_t   text;
  v_rows jsonb;
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Réservé aux administrateurs.';
  end if;
  for v_t in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' order by c.relname
  loop
    execute format('select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from public.%I t', v_t) into v_rows;
    v_out := v_out || jsonb_build_object(v_t, v_rows);
  end loop;
  return jsonb_build_object(
    'format', 'sauvegarde-aeroclub-v1',
    'exported_at', now(),
    'tables', v_out,
    'files', (select coalesce(jsonb_agg(jsonb_build_object('bucket', o.bucket_id, 'path', o.name) order by o.bucket_id, o.name), '[]'::jsonb)
                from storage.objects o)
  );
end;
$$;
revoke execute on function public.admin_export() from public, anon;
grant execute on function public.admin_export() to authenticated;

notify pgrst, 'reload schema';

select exists (select 1 from pg_proc where proname = 'admin_export') as "MISE A JOUR 32 OK";


-- =====================================================================
-- migration-33-fiabilite.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°33 : fiabilité avant la mise en service
--  - Les données d'exemple (avions, masse et centrage, carte du bar, liens,
--    bons plans, shop) ne sont posées qu'à la première installation :
--    relancer « mise-a-jour-complete.sql » ne remet plus d'anciennes
--    masses à vide, d'anciens prix ou des avions retirés.
--  - Organisateurs (CA, trésorier, chef pilote…) : peuvent modifier leurs
--    événements publiés et retirer un participant ; les propositions à
--    valider ne s'affichent qu'à ceux qui peuvent les valider.
--  - Quiz : le chef pilote et le responsable conformité gèrent les
--    questions depuis l'Espace pédagogique.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Données d'exemple déjà posées sur cette base --------------------------------
create table if not exists public._seeds (name text primary key, done_at timestamptz not null default now());
alter table public._seeds enable row level security;
revoke all on public._seeds from public, anon, authenticated;
create or replace function public._seed_once(p_name text)
returns boolean language plpgsql set search_path = '' as $fn$
begin
  insert into public._seeds (name) values (p_name) on conflict (name) do nothing;
  return found;
end;
$fn$;
revoke execute on function public._seed_once(text) from public, anon, authenticated;

insert into public._seeds (name)
select unnest(array['bar-04', 'avions-08', 'bar-12', 'avions-19', 'liens-19', 'centrage-20', 'centrage-21',
                    'bar-22', 'bons-plans-23', 'shop-25', 'centrage-26'])
on conflict (name) do nothing;

-- 2. Questions du quiz : gérées par le chef pilote / resp. conformité / admins -------
grant select, insert, update, delete on public.quiz_questions to authenticated;
grant usage on sequence public.quiz_questions_id_seq to authenticated;
drop policy if exists quiz_questions_teach_select on public.quiz_questions;
create policy quiz_questions_teach_select on public.quiz_questions for select to authenticated
  using (public.can_teach());
drop policy if exists quiz_questions_teach_insert on public.quiz_questions;
create policy quiz_questions_teach_insert on public.quiz_questions for insert to authenticated
  with check (public.can_teach());
drop policy if exists quiz_questions_teach_update on public.quiz_questions;
create policy quiz_questions_teach_update on public.quiz_questions for update to authenticated
  using (public.can_teach()) with check (public.can_teach());
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'quiz_questions_text_check') then
    alter table public.quiz_questions add constraint quiz_questions_text_check check (
      length(btrim(question)) between 1 and 500
      and length(btrim(option_a)) between 1 and 300 and length(btrim(option_b)) between 1 and 300
      and length(btrim(option_c)) between 1 and 300 and length(btrim(option_d)) between 1 and 300
      and (explanation is null or length(explanation) <= 1500)) not valid;
  end if;
end $$;
drop policy if exists quiz_questions_teach_delete on public.quiz_questions;
create policy quiz_questions_teach_delete on public.quiz_questions for delete to authenticated
  using (public.can_teach());
drop trigger if exists zz_audit on public.quiz_questions;
create trigger zz_audit after insert or update or delete on public.quiz_questions
  for each row execute function public._audit();

-- 3. Événements : droits des organisateurs ------------------------------------------
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
    'can_edit',              public.can_organize() or (v_row.instructor_id = v_uid and v_row.approval <> 'approved'),
    'can_remove',            v_staff or public.can_organize() or v_row.instructor_id = v_uid,
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

  if v_reg.user_id <> v_uid and not (public.is_staff() or public.can_organize() or v_outing.instructor_id = v_uid) then
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
      where (o.approval = 'approved' or o.instructor_id = v_uid or public.is_staff())
        and case when p_past
                 then coalesce(o.return_at, o.departure_at) < now()
                 else coalesce(o.return_at, o.departure_at) >= now() end
      limit 200
    ) t), '[]'::jsonb);
end;
$function$;

revoke execute on function public.get_outing(uuid), public.cancel_registration(uuid), public.list_outings(boolean) from public, anon;
grant execute on function public.get_outing(uuid), public.cancel_registration(uuid), public.list_outings(boolean) to authenticated;

notify pgrst, 'reload schema';

select exists (select 1 from public._seeds where name = 'centrage-26')
   and exists (select 1 from pg_policies where policyname = 'quiz_questions_teach_update') as "MISE A JOUR 33 OK";


-- =====================================================================
-- migration-34-quiz.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°34 : quiz à 3 questions par jour et banque de questions
--  - Chaque membre a désormais 3 questions par jour (au lieu d'une).
--  - Les réponses fausses ou ambiguës des questions d'origine sont corrigées
--    (seulement si elles n'ont pas déjà été modifiées depuis le site).
--  - Environ 900 nouvelles questions (QCM à 4 réponses) sont ajoutées, une seule
--    fois : le chef pilote peut ensuite les modifier, les retirer ou les supprimer.
--    Une grande partie s'appuie sur le « Guide de l'instructeur VFR » de l'ENAC
--    (édition 3, amendement 2, 12-2021, licence CC BY-NC-ND), les autres sur le
--    programme théorique LAPL/PPL.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Plusieurs réponses par jour ---------------------------------------------------
alter table public.quiz_answers add column if not exists answer char(1);
do $$
declare r record;
begin
  -- l'ancienne règle « une réponse par membre et par jour » disparaît
  for r in
    select c.conname from pg_constraint c
     where c.conrelid = 'public.quiz_answers'::regclass and c.contype = 'u'
       and (select array_agg(a.attname::text order by a.attname) from pg_attribute a
             where a.attrelid = c.conrelid and a.attnum = any (c.conkey)) = array['answered_on', 'user_id']
  loop
    execute format('alter table public.quiz_answers drop constraint %I', r.conname);
  end loop;
end $$;
create unique index if not exists quiz_answers_user_day_question
  on public.quiz_answers (user_id, answered_on, question_id);

-- Nombre de questions par jour
create or replace function public.quiz_per_day() returns int
language sql immutable set search_path = '' as $$ select 3 $$;

-- Les questions d'un jour : mélange stable (md5 de l'identifiant) pour varier les thèmes,
-- puis 3 questions consécutives de ce mélange par jour.
create or replace function public._quiz_set(p_day date)
returns int[]
language sql
stable
set search_path = ''
as $$
  with q as (
    select id, (row_number() over (order by md5(id::text), id) - 1) as rn, count(*) over () as n
      from public.quiz_questions
     where active
  ), k as (
    select q.id, min(g.k) as k
      from generate_series(0, public.quiz_per_day() - 1) as g(k)
      join q on q.rn = ((((p_day - date '2026-01-01') * public.quiz_per_day() + g.k) % q.n) + q.n) % q.n
     group by q.id
  )
  select coalesce(array_agg(id order by k), '{}') from k;
$$;
revoke execute on function public._quiz_set(date) from public, anon, authenticated;

-- Questions du jour (sans la bonne réponse tant que le membre n'a pas répondu)
create or replace function public.quiz_today_set()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ids int[];
begin
  if not public.is_approved() then return null; end if;
  v_ids := public._quiz_set(public.quiz_day());
  if coalesce(array_length(v_ids, 1), 0) = 0 then return null; end if;
  return jsonb_build_object(
    'day', public.quiz_day(),
    'questions', (
      select jsonb_agg(jsonb_build_object(
               'id', q.id, 'question', q.question, 'category', q.category,
               'option_a', q.option_a, 'option_b', q.option_b, 'option_c', q.option_c, 'option_d', q.option_d,
               'already_answered', a.id is not null,
               'my_answer', a.answer,
               'is_correct', a.is_correct,
               'correct', case when a.id is not null then q.correct end,
               'explanation', case when a.id is not null then q.explanation end)
             order by s.ord)
        from unnest(v_ids) with ordinality as s(id, ord)
        join public.quiz_questions q on q.id = s.id
        left join public.quiz_answers a
          on a.user_id = auth.uid() and a.answered_on = public.quiz_day() and a.question_id = q.id)
  );
end;
$$;

-- Ancien format (une seule question) : première question du jour pas encore répondue
create or replace function public.quiz_today()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_set jsonb := public.quiz_today_set();
  v_q   jsonb;
begin
  if v_set is null then return null; end if;
  select x into v_q from jsonb_array_elements(v_set->'questions') x
   where not (x->>'already_answered')::boolean limit 1;
  return coalesce(v_q, v_set->'questions'->0);
end;
$$;

-- Enregistre une réponse : la question doit faire partie des questions du jour
create or replace function public.quiz_answer(p_question int, p_answer text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_q   public.quiz_questions;
  v_ok  boolean;
  v_ans text := lower(btrim(coalesce(p_answer, '')));
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  if v_ans not in ('a', 'b', 'c', 'd') then raise exception 'Réponse invalide.'; end if;
  if not (p_question = any (public._quiz_set(public.quiz_day()))) then
    raise exception 'Cette question ne fait plus partie des questions du jour : rechargez la page.';
  end if;
  if exists (select 1 from public.quiz_answers
              where user_id = auth.uid() and answered_on = public.quiz_day() and question_id = p_question) then
    raise exception 'Vous avez déjà répondu à cette question.';
  end if;
  select * into v_q from public.quiz_questions where id = p_question;
  v_ok := v_q.correct = v_ans;
  insert into public.quiz_answers (user_id, question_id, answered_on, is_correct, answer)
  values (auth.uid(), p_question, public.quiz_day(), v_ok, v_ans)
  on conflict (user_id, answered_on, question_id) do nothing;
  return jsonb_build_object('correct', v_ok, 'answer', v_q.correct, 'explanation', v_q.explanation);
end;
$$;

-- Mes réponses récentes (3 par jour : on en garde 60) et mon total
create or replace function public.quiz_my_history()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'question_id', a.question_id, 'answered_on', a.answered_on, 'is_correct', a.is_correct,
           'question', q.question, 'category', q.category) order by a.answered_on desc, a.id desc), '[]'::jsonb)
  from (select * from public.quiz_answers where user_id = auth.uid() order by answered_on desc, id desc limit 60) a
  join public.quiz_questions q on q.id = a.question_id;
$$;

create or replace function public.quiz_my_stats()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('total', count(*), 'correct', count(*) filter (where is_correct))
    from public.quiz_answers where user_id = auth.uid();
$$;

revoke execute on function public.quiz_today_set(), public.quiz_today(), public.quiz_answer(int, text),
  public.quiz_my_history(), public.quiz_my_stats(), public.quiz_per_day() from public, anon;
grant execute on function public.quiz_today_set(), public.quiz_today(), public.quiz_answer(int, text),
  public.quiz_my_history(), public.quiz_my_stats(), public.quiz_per_day() to authenticated;


-- 2. Questions d'origine : réponses fausses ou ambiguës corrigées --------------------
--    Chaque correction ne s'applique que si la question est encore dans sa version
--    d'origine (une question déjà retouchée depuis le site n'est pas modifiée).
update public.quiz_questions set
  correct = 'a',
  explanation = 'Le QNH est la pression mesurée sur l''aérodrome, ramenée au niveau moyen de la mer avec les caractéristiques de l''atmosphère standard. Calé sur le QNH, l''altimètre indique l''altitude de l''aérodrome une fois au sol.'
 where question = 'Quelle est la définition du QNH ?' and correct = 'b'
   and option_a = 'Pression au niveau de la mer calculée avec une atmosphère standard';

update public.quiz_questions set
  option_a = '-1,98°C / 1000 ft', option_b = '-0,65°C / 1000 ft', option_c = '-3,5°C / 1000 ft', option_d = '-1°C / 1000 ft',
  correct = 'a'
 where question = 'Le gradient de température standard de l''ISA est de :' and option_a = '-2°C / 1000 ft';

update public.quiz_questions set
  question = 'En France, au-dessus du FL195, l''espace aérien est en règle générale de classe :',
  option_a = 'A', option_b = 'C', option_c = 'E', option_d = 'G',
  correct = 'b',
  explanation = 'Depuis la mise en place de l''espace aérien supérieur harmonisé, l''espace situé au-dessus du FL195 est de classe C en France. Le vol VFR y est en principe interdit, sauf dérogation.'
 where question = 'Quelle est la limite inférieure de la classe A en France métropolitaine ?' and correct = 'a';

update public.quiz_questions set
  question = 'En classe G, au-dessous de 3000 ft AMSL (ou 1000 ft au-dessus du sol si c''est plus haut), quelle est la visibilité minimale VFR de base fixée par la réglementation SERA ?',
  option_a = '5 km', option_b = '8 km', option_c = '10 km', option_d = '800 m',
  correct = 'a',
  explanation = 'Le minimum de base est 5 km, hors des nuages et en vue de la surface. Il peut être abaissé à 1500 m pour un avion volant à 140 kt ou moins quand l''autorité le permet, ce qui est le cas en France.'
 where question = 'En VFR, quelle est la visibilité minimale en dessous de 3000 ft AMSL hors espace contrôlé ?' and correct = 'a'
   and option_a = '1,5 km';

update public.quiz_questions set
  explanation = 'En classe D, le contact radio bilatéral et la clairance du contrôle sont obligatoires pour tous les vols, VFR compris. Les VFR reçoivent l''information de trafic sur les autres vols.'
 where question like 'Un pilote VFR en classe D doit établir une communication radio bilatérale%' and correct = 'b'
   and explanation like '%la clairance ATC n''est pas requise%';

update public.quiz_questions set
  question = 'Au-dessus d''une agglomération, quelle est la hauteur minimale de survol en VFR (règle générale SERA) ?',
  option_a = '300 m (1000 ft) au-dessus de l''obstacle le plus élevé dans un rayon de 600 m',
  option_b = '150 m (500 ft) au-dessus du sol',
  option_c = '150 m au-dessus de l''obstacle le plus élevé dans un rayon de 150 m',
  option_d = '50 m au-dessus des toits',
  correct = 'a',
  explanation = 'Règle SERA : 300 m (1000 ft) au-dessus de l''obstacle le plus élevé situé dans un rayon de 600 m autour de l''aéronef. En France, des hauteurs plus importantes sont imposées au-dessus des grandes agglomérations (voir la carte et l''AIP).'
 where question = 'Quelle est la hauteur minimale VFR au-dessus des agglomérations ?' and correct = 'a'
   and option_a like '150 m%';

update public.quiz_questions set
  question = 'Deux avions convergent à peu près à la même altitude. Lequel doit céder le passage ?',
  option_a = 'Le plus rapide', option_b = 'Celui qui voit l''autre sur sa gauche',
  option_c = 'Celui qui voit l''autre sur sa droite', option_d = 'Le plus léger',
  correct = 'c',
  explanation = 'Règle de l''air : en route convergente, l''aéronef qui voit l''autre sur sa droite s''écarte. Face à face, chacun vire à droite.'
 where question like 'La règle de l''air VFR basique%' and correct = 'b';

update public.quiz_questions set
  option_a = 'Relèvement magnétique de l''avion vu depuis la station (QDR)'
 where question = 'Qu''est-ce que le QDM ?' and option_a = 'Relèvement magnétique de la station par rapport à l''avion';

update public.quiz_questions set
  option_a = 'L''écart entre l''altitude prévue et l''altitude réelle'
 where question = 'Qu''est-ce que la dérive en navigation ?' and option_a = 'Différence entre le cap et le route';

update public.quiz_questions set
  option_a = 'Poussée et traînée'
 where question = 'La finesse d''un avion est le rapport entre :' and option_a = 'Portance et traînée';

update public.quiz_questions set
  question = 'Quel phénomène le carburateur peut-il subir, même par température extérieure positive et air humide ?'
 where question = 'Qu''est-ce que le carburateur en hiver peut provoquer ?';

update public.quiz_questions set
  question = 'Quelle est l''altitude de l''aérodrome d''Aix-les-Milles (LFMA) ?',
  option_a = '124 ft', option_b = '368 ft', option_c = '95 ft', option_d = '980 ft',
  correct = 'b',
  explanation = 'D''après la carte VAC LFMA, l''altitude de l''aérodrome est 368 ft, soit une correction QNH-QFE d''environ 14 hPa.'
 where question = 'À quelle altitude se trouve l''aérodrome de LFMA ?' and correct = 'd';

update public.quiz_questions set
  question = 'Quelle est l''orientation de la piste revêtue de LFMA ?',
  correct = 'c',
  explanation = 'La piste d''Aix-les-Milles est la 14/32 (QFU 143° et 323°, carte VAC LFMA).'
 where question = 'Quelle est l''orientation de la piste principale de LFMA ?' and correct = 'a';

update public.quiz_questions set
  question = 'Quelle est la distance d''atterrissage utilisable (LDA) en piste 14 à LFMA ?',
  option_a = '1481 m', option_b = '1248 m', option_c = '1830 m', option_d = '1124 m',
  correct = 'b',
  explanation = 'D''après la carte VAC (AIP France, AD 2 LFMA, AMDT 11/26), la LDA est de 1248 m en piste 14 et de 1124 m en piste 32.'
 where question = 'Quelle est la LDA (Landing Distance Available) de la piste 13 à LFMA ?' and correct = 'c';

update public.quiz_questions set
  question = 'Quelle est la fréquence de la tour d''Aix-les-Milles (LFMA) ?',
  option_a = '118,105 MHz', option_b = '121,605 MHz', option_c = '118,755 MHz', option_d = '123,500 MHz',
  correct = 'c',
  explanation = 'AIX Tour : 118,755 (carte VAC LFMA, AMDT 11/26). Le sol est sur 121,605 et l''ATIS sur 136,230. Vérifiez toujours la VAC et les NOTAM en vigueur.'
 where question = 'Quelle est la fréquence de l''AFIS d''Aix-les-Milles (LFMA) ?' and correct = 'a';

update public.quiz_questions set
  question = 'Dans quel espace aérien se trouve l''aérodrome de LFMA ?',
  option_a = 'La CTR d''Aix, de classe D', option_b = 'La TMA de Nice', option_c = 'Un espace non contrôlé de classe G',
  option_d = 'Une CTR de classe A',
  correct = 'a',
  explanation = 'LFMA est au centre de la CTR AIX, de classe D, du sol à 2500 ft AMSL (AIP France). Contact radio et clairance y sont obligatoires.'
 where question = 'Quel type d''espace aérien entoure LFMA ?' and correct = 'a' and option_a like 'CTR de Marseille%';

update public.quiz_questions set
  option_a = 'Toujours à droite', option_b = 'Toujours face au nord',
  option_c = 'À gauche, sauf sens contraire publié (carte VAC)', option_d = 'Au choix du pilote',
  explanation = 'Par défaut, les virages du circuit se font à gauche. Le sens réel est celui publié pour chaque aérodrome (carte VAC), souvent choisi pour éviter les zones habitées ou le relief.'
 where question = 'Le circuit de piste standard se fait :' and correct = 'c';

update public.quiz_questions set
  question = 'Selon les bonnes pratiques enseignées en école, à quelle vitesse sol maximale roule-t-on habituellement sur les voies de circulation ?',
  option_a = 'Environ 10 kt (allure d''un homme qui marche vite)', option_b = '30 kt', option_c = '50 kt', option_d = 'Aucune limite',
  correct = 'a',
  explanation = 'Il n''y a pas de limite chiffrée générale, mais on roule à une vitesse permettant de s''arrêter immédiatement : environ 10 kt au maximum, moins sur l''aire de trafic.'
 where question = 'Quelle est la vitesse maximale en circulation (roulage) habituelle sur un aérodrome ?' and correct = 'a'
   and option_a = '30 kt';

update public.quiz_questions set
  question = 'La prise de pression totale (Pitot) et son orifice de purge sont bouchés, la prise statique est libre. En montée, l''anémomètre :',
  option_a = 'Indique une vitesse trop élevée', option_b = 'Indique une vitesse trop faible', option_c = 'Reste parfaitement juste',
  option_d = 'Tombe immédiatement à zéro',
  correct = 'a',
  explanation = 'La pression totale reste emprisonnée alors que la pression statique diminue en montée : l''écart augmente et l''anémomètre indique trop (il se comporte comme un altimètre). Si seule la prise Pitot est bouchée et la purge libre, l''indication tend vers zéro.'
 where question = 'Si la sonde Pitot est bouchée en montée, l''anémomètre :' and correct = 'c';

update public.quiz_questions set
  question = 'Quelle fréquence VHF est réservée aux communications air-air entre pilotes en France ?',
  option_a = '121,500 MHz', option_b = '123,450 MHz', option_c = '118,000 MHz', option_d = '123,500 MHz',
  correct = 'b',
  explanation = '123,450 MHz est la fréquence air-air. 123,500 MHz est la fréquence d''auto-information des aérodromes sans fréquence propre, 121,500 MHz la fréquence de détresse.'
 where question = 'Sur quelle fréquence doit être calée la radio VHF par défaut ?' and correct = 'b';

update public.quiz_questions set
  option_a = 'Toujours bimoteur'
 where question = 'Le Piper PA-28 Warrior est un avion :' and option_a = 'Bimotor à train tricycle rétractable';

update public.quiz_questions set
  question = 'Le moteur Lycoming O-320 qui équipe de nombreux avions école est un moteur :',
  option_a = '6 cylindres en ligne refroidi par liquide', option_b = 'Rotatif à pistons',
  option_c = '4 cylindres à plat (opposés) refroidi par air', option_d = 'Diesel 4 temps suralimenté',
  correct = 'c',
  explanation = 'Le « O » signifie « opposed » : 4 cylindres opposés à plat, refroidis par air, d''une cylindrée de 320 pouces cubes (environ 5,2 litres), pour 150 à 160 ch selon la version.'
 where question = 'La puissance du moteur Lycoming O-320 équipant de nombreux PA-28 est de :';

update public.quiz_questions set
  question = 'Que signifie le sigle ULM ?',
  option_a = 'Ultra-Léger Motorisé', option_b = 'Unité Légère de Manœuvre', option_c = 'Ultra-Long Moyen-courrier', option_d = 'Utilitaire Léger Monomoteur',
  correct = 'a',
  explanation = 'ULM signifie Ultra-Léger Motorisé. Ses limites de masse dépendent de la classe d''ULM et ont évolué : on se reporte à la réglementation en vigueur.'
 where question = 'Qu''est-ce qu''un aéronef ULM ?' and correct = 'b';

update public.quiz_questions set
  question = 'Quelle est la vitesse du son au niveau de la mer en atmosphère standard (15°C) ?',
  option_a = 'Environ 340 m/s', option_b = 'Environ 300 m/s', option_c = 'Environ 400 m/s', option_d = 'Environ 250 m/s',
  explanation = 'À 15°C, la vitesse du son vaut environ 340 m/s (661 kt, 1225 km/h). Elle diminue quand la température baisse.'
 where question = 'Quelle est la vitesse approximative du son à 0°C au niveau de la mer ?' and correct = 'a';

update public.quiz_questions set
  question = 'Qu''appelle-t-on l''« effet tunnel » en facteurs humains ?',
  explanation = 'L''effet tunnel est une focalisation de l''attention sur un seul élément (une panne, un instrument, la piste) au détriment de la surveillance globale : trajectoire, vitesse, trafic.'
 where question like 'Qu''est-ce que l''effet IMVP%';

update public.quiz_questions set
  question = 'Qu''est-ce que la déclinaison magnétique ?'
 where question = 'Qu''est-ce que la dérive magnétique (variation) ?';

update public.quiz_questions set
  option_c = 'La couleur du carburant, pour l''esthétique'
 where question = 'Que vérifie-t-on en drainant le carburant avant le vol ?' and option_c = 'La couleur du carburant pour la esthétique';


-- 3. Banque de questions (posée une seule fois) ----------------------------------
do $seed$ begin
  if not public._seed_once('quiz-34') then return; end if;
  insert into public.quiz_questions (question, option_a, option_b, option_c, option_d, correct, explanation, category)
  select v.question, v.option_a, v.option_b, v.option_c, v.option_d, v.correct, v.explanation, v.category
  from (values
    ('Au roulage, le vent vient de l''avant gauche. Où place-t-on le manche (ailerons) ?', 'À droite, côté opposé au vent', 'Au neutre, le vent n''a pas d''effet au roulage', 'À gauche, côté vent', 'Tout à fait en avant', 'c', 'Vent de l''avant : manche côté vent pour empêcher l''aile au vent de se soulever (effet dièdre). Vent de l''arrière : manche du côté opposé au vent.', 'pilotage'),
    ('Au roulage, le vent vient de l''arrière droit. Où place-t-on le manche latéralement ?', 'À gauche, du côté opposé au vent', 'À droite, côté vent', 'Au neutre', 'Peu importe, seul le palonnier compte', 'a', 'Quand le vent vient de l''arrière, on met le manche du côté opposé au vent pour que l''aileron ne laisse pas le vent soulever l''aile.', 'pilotage'),
    ('Au roulage par vent de travers, quelle tendance l''avion présente-t-il en lacet ?', 'Il s''écarte du vent', 'Il n''a aucune tendance', 'Il se met face au vent comme une girouette', 'Il cabre', 'c', 'L''empennage vertical offre une grande surface au vent : l''avion tend à pivoter face au vent (effet girouette). On le contre avec une pression constante au palonnier.', 'pilotage'),
    ('Pourquoi l''aile au vent a-t-elle tendance à se soulever par vent de travers ?', 'À cause de l''effet dièdre', 'À cause du couple moteur', 'À cause de l''effet de sol', 'À cause du lacet inverse', 'a', 'Le dièdre de l''aile fait que le vent latéral augmente la portance de l''aile exposée, qui tend à se soulever.', 'pilotage'),
    ('Pour s''arrêter au roulage, quel est le bon ordre des actions ?', 'Réduire la puissance, puis freiner', 'Freiner, puis réduire la puissance', 'Freiner en gardant la puissance', 'Couper le moteur puis freiner', 'a', 'On réduit d''abord la puissance, puis on freine. Rouler en freinant avec de la puissance est une erreur fréquente qui use les freins.', 'pilotage'),
    ('Pourquoi le pilote doit-il être « assis sur l''axe » pour s''aligner correctement ?', 'Pour mieux voir les instruments', 'Pour éviter l''erreur de parallaxe', 'Pour équilibrer le centrage', 'Pour être vu par la tour', 'b', 'Le pilote est assis à gauche de l''axe de l''avion : s''il se place sur la ligne axiale de la piste, il évite l''erreur de parallaxe dans son alignement.', 'pilotage'),
    ('Pour un avion à train classique au roulage, où place-t-on la profondeur par vent de face ?', 'Manche en avant', 'Au neutre', 'Manche en arrière', 'Peu importe', 'c', 'Selon le guide ENAC, avec un train classique on garde le manche arrière par vent de face, et le manche avant par vent arrière s''il dépasse le souffle de l''hélice (environ 15 kt).', 'pilotage'),
    ('Quelle est la différence entre une action et une check-list ?', 'Les actions préparent la phase de vol, la check-list vérifie ensuite qu''elles ont été faites', 'C''est la même chose', 'La check-list se fait avant les actions', 'Les actions sont facultatives', 'a', 'Les actions préparent la phase suivante ; la check-list est une vérification qui intervient à l''issue d''une série d''actions.', 'pilotage'),
    ('Dans toutes les phases, quelle est la priorité absolue, avant les check-lists ?', 'La radio', 'La lecture de la carte', 'Le pilotage de l''avion', 'Le remplissage du log', 'c', 'Les moyens mnémotechniques et check-lists ne sont pas une fin : la priorité est toujours le pilotage. En aucun cas une check-list ne passe avant la trajectoire.', 'pilotage'),
    ('Quelle commande agit sur l''axe de tangage ?', 'Les ailerons', 'La gouverne de direction', 'Le compensateur de direction', 'La gouverne de profondeur (manche d''avant en arrière)', 'd', 'Le manche en longitudinal commande la profondeur, donc la rotation en tangage.', 'pilotage'),
    ('Quelle commande agit sur l''axe de roulis ?', 'La profondeur', 'Les ailerons (manche latéralement)', 'Le palonnier', 'Les volets', 'b', 'Le manche déplacé latéralement braque les ailerons et fait tourner l''avion en roulis.', 'pilotage'),
    ('Quelle commande agit sur l''axe de lacet ?', 'La gouverne de direction (palonnier)', 'Les ailerons', 'La profondeur', 'La manette des gaz', 'a', 'Le palonnier braque la gouverne de direction et fait tourner l''avion autour de l''axe de lacet.', 'pilotage'),
    ('Tant qu''on maintient une action sur une commande, que fait l''avion ?', 'La rotation s''arrête d''elle-même', 'L''avion revient seul à sa position initiale', 'La rotation se poursuit', 'Rien', 'c', 'Une commande braquée crée une rotation qui continue tant que l''action est maintenue, quelle que soit la position de l''avion dans l''espace.', 'pilotage'),
    ('Comment appelle-t-on l''angle entre l''axe longitudinal de l''avion et l''horizontale ?', 'L''incidence', 'L''inclinaison', 'La pente', 'L''assiette', 'd', 'L''assiette (thêta) est l''angle entre l''axe longitudinal de l''avion et l''horizontale.', 'pilotage'),
    ('Comment appelle-t-on l''angle entre l''horizontale et le plan moyen des ailes ?', 'L''inclinaison', 'L''assiette', 'Le calage', 'Le dièdre', 'a', 'L''inclinaison (phi) est l''angle entre l''horizontale et le plan moyen des ailes.', 'pilotage'),
    ('Qu''est-ce que le repère pare-brise (RPB) ?', 'Un instrument de navigation', 'La ligne rouge de l''anémomètre', 'Un autocollant de check-list', 'Un repère lié à l''avion qu''on compare à l''horizon pour visualiser l''assiette et les mouvements', 'd', 'Le RPB est un repère fixe sur le pare-brise. Sa position par rapport à l''horizon matérialise l''assiette et son défilement montre les mouvements de l''avion.', 'pilotage'),
    ('En palier croisière, où se trouve en général le repère pare-brise ?', 'Nettement au-dessus de l''horizon', 'Sur l''horizon', 'Nettement au-dessous de l''horizon', 'Hors de vue', 'b', 'Le RPB sur l''horizon représente l''assiette de référence 0°, qui correspond au palier croisière dans les conditions standard.', 'pilotage'),
    ('Sur un avion léger, l''assiette de montée est en général d''environ :', '20° à cabrer', '0°', '5° à piquer', '5° à cabrer', 'd', 'Selon le guide ENAC, l''assiette de montée est d''environ 5° (soit environ 5 cm sur le pare-brise à 60 cm de l''œil).', 'pilotage'),
    ('Sur un avion léger, l''assiette de descente est en général d''environ :', '3° à piquer', '15° à piquer', '5° à cabrer', '0°', 'a', 'Le guide ENAC donne environ 3° à piquer, soit 3 cm sous l''horizon sur le pare-brise.', 'pilotage'),
    ('Quelle est la méthode pour afficher une nouvelle assiette ?', 'Maintien, action, compensation', 'Compensation, puis action', 'Puissance, puis assiette', 'Action, quantification, neutralisation, maintien', 'd', 'On visualise la valeur visée, on agit, on poursuit jusqu''à la valeur, on neutralise l''action, puis on maintient et on corrige si nécessaire.', 'pilotage'),
    ('Qu''est-ce que le lacet inverse ?', 'La tendance de l''avion à se mettre face au vent', 'Une rotation en lacet opposée au sens du roulis, due à la traînée plus forte de l''aileron baissé', 'Le couple de renversement du moteur', 'La rotation de l''avion vers le virage', 'b', 'L''aileron baissé traîne plus que l''aileron levé : en mise en virage à droite, le nez part d''abord à gauche.', 'pilotage'),
    ('Comment contrer le lacet inverse ?', 'En mettant du palonnier du côté opposé', 'En conjuguant : palonnier du même côté que le manche', 'En poussant sur le manche', 'En réduisant la puissance', 'b', 'La conjugaison consiste à agir sur le palonnier dans le même sens que la commande de roulis tant que celle-ci est braquée.', 'pilotage'),
    ('À quoi voit-on qu''un virage est correctement conjugué à la mise en virage ?', 'Le repère pare-brise commence à défiler dans le sens du virage en même temps que l''avion s''incline', 'La bille part à l''extérieur', 'Le nez part d''abord à l''opposé', 'L''altitude augmente', 'a', 'Une bonne conjugaison donne un défilement immédiat du RPB sur l''horizon dans le sens du virage.', 'pilotage'),
    ('L''amplitude de la conjugaison au palonnier dépend-elle de l''inclinaison obtenue ?', 'Non, elle dépend surtout de la vitesse et du braquage des ailerons', 'Oui, elle est proportionnelle à l''inclinaison', 'Oui, il faut 1° de palonnier par degré d''inclinaison', 'Il n''y a jamais besoin de conjuguer', 'a', 'Le guide ENAC précise que la conjugaison dépend de la vitesse, de l''amplitude et de la rapidité du braquage des ailerons, mais pas de l''inclinaison.', 'pilotage'),
    ('Le lacet inverse est-il plus sensible à basse ou à grande vitesse ?', 'À grande vitesse', 'Il ne dépend pas de la vitesse', 'À basse vitesse', 'Il n''existe qu''au sol', 'c', 'À basse vitesse, il faut de plus grands braquages d''ailerons : le lacet inverse est plus marqué et la conjugaison doit être plus ample.', 'pilotage'),
    ('Avant de virer, quel secteur faut-il surveiller tout particulièrement ?', 'Uniquement droit devant', 'Le côté opposé au virage', 'Le dessous de l''avion', 'Trois quarts arrière du côté du virage, à la même altitude', 'd', 'Avant la mise en virage on vérifie tout le secteur, en insistant sur les trois quarts arrière du côté où l''on va virer.', 'pilotage'),
    ('Un avion sur une trajectoire de collision avec le vôtre :', 'Défile rapidement de gauche à droite', 'Reste immobile dans le pare-brise et grossit', 'Disparaît rapidement', 'Est toujours plus haut que vous', 'b', 'Un avion en route de collision garde un relèvement constant : il ne bouge pas dans le pare-brise, il grossit, ce qui le rend difficile à repérer.', 'pilotage'),
    ('Une fois l''inclinaison établie dans un virage, sans action en tangage, l''assiette :', 'Varie à cabrer', 'Reste constante', 'Oscille', 'Varie à piquer', 'd', 'En virage, la portance s''incline : sans action à cabrer, l''avion part à piquer. Au retour à inclinaison nulle, il faut au contraire une action à piquer.', 'pilotage'),
    ('Plutôt que « augmenter l''assiette », quelle expression le guide ENAC recommande-t-il ?', 'Monter le nez', 'Tirer plus', 'Augmenter l''incidence', 'Variation d''assiette à cabrer', 'd', '« Augmenter ou diminuer l''assiette » est équivoque : on parle de variation d''assiette à cabrer ou à piquer.', 'pilotage'),
    ('Quels sont les trois effets moteurs principaux d''un monomoteur à hélice ?', 'Effet dièdre, effet girouette, effet de sol', 'Lacet inverse, dérapage, glissade', 'Traînée, portance, poids', 'Couple de renversement (roulis), souffle hélicoïdal (lacet), couple cabreur ou piqueur (tangage)', 'd', 'Le guide décrit le couple de renversement sur le roulis, le souffle hélicoïdal sur le lacet et le couple cabreur/piqueur sur le tangage.', 'pilotage'),
    ('Les effets moteurs sont les plus marqués :', 'À faible vitesse et forte puissance', 'À grande vitesse et faible puissance', 'En croisière stabilisée', 'Au ralenti en descente', 'a', 'Ils augmentent avec la puissance et diminuent avec la vitesse. Le constructeur les neutralise en grande partie en croisière.', 'pilotage'),
    ('Le souffle hélicoïdal agit principalement sur quel axe ?', 'Le roulis', 'Le tangage', 'Aucun', 'Le lacet', 'd', 'Le flux d''air mis en rotation par l''hélice frappe la dérive de biais : la portance latérale crée un couple en lacet.', 'pilotage'),
    ('Pourquoi une augmentation de puissance fait-elle cabrer l''avion ?', 'Le moteur devient plus lourd', 'Le centre de gravité recule', 'Le souffle de l''hélice augmente la déportance de la profondeur', 'La traînée diminue', 'c', 'À vitesse constante, plus de puissance accélère le flux sur la profondeur, ce qui augmente sa déportance et crée un couple cabreur.', 'pilotage'),
    ('Hélice tournant dans le sens horaire vue de la place pilote : que fait l''avion à l''augmentation de puissance ?', 'Il cabre, s''incline et part en lacet à gauche', 'Il pique et part à droite', 'Il cabre et part à droite', 'Rien de particulier', 'a', 'Selon le guide ENAC, l''avion cabre, s''incline à gauche et part en lacet vers la gauche. Les effets s''inversent à la réduction.', 'pilotage'),
    ('À la réduction de puissance, avec une hélice tournant dans le sens horaire vue du pilote, le nez part :', 'À piquer et vers la droite', 'À cabrer et vers la gauche', 'À cabrer et vers la droite', 'Il ne bouge pas', 'a', 'Les trois effets s''inversent par rapport à l''augmentation de puissance : couple piqueur et lacet à droite.', 'pilotage'),
    ('Le couple de renversement est-il important sur les avions légers ?', 'Oui, il impose de garder du manche à fond', 'Non, il est négligeable et ne demande pas d''action particulière en vol', 'Oui, il fait systématiquement décrocher l''avion', 'Il n''existe que sur les bimoteurs', 'b', 'Le guide ENAC le juge négligeable sur la plupart des avions légers. Il est plus marqué avec une grande puissance et une aile de faible allongement.', 'pilotage'),
    ('Quel est le rôle du compensateur ?', 'Piloter l''avion à la place du manche', 'Changer de trajectoire', 'Annuler l''effort aux commandes à assiette stabilisée', 'Augmenter la vitesse', 'c', 'Le compensateur sert à annuler un effort une fois l''assiette et la vitesse stabilisées, pas à piloter l''avion.', 'pilotage'),
    ('Quel est le bon ordre lors d''un changement d''assiette ?', 'Compensation, assiette, puissance', 'Puissance, compensation, assiette', 'Assiette, puissance, stabilisation, compensation, vérification', 'Vérification, compensation, assiette', 'c', 'On affiche l''assiette puis la puissance, on attend la stabilisation, on compense, puis on vérifie en relâchant les commandes.', 'pilotage'),
    ('Quand fait-on la compensation fine ?', 'Pendant la mise en virage', 'Une fois la vitesse et la trajectoire stabilisées', 'Avant d''afficher la nouvelle assiette', 'Juste avant l''atterrissage uniquement', 'b', 'La compensation fine n''a de sens qu''à vitesse et trajectoire stables. On peut pré-compenser pendant une transition, mais la compensation définitive vient après stabilisation.', 'pilotage'),
    ('Comment vérifie-t-on que l''avion est bien compensé ?', 'En relâchant les commandes et en constatant que l''assiette reste constante', 'En regardant la position de la molette', 'En lisant l''anémomètre', 'En demandant à la tour', 'a', 'Une fois compensé, l''avion garde son assiette commandes libres.', 'pilotage'),
    ('Qu''appelle-t-on le circuit visuel ?', 'Le tour de piste', 'La visite prévol', 'Le balayage radar', 'Le déplacement méthodique du regard pour prélever les informations dans un ordre logique', 'd', 'Le circuit visuel organise la prise d''informations : en VFR, il part du RPB et de l''horizon et y revient après chaque coup d''œil aux instruments.', 'pilotage'),
    ('En VFR, quel est l''élément central du circuit visuel ?', 'L''altimètre', 'L''horizon artificiel', 'Le GPS', 'Le repère pare-brise et l''horizon', 'd', 'Le regard part du RPB pour y revenir aussitôt après chaque prise d''information instrumentale.', 'pilotage'),
    ('Dans quel ordre le guide ENAC conseille-t-il d''observer un instrument ?', 'Valeur, position, tendance', 'Couleur, valeur, tendance', 'Uniquement la valeur précise', 'Tendance, position d''aiguille, valeur', 'd', 'Un débutant cherche une valeur exacte ; on lui apprend à lire d''abord la tendance, puis la position de l''aiguille, puis la valeur.', 'pilotage'),
    ('Se focaliser longtemps sur un instrument entraîne :', 'Un meilleur pilotage', 'Une économie de carburant', 'Une perte de contrôle de l''attitude et une mauvaise surveillance du ciel', 'Rien de particulier', 'c', 'Fixer un instrument empêche de voir l''attitude par rapport à l''horizon et dégrade l''anti-abordage.', 'pilotage'),
    ('Au décollage, comment applique-t-on la puissance ?', 'Brutalement d''un coup', 'Par à-coups successifs', 'En freinant fort', 'D''un mouvement continu, en contrant les effets moteur, talons au plancher', 'd', 'On lâche les freins, talons au plancher pour ne pas freiner involontairement, et on met la puissance progressivement en contrant les effets moteur.', 'pilotage'),
    ('Pendant l''accélération au décollage, l''avion s''écarte de l''axe. Que faire d''abord ?', 'Revenir parallèle à l''axe au palonnier, puis rejoindre l''axe progressivement', 'Revenir brutalement sur l''axe', 'Freiner d''un côté', 'Tourner le manche', 'a', 'On cherche d''abord à rester parallèle à l''axe ; un retour précipité sur l''axe est une erreur fréquente.', 'pilotage'),
    ('À la vitesse de rotation, comment fait-on la rotation ?', 'Brutale pour décoller vite', 'En poussant sur le manche', 'Lente et continue, de l''ordre de 3° par seconde, jusqu''à l''assiette de montée initiale', 'En réduisant la puissance', 'c', 'Le guide ENAC indique une rotation lente et continue d''environ 3°/s jusqu''à l''assiette de montée initiale.', 'pilotage'),
    ('Selon le guide ENAC, quand effectue-t-on les actions après décollage ?', 'Dès que les roues quittent le sol', 'Au début du roulage', 'Au premier virage, quelle que soit la hauteur', 'Après avoir atteint une vitesse de sécurité (environ 1,2 Vs) et une hauteur minimale (en général 300 ft)', 'd', 'On attend une vitesse de sécurité (en général 1,2 Vs de la configuration suivante) et une hauteur minimale, en général 300 ft. Ce sont des minimums, pas des objectifs.', 'pilotage'),
    ('Pourquoi ne doit-on jamais utiliser le frein de parking sur la piste ?', 'Il risque de se débloquer mal ou incomplètement', 'Il use les pneus', 'Il est interdit par la tour', 'Il fait caler le moteur', 'a', 'Le guide ENAC le rappelle : le frein de parking peut se débloquer difficilement ou incomplètement, ce qui est dangereux au décollage.', 'pilotage'),
    ('Avant de s''aligner, que doit-on vérifier ?', 'Que le réservoir est plein', 'Que la radio est éteinte', 'Qu''aucun avion n''est en finale, sur les deux QFU', 'Que les volets sont rentrés à fond', 'c', 'La sécurité à l''alignement est l''affaire du pilote : on vérifie la finale dans les deux sens.', 'pilotage'),
    ('Avec un centrage arrière, au décollage, pour le même effort sur la profondeur, la variation d''assiette est :', 'Plus faible et plus lente', 'Identique', 'Plus importante et plus rapide', 'Nulle', 'c', 'En centrage arrière l''avion est plus maniable en tangage : la rotation est vive. En centrage avant, elle est plus lente et plus faible.', 'pilotage'),
    ('La vitesse verticale de montée dépend :', 'Uniquement de l''assiette', 'De la différence entre la puissance utile du moteur et la puissance nécessaire au vol', 'Uniquement de la masse', 'De la longueur de piste', 'b', 'La Vz résulte de l''excédent de puissance : puissance utile moins puissance nécessaire au vol.', 'pilotage'),
    ('Avec un faible excédent de puissance (masse maxi, altitude, chaleur), que doit faire le pilote après la rotation ?', 'Limiter l''assiette à cabrer pour continuer d''accélérer vers la vitesse de montée', 'Cabrer davantage pour monter vite', 'Rentrer les volets immédiatement', 'Réduire la puissance', 'a', 'Avec peu de puissance en excès, une assiette trop forte empêche d''accélérer et maintient l''avion au second régime.', 'pilotage'),
    ('Selon le guide ENAC, quelle majoration raisonnable appliquer aux performances du manuel de vol ?', 'Environ 20 %', '0 %, elles sont exactes', '100 %', '5 %', 'a', 'Les performances du manuel sont obtenues avec un avion neuf et des pilotes d''essai : l''ENAC applique une marge de 20 % dans son exploitation.', 'pilotage'),
    ('Qu''est-ce qu''un briefing décollage ?', 'Une lecture de la check-list', 'Un message radio', 'Le compte rendu du vol précédent', 'Un projet d''action annonçant ce qui va être fait et ce qui est prévu en cas de problème', 'd', 'Le briefing présente la trajectoire prévue, les menaces identifiées et les stratégies, dont la conduite à tenir en cas de panne avant ou après rotation.', 'pilotage'),
    ('Selon le guide ENAC, un bon briefing doit :', 'Être court (7 items maximum), se fixer sur les variables et être reconstruit à chaque vol', 'Être le plus long possible', 'Être toujours identique d''un vol à l''autre', 'Être fait en vol au détriment du pilotage', 'a', 'Le briefing élimine les constantes, se concentre sur les variables et doit être refait à chaque vol (attention au briefing automatique).', 'pilotage'),
    ('En montée à puissance constante, la composante du poids sur la trajectoire :', 'S''ajoute à la traction : la vitesse augmente', 'S''oppose à la traction : la vitesse diminue', 'Est nulle', 'Fait cabrer l''avion', 'b', 'En montée, une partie du poids freine l''avion. En descente, elle s''ajoute à la traction et la vitesse augmente.', 'pilotage'),
    ('À puissance constante, une variation d''assiette de 1° change la vitesse d''environ :', '1 kt', '30 kt', '5 kt sur un avion léger', 'Rien', 'c', 'Le guide ENAC retient l''ordre de grandeur 1° d''assiette pour environ 5 kt.', 'pilotage'),
    ('À puissance constante, une variation d''assiette de 1° change la vitesse verticale d''environ :', '10 ft/min', '100 à 200 ft/min sur un avion léger', '1000 ft/min', 'Rien', 'b', 'Ordre de grandeur du guide ENAC : 1° d''assiette pour 100 à 200 ft/min, d''autant plus que la vitesse est élevée.', 'pilotage'),
    ('À 100 kt, le facteur de base vaut 0,6. Une variation d''assiette de 1° donne une Vz d''environ :', '60 ft/min', '600 ft/min', '170 ft/min', '17 ft/min', 'c', 'Vz par degré = 1/Fb × 100, soit 1/0,6 × 100 ≈ 170 ft/min.', 'pilotage'),
    ('À 100 kt, quel vario correspond à une pente de 3° ?', 'Environ -100 ft/min', 'Environ -1500 ft/min', 'Environ -50 ft/min', 'Environ -500 ft/min', 'd', 'Le guide ENAC donne cet ordre de grandeur : à 100 kt, une pente de 3° correspond à environ -500 ft/min.', 'pilotage'),
    ('La pente de trajectoire est l''angle entre :', 'L''axe de l''avion et l''horizontale', 'L''horizontale et le vecteur vitesse', 'La corde de l''aile et le vent relatif', 'Les ailes et l''horizontale', 'b', 'La pente (gamma) est l''angle entre l''horizontale et le vecteur vitesse. Elle se mesure aussi par le rapport Vz/Vi.', 'pilotage'),
    ('L''incidence est l''angle entre :', 'L''axe longitudinal et l''horizontale', 'La corde de l''aile et la direction du vecteur vitesse', 'L''horizontale et la trajectoire', 'Le plan des ailes et l''horizontale', 'b', 'L''incidence (alpha) est l''angle entre la corde de l''aile et le vent relatif (vecteur vitesse).', 'pilotage'),
    ('Qu''est-ce que l''angle de calage de l''aile ?', 'L''angle entre l''aile et l''horizon', 'L''angle de braquage des volets', 'L''angle de dièdre', 'L''angle entre l''axe longitudinal de l''avion et la corde de l''aile', 'd', 'Le calage est fixé à la construction : c''est l''écart angulaire entre l''axe longitudinal et la corde de l''aile.', 'pilotage'),
    ('Sur une trajectoire en palier, si la vitesse diminue, que faut-il pour garder la même portance ?', 'Diminuer l''incidence', 'Rien', 'Sortir le train', 'Augmenter l''incidence', 'd', 'Fz = ½ ρ S V² Cz : à trajectoire constante, une baisse de vitesse doit être compensée par plus d''incidence, donc plus d''assiette en palier.', 'pilotage'),
    ('Dans la formule de portance Fz = ½ ρ S V² Cz, quels termes le pilote peut-il faire varier en vol à configuration constante ?', 'La vitesse et le Cz (par l''incidence)', 'La masse volumique et la surface', 'Uniquement la surface', 'Aucun', 'a', 'À configuration constante, la vitesse se pilote par la puissance et le Cz par l''incidence.', 'pilotage'),
    ('Selon le guide ENAC, quelle correspondance retient-on entre puissance et vitesse en palier ?', '10 tr/min pour 50 kt', 'Environ 1 pouce, 100 tr/min ou 5 % de puissance pour 5 kt', '1 pouce pour 30 kt', 'Il n''y a aucune relation', 'b', 'Ordre de grandeur du guide : 1 pouce de pression d''admission, 100 tr/min ou 5 % pour environ 5 kt.', 'pilotage'),
    ('Pour passer rapidement d''une vitesse à une vitesse plus faible en palier, on affiche :', 'La puissance exacte requise et on attend', 'Le ralenti puis la puissance maxi', 'Une puissance un peu inférieure à la puissance requise, puis on réajuste à la vitesse visée + 5 kt', 'Une puissance supérieure', 'c', 'On réduit un peu plus que nécessaire, puis on réajuste la puissance quand la vitesse arrive à la cible + 5 kt. On fait l''inverse pour accélérer.', 'pilotage'),
    ('En palier croisière, quel paramètre est subi ?', 'L''altitude', 'La puissance', 'La vitesse indiquée', 'Le cap', 'c', 'En palier croisière on tient l''altitude, la puissance et la ligne droite symétrique : la vitesse en découle.', 'pilotage'),
    ('En montée, quel paramètre est subi ?', 'Le taux de montée (Vz)', 'La vitesse', 'La puissance', 'Le cap', 'a', 'En montée on fixe la puissance et la vitesse par l''assiette : la Vz est subie.', 'pilotage'),
    ('En descente, comment pilote-t-on la pente et la vitesse ?', 'La pente par la puissance, la vitesse par les volets', 'La pente par l''assiette (contrôlée au vario), la vitesse par la puissance', 'Les deux par le compensateur', 'La pente par le palonnier', 'b', 'En descente, l''assiette fixe la pente (contrôlée par la Vz) et la puissance règle la vitesse.', 'pilotage'),
    ('Lors du passage de la montée au palier, à partir de quand commence-t-on la mise en palier ?', 'Exactement à l''altitude visée', 'Quand l''écart avec l''altitude visée atteint environ 1/10 du taux de montée', '1000 ft avant', 'Après avoir dépassé l''altitude', 'b', 'Exemple : à 500 ft/min de montée, on commence la mise en palier environ 50 ft avant l''altitude visée.', 'pilotage'),
    ('Pour passer de la montée au palier, on affiche d''abord, à l''anticipation :', 'L''assiette de descente', 'La puissance de croisière', 'Les volets', 'Environ la moitié de l''assiette de montée', 'd', 'Le guide ENAC : à l''anticipation, ½ assiette de montée, accompagnement de l''accélération, puis puissance de croisière à la vitesse visée.', 'pilotage'),
    ('Avant de passer en descente, que recommande le guide ENAC dans la préparation ?', 'Couper la radio', 'Recaler le directionnel, enrichir le mélange, réchauffer le carburateur si besoin, réservoir le plus plein', 'Rentrer les volets', 'Mettre plein gaz', 'b', 'La préparation de la descente comprend le directionnel, le mélange, le réchauffage carburateur éventuel et le réservoir le plus plein.', 'pilotage'),
    ('Pour une manœuvre d''évitement ou une approche interrompue, quel ordre d''actions est commun ?', 'Puissance, puis assiette', 'Assiette, puis puissance', 'Compensation, puis assiette', 'Volets, puis puissance', 'b', 'Dans les changements de trajectoire qui privilégient l''action, on affiche d''abord l''assiette, puis la puissance.', 'pilotage'),
    ('Selon le guide ENAC, quelle pente de descente « confort » retient-on à 120 kt ?', '-10°, soit -2000 ft/min', 'Environ -2°, soit environ -400 ft/min', '-0,5°', '-5°, soit -1500 ft/min', 'b', 'Le guide propose une pente confort de -2°, soit environ -400 ft/min à 120 kt.', 'pilotage'),
    ('Quel est l''avantage principal du compas magnétique ?', 'Il est très stable en virage', 'Il indique en permanence le nord magnétique sans alimentation', 'Il ne subit aucune erreur', 'Il se recale tout seul', 'b', 'Le compas n''a besoin d''aucune énergie, mais ses indications sont fausses en virage, en accélération et en turbulence.', 'pilotage'),
    ('Dans quelles situations le compas magnétique donne-t-il des indications erronées ?', 'Uniquement au sol', 'Uniquement en palier rectiligne', 'En virage, lors des accélérations et décélérations, en turbulence', 'Jamais', 'c', 'Ses erreurs sont maximales en virage et lors des variations de vitesse face à l''est ou à l''ouest.', 'pilotage'),
    ('En virage, dans l''hémisphère nord, le compas est :', 'Nerveux face au nord, paresseux face au sud', 'Toujours juste', 'Bloqué', 'Paresseux face au nord, nerveux face au sud', 'd', 'Le guide ENAC le résume ainsi : face au nord la rose est paresseuse, face au sud elle est nerveuse.', 'pilotage'),
    ('À quelle fréquence le guide ENAC conseille-t-il de recaler le directionnel ?', 'Une fois par vol', 'Toutes les heures', 'Environ toutes les 15 minutes et après les évolutions', 'Jamais, il est autonome', 'c', 'Le directionnel dérive : on le recale sur le compas environ toutes les 15 minutes et après des évolutions.', 'pilotage'),
    ('Dans quelles conditions recale-t-on le directionnel sur le compas ?', 'En virage', 'Pendant une accélération', 'Au décollage', 'En palier rectiligne stabilisé, équipements électriques comme lors de la compensation du compas', 'd', 'Le compas n''est fiable qu''en vol rectiligne stabilisé. Les équipements électriques peuvent influencer le compas, d''où cette précaution.', 'pilotage'),
    ('Les caps s''annoncent :', 'Avec 2 chiffres', 'En degrés et minutes', 'Avec 3 chiffres, par exemple 030', 'Avec le point cardinal seulement', 'c', 'On annonce toujours 3 chiffres : 003, 030, 300.', 'pilotage'),
    ('Que se passe-t-il si on approche un trousseau de clés du compas ?', 'Le directionnel dévie', 'Rien', 'Le compas dévie, alors que le directionnel n''est pas affecté', 'Les deux instruments s''arrêtent', 'c', 'Le compas est sensible aux masses métalliques et aux champs magnétiques (phares, électronique), pas le directionnel.', 'pilotage'),
    ('Selon le guide ENAC, de combien anticipe-t-on la sortie de virage ?', 'De la moitié du cap', 'D''environ un tiers de l''inclinaison', 'De 45° dans tous les cas', 'On n''anticipe jamais', 'b', 'Règle pratique : l''anticipation vaut environ 1/3 de l''inclinaison, soit environ 10° de cap pour un virage à 30°.', 'pilotage'),
    ('Le vol est symétrique quand :', 'L''avion est en palier', 'L''écoulement de l''air est parallèle au plan de symétrie de l''avion (bille centrée)', 'Les ailes sont horizontales', 'La vitesse est constante', 'b', 'Le vol symétrique correspond à une bille centrée : l''avion ne dérape pas.', 'pilotage'),
    ('La bille est décalée vers la droite. Comment corriger ?', 'Palonnier à gauche', 'Palonnier à droite (« le pied chasse la bille »)', 'Manche à droite', 'Manche à gauche', 'b', 'La bille part du côté du vent relatif ; on appuie sur le palonnier du côté de la bille.', 'pilotage'),
    ('En virage, la bille est du côté intérieur. Comment appelle-t-on cette situation et comment corriger ?', 'Un dérapage extérieur, palonnier extérieur', 'Un vol symétrique, rien à faire', 'Un décrochage, pousser', 'Une glissade (dérapage intérieur), palonnier intérieur', 'd', 'Bille à l''intérieur : glissade, corrigée au palonnier intérieur. Bille à l''extérieur : dérapage, corrigé au palonnier extérieur.', 'pilotage'),
    ('En virage en palier, la portance doit être :', 'Plus faible qu''en ligne droite', 'Égale au poids', 'Plus grande qu''en ligne droite', 'Nulle', 'c', 'Seule sa composante verticale équilibre le poids, donc la portance totale doit augmenter. Sa composante horizontale fait virer l''avion.', 'pilotage'),
    ('Quelle force fait tourner l''avion en virage ?', 'La traction', 'Le poids', 'La composante horizontale de la portance', 'La traînée', 'c', 'La portance inclinée a une composante horizontale, la force déviatrice, qui maintient le virage.', 'pilotage'),
    ('À puissance constante, en virage en palier, la vitesse :', 'Augmente', 'Reste identique', 'Varie sans règle', 'Diminue', 'd', 'Pour tenir le palier en virage il faut plus d''incidence, donc plus de traînée : la vitesse diminue si la puissance ne change pas.', 'pilotage'),
    ('Selon le guide ENAC, au-dessous de quelle vitesse les virages se font-ils à vitesse constante (avec ajout de puissance) ?', '2 Vs', '1,45 Vs', 'Vne', '1,1 Vs', 'b', 'Toute évolution à une vitesse inférieure ou égale à 1,45 Vs se fait à vitesse indiquée constante, en ajoutant de la puissance.', 'pilotage'),
    ('Pour maintenir la vitesse en virage, combien de puissance le guide ENAC conseille-t-il d''ajouter ?', 'Rien', 'La puissance maximale', '10 pouces', 'Environ 1 pouce, 100 tr/min ou 5 % par tranche de 15° d''inclinaison', 'd', 'Au-delà de 15° la relation 1 pouce pour 5 kt ne suffit plus : on ajoute environ 1 pouce par tranche de 15° d''inclinaison, sans attendre la baisse de vitesse.', 'pilotage'),
    ('En virage en montée, pourquoi le guide ENAC limite-t-il l''inclinaison à 20-25° ?', 'Parce qu''au-delà l''avion décroche toujours', 'Pour préserver les performances de montée', 'C''est une limite réglementaire', 'Pour économiser le carburant', 'b', 'Jusqu''à 20° la perte de taux de montée est faible ; au-delà de 30° elle devient significative. On peut incliner plus pour un évitement.', 'pilotage'),
    ('En virage en montée à pleine puissance, comment maintient-on la vitesse ?', 'Par une légère diminution de l''assiette', 'En ajoutant de la puissance', 'En sortant les volets', 'Ce n''est pas possible', 'a', 'La puissance étant déjà maximale, la vitesse se tient par l''assiette (légèrement à piquer), au prix d''une pente de montée plus faible.', 'pilotage'),
    ('Pourquoi le guide ENAC conseille-t-il de faire les démonstrations de virage de préférence à droite ?', 'Parce qu''on voit mieux à droite', 'C''est une règle de l''air', 'À cause de l''effet gyroscopique de l''hélice tournant en sens horaire, qui perturbe les virages à gauche', 'Parce que le compas est plus juste', 'c', 'Avec une hélice tournant en sens horaire, le couple gyroscopique perturbe la démonstration en virage à gauche.', 'pilotage'),
    ('Peut-on utiliser le compensateur pendant un virage ?', 'Non, le virage est une phase transitoire : on ne compense pas', 'Oui, il faut compenser à chaque virage', 'Oui, mais seulement à gauche', 'Uniquement en montée', 'a', 'Le guide ENAC rappelle que le virage est transitoire ; utiliser le compensateur en virage est une erreur fréquente. L''exception est la spirale stabilisée en descente.', 'pilotage'),
    ('À vitesse constante, si l''inclinaison augmente :', 'Le taux de virage augmente et le rayon diminue', 'Le taux de virage diminue et le rayon augmente', 'Rien ne change', 'Le rayon et le taux augmentent', 'a', 'Plus d''inclinaison donne un virage plus serré et plus rapide.', 'pilotage'),
    ('À inclinaison constante, si la vitesse augmente :', 'Le rayon diminue et le taux augmente', 'Rien ne change', 'Le rayon augmente et le taux de virage diminue', 'Le rayon et le taux diminuent', 'c', 'Plus vite, à la même inclinaison, l''avion tourne plus large et moins vite.', 'pilotage'),
    ('Par vent de travers, on garde un cap égal à la route à suivre. Que se passe-t-il ?', 'L''avion reste sur la route', 'L''avion accélère', 'L''avion dérive et s''écarte de la route', 'L''avion monte', 'c', 'Le vent latéral déplace l''avion : il faut afficher une correction de dérive, cap orienté du côté du vent.', 'pilotage'),
    ('De quel côté met-on la correction de dérive ?', 'Du côté opposé au vent', 'Du côté d''où vient le vent', 'Toujours à droite', 'Toujours à gauche', 'b', 'On oriente le nez vers le vent : le cap se trouve entre la route et la direction du vent.', 'pilotage'),
    ('Selon le guide ENAC, est-il plus facile de rejoindre un axe en étant au vent ou sous le vent de celui-ci ?', 'Sous le vent de l''axe', 'Au vent de l''axe', 'C''est identique', 'Cela ne dépend que de la vitesse', 'b', 'Au vent, le vent aide à revenir vers l''axe ; sous le vent, il faut lutter contre lui.', 'pilotage'),
    ('Un virage de 90° commence avec une composante de vent de face. Le changement de cap nécessaire pour suivre la nouvelle route sol est :', '90° moins la dérive', '90° plus la dérive', 'Exactement 90°', '180°', 'a', 'D''après le guide ENAC : avec une composante de vent de face, changement de cap = 90° - dérive ; avec une composante de vent arrière, 90° + dérive.', 'pilotage'),
    ('Pour un virage de 180° destiné à s''aligner, avec un vent arrière pendant le virage, quel est le seul moyen de rattraper l''axe ?', 'Retarder la mise en virage', 'Diminuer l''inclinaison', 'Augmenter l''inclinaison', 'Ralentir à Vs', 'c', 'Avec un vent arrière, anticiper est impossible : seule une inclinaison plus forte permet d''intercepter l''axe. Avec un vent de face, on retarde le virage ou on diminue l''inclinaison.', 'pilotage'),
    ('Quelle différence fondamentale doit-on bien assimiler avec la leçon sur le vent ?', 'Celle entre altitude et hauteur', 'Celle entre QNH et QFE', 'Celle entre trajectoire air et trajectoire sol', 'Celle entre VFR et IFR', 'c', 'Le vent fait que la trajectoire sol diffère de la trajectoire air : c''est la base de la dérive.', 'pilotage'),
    ('À quoi servent les dispositifs hypersustentateurs (volets) ?', 'À augmenter la vitesse de croisière', 'À réduire la consommation', 'À refroidir le moteur', 'À diminuer les vitesses de décollage et d''atterrissage, donc les distances', 'd', 'En modifiant le profil de l''aile, les volets abaissent la vitesse de décrochage et raccourcissent les distances de décollage et d''atterrissage.', 'pilotage'),
    ('Sur l''anémomètre, la VFE (vitesse maximale volets sortis) correspond à :', 'La limite inférieure de l''arc vert', 'Le trait rouge', 'La limite supérieure de l''arc jaune', 'La limite supérieure de l''arc blanc', 'd', 'L''arc blanc représente la plage d''utilisation des volets ; sa limite haute est la VFE en position atterrissage.', 'pilotage'),
    ('Pourquoi la VFE ne doit-elle jamais être dépassée ?', 'Le moteur risque de caler', 'Le compas devient faux', 'C''est une limitation structurale', 'L''avion devient instable en roulis', 'c', 'Au-delà de la VFE, les efforts sur les volets et leur structure peuvent provoquer des dommages.', 'pilotage'),
    ('Selon le guide ENAC, quelle est la vitesse minimale opérationnelle de rentrée des volets ?', 'Vne', 'Vs0', 'En général 1,2 Vs de la configuration suivante', 'La vitesse de croisière', 'c', 'Avant de rentrer les volets, la vitesse doit être d''au moins 1,2 fois la vitesse de décrochage de la configuration qu''on va prendre.', 'pilotage'),
    ('Quand on braque les volets à incidence donnée, que se passe-t-il ?', 'La portance diminue et la traînée augmente', 'La portance et la traînée augmentent', 'La portance augmente et la traînée diminue', 'Rien ne change', 'b', 'Les volets augmentent la courbure de l''aile : le Cz augmente, mais le Cx aussi, d''où une diminution de vitesse.', 'pilotage'),
    ('Pourquoi conseille-t-on de limiter les évolutions en configuration atterrissage ?', 'Le moteur chauffe', 'La VNE diminue', 'Les volets braqués en position atterrissage diminuent la manœuvrabilité', 'Le compas ne fonctionne plus', 'c', 'Le guide ENAC recommande de limiter les évolutions volets atterrissage, configuration moins manœuvrante et très traînante.', 'pilotage'),
    ('Selon le guide ENAC, une phase de vol est la combinaison :', 'D''une altitude et d''un cap', 'D''une vitesse et d''une masse', 'D''un QNH et d''un QFE', 'D''un régime de vol et d''une configuration', 'd', 'Phase de vol = régime (palier, montée, descente) + configuration (lisse, approche, atterrissage).', 'pilotage'),
    ('Quelle est la vitesse d''évolution habituelle en configuration approche selon le guide ENAC ?', '1,1 Vs', 'Vne', '1,45 Vs', '2 Vs', 'c', 'Les évolutions en approche (palier approche, virages) se font à 1,45 Vs ; la finale se fait à environ 1,3 Vs0 (Vref).', 'pilotage'),
    ('Oublier la compensation après un changement de configuration est :', 'Une erreur fréquente de l''élève', 'Recommandé', 'Sans importance', 'Obligatoire en finale', 'a', 'Chaque sortie ou rentrée de volets modifie l''équilibre en tangage : il faut recompenser.', 'pilotage'),
    ('Entre quelles valeurs d''incidence se produit en général le décrochage sur un avion léger ?', 'Entre 2° et 4°', 'Entre 30° et 40°', 'Il n''y a pas d''incidence critique', 'Entre 15° et 18°', 'd', 'Au-delà de 15 à 18° d''incidence, les filets d''air se décollent de l''extrados : c''est le décrochage.', 'pilotage'),
    ('De quoi dépend le décrochage ?', 'Uniquement de la vitesse', 'Uniquement de la masse', 'Uniquement de l''incidence', 'Uniquement de l''altitude', 'c', 'Le décrochage ne dépend que de l''incidence : il peut se produire à vitesse élevée, par exemple en ressource ou en virage serré.', 'pilotage'),
    ('Quels sont les symptômes caractéristiques d''un décrochage ?', 'Augmentation de vitesse et vibrations moteur', 'Bille au centre et vario positif', 'Aucun symptôme', 'Perte de contrôle sur un axe, impossibilité de tenir la pente manche en butée arrière, abattée', 'd', 'Le guide ENAC retient la perte de contrôle sur au moins un axe, l''impossibilité de tenir la pente avec le manche en butée arrière et l''abattée.', 'pilotage'),
    ('Quelle est la première action pour sortir d''un décrochage (après avoir déconnecté le pilote automatique éventuel) ?', 'Pousser sur le manche pour réduire l''incidence', 'Mettre plein gaz en tirant', 'Mettre du palonnier opposé', 'Sortir les volets', 'a', 'La priorité absolue est de réduire l''incidence en poussant jusqu''à la disparition des symptômes.', 'pilotage'),
    ('Dans la procédure de sortie de décrochage, quand annule-t-on l''inclinaison ?', 'Après avoir réduit l''incidence', 'Avant de pousser sur le manche', 'Jamais', 'À la fin du vol', 'a', 'Ordre : pousser (réduire l''incidence), trim à piquer si besoin, annuler l''inclinaison, ajuster la puissance, rentrer les aérofreins, revenir sur une trajectoire adaptée.', 'pilotage'),
    ('Pendant la sortie de décrochage, faut-il systématiquement mettre pleine puissance ?', 'Oui, toujours plein gaz immédiatement', 'Non, la puissance est ajustée selon les circonstances', 'Non, il faut couper le moteur', 'Oui, avant de pousser sur le manche', 'b', 'Le guide ENAC précise que la puissance maximale n''est le plus souvent pas nécessaire ; on l''ajuste en contrant les effets moteurs.', 'pilotage'),
    ('Pourquoi doit-on faire une ressource souple après un décrochage ?', 'Pour gagner du temps', 'Pour éviter un décrochage secondaire', 'Pour économiser le moteur', 'Pour ne pas dépasser la VFE uniquement', 'b', 'Une ressource trop vive augmente le facteur de charge et peut faire décrocher à nouveau. La priorité n''est pas la perte d''altitude minimale.', 'pilotage'),
    ('Selon le guide ENAC, quand la sortie de décrochage est-elle terminée ?', 'Dès que l''alarme s''arrête', 'Vitesse d''au moins 1,2 Vs de la configuration et trajectoire stabilisée proche de 1 g', 'Quand l''avion a repris son altitude initiale', 'Après 10 secondes', 'b', 'La récupération est terminée à au moins 1,2 Vs avec une trajectoire stabilisée et un facteur de charge proche de 1 g.', 'pilotage'),
    ('Comment la vitesse de décrochage varie-t-elle avec le facteur de charge n ?', 'Elle est multipliée par la racine carrée de n', 'Elle est multipliée par n', 'Elle est divisée par n', 'Elle ne varie pas', 'a', 'La vitesse de décrochage est multipliée par la racine carrée du facteur de charge.', 'pilotage'),
    ('Avec une hélice tournant à droite, en montée à pleine puissance, quelle aile décroche en principe la première ?', 'L''aile droite', 'L''aile gauche', 'Les deux en même temps', 'Aucune', 'b', 'Le souffle hélicoïdal réduit l''incidence de l''aile droite : l''aile gauche, à plus forte incidence, décroche généralement en premier.', 'pilotage'),
    ('Selon le guide ENAC, à quelle hauteur minimale effectue-t-on les exercices de décrochage ?', '500 ft', '3000 ft (choix de l''ENAC)', '1000 ft', '10 000 ft', 'b', 'Ces exercices exigent une hauteur minimale de sécurité ; l''ENAC a retenu 3000 ft.', 'pilotage'),
    ('Avant un exercice de décrochage, quelles vérifications fait-on ?', 'Uniquement la radio', 'Intérieures (objets libres, ceintures) et extérieures (trafic, zone survolée)', 'Uniquement le carburant', 'Aucune', 'b', 'On vérifie la cabine (rien ne doit flotter, ceintures serrées) et l''extérieur (autres avions, zone de survol).', 'pilotage'),
    ('Dans quelles situations le décrochage survient-il le plus souvent en réalité ?', 'En croisière calme', 'Pendant le roulage', 'Au parking', 'Quand charge de travail, stress et perte de conscience de la situation sont associés', 'd', 'Le guide ENAC souligne que le décrochage arrive surtout en situation dégradée : météo marginale, panne moteur, virage serré près du sol.', 'pilotage'),
    ('Comment visualiser en vol la désorganisation de l''écoulement à l''approche du décrochage ?', 'Avec la bille', 'Avec le compas', 'Avec des brins de laine collés sur l''aile', 'Avec le transpondeur', 'c', 'Le guide ENAC suggère des brins de laine d''environ 30 cm, de l''emplanture à l''aileron.', 'pilotage'),
    ('À l''approche du décrochage, l''utilisation des ailerons nécessite :', 'Aucune conjugaison', 'Moins de palonnier qu''en croisière', 'Une conjugaison accrue au palonnier', 'De couper le moteur', 'c', 'Aux fortes incidences, le lacet inverse et la dissymétrie augmentent : il faut davantage de palonnier.', 'pilotage'),
    ('Où se situe la plage de vol lent ?', 'Entre 1,45 Vs et Vne', 'Entre la vitesse de décrochage et environ 1,3 Vs', 'Au-dessus de la vitesse de croisière', 'Entre Vno et Vne', 'b', 'Le vol lent va de la vitesse minimale de vol au point bas de la courbe de puissance, proche de 1,3 Vs.', 'pilotage'),
    ('La traînée induite :', 'Augmente avec l''incidence (donc quand la vitesse diminue)', 'Augmente avec la vitesse', 'Est constante', 'N''existe qu''au sol', 'a', 'La traînée induite est liée à la portance et croît avec l''incidence ; elle domine à basse vitesse.', 'pilotage'),
    ('La traînée parasite (frottement, forme, interférence) :', 'Diminue quand la vitesse augmente', 'Est constante', 'N''existe qu''en virage', 'Augmente avec la vitesse', 'd', 'Elle croît avec le carré de la vitesse ; elle domine à grande vitesse.', 'pilotage'),
    ('Au premier régime de vol :', 'Il faut plus de puissance pour voler moins vite', 'La vitesse est stable : plus de puissance donne plus de vitesse', 'L''avion est décroché', 'Le moteur est arrêté', 'b', 'Au premier régime, puissance nécessaire et vitesse varient dans le même sens : le vol est stable en vitesse.', 'pilotage'),
    ('Au second régime de vol :', 'L''avion est plus stable qu''au premier régime', 'Il faut plus de puissance pour voler plus lentement, la vitesse est instable', 'La traînée est minimale', 'L''avion vole à Vne', 'b', 'Au second régime, une petite baisse de vitesse augmente fortement la traînée : la vitesse est instable et demande de fortes variations de puissance.', 'pilotage'),
    ('À quoi correspond le point bas de la courbe de puissance nécessaire ?', 'À la vitesse maximale', 'À la puissance minimale pour tenir le palier, séparation entre premier et second régime', 'Au décrochage', 'À la Vne', 'b', 'C''est la vitesse de puissance minimale, proche de 1,3 Vs sur un avion léger, frontière entre les deux régimes.', 'pilotage'),
    ('Citez un symptôme du vol lent :', 'Vitesse élevée', 'Commandes très dures', 'Assiette anormalement cabrée et faible efficacité des gouvernes', 'Vario fortement positif', 'c', 'Symptômes : forte incidence, gouvernes peu efficaces, efforts faibles, effets secondaires amplifiés, stabilité réduite, avertisseur, parfois buffeting.', 'pilotage'),
    ('Selon le guide ENAC, vers quelle vitesse l''avertisseur de décrochage retentit-il en général ?', 'Exactement à Vs', 'Vers 1,15 Vs, soit 5 à 10 kt au-dessus du décrochage', 'À 2 Vs', 'À la Vne', 'b', 'L''avertisseur se déclenche environ 5 à 10 kt avant le décrochage.', 'pilotage'),
    ('Face à une alarme de décrochage continue, que fait-on en général ?', 'On l''ignore', 'On attend qu''elle s''arrête', 'On sort les volets', 'On applique immédiatement la procédure de sortie de décrochage', 'd', 'Une alarme continue, une fois identifiée, impose presque toujours la sortie de décrochage immédiate (hors exercice annoncé par l''instructeur).', 'pilotage'),
    ('Une alarme de décrochage brève retentit dans le dernier virage. Que faire ?', 'Appliquer sans délai la procédure de sortie, puis analyser la cause', 'L''ignorer car elle est brève', 'Augmenter l''inclinaison', 'Tirer sur le manche', 'a', 'Dans le dernier virage, l''avion n''a rien à faire en vol lent : l''alarme signale un écart significatif, à corriger immédiatement.', 'pilotage'),
    ('Pourquoi faut-il « identifier » l''alarme avant de réagir ?', 'Plusieurs alarmes existent (train, pilote automatique…) : on évite une réaction inadaptée', 'Pour prévenir la tour', 'Pour faire passer le temps', 'C''est inutile', 'a', 'Le guide ENAC conseille d''annoncer clairement « stall » ou « décrochage » pour ne pas confondre avec une autre alarme.', 'pilotage'),
    ('Le facteur de charge est le rapport :', 'De la portance sur le poids', 'Du poids sur la portance', 'De la vitesse sur la masse', 'De la traction sur la traînée', 'a', 'n = Fz / P. En virage en palier stabilisé, n = 1 / cos(inclinaison).', 'pilotage'),
    ('En virage en palier à 60° d''inclinaison, le facteur de charge vaut :', '1,15', '2', '1,41', '3', 'b', 'n = 1/cos 60° = 2. La vitesse de décrochage augmente alors d''environ 40 %.', 'pilotage'),
    ('En virage en palier à 45° d''inclinaison, le facteur de charge vaut environ :', '1,15', '2', '1,4', '3', 'c', 'n = 1/cos 45° ≈ 1,41, et la vitesse de décrochage augmente d''environ 19 %.', 'pilotage'),
    ('En virage en palier à 30° d''inclinaison, le facteur de charge vaut environ :', '1,15', '1,41', '2', '1', 'a', 'n = 1/cos 30° ≈ 1,15 ; la vitesse de décrochage augmente d''environ 7 %.', 'pilotage'),
    ('Selon le guide ENAC, quelle inclinaison opérationnelle maximale à 1,45 Vs ?', '60°', '10°', '20°', '37°', 'd', 'Le guide associe 37° à 1,45 Vs, 20° à 1,3 Vs, et 10° à 1,1 et 1,2 Vs.', 'pilotage'),
    ('Selon le guide ENAC, quelle inclinaison opérationnelle maximale à 1,3 Vs ?', '37°', '45°', '5°', '20°', 'd', 'À 1,3 Vs, l''inclinaison opérationnelle est limitée à 20° pour garder une marge suffisante.', 'pilotage'),
    ('Pourquoi limiter l''inclinaison en vol lent ?', 'Pour économiser le carburant', 'Pour la radio', 'Parce que le compas est faux', 'Le facteur de charge augmente la vitesse de décrochage et la marge est déjà faible', 'd', 'En vol lent, la marge au décrochage est réduite ; incliner augmente la vitesse de décrochage.', 'pilotage'),
    ('Comment corrige-t-on l''altitude en vol lent, entre 1,1 et 1,2 Vs ?', 'Uniquement par la puissance', 'Par les volets', 'Par variation d''assiette de ±1°, accompagnée d''une importante variation de puissance', 'Par le compensateur', 'c', 'Au second régime, les règles classiques ne s''appliquent pas : chaque variation d''assiette demande une forte variation de puissance pour garder la vitesse.', 'pilotage'),
    ('Qu''est-ce que le foyer d''un avion ?', 'Le centre de gravité', 'Le réservoir principal', 'Le point d''application des variations de portance dues aux variations d''incidence', 'La position du pilote', 'c', 'Le foyer est propre à l''avion ; la distance entre le centre de gravité et le foyer est la marge statique.', 'pilotage'),
    ('La distance entre le centre de gravité et le foyer s''appelle :', 'La marge statique', 'La corde moyenne', 'Le bras de levier du moteur', 'L''envergure', 'a', 'La qualité du pilotage longitudinal dépend de la marge statique.', 'pilotage'),
    ('Avec un centrage en limite arrière (marge statique faible) :', 'L''avion est très stable et lourd aux commandes', 'L''arrondi est difficile par manque de profondeur', 'Le décollage est plus long', 'L''avion est très maniable, avec un risque de trop cabrer', 'd', 'Faible marge statique : effort faible par g, risque de trop cabrer au décollage et à l''atterrissage et de dépasser le facteur de charge.', 'pilotage'),
    ('Avec un centrage en limite avant (marge statique importante) :', 'L''avion est peu maniable et l''arrondi peut être insuffisant malgré le manche en butée', 'L''avion est très maniable', 'L''avion part facilement en vrille', 'Les efforts aux commandes sont très faibles', 'a', 'Grande marge statique : avion stable et lourd en tangage, rotation difficile, risque de ne pas pouvoir arrondir.', 'pilotage'),
    ('En croisière avec un centrage avant, la position du compensateur est :', 'Plus en arrière (plus à cabrer) qu''avec un centrage moyen', 'Plus en avant', 'Identique', 'Au neutre', 'a', 'Le guide ENAC le fait constater : centrage avant, compensateur plus à cabrer ; centrage arrière, plus à piquer.', 'pilotage'),
    ('Où se trouve l''enveloppe de masse et centrage d''un avion ?', 'Dans le manuel de vol', 'Sur la carte VAC', 'Dans le carnet de route', 'Sur le certificat d''immatriculation', 'a', 'Le constructeur détermine l''enveloppe ; elle figure dans le manuel de vol.', 'pilotage'),
    ('Un moment est le produit :', 'D''une vitesse par un temps', 'D''une masse par une vitesse', 'D''une puissance par une distance', 'D''une masse par un bras de levier', 'd', 'Moment = masse × bras de levier. Le centre de gravité = somme des moments / masse totale.', 'pilotage'),
    ('Selon les conditions de certification, l''approche se fait à une vitesse d''au moins :', '1,1 Vso', '2 Vso', '1,3 Vso jusqu''à 15 m (50 ft)', 'Vne', 'c', 'La certification retient une approche stabilisée jusqu''à 15 m à au moins 1,3 Vso.', 'pilotage'),
    ('Qu''est-ce que la Vref ?', 'La vitesse de croisière', 'La vitesse d''approche finale sans vent en configuration atterrissage, fixée par le constructeur', 'La vitesse de rotation', 'La vitesse maximale volets sortis', 'b', 'À défaut d''indication du constructeur, la Vref n''est pas inférieure à 1,3 Vso.', 'pilotage'),
    ('Comment calcule-t-on la Vapp (vitesse d''approche retenue) ?', 'Vref - 10 kt', 'Vs × 2', 'Vref + correction de vent effectif (Kve)', 'Vne / 2', 'c', 'Le pilote ajoute à la Vref une majoration liée au vent effectif et aux rafales.', 'pilotage'),
    ('Selon la règle du guide ENAC, quel Kve ajouter pour un vent effectif de 15 kt ?', '0 kt', '10 kt', '5 kt', '15 kt', 'c', 'Règle donnée : vent effectif < 10 kt : 0 ; de 10 à 20 kt : +5 kt ; > 20 kt : +10 kt.', 'pilotage'),
    ('Pourquoi ajoute-t-on un supplément de vitesse par fort gradient de vent ?', 'Pour atterrir plus long volontairement', 'Le vent diminue près du sol, ce qui fait baisser la vitesse propre en finale', 'Pour la radio', 'Pour refroidir le moteur', 'b', 'Près du sol le vent faiblit : la vitesse air diminue et la trajectoire s''incurve vers le bas. Le supplément anticipe cet effet.', 'pilotage'),
    ('Un plan d''approche de 3° correspond à une pente d''environ :', '10 %, soit 600 ft par nautique', '1 %, soit 60 ft par nautique', '20 %', '5 %, soit environ 300 ft par nautique', 'd', 'Le plan de 3°/5 % représente environ 300 ft de hauteur par NM.', 'pilotage'),
    ('Comment calcule-t-on le vario sur un plan de 5 % ?', 'Vz = vitesse sol / 5', 'Vz (ft/min) = vitesse sol (kt) × 5', 'Vz = vitesse indiquée × 10', 'Vz = 500 ft/min dans tous les cas', 'b', 'Exemple du guide : 68 kt de vitesse sol × 5 = -340 ft/min.', 'pilotage'),
    ('Le point d''aboutissement de la trajectoire est :', 'Le point du sol qui reste immobile dans le pare-brise', 'Le seuil de piste', 'Le point où l''avion s''arrête', 'La tour de contrôle', 'a', 'Le point d''aboutissement est la projection du vecteur vitesse : c''est le point d''immobilité apparente.', 'pilotage'),
    ('Dans une finale idéale, le point d''aboutissement :', 'Est en bout de piste', 'Est confondu avec le point cible choisi par le pilote', 'Est avant le seuil', 'N''a pas d''importance', 'b', 'Le pilote fait coïncider le point d''aboutissement réel avec le point cible.', 'pilotage'),
    ('Selon le guide ENAC, à quelle distance du point d''aboutissement se situe environ le point de toucher ?', 'Environ 1000 m', 'Environ 10 m', 'Au seuil', 'Environ 150 m', 'd', 'Le point de toucher est défini environ 150 m après le point cible ; s''il s''éloigne nettement, on applique l''atterrissage manqué.', 'pilotage'),
    ('Quel plancher de stabilisation l''ENAC a-t-elle retenu pour ses monomoteurs en VMC ?', '100 ft', '500 ft', '1000 ft', '20 ft', 'a', 'Le plancher de stabilisation est fixé par l''exploitant ; l''ENAC a retenu 100 ft pour les SEP.', 'pilotage'),
    ('Parmi ces éléments, lequel n''est pas un critère de stabilisation de la finale ?', 'Avion configuré pour l''atterrissage', 'Vitesse stabilisée et puissance cohérente', 'Check-list avant atterrissage effectuée', 'Avoir contacté le prochain aérodrome', 'd', 'Les critères : position garantissant un poser en sécurité, configuration, vitesse stabilisée, puissance cohérente, check-list faite.', 'pilotage'),
    ('Si un critère de stabilisation n''est pas réuni à l''objectif de stabilisation, que faut-il faire ?', 'Continuer et corriger près du sol', 'Freiner plus fort à l''atterrissage', 'Augmenter l''inclinaison', 'Interrompre l''approche', 'd', 'L''approche non stabilisée doit être interrompue. La remise de gaz n''est pas un échec, c''est une bonne décision.', 'pilotage'),
    ('Comment visualise-t-on un plan de 3° depuis le poste ?', 'Le seuil est au niveau de l''horizon', 'La piste occupe tout le pare-brise', 'Le capot cache la piste', 'Le point d''aboutissement est environ 3 cm sous l''horizon, à bras tendu (60 cm)', 'd', 'À 60 cm de l''œil, 3 cm sous l''horizon correspondent à 3°.', 'pilotage'),
    ('Pour rattraper un plan trop faible (trop bas), que fait-on ?', 'On pousse sur le manche', 'On prend l''assiette de palier puis on ajuste la puissance pour garder la vitesse, jusqu''à retrouver le plan', 'On réduit la puissance', 'On sort plus de volets', 'b', 'On rejoint le plan par en dessous : palier, puissance ajustée, puis reprise de la descente sur le plan.', 'pilotage'),
    ('Selon le guide ENAC, l''assiette d''approche interrompue sur avion léger vaut environ :', 'Le double de l''assiette de montée', 'L''assiette de descente', '0°', 'La moitié de l''assiette de montée', 'd', 'L''approche interrompue se fait à environ la moitié de l''assiette de montée, à forte puissance et faible vitesse : effets moteur importants.', 'pilotage'),
    ('Ordre des actions pour une approche interrompue :', 'Assiette, puissance en contrant les effets moteur, puis rentrée des traînées selon le manuel', 'Rentrée des volets, puis puissance, puis assiette', 'Puissance seulement', 'Freins puis puissance', 'a', 'On affiche l''assiette, on met la puissance en contrant les effets moteurs, puis on réduit les traînées comme prévu par le manuel de vol.', 'pilotage'),
    ('En finale, comment corrige-t-on la vitesse selon le guide ENAC ?', 'Par la puissance (la trajectoire étant tenue par l''assiette)', 'Par l''assiette uniquement', 'Par les volets', 'Par le palonnier', 'a', 'Corriger la vitesse avec l''assiette en finale est une erreur fréquente : on garde le plan à l''assiette et on règle la vitesse à la puissance.', 'pilotage'),
    ('En finale, quel rythme de circuit visuel le guide ENAC préconise-t-il ?', 'Vitesse, vitesse, vitesse', 'Axe, plan, vitesse, axe, plan, vitesse…', 'Uniquement la piste', 'Les instruments moteur', 'b', 'On balaie régulièrement axe, plan et vitesse, en corrigeant chaque écart détecté.', 'pilotage'),
    ('En finale, comment corrige-t-on les écarts d''axe ?', 'Uniquement au palonnier', 'Par des corrections de cap à faible inclinaison (moins de 20°), bien conjuguées', 'Par de fortes inclinaisons', 'En sortant les volets', 'b', 'Corriger l''axe uniquement au palonnier est une erreur fréquente ; on fait de petits virages coordonnés.', 'pilotage'),
    ('Où commence la phase d''atterrissage selon le guide ENAC ?', 'À la réduction de puissance', 'Au début de la finale', 'À l''arrondi', 'Au toucher des roues', 'a', 'L''atterrissage débute à la réduction de puissance et se termine à la vitesse de roulage.', 'pilotage'),
    ('Selon le guide ENAC, dans des conditions standard, où débute la réduction de puissance ?', 'À 500 ft', 'Au seuil, à 0 ft', 'Après le toucher', 'À environ 25 ft, à mi-chemin entre le passage des 50 ft et le point d''aboutissement', 'd', 'Pour la plupart des avions, la réduction commence vers 25 ft, environ 150 m avant le point d''aboutissement.', 'pilotage'),
    ('Selon le guide ENAC, un excédent de vitesse de 10 kt en finale ajoute environ :', '150 m de distance d''atterrissage', '10 m', '1 km', 'Rien', 'a', 'D''où l''intérêt d''anticiper la réduction de puissance en cas d''excédent de vitesse.', 'pilotage'),
    ('À quelle hauteur commence-t-on en général l''arrondi ?', '100 ft', '50 ft', 'Au toucher', 'Environ 10 ft, quand le point d''aboutissement commence à être masqué par le capot', 'd', 'L''arrondi fait passer la trajectoire d''environ 3° à environ 1°, puis on rejoint l''assiette d''atterrissage.', 'pilotage'),
    ('Pendant l''arrondi, l''avion remonte. Que faire ?', 'Pousser fort sur le manche', 'Couper le moteur', 'Freiner', 'Appliquer l''atterrissage manqué', 'd', 'Si l''avion remonte ou en cas de rebond important, on remet les gaz. Il ne faut jamais pousser sur le manche pendant l''arrondi.', 'pilotage'),
    ('Pendant l''arrondi, l''avion reste parallèle à la piste sans descendre. Que faire ?', 'Pousser sur le manche', 'Remettre plein gaz et monter', 'Bloquer l''assiette jusqu''à ce qu''il se remette à descendre, puis reprendre l''arrondi', 'Freiner', 'c', 'L''avion va s''enfoncer de lui-même en perdant de la vitesse ; on reprend alors l''arrondi.', 'pilotage'),
    ('Pendant l''arrondi, faut-il pousser sur le manche si l''avion flotte ?', 'Oui, toujours', 'Oui, si la piste est longue', 'Jamais', 'Oui, avec un train classique', 'c', 'Le guide ENAC est formel : ne jamais pousser sur le manche durant l''arrondi.', 'pilotage'),
    ('Pour un atterrissage manqué, quelles sont les premières actions ?', 'Pousser pour reprendre de la vitesse', 'Rentrer les volets d''abord', 'Maintenir l''assiette (positive ou nulle) et les ailes horizontales, puis puissance de décollage en contrant les effets moteur', 'Couper le moteur', 'c', 'Ensuite on accélère sur une pente nulle ou légèrement positive puis on prend l''assiette d''approche interrompue.', 'pilotage'),
    ('Pour un freinage efficace après l''atterrissage, il faut :', 'Freiner fort dès le toucher à grande vitesse', 'Garder le manche en avant', 'Garder les volets sortis à fond quoi qu''il arrive', 'Un poids maximal sur le train principal et une portance minimale, donc une vitesse réduite', 'd', 'Le freinage doit être progressif et continu pour éviter de bloquer les roues.', 'pilotage'),
    ('Pendant l''atterrissage, où doit rester le regard à partir de la réduction de puissance ?', 'Sur l''anémomètre', 'Sur le seuil juste devant le capot', 'Sur la manche à air', 'Sur l''horizon, pour exploiter la vision périphérique', 'd', 'Après la réduction, les informations viennent en grande partie de la vision périphérique ; le regard reste loin devant.', 'pilotage'),
    ('Pourquoi un avion à train classique est-il instable au roulage ?', 'Son moteur est plus puissant', 'Il a des freins moins efficaces', 'Son centre de gravité est en arrière du train principal', 'Son aile est plus haute', 'c', 'Avec le centre de gravité derrière le train principal, un écart d''axe tend à s''amplifier (cheval de bois).', 'pilotage'),
    ('Avec un avion à roulette de queue, quelle assiette d''atterrissage adopte-t-on en général ?', 'L''assiette « trois points»', 'Le train principal seul, queue haute, systématiquement', 'La roulette de queue en premier', 'Le train avant en premier', 'a', 'On se pose trois points, puis on amène le manche en butée arrière pour tenir l''axe et éviter le passage sur le nez.', 'pilotage'),
    ('Le « touch and go » existe-t-il en tant qu''opération aérienne selon le guide ENAC ?', 'Oui, c''est la procédure normale de fin de vol', 'Non, c''est un exercice d''instruction ; une approche se conclut normalement par un atterrissage ou une approche interrompue', 'Oui, il est obligatoire à chaque vol', 'Il est interdit en France', 'b', 'Le guide le présente comme un outil d''instruction. Le « stop and go » est une autre option si la piste est assez longue.', 'pilotage'),
    ('Quand l''atterrissage est-il réellement terminé ?', 'Au toucher des roues', 'Quand la piste est dégagée', 'À la réduction de puissance', 'À l''arrondi', 'b', 'Le relâchement de l''attention après le toucher est une erreur fréquente : on pilote jusqu''à la sortie de piste.', 'pilotage'),
    ('Pour un circuit rectangulaire en l''absence de circuit publié, quelle hauteur le guide ENAC retient-il ?', '500 ft', '2000 ft', '300 ft', '1000 ft au-dessus de l''aérodrome', 'd', 'Le tour de piste rectangulaire de référence se fait à 1000 ft AAL.', 'pilotage'),
    ('Dans le tour de piste rectangulaire du guide ENAC, à quelle distance et quelle hauteur l''avion passe-t-il en début de finale ?', '5 NM et 2000 ft', '0,5 NM et 100 ft', '3 NM et 1500 ft', 'Environ 1,6 NM (3 km) et 500 ft', 'd', 'Sur un plan de 3°, 500 ft correspondent à 1,6 NM, soit environ 3 km.', 'pilotage'),
    ('Quel écartement de vent arrière le guide ENAC retient-il pour le circuit rectangulaire ?', '0,2 NM', '5 NM', 'Environ 2 NM de l''axe de piste', '10 NM', 'c', 'L''écartement d''environ 2 NM se visualise par projection de la longueur d''aile.', 'pilotage'),
    ('Le long d''une piste de 1000 m, comment positionner le point de fin de vent arrière selon le guide ENAC ?', 'Juste au travers du seuil', 'À 10 longueurs de piste', 'Au travers du milieu de piste', 'En projetant environ 3 fois la longueur de piste au-delà', 'd', '3 × 1000 m = 3000 m, soit environ 1,6 NM, la distance de la finale à 500 ft.', 'pilotage'),
    ('En vent arrière à l''écartement nominal, sous quel angle voit-on la piste en fin d''éloignement ?', '90°', '10°', 'On ne la voit plus', 'Environ 45° vers l''arrière', 'd', 'Le guide ENAC donne 45° vers l''arrière pour le circuit rectangulaire et environ 30° pour le circuit basse hauteur.', 'pilotage'),
    ('Pourquoi configure-t-on l''avion en approche le plus tôt possible en vent arrière ?', 'Pour aller plus vite', 'Pour économiser le carburant', 'Pour être plus disponible ensuite pendant l''éloignement', 'Ce n''est pas recommandé', 'c', 'Le guide ENAC conseille de passer en configuration approche tôt pour libérer de la disponibilité.', 'pilotage'),
    ('Quel est le premier virage après le décollage dans le circuit rectangulaire ?', 'Un demi-tour immédiat', 'Un virage de 90° vers la branche vent traversier, après 500 ft et l''extrémité de piste', 'Un virage à 45° dès le décollage', 'Un virage à 300 ft avant la fin de piste', 'b', 'Le premier virage, en montée, se fait à inclinaison limitée à 20°, après 500 ft sol et au-delà de la piste.', 'pilotage'),
    ('Selon le guide ENAC, quelle est la hauteur minimale retenue pour un tour de piste ?', '100 ft AAL', '1000 ft AAL', '50 ft AAL', '300 ft AAL', 'd', 'Entre 300 et 600 ft on emploie la technique du tour de piste basse hauteur.', 'pilotage'),
    ('En montée initiale, quand peut intervenir au plus tôt le premier virage selon le guide ENAC ?', 'Dès que l''avion décolle', 'Après 100 ft sol et pas avant la fin de piste', 'Après 3000 ft', 'Avant la fin de piste', 'b', 'C''est la limite basse retenue, utile notamment pour le circuit à basse hauteur.', 'pilotage'),
    ('Quand utilise-t-on le circuit d''aérodrome à basse hauteur ?', 'À chaque tour de piste', 'Pour aller plus vite en navigation', 'Uniquement de nuit', 'En cas de plafond bas, de visibilité réduite ou d''incident après décollage nécessitant un retour rapide', 'd', 'C''est une procédure pour situation dégradée, à exécuter sans évolutions précipitées.', 'pilotage'),
    ('Entre quelles hauteurs s''effectue le circuit basse hauteur selon le guide ENAC ?', 'Entre 1000 et 1500 ft', 'Entre 300 et 600 ft', 'Entre 50 et 100 ft', 'Entre 2000 et 3000 ft', 'b', 'L''avion doit être stabilisé à 100 ft au plus tard en finale.', 'pilotage'),
    ('Dans le dernier virage du circuit basse hauteur, quelle inclinaison maximale le guide ENAC retient-il ?', '60°', '37°', '15°', '45°', 'b', 'L''inclinaison choisie entre 30° et 37° en début de virage est réduite à l''approche de l''axe ; elle est limitée à 37°.', 'pilotage'),
    ('En circuit basse hauteur, l''éloignement sans vent à 500 ft dure environ :', '30 secondes', '3 minutes', '5 secondes', '10 minutes', 'a', 'Le guide donne une formule de chronométrage : H/10 × Fb secondes, soit environ 30 s à 500 ft.', 'pilotage'),
    ('Selon le guide ENAC, quelle est la limite haute retenue pour un tour de piste, hors altitude publiée ?', '3000 ft AAL', '1500 ft AAL', '1000 ft AAL', '5000 ft AAL', 'b', 'L''ENAC retient 1500 ft AAL comme limite haute, sauf circuit publié différent.', 'pilotage'),
    ('Sur un aérodrome avec un circuit publié, que doit faire le pilote ?', 'Faire un circuit rectangulaire standard', 'Choisir librement', 'Suivre l''avion précédent', 'Suivre les trajectoires imposées (trace sol et/ou altitude) publiées sur la carte', 'd', 'Les trajectoires publiées doivent être suivies ; on détermine le point de mise en descente en conséquence.', 'pilotage'),
    ('Quelles sont les caractéristiques d''un virage engagé ?', 'Diminution rapide de la vitesse et vibrations', 'Avion en vrille à plat', 'Bille à fond d''un côté et vitesse nulle', 'Augmentation de l''inclinaison, de l''assiette à piquer et surtout de la vitesse', 'd', 'Le virage engagé est une spirale où la vitesse augmente vite, au risque de dépasser la VNE ou le facteur de charge.', 'pilotage'),
    ('Quel est le premier geste pour sortir d''un virage engagé ?', 'Tirer fort sur le manche', 'Mettre plein gaz', 'Mettre du palonnier opposé à fond', 'Réduire complètement la puissance', 'd', 'Ordre : réduire la puissance, annuler l''inclinaison, ressource souple jusqu''au palier, puis remettre la puissance à la vitesse de croisière.', 'pilotage'),
    ('Dans un virage engagé, pourquoi annuler l''inclinaison avant de tirer ?', 'Pour aller plus vite', 'Parce que le compas l''exige', 'Ce n''est pas nécessaire', 'Tirer en virage incliné resserre la spirale et augmente le facteur de charge', 'd', 'Tant que l''avion est incliné, tirer sur le manche resserre le virage au lieu de redresser la trajectoire.', 'pilotage'),
    ('En virage engagé, le vol est le plus souvent :', 'Symétrique, avec un facteur de charge proche de 1', 'Fortement dérapé', 'Décroché', 'En vol dos', 'a', 'Le guide ENAC souligne ce point : le vol reste généralement symétrique, ce qui distingue le virage engagé de la vrille.', 'pilotage'),
    ('En cas de mauvaise visibilité, quel instrument aide à sortir d''un virage engagé ?', 'Le compas', 'L''altimètre seul', 'Le transpondeur', 'L''indicateur de virage', 'd', 'L''indicateur de virage reste une aide fiable pour annuler la rotation.', 'pilotage'),
    ('Avant la rotation, une alarme ou une panne apparaît. Que faire ?', 'Décoller quand même puis revenir', 'Faire un virage sur la piste', 'Couper la radio', 'Interrompre le décollage, avec un freinage adapté à la longueur de piste restante', 'd', 'Exemples : alarme, anomalie moteur, vibrations, pneu éclaté, porte ouverte, anémomètre bloqué. Le freinage doit être continu, sans à-coups.', 'pilotage'),
    ('Panne moteur franche juste après le décollage. Que faire selon le guide ENAC ?', 'Faire demi-tour pour revenir sur la piste', 'Cabrer pour garder de l''altitude', 'Prendre l''assiette de descente moteur réduit et se poser à peu près droit devant', 'Chercher la cause de la panne avant tout', 'c', 'Le demi-tour est à proscrire, la hauteur étant en général insuffisante. On évite les obstacles avec l''inclinaison permise, puis on applique la procédure du manuel.', 'pilotage'),
    ('Incident mineur en montée initiale (alarme, anémomètre en panne). Quelle est la priorité ?', 'Piloter l''avion, puis gérer la trajectoire, puis communiquer', 'Appeler la tour immédiatement', 'Lire la check-list en premier', 'Réduire la puissance', 'a', 'Une fois la trajectoire sécurisée, on déroule un processus de décision structuré (FORDEC, ABDI…).', 'pilotage'),
    ('Lors d''une simulation de panne, que faut-il annoncer à l''élève et au contrôle ?', '« Mayday »', '« Pan pan »', '« Pour exercice… »', 'Rien', 'c', 'Annoncer « pour exercice » évite de déclencher une procédure réelle face à une situation fictive.', 'pilotage'),
    ('Avant le premier vol solo, quelle leçon doit être parfaitement assimilée selon le guide ENAC ?', 'Les pannes en phase de décollage', 'Le vol de nuit', 'La vrille', 'La radionavigation', 'a', 'Le premier solo n''est envisageable que si l''élève est entraîné aux pannes au décollage.', 'pilotage'),
    ('À partir de quelle inclinaison parle-t-on de virage à grande inclinaison ?', '20°', '30°', '45° et plus', '90°', 'c', 'Un virage est dit à grande inclinaison à partir de 45°. Il sert surtout aux situations d''urgence (évitement).', 'pilotage'),
    ('Pendant un virage à grande inclinaison, l''effort à cabrer sur le manche est :', 'Proportionnel au facteur de charge', 'Nul', 'Plus faible qu''en ligne droite', 'Toujours à piquer', 'a', 'Il faut maintenir une action à cabrer importante pour tenir la pente, d''autant plus que l''inclinaison est forte.', 'pilotage'),
    ('Selon le guide ENAC, à quoi doit-on se référer en priorité pendant un virage à grande inclinaison ?', 'Aux repères extérieurs, les instruments n''étant qu''informatifs', 'À l''horizon artificiel uniquement', 'Au GPS', 'Au compas', 'a', 'La réalisation se fait par visualisation de l''extérieur.', 'pilotage'),
    ('Parmi ces éléments, lequel figure dans les conditions réglementaires du lâcher solo ?', 'Une licence PPL', 'Une autorisation écrite de l''instructeur habilité', 'Une qualification de vol de nuit', '500 heures de vol', 'b', 'Le guide ENAC liste notamment l''âge requis, le certificat médical, l''autorisation écrite de l''instructeur et l''autorisation parentale pour un mineur non émancipé.', 'pilotage'),
    ('Selon le guide ENAC, quelle quantité minimale de carburant pour un premier vol solo ?', 'Pour 15 minutes', 'Le plein complet obligatoire', 'Pour 2 heures de vol au minimum', 'Pour 30 minutes', 'c', 'C''est l''un des points de la liste de consignes avant lâcher, avec la vérification de l''avion et des documents.', 'pilotage'),
    ('Au premier solo, en quoi le comportement de l''avion change-t-il ?', 'Il est plus léger et son centrage est modifié', 'Il est plus lourd', 'Il ne change pas', 'Il ne peut plus décoller', 'a', 'Sans l''instructeur, l''avion est plus léger, décolle plus tôt et monte mieux ; le centrage change aussi.', 'pilotage'),
    ('Pendant le vol solo d''un élève, l''instructeur doit-il le guider à la radio ?', 'Oui, en permanence', 'Oui, à chaque virage', 'Oui, il doit piloter à distance', 'Non, si le lâcher est décidé c''est que l''élève est autonome', 'd', 'Le guidage radio est une erreur de l''instructeur. Il assure en revanche une veille radio.', 'pilotage'),
    ('Avant un vol solo, quelle activité récente peut être incompatible ?', 'Une marche à pied', 'La lecture d''un livre', 'Un repas léger', 'Une plongée sous-marine', 'd', 'Le guide ENAC cite la plongée parmi les points de santé à vérifier, avec l''absence de traitement incompatible.', 'pilotage'),
    ('Qu''est-ce qui ne doit pas influencer la décision de lâcher un élève ?', 'La météo', 'La forme de l''élève', 'L''état de l''avion', 'Le planning ou le volume d''heures', 'd', 'Être influencé par des éléments extérieurs comme le planning est une erreur de l''instructeur.', 'pilotage'),
    ('Quel type de décollage est pris en compte pour déterminer les performances du manuel de vol ?', 'Le décollage roulé (rolling)', 'Le décollage sur piste limitative, avec mise en puissance sur freins', 'Le décollage sur terrain meuble', 'Le décollage vent arrière', 'b', 'C''est le décollage de certification ; il se distingue par la mise en puissance sur freins.', 'pilotage'),
    ('Pour un décollage sur piste limitative, comment s''aligne-t-on ?', 'Au milieu de la piste', 'Sur les premiers mètres de piste, avion et roue avant bien alignés, pour garder toute la longueur', 'En roulant sans s''arrêter depuis la bretelle la plus proche', 'N''importe où', 'b', 'Chaque mètre compte : on s''aligne en début de piste, roue avant dans l''axe, puis puissance de décollage sur freins.', 'pilotage'),
    ('Au décollage par vent de travers, quelle action au palonnier pour tenir l''axe pendant la mise en puissance ?', 'Palonnier côté vent', 'Aucune action', 'Palonnier alternativement des deux côtés', 'Palonnier du côté opposé au vent, pour contrer l''effet girouette', 'd', 'L''avion tend à se mettre face au vent : on contre au palonnier côté opposé, et on met du manche dans le vent contre l''effet dièdre.', 'pilotage'),
    ('Pendant l''accélération au décollage vent de travers, le braquage des ailerons dans le vent :', 'Augmente jusqu''à la butée', 'Diminue progressivement jusqu''à être faible au moment du décollage', 'Reste constant', 'Est inversé', 'b', 'Les gouvernes devenant plus efficaces avec la vitesse, on réduit progressivement le braquage.', 'pilotage'),
    ('Après un décollage vent de travers, comment l''avion prend-il sa correction de dérive ?', 'Naturellement, si le pilote maintient la symétrie du vol', 'En inclinant fortement du côté du vent', 'En gardant le palonnier enfoncé', 'Il ne peut pas en prendre', 'a', 'Une fois en l''air, en vol symétrique, l''avion s''oriente de lui-même et affiche la correction de dérive.', 'pilotage'),
    ('Sur un terrain meuble (boue, herbe grasse, neige), quel est l''objectif au décollage ?', 'Rouler le plus longtemps possible', 'Décoller avec les volets rentrés et le nez bas', 'Décoller à la vitesse minimale de sustentation pour se dégager vite du freinage du sol', 'Freiner pendant la mise en puissance', 'c', 'On cherche à soulager les roues au plus tôt ; l''avion décolle de lui-même quand la vitesse est suffisante.', 'pilotage'),
    ('Sur un terrain meuble, faut-il marquer un arrêt après l''alignement ?', 'Oui, toujours un arrêt complet', 'Non, on applique la puissance immédiatement en gardant le manche en arrière', 'Oui, en freinant fort', 'Oui, moteur au ralenti pendant une minute', 'b', 'Ne pas s''arrêter évite l''enlisement ; le manche en arrière soulage la roue avant.', 'pilotage'),
    ('Juste après un décollage sur terrain meuble, quelle assiette prend-on ?', 'L''assiette de montée maximale', 'Une assiette à piquer prononcée', 'L''assiette de descente', 'Celle qui permet d''accélérer sans redescendre, dans l''effet de sol', 'd', 'L''avion a décollé à basse vitesse : on accélère en palier près du sol jusqu''à la vitesse de montée normale.', 'pilotage'),
    ('Par rapport à la montée normale, la montée à Vz maximum (Vy) apporte selon le guide ENAC :', 'Une vitesse plus élevée', 'Une pente plus faible', 'Un gain de Vz d''environ 30 % pour une vitesse inférieure d''environ 20 %', 'Aucun gain', 'c', 'Le moteur fonctionne à la puissance maximale continue : consommation plus forte et refroidissement moins bon.', 'pilotage'),
    ('Quand utilise-t-on la montée à pente maximum (Vx) ?', 'Momentanément, pour franchir un obstacle', 'Pour toute la montée en navigation', 'En croisière', 'Pour économiser le moteur', 'a', 'Elle se fait près du décrochage, avec un mauvais refroidissement et une visibilité réduite vers l''avant : on ne la prolonge pas.', 'pilotage'),
    ('Pendant une montée à pente maximum, les virages doivent se faire :', 'À 45° pour aller vite', 'À très faible inclinaison', 'À 60°', 'Ce n''est pas un problème', 'b', 'La vitesse est proche du décrochage ; ce type de montée est aussi à éviter en atmosphère turbulente.', 'pilotage'),
    ('À quoi correspond à peu près la vitesse de meilleur taux de montée ?', 'À la vitesse de puissance minimale nécessaire (frontière entre premier et second régime)', 'À la Vne', 'À la vitesse de décrochage', 'À la vitesse de croisière', 'a', 'C''est là que l''excédent de puissance est maximal.', 'pilotage'),
    ('Comment trouver expérimentalement la vitesse de meilleure pente ?', 'C''est celle qui donne la plus grande Vz', 'C''est la vitesse qui donne le rapport Vz/Vi le plus grand', 'C''est la plus grande vitesse', 'C''est la vitesse de décrochage', 'b', 'Pleine puissance, on note Vz et Vi pour plusieurs assiettes : la meilleure Vz donne Vy, le meilleur rapport Vz/Vi donne Vx.', 'pilotage'),
    ('Une fois l''obstacle franchi après une montée à pente maximum, que fait-on ?', 'On accélère vers la vitesse de montée normale puis on réduit vers la puissance de montée', 'On garde Vx jusqu''à l''altitude de croisière', 'On réduit tout de suite au ralenti', 'On sort les volets', 'a', 'On reprend l''assiette de montée initiale, on accélère, puis on affiche la puissance de montée.', 'pilotage'),
    ('Pourquoi surveiller particulièrement les paramètres moteur en montée à faible vitesse ?', 'Le moteur consomme moins', 'L''huile gèle', 'Le mélange s''appauvrit seul', 'L''assiette cabrée et la faible vitesse réduisent le refroidissement', 'd', 'À forte puissance et faible vitesse, le moteur chauffe ; on surveille notamment la température culasse.', 'pilotage'),
    ('À quoi sert une trajectoire anti-bruit au départ ?', 'À atteindre l''altitude la plus élevée possible avant de survoler des zones sensibles', 'À voler plus bas pour être moins vu', 'À raccourcir la navigation', 'À éviter les contrôleurs', 'a', 'Elles relèvent de la réglementation et du savoir-être ; certaines imposent des virages à des points ou altitudes précis.', 'pilotage'),
    ('Quelle attitude dangereuse est souvent associée aux accidents de décollage sur piste courte ou par forte chaleur ?', 'L''excès de prudence', 'L''anxiété de l''instructeur', 'L''invulnérabilité (« ça va passer ») et la négligence (pas de calcul de performance)', 'Le respect des marges', 'c', 'Le guide ENAC relie ces accidents à la méconnaissance des performances, souvent combinée à ces attitudes.', 'pilotage'),
    ('Atterrissage vent de travers en crabe : quand décrabe-t-on ?', 'En courte finale à 300 ft', 'Après le toucher', 'Jamais', 'À la fin de l''arrondi, juste avant le contact, en empêchant l''avion de s''incliner sous le vent', 'd', 'On garde la correction de dérive jusqu''à la fin de l''arrondi, puis on aligne l''axe de l''avion sur la piste au palonnier, avec un peu d''inclinaison au vent.', 'pilotage'),
    ('Avec la méthode de l''aile basse dans le vent, sur quelle roue l''avion touche-t-il d''abord ?', 'La roue avant', 'La roue au vent, puis la roue sous le vent, puis la roue avant', 'La roue sous le vent', 'Les trois en même temps', 'b', 'L''axe est tenu au palonnier et la dérive annulée par une inclinaison du côté du vent.', 'pilotage'),
    ('Après le toucher par vent de travers, que fait-on des ailerons pendant la décélération ?', 'On augmente progressivement leur braquage dans le vent', 'On les remet au neutre', 'On les braque sous le vent', 'On les ignore', 'a', 'À mesure que la vitesse diminue, les ailerons perdent de l''efficacité : on les braque davantage pour éviter que l''aile au vent ne se soulève.', 'pilotage'),
    ('Sur un terrain meuble, comment atterrit-on si le manuel de vol ne décrit pas de procédure ?', 'Approche rapide, volets rentrés', 'Approche à 1,3 Vso, volets au maximum, toucher à la vitesse la plus faible, roue avant en l''air le plus longtemps possible', 'Toucher sur la roue avant', 'Freiner fort au toucher', 'b', 'Pendant le roulage on garde la profondeur à cabrer et on évite de laisser l''avion s''immobiliser seul pour ne pas s''enliser.', 'pilotage'),
    ('Avec un train classique par fort vent de face, quelle technique d''atterrissage propose le guide ENAC ?', 'Un atterrissage trois points à forte incidence', 'Un atterrissage moteur coupé', 'Un atterrissage vent arrière', 'Un atterrissage en ligne de vol sur le train principal, puis le contrôle du toucher de la roulette', 'd', 'En trois points l''incidence est forte : par fort vent de face, l''avion risque de « courir » au-dessus de la piste.', 'pilotage'),
    ('Faute de données, de combien majorer la distance d''atterrissage volets 0° par rapport à volets atterrissage ?', '5 %', '200 %', '50 %', 'Aucune majoration', 'c', 'Le guide ENAC propose 50 % en l''absence de critères de performance.', 'pilotage'),
    ('Quelles vitesses utilise-t-on pour un atterrissage volets 0° ?', 'Les mêmes que volets sortis', 'Vne', '1,45 Vs en évolution et 1,3 Vs en finale, calculées pour la configuration volets 0°', '1,1 Vs partout', 'c', 'Les vitesses sont recalculées à partir de la vitesse de décrochage lisse, plus élevée.', 'pilotage'),
    ('Pourquoi faut-il une finale plus longue pour un atterrissage volets 0° ?', 'Il est plus lent', 'Les freins sont moins bons', 'La tour l''exige', 'L''avion est plus fin et décélère difficilement', 'd', 'En plus, l''avion est plus cabré, ce qui gêne la perception de la hauteur d''arrondi ; l''arrondi est plus long avant le contact.', 'pilotage'),
    ('Pour un atterrissage sur piste limitative, la finale se fait :', 'Vref + 20 kt', 'Volets rentrés', 'À la vitesse de croisière', 'À Vref, avec un point d''aboutissement au plus près du seuil', 'd', 'C''est le type d''atterrissage de certification : précision de vitesse, point cible proche du seuil, freinage maximal jusqu''à l''arrêt.', 'pilotage'),
    ('Quand envisage-t-on un atterrissage de précaution ?', 'Dès qu''on est en retard', 'Quand l''aérodrome de destination, le dégagement et le déroutement ne sont plus accessibles', 'Pour faire une pause', 'Pour économiser une taxe d''atterrissage', 'b', 'Raisons possibles : dégradation météo, manque de carburant, problème mécanique, approche de la nuit.', 'pilotage'),
    ('Que signifie l''acronyme FORDEC ?', 'Faits, Options, Risques, Décision, Exécution, Contrôle', 'Fuel, Oil, Radio, Direction, Engine, Check', 'Freinage, Orientation, Roulage, Décollage, Croisière', 'Formation, Organisation, Règles, Décision, Exercice, Contrôle', 'a', 'C''est une aide pour structurer l''analyse et la prise de décision.', 'pilotage'),
    ('Le moyen mnémotechnique VERDO pour choisir un terrain signifie :', 'Vent, État de surface, Relief, Dimensions, Obstacles', 'Vitesse, Essence, Radio, Direction, Orientation', 'Visibilité, Écartement, Route, Distance, Ordre', 'Volets, Essence, Réchauffage, Démarreur, Oxygène', 'a', 'Il structure les critères de choix d''un terrain pour un atterrissage hors aérodrome.', 'pilotage'),
    ('Pour un atterrissage hors aérodrome, quel type de champ est en général préférable ?', 'Les cultures hautes (maïs, tournesol)', 'Les chaumes', 'Les champs labourés non hersés', 'Les plans d''eau', 'b', 'Ordre de préférence : surfaces dures, chaumes, labours hersés, cultures fourragères, céréales, labours non hersés, cultures hautes.', 'pilotage'),
    ('Pour un atterrissage hors aérodrome, quel terrain est le moins favorable parmi ceux-ci ?', 'Les chaumes', 'Les labours hersés', 'Les cultures hautes', 'Les cultures fourragères', 'c', 'Les cultures hautes (maïs, tournesol, tabac) arrivent en dernier dans l''ordre de préférence.', 'pilotage'),
    ('Sur un terrain en pente, dans quel sens faut-il se poser ?', 'En descente', 'En montée (pente montante), en évitant le dévers latéral', 'En travers de la pente', 'Peu importe', 'b', 'Se poser dans le sens montant raccourcit la distance d''atterrissage. Attention au relief pour la remise de gaz.', 'pilotage'),
    ('Comment estimer la longueur d''un champ en vol ?', 'En chronométrant son survol : à 100 kt sol, environ 50 m par seconde', 'En comptant les arbres', 'Au GPS uniquement', 'Ce n''est pas possible', 'a', 'Le guide ENAC donne 50 m/s à 100 kt et 60 m/s à 120 kt (10 secondes à 100 kt font environ 500 m).', 'pilotage'),
    ('Pourquoi éviter un champ en fond de vallée ou bordé de végétation haute ?', 'Risque de lignes électriques difficiles à voir', 'Le vent y est toujours nul', 'Les secours ne peuvent pas y accéder', 'Ce n''est pas un problème', 'a', 'Les portées de lignes électriques sont souvent invisibles ; des obstacles en bout de champ pénalisent aussi la remise de gaz.', 'pilotage'),
    ('À quelle hauteur effectue-t-on la reconnaissance haute du terrain choisi ?', '50 ft', 'Si possible entre 1000 et 1500 ft sol', '5000 ft', 'Au ras du sol', 'b', 'On y détermine le vent, l''état de surface et le relief, et on repère d''autres zones possibles.', 'pilotage'),
    ('À quelle hauteur se fait la reconnaissance basse d''un atterrissage de précaution ?', 'À 1500 ft', 'À 50 ft dans l''axe', 'À 3000 ft', 'Entre 300 et 500 ft (500 ft en instruction), en configuration approche, décalé de l''axe', 'd', 'Elle confirme le vent, la surface et le relief, et évalue les dimensions et obstacles.', 'pilotage'),
    ('Pendant un atterrissage de précaution, quand active-t-on la balise de détresse en mode manuel ?', 'Avant tout message radio', 'Jamais', 'Après le dernier message radio, car elle peut perturber la VHF', 'Une fois au sol seulement', 'c', 'On prévient un organisme, on affiche 7700, puis on active la balise après le dernier message.', 'pilotage'),
    ('Après un atterrissage de précaution, qui faut-il prévenir ?', 'Personne', 'Uniquement l''aéroclub', 'Le constructeur', 'Une autorité civile ou militaire (mairie, gendarmerie…)', 'd', 'On organise aussi la garde de l''avion. Un nouveau décollage ne peut se faire qu''avec l''accord de l''autorité compétente.', 'pilotage'),
    ('Selon le guide ENAC, combien de temps faut-il, sans précipitation, pour réaliser une procédure d''atterrissage de précaution ?', 'Plus d''une heure', '30 secondes', 'Il n''y a pas de durée', 'Moins de 15 minutes', 'd', 'Le guide insiste : sans précipitation, la procédure se réalise facilement en moins de 15 minutes. Il faut décider avant qu''il ne soit trop tard.', 'pilotage'),
    ('Pendant l''exercice d''atterrissage de précaution en instruction, à quelle hauteur minimale fait-on l''approche interrompue ?', '500 ft', '150 ft', '20 ft', '1000 ft', 'b', 'Le guide ENAC fixe une remise de gaz à 150 ft minimum lors des simulations.', 'pilotage'),
    ('Une erreur fréquente lors d''un atterrissage de précaution est :', 'Une reconnaissance trop soignée', 'Un message radio trop précoce', 'Une check-list trop complète', 'Un circuit trop court par peur de perdre le champ de vue', 'd', 'Un circuit trop serré conduit à un plan fort et une vitesse excessive en finale.', 'pilotage'),
    ('Comment détermine-t-on l''angle simple de plané d''un avion ?', 'En descente moteur réduit, en repérant le point d''immobilité apparente au sol', 'En lisant le manuel de vol uniquement', 'Au GPS', 'Avec le variomètre seul', 'a', 'On le fait en configuration approche à 1,3 Vs1 + 5 kt, puis en configuration atterrissage à 1,3 Vs0 + 5 kt.', 'pilotage'),
    ('Pourquoi ajoute-t-on 5 kt à 1,3 Vs pour les exercices moteur réduit ?', 'Pour aller plus loin', 'Pour tenir compte du redressement plus important de la trajectoire à l''arrondi', 'Pour refroidir le moteur', 'C''est une exigence réglementaire', 'b', 'Au point habituel de réduction, on « casse » la pente pour revenir vers 3°, ce qui résorbe ces 5 kt.', 'pilotage'),
    ('Selon le guide ENAC, quel est l''ordre de grandeur de l''angle de plané d''un avion léger volets 0° ?', 'Environ 1°', 'Environ 6°', 'Environ 20°', 'Environ 45°', 'b', 'Il est d''environ 6° volets 0° et environ 8° volets atterrissage.', 'pilotage'),
    ('En prise de terrain moteur réduit dans l''axe, comment ajuste-t-on la trajectoire ?', 'On garde les volets rentrés jusqu''au sol', 'On remet de la puissance', 'On vise un plan en configuration approche avec un excédent de hauteur, résorbé ensuite en sortant les volets atterrissage', 'On fait des S', 'c', 'La précision dépend du moment où l''on passe en configuration atterrissage.', 'pilotage'),
    ('En vol moteur réduit, si l''on se voit sur un plan trop faible, que faut-il faire ?', 'Tirer pour allonger le plané', 'Sortir les volets', 'Une approche interrompue, au plus tard à 100 ft', 'Continuer en espérant arriver', 'c', 'Tirer sur le manche n''allonge pas le plané. En exercice, on remet les gaz au plus tard à 100 ft.', 'pilotage'),
    ('En vol moteur réduit, si l''on se voit sur un plan trop fort, que peut-on faire ?', 'Remettre de la puissance', 'Anticiper la sortie des volets atterrissage', 'Rentrer les volets', 'Accélérer', 'b', 'Les volets augmentent la pente de descente et permettent de résorber un excédent de hauteur.', 'pilotage'),
    ('Comment corrige-t-on l''effet du vent effectif dans les prises de terrain moteur réduit ?', 'En visant plus loin par vent de face', 'En ne changeant rien', 'En augmentant l''inclinaison', 'En décalant le point cible au vent, d''environ 20 m par kt', 'd', 'Le point cible est décalé au vent (environ 20 m par kt de vent effectif) ; les points d''aboutissement et de toucher restent les mêmes.', 'pilotage'),
    ('En prise de terrain en « L », qu''est-ce que le point clé ?', 'Le point où l''avion voit la perpendiculaire passant par le point cible sous l''angle double de plané, à 45° de l''axe', 'Le seuil de piste', 'Le milieu de la vent arrière', 'Le point de toucher', 'a', 'Le point clé est à la base de toutes les évolutions moteur réduit.', 'pilotage'),
    ('De quoi est constituée la prise de terrain en « L » ?', 'D''une seule finale très longue', 'D''un virage de 360°', 'D''une vent arrière seulement', 'De deux branches égales, base et finale', 'd', 'C''est l''équivalent d''une finale repliée à 90° en son milieu, ce qui limite l''effet du vent.', 'pilotage'),
    ('Pendant la base d''une prise de terrain en « L », l''angle sous lequel on voit la droite de référence diminue trop vite. Que faire ?', 'Rallonger la trajectoire', 'Ne rien changer', 'Raccourcir la trajectoire, l''avion est trop bas', 'Remettre de la puissance tout de suite', 'c', 'Si l''angle passe trop vite de 2 AP à 1 AP, l''avion est trop bas : on raccourcit. S''il diminue trop lentement, on rallonge.', 'pilotage'),
    ('En prise de terrain par encadrement, sous quel angle converge-t-on vers la piste ?', '90°', '5°', '30°', '60°', 'c', 'Cette convergence permet de garder l''axe de piste sous l''angle double de plané pendant toute la descente.', 'pilotage'),
    ('Pour l''exercice de panne moteur verticale, à quelle hauteur survole-t-on la piste ?', '500 ft', '10 000 ft', '100 ft', 'Environ 2000 à 2500 ft', 'd', 'On réduit en coupant la piste, puis on rejoint la trajectoire d''encadrement par un virage à 30°.', 'pilotage'),
    ('À quelle inclinaison fait-on les virages en exercice moteur réduit selon le guide ENAC ?', '30°', '60°', '10°', '45°', 'a', '30° laisse le maximum de temps à inclinaison nulle pour bien visualiser les angles de plané.', 'pilotage'),
    ('En vol moteur réduit, quel risque particulier pour l''anti-abordage ?', 'Aucun', 'Le bruit du moteur', 'Le soleil', 'La descente rapide sur un plan fort et la mauvaise visibilité vers le bas', 'd', 'La trajectoire diffère de celle des autres avions du circuit ; il faut une vigilance accrue.', 'pilotage'),
    ('Qu''est-ce que la vrille ?', 'Un virage serré à grande vitesse', 'Une spirale symétrique à grande vitesse', 'Un tonneau', 'Une chute de l''avion en trajectoire hélicoïdale, au-delà de l''incidence de décrochage, conséquence d''un décrochage dissymétrique', 'd', 'La vrille combine décrochage, dérapage et rotation autour des trois axes.', 'pilotage'),
    ('Quelle différence fondamentale entre vrille et virage engagé ?', 'Il n''y a aucune différence', 'En vrille l''avion est décroché et la vitesse est faible ; en virage engagé il ne l''est pas et la vitesse augmente', 'La vrille se fait toujours moteur plein gaz', 'Le virage engagé est toujours à droite', 'b', 'D''où des procédures de sortie très différentes.', 'pilotage'),
    ('Sur un avion léger, quelle action donne l''arrêt de vrille le plus rapide ?', 'Le manche du côté de la rotation', 'Le palonnier opposé au sens de rotation', 'Plein gaz', 'Les volets sortis', 'b', 'La position de la profondeur dépend de l''avion. On réduit les gaz si la vrille s''engage avec puissance et on suit la procédure du manuel.', 'pilotage'),
    ('Pendant une vrille, que fait-on des ailerons dans la procédure générale ?', 'On braque à fond dans le sens de la rotation', 'On braque à fond contre la rotation', 'On les met au neutre', 'Peu importe', 'c', 'Le neutre simplifie la procédure ; mettre du manche à l''opposé de la vrille peut l''aplatir.', 'pilotage'),
    ('Dans quelle situation réelle une vrille peut-elle survenir ?', 'Dans le dernier virage, en corrigeant la prise d''axe au palonnier à faible vitesse', 'En croisière stabilisée', 'Au roulage', 'En montée normale bien conjuguée', 'a', 'Faible vitesse et dissymétrie : c''est le scénario classique de vrille près du sol.', 'pilotage'),
    ('Pourquoi un centrage arrière hors limite est-il dangereux vis-à-vis de la vrille ?', 'Il empêche toute vrille', 'Il augmente la vitesse de décrochage', 'Il n''a aucun effet', 'Il favorise l''entrée en vrille et rend la sortie difficile', 'd', 'Hors des limites arrière, la stabilité diminue et la vrille peut devenir irrécupérable.', 'pilotage'),
    ('Une fois la rotation de la vrille arrêtée, que faut-il faire ?', 'Maintenir le palonnier à fond', 'Tirer fort immédiatement', 'Remettre les commandes au neutre puis faire une ressource souple', 'Mettre plein gaz en tirant', 'c', 'Garder les actions de sortie trop longtemps peut engager une vrille dans l''autre sens ; une ressource brutale peut faire redécrocher.', 'pilotage'),
    ('Quelles sont les trois priorités dans toute situation anormale ou d''urgence ?', 'Communication, pilotage, trajectoire', 'Check-list, radio, pilotage', 'Radio, carburant, pilotage', 'Pilotage, trajectoire, communication', 'd', 'Piloter reste la priorité absolue. En anglais : aviate, navigate, communicate.', 'pilotage'),
    ('Quelle différence entre procédure anormale et procédure d''urgence ?', 'Il n''y en a pas', 'L''anormale est plus grave', 'L''urgence se traite toujours au sol', 'L''anormale n''a pas de caractère urgent, l''urgence impose des actions immédiates', 'd', 'Une procédure anormale se traite méthodiquement, check-list en main ; en urgence, le facteur temps est essentiel.', 'pilotage'),
    ('Face à une panne d''un système, que vérifie-t-on d''abord ?', 'La météo', 'Les commandes, l''alimentation, la protection (disjoncteur) et la signalisation', 'Le carburant restant uniquement', 'Le cap', 'b', 'Si le problème persiste, on applique la procédure de la check-list, en lisant chaque item avec sa réponse.', 'pilotage'),
    ('Quels sont les trois points de la procédure d''atterrissage forcé selon le guide ENAC ?', 'Appeler, attendre, atterrir', 'Assurer la survie, alerter, minimiser les risques', 'Freiner, couper, sortir', 'Monter, virer, descendre', 'b', 'On choisit d''abord une zone accessible au plané et on la rejoint à finesse maximale.', 'pilotage'),
    ('Panne moteur en campagne : à quelle vitesse rejoint-on la zone choisie ?', 'À la Vne', 'À la vitesse de décrochage', 'À la vitesse de croisière', 'À la vitesse de finesse maximale', 'd', 'C''est la vitesse qui permet de parcourir la plus grande distance en plané.', 'pilotage'),
    ('Si l''on doit se poser dans une forêt, que recommande le guide ENAC ?', 'Mieux vaut se poser sur la cime des arbres que dans une clairière trop étroite', 'Viser une clairière même minuscule', 'Plonger vers le sol', 'Sauter en parachute', 'a', 'Les cimes amortissent le choc ; une clairière trop petite mène à un impact violent contre les arbres de bordure.', 'pilotage'),
    ('Avant un atterrissage forcé, comment limite-t-on le risque d''incendie ?', 'En gardant le moteur au ralenti', 'En fermant le carburant et en coupant l''alimentation électrique générale', 'En vidant les réservoirs en vol', 'En ouvrant les portes', 'b', 'On limite aussi les conséquences du choc : ceintures serrées, lunettes ôtées, position adéquate.', 'pilotage'),
    ('En urgence, l''alerte (message de détresse, 7700) doit-elle passer avant la précision du pilotage à basse hauteur ?', 'Oui, toujours', 'Oui, avant toute action', 'Non, elle ne doit jamais prendre la priorité sur le pilotage près du sol', 'Il ne faut jamais alerter', 'c', 'On alerte si le temps le permet.', 'pilotage'),
    ('Une erreur fréquente lors d''une panne moteur en vol est :', 'Choisir trop vite un champ accessible', 'Changer plusieurs fois de champ et perdre l''accessibilité de toute surface', 'Prendre la vitesse de finesse max', 'Lancer un message de détresse', 'b', 'Il faut s''en tenir au choix fait tant qu''il reste accessible.', 'pilotage'),
    ('À quoi sert le virage à forte inclinaison en descente moteur réduit ?', 'À accélérer en croisière', 'À économiser du carburant', 'À descendre dans un espace restreint, par exemple un trou dans une couche nuageuse', 'À sortir d''une vrille', 'c', 'C''est une procédure anormale qui demande un processus de décision complet.', 'pilotage'),
    ('Pour le virage à forte inclinaison en descente moteur réduit, comment l''avion est-il préparé ?', 'Lisse à la vitesse de croisière', 'Volets rentrés à Vne', 'Configuration atterrissage à 1,45 Vs0', 'Plein gaz', 'c', 'On stabilise ensuite un virage à 45° à vitesse stable.', 'pilotage'),
    ('Dans le virage à forte inclinaison en descente moteur réduit, peut-on compenser ?', 'Oui, c''est une spirale stabilisée et non une phase transitoire', 'Non, jamais', 'Seulement à droite', 'Seulement en montée', 'a', 'Compenser aide à tenir la vitesse et limite le risque de départ en virage engagé.', 'pilotage'),
    ('Pendant la spirale moteur réduit à 45°, si l''inclinaison dépasse 45° :', 'Le taux de chute et la vitesse augmentent rapidement, avec un risque de virage engagé', 'La vitesse diminue', 'L''avion remonte', 'Rien ne change', 'a', 'Corriger par l''assiette seule, sans revenir à l''inclinaison initiale, peut mener au virage engagé.', 'pilotage'),
    ('Quelles menaces présente une descente dans un trou de la couche nuageuse ?', 'Aucune', 'Relief proche, trafic sous la couche, sortie du domaine de vol, perte des références', 'Uniquement le givrage', 'Uniquement la turbulence', 'b', 'Le guide ENAC insiste sur l''approche TEM et l''existence d''autres solutions selon la situation.', 'pilotage'),
    ('Après le passage sous la couche, quel risque surveiller lors de la remise en palier ?', 'Une panne radio', 'Dépasser la VFE si les traînées sont rentrées trop tard', 'Un givrage carburateur certain', 'Une perte du transpondeur', 'b', 'À l''inverse, une remise de puissance tardive rapproche du décrochage.', 'pilotage'),
    ('Qu''est-ce que le TEM ?', 'Le temps estimé de manœuvre', 'Un type de moteur', 'La gestion des menaces et des erreurs (Threat and Error Management)', 'Un mode du transpondeur', 'c', 'Le TEM consiste à identifier les menaces, prévoir des stratégies et gérer ses erreurs. On le retrouve dans les briefings du guide ENAC.', 'pilotage'),
    ('Pour s''entraîner aux situations UPRT, quelle erreur d''instructeur le guide ENAC cite-t-il ?', 'Les présenter progressivement', 'Les montrer à haute altitude', 'Faire un briefing complet', 'Présenter toutes les situations et leurs procédures de sortie en même temps, ce qui crée la confusion', 'd', 'UPRT : prévention et récupération des positions inusuelles. On les aborde progressivement.', 'pilotage'),
    ('Pendant un exercice de virage engagé, à quelle hauteur minimale doit se faire la sortie selon le guide ENAC ?', '100 ft', '300 ft', '5000 ft', '1000 ft sol minimum', 'd', 'On adapte l''exercice pour sortir au moins à 1000 ft sol, en respectant le manuel de sécurité de l''organisme.', 'pilotage'),
    ('Quand pratique-t-on la navigation à l''estime ?', 'Pour joindre deux points par le trajet le plus direct, la ligne droite', 'Uniquement de nuit', 'Uniquement en suivant une autoroute', 'Uniquement avec un GPS', 'a', 'L''estime consiste à tenir un cap et un temps calculés en fonction du vent.', 'navigation'),
    ('Comment calcule-t-on la route magnétique à partir de la route vraie ?', 'Rm = Rv - déclinaison (déclinaison Est positive, Ouest négative)', 'Rm = Rv + déviation', 'Rm = Rv × déclinaison', 'Rm = Rv + dérive', 'a', 'Avec une déclinaison de 3° Est, une route vraie de 090° donne une route magnétique de 087°.', 'navigation'),
    ('Avec une déclinaison de 2° Ouest, une route vraie de 180° correspond à une route magnétique de :', '178°', '180°', '160°', '182°', 'd', 'Rm = Rv - D, avec D = -2° (Ouest) : 180 - (-2) = 182°.', 'navigation'),
    ('Qu''est-ce que le facteur de base (Fb) ?', '60 divisé par la vitesse propre en kt (temps en minutes pour 1 NM)', 'La vitesse sol divisée par 60', 'La consommation horaire', 'La dérive maximale', 'a', 'Fb = 60/Vp. À 120 kt, Fb = 0,5 : on met 0,5 minute par nautique.', 'navigation'),
    ('À une vitesse propre de 100 kt, combien de temps sans vent pour 30 NM ?', '30 minutes', '10 minutes', '3 minutes', '18 minutes', 'd', 'Fb = 60/100 = 0,6 ; temps = 30 × 0,6 = 18 minutes.', 'navigation'),
    ('À 120 kt de vitesse sol, combien de temps pour parcourir 50 NM ?', '25 minutes', '50 minutes', '12 minutes', '42 minutes', 'a', 'Fb = 0,5 ; 50 × 0,5 = 25 minutes.', 'navigation'),
    ('Comment calcule-t-on la dérive maximale ?', 'Vitesse du vent / vitesse propre', 'Vitesse propre × facteur de base', 'Vitesse du vent × facteur de base', 'Vent effectif × 2', 'c', 'Xmax = Vw × Fb. Avec 20 kt de vent à 100 kt (Fb 0,6), la dérive maximale vaut 12°.', 'navigation'),
    ('Vent de 20 kt plein travers, vitesse propre 120 kt. Quelle dérive environ ?', '10°', '20°', '5°', '2°', 'a', 'Fb = 0,5 ; dérive = 20 × 0,5 = 10°.', 'navigation'),
    ('Qu''est-ce que l''angle au vent ?', 'L''angle entre la route et la direction d''où vient le vent', 'L''angle entre le cap et le nord', 'L''angle de montée', 'L''angle d''incidence', 'a', 'C''est à partir de lui qu''on calcule les composantes de vent effectif et de vent traversier.', 'navigation'),
    ('Comment calcule-t-on le vent traversier ?', 'Vent × cosinus de l''angle au vent', 'Vent / 2', 'Vent × tangente', 'Vent × sinus de l''angle au vent', 'd', 'Vent traversier = Vw × sin(a) ; vent effectif = Vw × cos(a).', 'navigation'),
    ('Comment calcule-t-on le vent effectif (de face ou arrière) ?', 'Vent × sinus de l''angle au vent', 'Vent × cosinus de l''angle au vent', 'Vent × 2', 'Vent - vitesse propre', 'b', 'Le vent effectif modifie la vitesse sol : Vs = Vp ± Ve.', 'navigation'),
    ('Avec la méthode des « heures » du guide ENAC, que vaut approximativement sin 30° ?', '1/4', '3/4', '1', '1/2', 'd', '15° ↔ ¼ d''heure (¼), 30° ↔ ½ heure (½), 45° ↔ ¾ d''heure (¾), 60° et plus ↔ 1 heure (1).', 'navigation'),
    ('Avec la méthode approchée du guide ENAC, que vaut approximativement sin 45° ?', '3/4', '1/2', '1/4', '1', 'a', 'Valeur réelle 0,71, arrondie à 3/4, précision suffisante en vol.', 'navigation'),
    ('Avec la méthode approchée du guide ENAC, quelle composante traversière pour un vent de 30 kt à 60° de la route ?', '15 kt', '7 kt', '22 kt', '30 kt (sin 60° ≈ 1)', 'd', 'À partir de 60°, on considère tout le vent comme traversier (sin 60° ≈ 0,87).', 'navigation'),
    ('Route 310°, vent du 100° pour 30 kt. Quelle composante de vent traversier selon l''exemple du guide ENAC ?', '30 kt', '0 kt', '25 kt', '15 kt', 'd', 'L''angle aigu entre route et vent est de 30° : Cw = ½ × 30 = 15 kt. Le vent est arrière : Tw ≈ 30 kt.', 'navigation'),
    ('Pour corriger la dérive, où doit se trouver le cap de l''avion ?', 'Du côté opposé au vent', 'Entre la route et la direction d''où vient le vent', 'Toujours égal à la route', 'Toujours au nord', 'b', 'Le nez est orienté vers le vent.', 'navigation'),
    ('Vitesse propre 100 kt, vent de face effectif 20 kt. Quelle vitesse sol ?', '120 kt', '100 kt', '20 kt', '80 kt', 'd', 'Vs = Vp - Ve = 100 - 20 = 80 kt.', 'navigation'),
    ('Au cap et au temps calculés, quel est le rayon du cercle d''incertitude selon le guide ENAC ?', 'La moitié de la distance', '1 NM quelle que soit la distance', 'Environ un dixième de la distance parcourue', '10 NM', 'c', 'Après 50 NM d''estime, l''avion se trouve dans un cercle d''environ 5 NM de rayon.', 'navigation'),
    ('Pourquoi faire des branches d''estime plus courtes quand la visibilité est mauvaise ?', 'Pour économiser le carburant', 'Pour la radio', 'L''imprécision augmente avec la distance parcourue', 'Parce que le compas devient faux', 'c', 'L''incertitude étant d''environ 10 % de la distance, des branches courtes gardent le point dans le champ de vision.', 'navigation'),
    ('Dans les deux dernières minutes avant un point tournant, que fait l''élève selon le guide ENAC ?', 'Il change de cap pour chercher le point', 'Un balayage méthodique du secteur avant en tenant le cap avec précision', 'Il regarde la carte en permanence', 'Il appelle la tour', 'b', 'La tenue de cap est primordiale à l''approche du repère.', 'navigation'),
    ('Quels sont les trois critères pour choisir l''altitude ou le niveau de croisière ?', 'La couleur de l''avion, la radio et le GPS', 'La réglementation, la sécurité et l''aspect opérationnel', 'Le prix du carburant et l''heure', 'Uniquement la météo', 'b', 'On tient compte des règles de survol, des conditions VMC, des zones et de la règle semi-circulaire.', 'navigation'),
    ('Par mauvais temps, quelle hauteur de survol le guide ENAC propose-t-il au minimum ?', '50 ft', '5000 ft', '100 ft au-dessus du sol', '500 ft au-dessus de l''obstacle le plus élevé jusqu''à 5 NM de part et d''autre de la route', 'd', 'C''est une marge de sécurité envisageable en cas de mauvais temps.', 'navigation'),
    ('Qu''est-ce que le cheminement ?', 'Suivre des lignes naturelles ou artificielles jalonnées de repères', 'Voler au GPS', 'Voler aux instruments', 'Suivre un radial VOR uniquement', 'a', 'Fleuves, routes, voies ferrées, côtes : on les suit en les identifiant.', 'navigation'),
    ('Quand pratique-t-on le cheminement ?', 'Uniquement de nuit', 'Uniquement au-dessus des nuages', 'Quand la route longe un repère, par mauvais temps, en déroutement ou en égarement', 'Jamais en VFR', 'c', 'C''est la base de la navigation « quand rien ne va plus ».', 'navigation'),
    ('En cheminement, de quel côté le guide ENAC conseille-t-il de placer le repère suivi ?', 'Sur sa droite', 'Sur sa gauche, de façon à le garder en vue', 'Juste sous l''avion', 'Peu importe', 'b', 'Le pilote, assis à gauche, voit mieux le repère ; on survole de préférence les lignes en se plaçant à leur droite, car de nombreux avions suivent les mêmes itinéraires.', 'navigation'),
    ('Sur une carte au 1/500 000, la largeur d''un doigt correspond en moyenne à environ :', '50 NM', '5 NM', '1 NM', '0,5 NM', 'b', 'Le guide ENAC propose d''étalonner ses doigts pour mesurer rapidement les distances en vol.', 'navigation'),
    ('Combien de nautiques représente 1° de latitude (mesuré sur un méridien) ?', '100 NM', '10 NM', '60 NM', '1 NM', 'c', '1 minute de latitude = 1 NM ; on peut reporter une distance sur un méridien.', 'navigation'),
    ('Quelle est la règle d''or de l''identification d''un repère ?', 'Chrono, carte, sol : l''heure, puis ce que la carte annonce, puis la vérification au sol', 'Sol, carte, chrono', 'Chercher sur la carte tout ce que l''on voit au sol', 'GPS d''abord', 'a', 'Tout ce qui est sur la carte existe au sol, mais tout ce qui est au sol n''est pas sur la carte. On procède aussi du gros repère vers le petit.', 'navigation'),
    ('Pour identifier un petit repère, que recommande-t-on ?', 'Chercher directement le détail', 'Descendre à basse hauteur', 'Se fier au GPS', 'Repérer d''abord un gros repère voisin (ville, autoroute, fleuve), puis chercher le détail', 'd', 'On procède « du gros repère vers le petit repère ».', 'navigation'),
    ('Qu''est-ce qu''une erreur systématique en navigation ?', 'Une erreur de calcul', 'Une faute de compas', 'Une dérive non corrigée', 'Se décaler volontairement d''un côté de la route pour être sûr du côté où tourner en arrivant sur un grand repère linéaire', 'd', 'On vise volontairement un côté du but pour savoir ensuite dans quel sens suivre le repère linéaire.', 'navigation'),
    ('Quelles sont les actions du point tournant selon le guide ENAC ?', 'Train, volets, mélange', 'Top, cap, altitude, estimée, puis radio, radionav, moteur, essence, directionnel', 'Radio uniquement', 'Rien, on continue', 'b', 'Le point tournant se fait méthodiquement : trajectoire d''abord, puis communications, puis avion.', 'navigation'),
    ('Pour corriger un écart de route, quelle méthode le guide ENAC propose-t-il ?', 'Changer de cap de 90°', 'Altérer le cap du double de l''écart constaté pendant un temps égal au temps écoulé, puis reprendre le cap corrigé', 'Ne rien faire', 'Faire un 360°', 'b', 'On peut aussi corriger à vue en visant un repère.', 'navigation'),
    ('Temps estimé sans vent : 12 min. Temps réel : 14 min. Pour le tronçon suivant de 6 min sans vent, quelle estimée ?', '6 minutes', '5 minutes', '7 minutes', '8 minutes', 'c', 'On a perdu 2 min sur 12 (1/6) ; sur 6 minutes on perd 1 minute, soit 7 minutes.', 'navigation'),
    ('Si l''origine de la navigation est le décollage, combien de temps ajoute-t-on au premier tronçon selon le guide ENAC ?', 'Dix minutes', 'Une minute', 'Rien', 'Trois minutes', 'b', 'Le guide propose +1 min au départ du décollage, +2 min d''un repère local, +3 min d''une vent arrière.', 'navigation'),
    ('Quel est l''avantage de prendre une origine de navigation sur un repère précis plutôt qu''au décollage ?', 'On gagne du carburant', 'Le top est précis, l''avion est en croisière au bon cap', 'La radio est plus claire', 'Il n''y en a pas', 'b', 'Partir directement après l''envol rend le temps de la première branche imprécis et peut croiser le trafic du circuit.', 'navigation'),
    ('Pour descendre de 7000 ft à -500 ft/min, combien de temps de descente faut-il ?', '7 minutes', '35 minutes', '5 minutes', '14 minutes', 'd', '7000 / 500 = 14 minutes. Le guide ENAC ajoute 3 minutes pour un palier de stabilisation : top descente 17 minutes avant l''arrivée.', 'navigation'),
    ('Selon le guide ENAC, une descente de croisière sur avion léger se fait sur un plan d''environ :', '2°, soit environ 200 ft par NM', '10°, soit 1000 ft par NM', '0,5°', '5°', 'a', 'Pour perdre 7000 ft : 7000/200 = 35 NM, plus 5 NM d''anticipation, soit top descente à 40 NM.', 'navigation'),
    ('Pour perdre 3000 ft sur un plan de 200 ft par NM, à quelle distance commence-t-on la descente (hors palier de stabilisation) ?', '30 NM', '15 NM', '3 NM', '60 NM', 'b', '3000 / 200 = 15 NM.', 'navigation'),
    ('Quelles sont les trois tactiques d''arrivée sur un aérodrome contrôlé selon le guide ENAC ?', 'Par la verticale uniquement', 'En spirale', 'Arrivée directe, semi-directe ou en vent arrière', 'Moteur réduit', 'c', 'Le choix dépend de la météo, du trafic, des restrictions et des instructions du contrôle.', 'navigation'),
    ('Sur un aérodrome non contrôlé, où doit se faire l''observation verticale terrain ?', 'À 100 ft', 'Si possible au-dessus du plus haut des circuits publiés', 'Dans le circuit', 'Au-dessus de 5000 ft', 'b', 'La reconnaissance ne se limite pas à la manche à air : circuit, état de la piste, activité au sol et en vol.', 'navigation'),
    ('Sur un aérodrome sans fréquence assignée, par quoi commence le message radio ?', 'L''indicatif seul', '« Mayday »', 'La météo', 'Le nom de l''aérodrome, suivi de l''indicatif et de la position', 'd', 'Exemple : « Lapalisse, F-ABCD, vent arrière piste 27 ».', 'navigation'),
    ('Sur un aérodrome non contrôlé, quand émet-on des messages à l''arrivée ?', 'Avant l''intégration, en vent arrière, en base, en finale, piste dégagée et au parking', 'Uniquement en finale', 'Uniquement au parking', 'Jamais', 'a', 'L''auto-information permet à chacun de se situer dans le circuit.', 'navigation'),
    ('Sur un aérodrome non contrôlé, quand émet-on des messages au départ ?', 'Uniquement au décollage', 'Jamais', 'Avant de rouler, au point d''arrêt, une fois aligné et en quittant le circuit', 'Uniquement en croisière', 'c', 'Ces messages informent les autres usagers de vos intentions.', 'navigation'),
    ('Quelle carte est plutôt utilisée pour préparer un itinéraire direct en niveau de vol avec les moyens radio selon le guide ENAC ?', 'Le plan de ville', 'La carte au 1/1 000 000', 'La carte au 1/25 000', 'Une carte routière', 'b', 'Le 1/500 000 sert plutôt à l''itinéraire de mauvais temps, en cheminement.', 'navigation'),
    ('Qu''appelle-t-on un déroutement ?', 'Un retour au parking', 'Une remise de gaz', 'Un virage de 360°', 'Un changement de destination en vol suite à une difficulté météo ou mécanique', 'd', 'Il faut savoir faire le point, estimer la nouvelle route et le cap, l''heure d''arrivée et le carburant.', 'navigation'),
    ('Qu''indique un VOR ?', 'La distance à la station', 'Le radial (relèvement magnétique depuis la station) sur lequel se trouve l''avion', 'L''altitude', 'La vitesse sol', 'b', 'Les informations du VOR sont indépendantes du cap de l''avion.', 'navigation'),
    ('L''indication VOR (radial, TO/FROM) dépend-elle du cap de l''avion ?', 'Oui, totalement', 'Oui, uniquement en virage', 'Oui, de nuit', 'Non, elle ne dépend que de la position de l''avion', 'd', 'Un virage de 180° ne change pas l''indication : c''est une différence fondamentale avec l''ADF.', 'navigation'),
    ('L''indication de l''aiguille d''un ADF dépend-elle du cap de l''avion ?', 'Oui, elle indique un gisement (angle relatif à l''axe de l''avion)', 'Non, jamais', 'Seulement de nuit', 'Seulement au sol', 'a', 'Relèvement magnétique de la station = cap magnétique + gisement.', 'navigation'),
    ('Cap magnétique 060°, l''aiguille de l''ADF indique un gisement de 030°. Quel est le QDM de la balise ?', '030°', '060°', '090°', '270°', 'c', 'QDM = Cm + gisement = 060 + 030 = 090°.', 'navigation'),
    ('Comment se situe-t-on plus précisément avec des moyens radio ?', 'Avec deux VOR (recoupement) ou un VOR-DME', 'Avec un seul VOR sans DME', 'Avec le compas', 'Avec le transpondeur', 'a', 'Le recoupement de deux radiales ou un radial plus une distance DME donne une position.', 'navigation'),
    ('Pourquoi l''information VOR n''est-elle reçue qu''après le décollage en général ?', 'La station s''allume au décollage', 'Le récepteur doit chauffer', 'Ce n''est pas le cas', 'La VHF se propage en portée optique', 'd', 'L''avion au sol est souvent masqué par le relief ou la courbure de la Terre.', 'navigation'),
    ('Au passage à la verticale d''un VOR, que constate-t-on ?', 'Des battements d''aiguille et le passage de TO à FROM', 'L''aiguille reste fixe', 'Le DME affiche une distance infinie', 'Rien', 'a', 'Le passage verticale se trouve dans un cône de silence où l''indication est instable.', 'navigation'),
    ('Selon le guide ENAC, sous quel angle rejoindre un radial à plus de 3 minutes de la station ?', '90°', '5°', '180°', 'Environ 30° de convergence', 'd', 'On diminue ensuite l''amplitude des corrections à l''approche de la station.', 'navigation'),
    ('Qu''appelle-t-on la « courbe du chien » en radiocompas ?', 'Un virage de 360°', 'Une approche IFR', 'Une technique de décollage', 'Garder l''aiguille de l''ADF dans l''axe (gisement nul) : la trajectoire s''incurve sous l''effet du vent', 'd', 'L''avion finit à la verticale de la balise, mais sur une trajectoire courbe ; l''autre méthode est de tenir un gisement égal à la dérive.', 'navigation'),
    ('Quelle précaution particulière près d''une balise radio ?', 'Couper la radio', 'Renforcer l''anti-abordage : les balises concentrent les trafics VFR et IFR', 'Descendre très bas', 'Voler en spirale', 'b', 'Le guide ENAC rappelle d''informer le contrôle de sa position même si le contact n''est pas toujours obligatoire en transit.', 'navigation'),
    ('En VFR, quel est le statut des aides radioélectriques ?', 'Le moyen principal obligatoire', 'Des moyens interdits', 'Des moyens secondaires de confirmation de la navigation', 'Des moyens réservés à l''IFR', 'c', 'La navigation VFR repose sur l''estime et la lecture de carte.', 'navigation'),
    ('En cas d''égarement, quelle méthode courante permet de reprendre la navigation ?', 'Continuer tout droit', 'Monter au-dessus des nuages', 'L''erreur systématique vers un gros repère, qui devient une nouvelle origine', 'Couper le moteur', 'c', 'On peut aussi utiliser les services de la circulation aérienne (gonio, radar).', 'navigation'),
    ('En cas d''égarement, quels services de la circulation aérienne peuvent aider ?', 'La météo', 'Le BRIA par téléphone uniquement', 'Aucun', 'Le radiogoniomètre (gonio) et le radar', 'd', 'Un contrôleur peut vous donner un relèvement (QDM) ou votre position radar.', 'navigation'),
    ('En cas d''égarement en fin d''autonomie ou par météo très dégradée, que faut-il envisager ?', 'Continuer à chercher indéfiniment', 'Monter au-dessus de la couche', 'Faire des cercles jusqu''à la panne sèche', 'Interrompre le vol (atterrissage de précaution)', 'd', 'Le guide ENAC demande de faire percevoir cette nécessité à l''élève.', 'navigation'),
    ('Quelles erreurs de programmation sont citées pour l''usage du GPS ?', 'Aucune, le GPS ne se trompe jamais', 'Uniquement des pannes de batterie', 'Uniquement des erreurs de cartographie papier', 'Data base pas à jour, mauvaises données ou mauvaise programmation, révélées à un moment inattendu', 'd', 'Ces erreurs latentes sont difficiles à détecter et sont à l''origine d''accidents.', 'navigation'),
    ('Avant d''utiliser le GPS d''un avion du club, que faut-il faire ?', 'Rien', 'Effacer les waypoints des autres utilisateurs et vérifier la route programmée avec la navigation préparée', 'Le réinitialiser en vol', 'Programmer en vol uniquement', 'b', 'On contrôle la cohérence de chaque branche avec le log préparé.', 'navigation'),
    ('Le guide ENAC recommande-t-il de programmer le GPS en vol ?', 'Oui, c''est préférable', 'Oui, en virage', 'Non, c''est fortement déconseillé, on n''utilise alors que des points de la data base', 'Uniquement en solo', 'c', 'La programmation en vol consomme du temps et de l''attention, souvent au détriment de la trajectoire.', 'navigation'),
    ('La fonction « nearest » du GPS indique l''aérodrome le plus proche. Est-il forcément utilisable ?', 'Oui, toujours', 'Oui, s''il a une piste en dur', 'Oui, la nuit', 'Non, il faut vérifier météo, limitations et NOTAM', 'd', 'L''aérodrome le plus proche n''est pas forcément accessible.', 'navigation'),
    ('Le GPS peut-il éviter seul les zones et le relief ?', 'Oui, toujours', 'Non, il ne vous fera éviter ni les montagnes ni les zones', 'Oui, avec la fonction GOTO', 'Oui, en mode MAP', 'b', 'En fonction GOTO, il faut avoir une idée de la nouvelle route pour ne pas « emplafonner » une zone.', 'navigation'),
    ('Quel est le piège psychologique classique avec le GPS ?', 'Il rend le vol trop facile', 'La confiance aveugle et le biais de confirmation, même quand l''information est fausse', 'Il fatigue les yeux', 'Aucun', 'b', 'D''où l''importance de garder la maîtrise de la navigation de base.', 'navigation'),
    ('Qu''est-ce que l''orthodromie ?', 'Une route à cap constant', 'Le plus court chemin entre deux points sur la sphère terrestre (arc de grand cercle)', 'Une route magnétique', 'Un parallèle', 'b', 'La loxodromie, elle, coupe tous les méridiens sous le même angle.', 'navigation'),
    ('Qu''est-ce qu''une loxodromie ?', 'Le plus court chemin', 'Un grand cercle', 'Un méridien', 'Une route qui coupe les méridiens sous un angle constant', 'd', 'Sur de courtes distances en VFR, la différence avec l''orthodromie est négligeable.', 'navigation'),
    ('Combien de mètres dans un mille nautique ?', '1609 m', '1852 m', '1000 m', '1500 m', 'b', 'Le mille terrestre (statute mile) vaut 1609 m.', 'navigation'),
    ('Que représente 1 kt (nœud) ?', '1 km par heure', '1 mètre par seconde', '1 mille nautique par heure', '1 mille terrestre par heure', 'c', '1 kt ≈ 1,852 km/h ≈ 0,51 m/s.', 'navigation'),
    ('Combien de mètres dans 1 pied (ft) ?', '0,5 m', '0,3048 m', '1,2 m', '0,03 m', 'b', '1000 ft ≈ 305 m.', 'navigation'),
    ('Sur une carte au 1/500 000, 1 cm représente :', '500 m', '50 km', '5 km', '1 km', 'c', '1 cm × 500 000 = 500 000 cm = 5 km.', 'navigation'),
    ('Quelle projection est utilisée pour la carte OACI au 1/500 000 ?', 'Mercator', 'Lambert conique conforme', 'Projection plate', 'Gnomonique', 'b', 'Sur la projection Lambert, une ligne droite est très proche d''une orthodromie et les angles sont conservés.', 'navigation'),
    ('Sur une carte, les angles de route se mesurent par rapport :', 'Au bord de la carte', 'Au nord magnétique', 'À l''équateur', 'Au méridien (nord vrai) le plus proche du milieu de la route', 'd', 'On convertit ensuite en route magnétique avec la déclinaison.', 'navigation'),
    ('Sur la carte OACI au 1/500 000 éditée par l''IGN, quelle tranche d''espace est représentée ?', 'Uniquement les espaces au-dessus du FL195', 'Seulement les CTR', 'Les espaces jusqu''au FL115 ou 3000 ft ASFC, la plus élevée des deux valeurs', 'Tout l''espace jusqu''au FL600', 'c', 'Au-dessus, il faut consulter d''autres cartes (1/1 000 000, AIP).', 'navigation'),
    ('Quelle règle détermine les niveaux de croisière VFR au-dessus de 3000 ft ASFC ?', 'La règle semi-circulaire, selon la route magnétique', 'La règle du quart de cercle selon le vent', 'Aucune règle', 'Le niveau le plus bas toujours', 'a', 'Route magnétique 000° à 179° : niveaux impairs + 500 ft (FL35, 55…) ; 180° à 359° : pairs + 500 ft (FL45, 65…).', 'navigation'),
    ('Route magnétique 090°, en croisière VFR au-dessus de 3000 ft ASFC : quel niveau est adapté ?', 'FL60', 'FL50', 'FL45', 'FL55', 'd', 'Route 000-179° : impairs + 500, donc FL35, FL55, FL75…', 'navigation'),
    ('Route magnétique 250°, en croisière VFR au-dessus de 3000 ft ASFC : quel niveau est adapté ?', 'FL55', 'FL60', 'FL65', 'FL75', 'c', 'Route 180-359° : pairs + 500, donc FL45, FL65, FL85…', 'navigation'),
    ('Une erreur de cap de 5° maintenue sur 60 NM donne un écart latéral d''environ :', '1 NM', '10 NM', '0,5 NM', '5 NM', 'd', 'Règle du 1 sur 60 : 1° d''erreur donne 1 NM d''écart pour 60 NM parcourus.', 'navigation'),
    ('Après 30 NM, on constate un écart de 3 NM à droite de la route. Quelle erreur de route ?', '3°', 'Environ 6°', '1°', '12°', 'b', 'Écart angulaire = 3 × 60 / 30 = 6°.', 'navigation'),
    ('Que contient un journal de navigation (log) préparé ?', 'Seulement la météo', 'Routes magnétiques, distances, temps estimés, repères, altitudes de sécurité, fréquences', 'Les horaires de l''aéroclub', 'Le carnet de route', 'b', 'Il doit être clair, aéré et sans surcharge.', 'navigation'),
    ('Que veut dire « heure estimée d''arrivée » (HEA, ETA) ?', 'L''heure prévue d''arrivée sur un point, calculée à partir de l''heure de passage et du temps de branche', 'L''heure du décollage', 'L''heure du coucher du soleil', 'L''heure de dépôt du plan de vol', 'a', 'Elle s''actualise à chaque point tournant.', 'navigation'),
    ('La déclinaison magnétique en France métropolitaine aujourd''hui est :', 'Faible, de l''ordre de quelques degrés, orientée Est', 'Forte, de l''ordre de 20° Ouest', 'Nulle partout et définitivement', 'Supérieure à 45°', 'a', 'Elle varie lentement dans le temps et selon le lieu (par exemple 3° Est à Aix en 2025, d''après la VAC).', 'navigation'),
    ('Qu''est-ce que la déviation du compas, et où la trouve-t-on ?', 'L''écart entre nord vrai et nord magnétique, sur la carte', 'L''erreur du GPS', 'L''erreur propre au compas de l''avion, indiquée sur la carte de compensation à bord', 'La dérive due au vent', 'c', 'Cap compas + déviation = cap magnétique.', 'navigation'),
    ('Quelle est la différence entre route et cap ?', 'Il n''y en a pas', 'Le cap est mesuré au sol', 'La route ne dépend pas du vent', 'La route est la trajectoire suivie par rapport au sol, le cap est la direction de l''axe de l''avion', 'd', 'Par vent de travers, cap et route diffèrent de la dérive.', 'navigation'),
    ('Que signifie le sigle DME ?', 'Distance Measuring Equipment (équipement de mesure de distance)', 'Direction Magnetic Equipment', 'Data Monitoring Element', 'Descent Management Equipment', 'a', 'Le DME donne une distance oblique entre l''avion et la station.', 'navigation'),
    ('La distance affichée par un DME est :', 'La distance horizontale exacte au sol', 'La distance oblique (en ligne droite) entre l''avion et la station', 'La distance au prochain waypoint GPS', 'La distance à l''aérodrome de destination', 'b', 'À la verticale d''une station, le DME indique la hauteur de l''avion en NM.', 'navigation'),
    ('Qu''est-ce que le QDR ?', 'Le cap à suivre vers la station', 'Le relèvement magnétique de l''avion vu depuis la station', 'La distance à la station', 'L''altitude de l''aérodrome', 'b', 'QDR = QDM ± 180°.', 'navigation'),
    ('Un contrôleur vous donne un QDM 270. Où êtes-vous par rapport à la station ?', 'À l''Est de la station', 'À l''Ouest de la station', 'Au Nord', 'Au Sud', 'a', 'Pour rejoindre la station vous devez suivre le 270 (vers l''Ouest), donc vous êtes à l''Est.', 'navigation'),
    ('Qu''appelle-t-on « nuit aéronautique » en France, en pratique ?', 'Toute la période où le soleil est couché', 'De 22 h à 6 h', 'De 18 h à 8 h', 'La période commençant 30 minutes après le coucher du soleil et se terminant 30 minutes avant son lever', 'd', 'Le vol pendant cette période nécessite la qualification de vol de nuit.', 'navigation'),
    ('Quel est l''intérêt d''un itinéraire « de mauvais temps » préparé à l''avance ?', 'Raccourcir la route', 'Éviter de payer des taxes', 'Pouvoir arriver par visibilité et plafond dégradés en cheminant à l''écart du relief', 'Voler plus haut', 'c', 'Le guide ENAC conseille de le préparer sur la carte au 1/500 000.', 'navigation'),
    ('Qu''est-ce que le cône de silence d''un VOR ?', 'Une zone interdite', 'Une fréquence non utilisée', 'Une zone au-dessus de la station où les indications sont instables', 'La portée maximale', 'c', 'À la verticale de la station, l''indicateur oscille et le drapeau TO/FROM bascule.', 'navigation'),
    ('Que signifie l''heure UTC ?', 'L''heure locale de Paris', 'L''heure du club', 'Le temps universel coordonné, référence horaire en aéronautique', 'L''heure d''été', 'c', 'En France, l''heure légale est UTC+1 en hiver et UTC+2 en été.', 'navigation'),
    ('Il est 15 h 00 à Paris en été. Quelle heure est-il en UTC ?', '15 h 00', '13 h 00', '14 h 00', '17 h 00', 'b', 'En été, Paris est à UTC+2 : 15 h - 2 h = 13 h UTC.', 'navigation'),
    ('Il est 10 h 00 UTC en hiver. Quelle heure est-il à Paris ?', '10 h 00', '11 h 00', '12 h 00', '9 h 00', 'b', 'En hiver, l''heure légale française est UTC+1.', 'navigation'),
    ('À quoi sert le rapporteur et la règle Cras ?', 'À calculer le centrage', 'À tracer les routes et mesurer les angles et distances sur la carte', 'À mesurer la pression', 'À régler l''altimètre', 'b', 'La règle Cras, inventée par l''amiral Jean Cras, est précise mais encombrante en vol ; on utilise plutôt un rapporteur carré à bord.', 'navigation'),
    ('Une règle graduée pour le 1/500 000 est-elle valable sur une carte au 1/1 000 000 ?', 'Oui, toujours', 'Oui, en divisant par 10', 'Non, les mesures de distance ne valent que pour l''échelle prévue', 'Oui, si on la retourne', 'c', 'Il faut utiliser la graduation correspondant à l''échelle de la carte.', 'navigation'),
    ('Qu''est-ce qu''un radial 090 d''un VOR ?', 'La ligne vers la station en venant de l''Est', 'La ligne partant de la station vers l''Est magnétique', 'La ligne partant de la station vers l''Ouest', 'Une fréquence', 'b', 'Le radial est le relèvement magnétique de l''avion vu depuis la station (QDR).', 'navigation'),
    ('Au retour vers une station VOR en suivant le radial 180, quel cap approximatif sans vent ?', '360°', '180°', '090°', '270°', 'a', 'Sur le radial 180 vous êtes au Sud ; pour revenir vers la station, vous volez vers le Nord (QDM 360).', 'navigation'),
    ('Dans l''atmosphère standard (ISA), quelle est la température au niveau de la mer ?', '0°C', '15°C', '20°C', '10°C', 'b', 'ISA : 15°C et 1013,25 hPa au niveau moyen de la mer, décroissance d''environ 2°C par 1000 ft jusqu''à la tropopause.', 'meteo'),
    ('Dans l''atmosphère standard, quelle température à 5000 ft environ ?', '15°C', '-5°C', '5°C', '10°C', 'c', '15°C - 2°C × 5 = 5°C.', 'meteo'),
    ('Quelle est la température standard de la tropopause en ISA ?', '-15°C', '0°C', '-100°C', '-56,5°C', 'd', 'Elle est atteinte vers 11 km (36 000 ft) et reste constante au-dessus dans la basse stratosphère.', 'meteo'),
    ('Près du niveau de la mer, à combien de pieds correspond environ 1 hPa ?', 'Environ 100 ft', 'Environ 3 ft', 'Environ 28 ft (8,5 m)', 'Environ 280 ft', 'c', 'On utilise souvent 27 ou 28 ft par hPa dans les calculs de pilote.', 'meteo'),
    ('On vole d''une zone de haute pression vers une basse pression sans recaler l''altimètre. L''altitude réelle est :', 'Plus basse que l''altitude indiquée', 'Plus haute que l''altitude indiquée', 'Identique', 'Aléatoire', 'a', '« Des hautes vers les basses, gare aux bosses » : l''altimètre surestime l''altitude.', 'meteo'),
    ('Par temps très froid, avec l''altimètre calé au QNH, l''altitude réelle est :', 'Plus basse que l''altitude indiquée', 'Plus haute que l''altitude indiquée', 'Identique', 'Toujours nulle', 'a', 'L''air froid est plus dense : les surfaces de pression sont plus resserrées et l''altimètre indique trop. Marge supplémentaire au-dessus du relief.', 'meteo'),
    ('Qu''est-ce que le QFE ?', 'La pression au niveau de l''aérodrome : calé dessus, l''altimètre indique la hauteur au-dessus de la piste', 'La pression ramenée au niveau de la mer', 'La pression standard 1013,25 hPa', 'La température au sol', 'a', 'Calé au QFE, l''altimètre affiche 0 au sol sur l''aérodrome.', 'meteo'),
    ('Calé sur 1013,25 hPa, que lit-on sur l''altimètre ?', 'Un niveau de vol (altitude pression)', 'L''altitude réelle', 'La hauteur au-dessus du sol', 'L''altitude-densité', 'a', 'Le niveau de vol s''exprime en centaines de pieds : 5500 ft sur 1013 = FL55.', 'meteo'),
    ('Qu''est-ce que l''altitude de transition ?', 'L''altitude à partir de laquelle on vole en niveaux de vol, en montée', 'L''altitude de croisière maximale', 'L''altitude des nuages', 'La hauteur du circuit de piste', 'a', 'Au-dessous, on vole en altitude au QNH ; au-dessus, en niveaux de vol sur 1013. En France elle est souvent de 5000 ft, mais elle varie selon les régions (voir l''AIP et la VAC).', 'meteo'),
    ('Qu''est-ce que le niveau de transition ?', 'Le niveau le plus haut autorisé en VFR', 'Le premier niveau de vol utilisable au-dessus de l''altitude de transition', 'La base des nuages', 'Le niveau de la tropopause', 'b', 'En descente, on repasse au QNH en franchissant le niveau de transition.', 'meteo'),
    ('Dans l''hémisphère nord, comment le vent tourne-t-il autour d''une dépression ?', 'Dans le sens des aiguilles d''une montre', 'Il ne tourne pas', 'Dans le sens inverse des aiguilles d''une montre', 'Il souffle vers l''extérieur', 'c', 'Autour d''un anticyclone, il tourne dans le sens des aiguilles d''une montre.', 'meteo'),
    ('Loi de Buys-Ballot : dans l''hémisphère nord, dos au vent, où se trouve la dépression ?', 'À droite', 'Devant', 'Derrière', 'À gauche', 'd', 'Dos au vent, les basses pressions sont à gauche et les hautes pressions à droite.', 'meteo'),
    ('Sur une carte isobare, des isobares très resserrées indiquent :', 'Un vent faible', 'Une absence de nuages', 'Une température élevée', 'Un vent fort', 'd', 'Plus le gradient de pression est fort, plus le vent est fort.', 'meteo'),
    ('Comment le vent varie-t-il en général du sol vers 2000 ft dans l''hémisphère nord ?', 'Il faiblit et tourne à gauche', 'Il forcit et tourne à droite (vire)', 'Il ne change pas', 'Il s''inverse', 'b', 'Au sol, le frottement le ralentit et le fait tourner vers les basses pressions ; en altitude il forcit et vire.', 'meteo'),
    ('Qu''est-ce qu''un front froid ?', 'Une masse d''air froid qui avance et soulève l''air chaud', 'Une masse d''air chaud qui avance sur l''air froid', 'Une zone de calme', 'Une zone sans nuages', 'a', 'Il donne souvent des nuages à développement vertical (cumulus, cumulonimbus), des averses et un vent qui tourne.', 'meteo'),
    ('Qu''est-ce qu''un front chaud ?', 'Une masse d''air froid qui avance', 'Une masse d''air chaud qui avance et glisse au-dessus de l''air froid', 'Une zone orageuse isolée', 'Une inversion au sol', 'b', 'Il donne en général une couverture nuageuse étendue (cirrus, altostratus, nimbostratus) et des précipitations continues.', 'meteo'),
    ('Après le passage d''un front froid, on observe souvent :', 'Du brouillard persistant', 'Une hausse de température', 'Un ciel uniformément couvert', 'Une bonne visibilité et un ciel de traîne avec des averses', 'd', 'L''air froid instable donne des cumulus et des averses, mais une bonne visibilité entre elles.', 'meteo'),
    ('Qu''est-ce qu''une occlusion ?', 'Un anticyclone', 'Une zone de vent nul', 'Un orage isolé', 'La rencontre du front froid qui rattrape le front chaud', 'd', 'Le secteur chaud est rejeté en altitude ; le temps peut y être très perturbé.', 'meteo'),
    ('Comment se forme le brouillard de rayonnement ?', 'Par de l''air chaud et humide qui passe sur une surface froide', 'Par refroidissement du sol la nuit, ciel clair et vent faible, en air humide', 'Par une averse orageuse', 'Par un vent fort', 'b', 'Il se forme surtout en fin de nuit, souvent dans les vallées, et se dissipe en général dans la matinée.', 'meteo'),
    ('Comment se forme le brouillard d''advection ?', 'Par refroidissement nocturne sans vent', 'Par une montée d''air le long d''un relief', 'Par l''évaporation d''une rivière en été', 'Par de l''air chaud et humide qui se déplace sur une surface plus froide', 'd', 'Il peut persister même avec du vent et couvrir de grandes zones, par exemple sur les côtes.', 'meteo'),
    ('Qu''est-ce que le point de rosée ?', 'La température maximale de la journée', 'La température de l''eau', 'La température à laquelle l''air doit être refroidi pour être saturé', 'La température de congélation', 'c', 'Plus la température et le point de rosée sont proches, plus le risque de brouillard ou de nuages bas est grand.', 'meteo'),
    ('Dans un METAR, « 08/07 » signifie :', 'Vent 080° à 7 kt', 'Visibilité 8 km, plafond 700 ft', 'Température 8°C, point de rosée 7°C', 'QNH 1008', 'c', 'Un écart de 1°C entre température et point de rosée signale un fort risque de brouillard ou de nuages bas.', 'meteo'),
    ('Que signifie « BKN » dans un METAR ?', 'Peu nuageux : 1 à 2 octas', 'Épars : 3 à 4 octas', 'Fragmenté : 5 à 7 octas', 'Couvert : 8 octas', 'c', 'FEW 1-2 octas, SCT 3-4, BKN 5-7, OVC 8.', 'meteo'),
    ('Que signifie « SCT » dans un METAR ?', 'Épars : 3 à 4 octas', 'Fragmenté : 5 à 7 octas', 'Couvert', 'Ciel clair', 'a', 'La couverture nuageuse se mesure en huitièmes de ciel (octas).', 'meteo'),
    ('Que signifie « OVC008 » dans un METAR ?', 'Couverture de 8 octas à 8000 ft', 'Visibilité 800 m', 'Vent de 8 kt', 'Ciel couvert à 800 ft', 'd', 'La hauteur des nuages est donnée en centaines de pieds au-dessus de l''aérodrome.', 'meteo'),
    ('Qu''appelle-t-on plafond en météo aéronautique ?', 'La hauteur des nuages les plus hauts', 'L''altitude maximale de l''avion', 'La hauteur de la base de la plus basse couche couvrant plus de la moitié du ciel (BKN ou OVC), au-dessous de 20 000 ft', 'La base des cumulus isolés', 'c', 'Une couche FEW ou SCT ne constitue pas un plafond.', 'meteo'),
    ('Dans un METAR, que signifie « 9999 » pour la visibilité ?', '9999 m exactement', 'Visibilité nulle', 'Donnée manquante', '10 km ou plus', 'd', 'La visibilité est exprimée en mètres ; 9999 indique 10 km ou plus.', 'meteo'),
    ('Que signifie « BR » dans un METAR ?', 'Brouillard', 'Bruine', 'Brume (visibilité de 1000 m à 5000 m)', 'Brume sèche', 'c', 'BR : brume humide ; FG : brouillard (moins de 1000 m) ; HZ : brume sèche ; DZ : bruine.', 'meteo'),
    ('Que signifie « FG » dans un METAR ?', 'Brume', 'Fumée', 'Grêle', 'Brouillard, visibilité inférieure à 1000 m', 'd', 'FG vient du mot anglais fog.', 'meteo'),
    ('Que signifie « TSRA » dans un METAR ?', 'Orage avec pluie', 'Pluie verglaçante', 'Averse de neige', 'Tempête de sable', 'a', 'TS : orage (thunderstorm), RA : pluie. Un « + » devant indique une forte intensité.', 'meteo'),
    ('Que signifie « SHRA » dans un METAR ?', 'Pluie continue faible', 'Neige', 'Brume', 'Averses de pluie', 'd', 'SH indique des averses, souvent liées aux nuages convectifs.', 'meteo'),
    ('Que signifie « +SN » dans un METAR ?', 'Neige faible', 'Forte neige', 'Pluie forte', 'Grêle', 'b', 'Le signe + indique une forte intensité, le signe - une faible intensité.', 'meteo'),
    ('Que signifie « VCSH » dans un METAR ?', 'Averses sur l''aérodrome', 'Visibilité réduite par la fumée', 'Averses au voisinage de l''aérodrome', 'Vent calme', 'c', 'VC (vicinity) signifie au voisinage, en général entre 8 et 16 km de l''aérodrome.', 'meteo'),
    ('Dans un METAR, « 24015G25KT » signifie :', 'Vent du 150° pour 24 kt', 'Visibilité 2400 m', 'Vent du 240° pour 15 kt avec rafales à 25 kt', 'Vent du 240° à 25 kt en moyenne', 'c', 'G indique les rafales (gusts).', 'meteo'),
    ('Dans un METAR, « VRB03KT » signifie :', 'Vent du 030°', 'Vent de 30 kt', 'Visibilité réduite à 300 m', 'Vent de direction variable, 3 kt', 'd', 'Le vent faible de direction variable est noté VRB.', 'meteo'),
    ('Dans un METAR, « Q1018 » indique :', 'Un QFE de 1018 hPa', 'Une visibilité de 1018 m', 'Une heure d''observation', 'Un QNH de 1018 hPa', 'd', 'Le QNH arrondi à l''hectopascal inférieur est donné après la lettre Q.', 'meteo'),
    ('Que signifie « NOSIG » à la fin d''un METAR ?', 'Pas de changement significatif prévu dans les 2 heures', 'Pas de signal radio', 'Pas d''observation', 'Pas de nuages', 'a', 'NOSIG est une prévision de tendance pour les deux heures qui suivent l''observation.', 'meteo'),
    ('Que signifie « TEMPO » dans un TAF ?', 'Un changement définitif', 'Des variations temporaires de moins d''une heure à chaque fois, sur moins de la moitié de la période', 'Une prévision annulée', 'Une observation passée', 'b', 'BECMG indique au contraire un changement durable qui s''établit pendant la période indiquée.', 'meteo'),
    ('Que signifie « BECMG » dans un TAF ?', 'Une variation temporaire', 'Une probabilité de 30 %', 'Un changement progressif et durable des conditions pendant la période indiquée', 'La fin de la prévision', 'c', 'Exemple : BECMG 1214 : le changement s''opère entre 12 h et 14 h UTC.', 'meteo'),
    ('Que signifie « PROB30 » dans un TAF ?', 'Une probabilité de 30 % que le phénomène se produise', '30 minutes de validité', '30 % de couverture nuageuse', 'Un vent de 30 kt', 'a', 'On trouve PROB30 ou PROB40, éventuellement combiné avec TEMPO.', 'meteo'),
    ('Qu''est-ce qu''un TAF ?', 'Une observation horaire', 'Une prévision météo d''aérodrome', 'Une carte de vent en altitude', 'Un avis de phénomène dangereux en route', 'b', 'Le TAF couvre généralement 9 à 30 heures selon les aérodromes.', 'meteo'),
    ('En quelle heure sont exprimés les METAR et TAF ?', 'En heure locale', 'En heure d''été', 'En heure de l''aéroclub', 'En UTC', 'd', 'Exemple : 231030Z = le 23 du mois à 10 h 30 UTC.', 'meteo'),
    ('Qu''est-ce qu''un SPECI ?', 'Une prévision de 24 heures', 'Un bulletin pour les ULM', 'Une observation spéciale émise entre deux METAR lors d''un changement significatif', 'Une carte de front', 'c', 'Il signale une évolution importante (visibilité, plafond, phénomène dangereux).', 'meteo'),
    ('Qu''est-ce que la carte TEMSI ?', 'Une carte de prévision du temps significatif (nuages, fronts, phénomènes dangereux)', 'Une carte de relief', 'Une carte des espaces aériens', 'Une carte des vents au sol', 'a', 'La TEMSI France couvre les basses couches et sert à la préparation des vols VFR.', 'meteo'),
    ('Que fournit la carte WINTEM ?', 'Les orages en cours', 'Les NOTAM', 'Les fréquences radio', 'Les vents et températures prévus en altitude', 'd', 'Elle sert à calculer dérives et vitesses sol en navigation.', 'meteo'),
    ('Quel est le stade de formation d''un orage où les phénomènes sont les plus violents ?', 'Le stade de cumulus', 'Le stade de maturité', 'Le stade de dissipation', 'Avant la formation du nuage', 'b', 'Au stade mature coexistent courants ascendants et descendants violents, grêle, foudre et rafales.', 'meteo'),
    ('Quelle distance minimale est recommandée pour contourner un orage ?', 'Au moins 10 NM (environ 20 km)', '500 m', '1 NM', 'Il suffit de passer dessous', 'a', 'Turbulence, grêle et rafales peuvent s''étendre loin autour du cumulonimbus ; on ne passe jamais dessous.', 'meteo'),
    ('Qu''est-ce que le cisaillement de vent ?', 'Un vent régulier', 'Un vent de face constant', 'Un vent nul', 'Une variation brutale de la direction ou de la force du vent sur une courte distance', 'd', 'Il est particulièrement dangereux près du sol, en approche et au décollage, par exemple sous un orage.', 'meteo'),
    ('Qu''est-ce qu''une rafale descendante (microburst) ?', 'Un vent de mer', 'Un tourbillon de sable', 'Un violent courant descendant sous un orage qui s''étale au sol', 'Une brise de pente', 'c', 'En approche, on rencontre d''abord un vent de face (gain de vitesse) puis un vent arrière et un courant descendant : grand danger.', 'meteo'),
    ('Quel type de précipitation est le plus dangereux en termes de givrage ?', 'La pluie verglaçante (surfondue)', 'La neige sèche', 'La grêle fine', 'La bruine chaude', 'a', 'L''eau surfondue gèle instantanément au contact de l''avion et forme un verglas lourd et transparent.', 'meteo'),
    ('Entre quelles températures le risque de givrage en nuage est-il le plus élevé ?', 'Au-dessus de +10°C', 'En dessous de -40°C uniquement', 'Entre 0°C et environ -15°C', 'Il n''y a pas de givrage en nuage', 'c', 'Dans cette plage, les nuages contiennent beaucoup de gouttelettes surfondues.', 'meteo'),
    ('Un avion léger non équipé peut-il voler dans des conditions givrantes connues ?', 'Oui, sans limite', 'Oui, s''il vole vite', 'Oui, la nuit', 'Non', 'd', 'Le givrage alourdit l''avion, dégrade la portance et peut bloquer les commandes et la prise Pitot.', 'meteo'),
    ('Quel nuage est associé à l''orage ?', 'Le cirrus', 'L''altocumulus', 'Le stratus', 'Le cumulonimbus', 'd', 'Le cumulonimbus (CB) peut s''élever jusqu''à la tropopause avec son sommet en enclume.', 'meteo'),
    ('Quel nuage donne souvent une couche grise basse et uniforme, parfois de la bruine ?', 'Le cirrus', 'Le cumulonimbus', 'L''altocumulus lenticulaire', 'Le stratus', 'd', 'Les stratus bas peuvent fermer les aérodromes au VFR.', 'meteo'),
    ('Les cirrus sont des nuages :', 'De l''étage supérieur, formés de cristaux de glace', 'De l''étage inférieur', 'À développement vertical', 'De brouillard', 'a', 'Ils annoncent souvent l''arrivée d''un front chaud.', 'meteo'),
    ('Que signale la présence d''altocumulus lenticulaires sous le vent d''un relief ?', 'Des ondes de relief, avec un risque de forte turbulence (rotors) à basse altitude', 'Une atmosphère calme', 'Un front chaud imminent', 'Du brouillard', 'a', 'Les rotors sous les lenticulaires sont très turbulents.', 'meteo'),
    ('Qu''est-ce que la brise de mer ?', 'Un vent de jour qui souffle de la mer vers la terre', 'Un vent de nuit de la terre vers la mer', 'Un vent d''altitude', 'Un vent de tempête', 'a', 'Le sol se réchauffe plus vite que la mer ; la nuit, le phénomène s''inverse (brise de terre).', 'meteo'),
    ('Qu''est-ce qu''un vent catabatique ?', 'Un vent montant les pentes le jour', 'Un vent de mer', 'Un vent d''orage', 'Un vent descendant les pentes la nuit, par refroidissement de l''air', 'd', 'Le vent montant les pentes le jour est un vent anabatique.', 'meteo'),
    ('Qu''est-ce que le mistral ?', 'Un vent de sud chaud et humide', 'Un vent de secteur nord à nord-ouest qui descend la vallée du Rhône vers la Méditerranée', 'Une brise de mer', 'Un vent d''est venant d''Italie', 'b', 'Il est souvent fort, rafaleux et turbulent en basses couches, notamment en Provence.', 'meteo'),
    ('Qu''est-ce que l''effet de foehn ?', 'Un brouillard de vallée', 'Un vent chaud et sec qui descend le versant sous le vent d''un relief', 'Un vent froid de mer', 'Une averse orageuse', 'b', 'L''air se refroidit en montant (nuages et pluies au vent) puis se réchauffe davantage en descendant.', 'meteo'),
    ('Une masse d''air instable favorise :', 'Le brouillard et les stratus', 'Un ciel totalement clair et calme', 'Les inversions au sol', 'Les nuages cumuliformes, les averses et la turbulence', 'd', 'L''air soulevé continue de monter : convection, cumulus, voire orages.', 'meteo'),
    ('Une masse d''air stable favorise :', 'Les nuages stratiformes, la brume et une mauvaise visibilité', 'Les orages', 'Les cumulus bourgeonnants', 'La turbulence convective', 'a', 'L''air stable résiste aux mouvements verticaux ; les polluants et l''humidité restent piégés en basses couches.', 'meteo'),
    ('Pourquoi l''humidité dégrade-t-elle les performances de l''avion ?', 'L''eau alourdit l''avion', 'L''air humide est moins dense que l''air sec à même température et pression', 'L''humidité refroidit le moteur', 'Elle ne les dégrade pas', 'b', 'La vapeur d''eau est plus légère que l''air sec : l''air humide est moins dense.', 'meteo'),
    ('Quel effet a une augmentation de température sur l''altitude-densité ?', 'Elle la diminue', 'Aucun', 'Elle la rend nulle', 'Elle l''augmente', 'd', 'Air chaud = air moins dense = performances dégradées (décollage plus long, montée plus faible).', 'meteo'),
    ('Que sont les nuages de type « cumulus de beau temps » ?', 'Des nuages d''orage', 'Des cumulus peu développés liés à la convection diurne', 'Des nuages de front chaud', 'Des brouillards', 'b', 'Ils indiquent des ascendances et une turbulence modérée sous leur base.', 'meteo'),
    ('Qu''est-ce qu''une inversion de température au sol ?', 'Une baisse brutale de pression', 'Un vent fort au sol', 'Une couche où la température augmente avec l''altitude près du sol', 'Une zone orageuse', 'c', 'Elle se forme souvent la nuit par ciel clair et piège brume et pollution.', 'meteo'),
    ('Quel service fournit la météo aéronautique officielle en France ?', 'Le SIA', 'La DGAC directement', 'Météo-France (portail Aeroweb)', 'L''aéroclub', 'c', 'Aeroweb donne METAR, TAF, TEMSI, WINTEM et autres produits pour la préparation des vols.', 'meteo'),
    ('Qu''est-ce qu''un GAMET ?', 'Une observation d''aérodrome', 'Une prévision de zone pour les vols à basse altitude', 'Un message radio de détresse', 'Une carte de relief', 'b', 'Il décrit les phénomènes significatifs pour les vols en basses couches dans une région.', 'meteo'),
    ('Qu''est-ce qu''un AIRMET ?', 'Une observation d''aérodrome', 'Un plan de vol', 'Un NOTAM d''aérodrome', 'Un avis de phénomènes météo pouvant affecter les vols à basse altitude, non déjà couverts par le GAMET', 'd', 'Les SIGMET concernent des phénomènes plus dangereux (orages violents, givrage ou turbulence forts).', 'meteo'),
    ('Le vent de 270° annoncé dans un METAR est donné par rapport :', 'Au nord magnétique', 'À l''axe de piste', 'Au nord vrai', 'Au nord compas', 'c', 'Dans les METAR et TAF, le vent est donné en degrés vrais. La tour et l''ATIS donnent le vent en degrés magnétiques.', 'meteo'),
    ('Quelle direction de vent est donnée par la tour de contrôle ?', 'Le vent vrai', 'Le vent magnétique', 'Le vent en altitude', 'Le vent maximal du jour', 'b', 'On peut ainsi le comparer directement au QFU de la piste.', 'meteo'),
    ('Quel phénomène peut-on rencontrer en descendant sous le vent d''un relief par vent fort ?', 'Un air parfaitement calme', 'Une augmentation de visibilité garantie', 'Des rabattants et de la turbulence', 'Un vent nul', 'c', 'Sous le vent, l''air descend : l''avion peut perdre de l''altitude malgré la puissance.', 'meteo'),
    ('À quoi sert la brume sèche (HZ) dans un METAR ?', 'Elle signale une réduction de visibilité par des particules sèches (poussières, fumées)', 'Elle indique du brouillard humide', 'Elle indique de la grêle', 'Elle indique un vent fort', 'a', 'La brume sèche peut fortement dégrader la visibilité oblique, en particulier contre le soleil.', 'meteo'),
    ('Qu''est-ce qu''une dépression thermique ?', 'Un anticyclone d''hiver', 'Une basse pression due au fort réchauffement du sol', 'Un front froid', 'Une zone de brouillard', 'b', 'Elle se forme par exemple sur la péninsule Ibérique en été.', 'meteo'),
    ('Un anticyclone est en général associé à :', 'Un temps calme et stable, parfois des brumes ou brouillards', 'Des tempêtes', 'Des orages permanents', 'Des vents très forts', 'a', 'En hiver, il peut donner des stratus bas persistants ; en été, du beau temps.', 'meteo'),
    ('Qu''est-ce qu''un thalweg ?', 'Une zone allongée de basses pressions', 'Une zone de hautes pressions', 'Une vallée sans vent', 'Un type de nuage', 'a', 'Il est souvent associé à du mauvais temps ou à des orages.', 'meteo'),
    ('Qu''est-ce qu''une dorsale ?', 'Une zone de basses pressions', 'Une zone allongée de hautes pressions', 'Une chaîne de montagnes', 'Un front', 'b', 'Elle apporte en général une amélioration temporaire du temps.', 'meteo'),
    ('La grêle est associée à quel type de nuage ?', 'Le stratus', 'Le cirrostratus', 'L''altostratus', 'Le cumulonimbus', 'd', 'Elle peut tomber jusqu''à plusieurs kilomètres en avant de l''orage.', 'meteo'),
    ('Pourquoi faut-il se méfier d''un ciel dégagé la nuit avec un faible écart entre température et point de rosée ?', 'Risque d''orage', 'Risque de brouillard de rayonnement au lever du jour', 'Risque de vent fort', 'Aucun risque', 'b', 'Le sol rayonne, l''air se refroidit jusqu''à saturation.', 'meteo'),
    ('Quelle est la turbulence de « ciel clair » ?', 'Une turbulence en air limpide, sans nuage pour la signaler', 'Une turbulence dans les nuages', 'Un brouillard', 'Un orage visible', 'a', 'Elle se rencontre surtout près des courants-jets en haute altitude.', 'meteo'),
    ('Que mesure un hygromètre ?', 'L''humidité de l''air', 'La pression', 'La température', 'Le vent', 'a', 'Un psychromètre utilise un thermomètre sec et un thermomètre mouillé.', 'meteo'),
    ('Quel instrument mesure la pression atmosphérique ?', 'Le baromètre', 'L''anémomètre', 'L''hygromètre', 'Le thermomètre', 'a', 'L''altimètre de l''avion est un baromètre anéroïde gradué en pieds.', 'meteo'),
    ('À quelle heure se produit en général le maximum de convection et d''orages de chaleur ?', 'L''après-midi', 'Le matin à l''aube', 'La nuit', 'À midi pile partout', 'a', 'Le sol est le plus chaud en milieu et fin d''après-midi.', 'meteo'),
    ('Comment la température varie-t-elle dans une couche d''air qui monte sans échange de chaleur (air sec) ?', 'Elle augmente', 'Elle reste constante', 'Elle diminue de 10°C par 100 m', 'Elle diminue d''environ 1°C par 100 m (3°C par 1000 ft)', 'd', 'C''est le gradient adiabatique sec ; l''air saturé se refroidit moins vite (environ 0,6°C par 100 m).', 'meteo'),
    ('Comment estime-t-on simplement la base des cumulus ?', 'Environ 400 ft par degré d''écart entre température et point de rosée', '1000 ft par degré', '100 ft par hPa', 'La base est toujours à 3000 ft', 'a', 'Exemple : 20°C et 10°C de point de rosée donnent une base vers 4000 ft.', 'meteo'),
    ('Qu''est-ce qu''une ligne de grains ?', 'Une rangée de champs de blé', 'Une ligne d''orages ou d''averses violentes, souvent en avant d''un front froid', 'Une isobare', 'Une route aérienne', 'b', 'Elle peut être infranchissable pour un avion léger.', 'meteo'),
    ('Quelle est la principale source d''information sur les phénomènes dangereux en route pour l''aviation générale ?', 'La radio FM', 'Les réseaux sociaux', 'Les SIGMET, AIRMET, GAMET et la TEMSI', 'Les NOTAM d''aérodrome uniquement', 'c', 'Ces produits se consultent lors de la préparation et peuvent être demandés en vol au SIV.', 'meteo'),
    ('Le vent est annoncé 310/20 pour une piste 27. De quel côté vient la composante traversière ?', 'De la droite', 'De la gauche', 'De face exactement', 'De l''arrière', 'a', 'Le vent vient de 40° à droite de l''axe 270.', 'meteo'),
    ('Vent 300/20, piste 33. Quelle composante traversière environ ?', '20 kt', '0 kt', '17 kt', '10 kt', 'd', 'Angle 30° : sin 30° = 0,5, soit 10 kt ; la composante de face vaut environ 17 kt.', 'meteo'),
    ('Vent 090/15, piste 09. Quelle composante traversière ?', '15 kt', '7 kt', '10 kt', '0 kt', 'd', 'Le vent est dans l''axe : 15 kt de face, pas de traversier.', 'meteo'),
    ('Vent 180/10 pour une piste 36. Quel vent effectif ?', '10 kt de face', '5 kt traversier', '10 kt de vent arrière', 'Vent nul', 'c', 'Décoller ou atterrir vent arrière allonge fortement les distances : on change de piste.', 'meteo'),
    ('Qu''appelle-t-on « visibilité » dans un METAR ?', 'La visibilité verticale', 'La visibilité depuis le cockpit en vol', 'La portée radio', 'La visibilité horizontale dominante au sol', 'd', 'En vol, la visibilité oblique peut être bien plus faible.', 'meteo'),
    ('Que signifie « VV002 » dans un METAR ?', 'Vent variable de 2 kt', 'Visibilité verticale de 200 ft (ciel invisible)', 'Visibilité 200 m', 'Nuages à 2000 ft', 'b', 'On utilise VV quand le ciel est masqué, par exemple par du brouillard.', 'meteo'),
    ('Une couche de nuages FEW030 constitue-t-elle un plafond ?', 'Non, FEW signifie 1 à 2 octas', 'Oui', 'Oui, si elle est sous 5000 ft', 'Oui, la nuit', 'a', 'Seules les couches BKN ou OVC constituent un plafond.', 'meteo'),
    ('Le passage d''un front froid au sol se traduit souvent par :', 'Une baisse de pression continue et un réchauffement', 'Une hausse de pression, une baisse de température et une rotation du vent', 'Un vent qui cesse totalement', 'Un ciel qui reste inchangé', 'b', 'Il peut être accompagné d''averses et de rafales.', 'meteo'),
    ('En classe A, quels vols sont admis ?', 'IFR et VFR', 'Uniquement les VFR', 'Les ULM', 'Uniquement les vols IFR', 'd', 'La classe A est réservée aux vols IFR, tous séparés entre eux.', 'reglementation'),
    ('En classe E, un vol VFR a-t-il besoin d''une clairance ?', 'Non, ni clairance ni contact radio obligatoire', 'Oui, toujours', 'Oui, avec contact radio', 'Seulement de nuit', 'a', 'En classe E, seuls les IFR sont contrôlés ; les VFR reçoivent l''information de vol dans la mesure du possible.', 'reglementation'),
    ('En classe G, quel service reçoivent les vols VFR ?', 'Le service d''information de vol, sur demande', 'Le contrôle avec séparation', 'Aucun service', 'La séparation radar', 'a', 'La classe G est un espace non contrôlé ; le SIV peut fournir information de vol et alerte.', 'reglementation'),
    ('En classe C, un VFR est-il séparé des IFR ?', 'Non', 'Oui, et aussi des autres VFR', 'Oui, et il reçoit l''information de trafic sur les autres VFR', 'Seulement de nuit', 'c', 'En classe C, IFR et VFR sont séparés ; entre VFR, le contrôle donne l''information de trafic.', 'reglementation'),
    ('En classe D, un VFR est-il séparé des autres vols par le contrôle ?', 'Oui, de tous les vols', 'Oui, des IFR uniquement', 'Non, il reçoit l''information de trafic', 'Non, et il ne reçoit aucune information', 'c', 'En classe D, seuls les IFR sont séparés entre eux ; les VFR reçoivent l''information de trafic. Clairance et radio sont obligatoires.', 'reglementation'),
    ('Quelle est la vitesse maximale en VFR au-dessous du FL100 dans les classes C, D, E, F et G ?', '250 kt IAS', '200 kt', '300 kt', 'Pas de limite', 'a', 'Cette limite ne s''applique pas en classes A et B.', 'reglementation'),
    ('Quelles sont les distances minimales aux nuages en VFR dans un espace contrôlé, au-dessous du FL100 ?', '500 m et 100 ft', 'Hors des nuages et en vue du sol', '5 km et 2000 ft', '1500 m horizontalement et 300 m (1000 ft) verticalement', 'd', 'La visibilité minimale associée est de 5 km au-dessous du FL100 et 8 km au-dessus.', 'reglementation'),
    ('Quelle visibilité minimale en VFR au-dessus du FL100 (3050 m AMSL) ?', '5 km', '1500 m', '8 km', '10 km', 'c', 'Au-dessus de 10 000 ft, la visibilité exigée passe à 8 km.', 'reglementation'),
    ('Quels sont les minima du VFR spécial (SERA) dans une zone de contrôle ?', '5 km et plafond 1500 ft', '800 m sans plafond', 'Visibilité 1500 m, plafond 600 ft, hors des nuages et en vue de la surface, vitesse ≤ 140 kt', 'Aucun minimum', 'c', 'Le VFR spécial se fait sur clairance. Certains aérodromes publient des minima plus élevés (par exemple 3000 m à LFMA).', 'reglementation'),
    ('Qui peut autoriser un vol en VFR spécial ?', 'Le contrôle de la zone de contrôle (CTR)', 'Le pilote lui-même', 'Le chef pilote', 'Le BRIA', 'a', 'Le VFR spécial s''effectue dans une CTR, sur clairance ATC.', 'reglementation'),
    ('Hors agglomération, quelle hauteur minimale de survol en VFR (SERA) ?', '50 m', '150 m (500 ft) au-dessus du sol ou de l''eau, ou de l''obstacle le plus élevé dans un rayon de 150 m', '300 m', '1000 m', 'b', 'Sauf pour le décollage et l''atterrissage ou sur autorisation.', 'reglementation'),
    ('Face à face avec un autre aéronef, que doit faire chaque pilote ?', 'Obliquer vers sa gauche', 'Monter', 'Obliquer vers sa droite', 'Descendre', 'c', 'Règle de l''air : en rapprochement de face, chacun vire à droite.', 'reglementation'),
    ('Un avion en rattrape un autre. Comment le dépasse-t-il ?', 'Par la droite, en s''écartant de sa trajectoire', 'Par la gauche', 'Par-dessous', 'Par-dessus en montée', 'a', 'L''aéronef rattrapé a la priorité ; le dépassant s''écarte vers la droite.', 'reglementation'),
    ('Qui a la priorité entre un avion et un planeur ?', 'L''avion', 'Le plus rapide', 'Le planeur', 'Le plus lourd', 'c', 'Les aérodynes motorisés cèdent le passage aux dirigeables, planeurs et ballons.', 'reglementation'),
    ('Qui a la priorité entre un planeur et un ballon ?', 'Le planeur', 'Le ballon', 'Le plus haut', 'Aucun', 'b', 'Les planeurs cèdent le passage aux ballons.', 'reglementation'),
    ('Deux avions s''approchent pour atterrir. Lequel a la priorité ?', 'Le plus bas, sans couper la route de l''autre en finale', 'Le plus haut', 'Le plus rapide', 'Le plus lourd', 'a', 'L''aéronef le plus bas a la priorité, mais ne doit pas en profiter pour s''intercaler devant un aéronef en finale.', 'reglementation'),
    ('Un aéronef en détresse :', 'Doit céder le passage', 'N''a pas de priorité particulière', 'Doit attendre la fin du trafic', 'A la priorité sur tous les autres', 'd', 'Il a la priorité absolue.', 'reglementation'),
    ('Au roulage, deux avions se rencontrent de face. Que font-ils ?', 'Celui de gauche passe', 'Le plus gros passe', 'Ils reculent', 'Chacun s''arrête ou s''écarte vers sa droite', 'd', 'Les règles de priorité au sol s''inspirent des règles en vol.', 'reglementation'),
    ('Signal lumineux de la tour vers un avion en vol : feu vert fixe. Signification ?', 'Revenez atterrir', 'Ne pas atterrir, aérodrome dangereux', 'Cédez le passage et continuez à tourner', 'Autorisé à atterrir', 'd', 'Feu rouge fixe : cédez le passage et continuez à circuler.', 'reglementation'),
    ('Signal lumineux vers un avion en vol : éclats verts. Signification ?', 'Revenez pour atterrir', 'Autorisé à atterrir', 'Atterrissez immédiatement', 'Aérodrome fermé', 'a', 'Les éclats verts invitent à revenir ; l''autorisation d''atterrir sera donnée par un feu vert fixe.', 'reglementation'),
    ('Signal lumineux vers un avion en vol : éclats rouges. Signification ?', 'Aérodrome dangereux, n''atterrissez pas', 'Autorisé à atterrir', 'Revenez pour atterrir', 'Allez au parking', 'a', 'Feu rouge fixe : cédez le passage et continuez à tourner.', 'reglementation'),
    ('Signal lumineux vers un avion au sol : feu vert fixe. Signification ?', 'Autorisé à décoller', 'Autorisé à rouler', 'Arrêtez-vous', 'Retournez au point de départ', 'a', 'Au sol, éclats verts = autorisé à rouler ; feu rouge fixe = arrêtez ; éclats rouges = dégagez l''aire d''atterrissage.', 'reglementation'),
    ('Signal lumineux vers un avion au sol : éclats blancs. Signification ?', 'Autorisé à décoller', 'Retournez à votre point de départ sur l''aérodrome', 'Arrêtez-vous', 'Dégagez la piste', 'b', 'En vol, les éclats blancs signifient : atterrissez sur cet aérodrome et rejoignez l''aire de trafic.', 'reglementation'),
    ('Signal lumineux vers un avion au sol : feu rouge fixe. Signification ?', 'Autorisé à rouler', 'Autorisé à décoller', 'Arrêtez-vous', 'Retournez au parking', 'c', 'Éclats rouges : dégagez l''aire d''atterrissage en service.', 'reglementation'),
    ('Dans l''aire à signaux, que signifie un carré rouge avec deux diagonales jaunes ?', 'Prudence à l''atterrissage', 'Planeurs en activité', 'Atterrissages interdits', 'Circuit à droite', 'c', 'Un carré rouge avec une seule diagonale jaune signifie : prudence particulière à l''approche et à l''atterrissage.', 'reglementation'),
    ('Dans l''aire à signaux, que signifie une double croix blanche ?', 'Aérodrome fermé', 'Activité de vol à voile en cours', 'Atterrissage interdit', 'Parachutage', 'b', 'La double croix blanche horizontale signale des planeurs.', 'reglementation'),
    ('Dans l''aire à signaux, que signifie un « T » blanc ?', 'Taxi interdit', 'Il indique la direction d''atterrissage et de décollage', 'Tour fermée', 'Terrain en travaux', 'b', 'On atterrit le long de la barre du T, vers la barre transversale.', 'reglementation'),
    ('Dans l''aire à signaux, que signifie un haltère blanc ?', 'Piste fermée', 'Atterrissage interdit', 'Les mouvements au sol doivent se faire uniquement sur les surfaces en dur', 'Activité de parachutisme', 'c', 'Si l''haltère porte des bandes noires, décollages et atterrissages se font sur piste, les autres mouvements pouvant se faire ailleurs.', 'reglementation'),
    ('Sur une piste, que signalent des croix blanches ?', 'L''axe de piste', 'Une partie de piste impraticable', 'Un seuil décalé', 'Une zone de parking', 'b', 'Elles indiquent une zone hors service.', 'reglementation'),
    ('Comment est déterminé le numéro d''une piste ?', 'Par son orientation magnétique arrondie à la dizaine de degrés, divisée par 10', 'Par son orientation vraie', 'Par l''ordre de construction', 'Par sa longueur', 'a', 'Une piste orientée 143° magnétiques est la piste 14.', 'reglementation'),
    ('Au point d''arrêt d''une piste, de quel côté du marquage doit-on s''arrêter ?', 'Du côté des traits pointillés', 'Du côté des traits continus', 'Sur le marquage', 'Peu importe', 'b', 'On s''arrête avant les deux lignes continues ; les pointillés sont du côté de la piste.', 'reglementation'),
    ('Un panneau rouge avec inscription blanche sur une voie de circulation indique :', 'Une direction', 'Un emplacement', 'Une instruction obligatoire, par exemple un point d''attente avant piste', 'Une information facultative', 'c', 'Les panneaux jaunes sur fond noir indiquent l''emplacement ; noir sur jaune, la direction.', 'reglementation'),
    ('Quel âge minimum pour obtenir le PPL(A) ?', '16 ans', '17 ans', '18 ans', '15 ans', 'b', 'Le LAPL(A) est également accessible à partir de 17 ans ; le premier vol solo est possible dès 16 ans.', 'reglementation'),
    ('À partir de quel âge un élève peut-il effectuer son premier vol solo en avion ?', '14 ans', '17 ans', '16 ans', '18 ans', 'c', 'Le solo demande aussi un certificat médical et une autorisation de l''instructeur.', 'reglementation'),
    ('Combien d''heures de vol minimum exige la formation PPL(A) ?', '30 heures', '45 heures', '20 heures', '100 heures', 'b', 'Dont au moins 25 h en double commande et 10 h en solo supervisé, avec 5 h de navigation solo.', 'reglementation'),
    ('Combien d''heures de vol minimum exige la formation LAPL(A) ?', '30 heures', '45 heures', '15 heures', '60 heures', 'a', 'Dont au moins 15 h en double commande et 6 h en solo supervisé, avec 3 h de navigation solo.', 'reglementation'),
    ('Pour le PPL(A), quelle navigation solo est exigée ?', 'Une navigation de 20 NM', 'Un aller-retour de 50 NM', 'Une navigation d''au moins 150 NM avec deux atterrissages complets sur deux aérodromes différents', 'Aucune', 'c', 'C''est la « grande navigation » solo du PPL.', 'reglementation'),
    ('Pour le LAPL(A), quelle navigation solo est exigée ?', 'Une navigation de 150 NM', 'Aucune', 'Une navigation d''au moins 80 NM avec un atterrissage complet sur un autre aérodrome', 'Un vol local de 10 NM', 'c', 'Elle fait partie des 3 h de navigation solo minimum.', 'reglementation'),
    ('Combien de matières compte l''examen théorique LAPL/PPL ?', '9', '5', '12', '3', 'a', 'Droit aérien, connaissances générales de l''aéronef, performances et préparation du vol, performance humaine, météorologie, navigation, procédures opérationnelles, principes du vol, communications.', 'reglementation'),
    ('Quel taux de réussite faut-il obtenir à chaque matière de l''examen théorique ?', '50 %', '60 %', '90 %', '75 %', 'd', 'Chaque matière doit être réussie avec au moins 75 % de bonnes réponses.', 'reglementation'),
    ('Combien de temps est valable le succès à l''examen théorique pour délivrer la licence ?', '6 mois', '5 ans', 'À vie', '24 mois', 'd', 'La licence doit être délivrée dans les 24 mois suivant la réussite complète de l''examen théorique.', 'reglementation'),
    ('Quelle est la durée de validité de la qualification de classe SEP (monomoteur à pistons) ?', '24 mois', '12 mois', '36 mois', 'À vie', 'a', 'Elle se proroge par l''expérience ou par un contrôle de compétences.', 'reglementation'),
    ('Pour proroger la SEP par l''expérience, quelles sont les conditions principales ?', '12 h de vol dans les 12 mois précédant l''échéance, dont 6 h CDB, 12 décollages et atterrissages et un vol d''entraînement d''1 h avec un instructeur', '1 h de vol par an', '50 h de vol en 2 ans', 'Un seul vol avec instructeur', 'a', 'Sinon, on passe un contrôle de compétences avec un examinateur.', 'reglementation'),
    ('Quelle condition d''expérience récente faut-il pour emmener des passagers ?', '1 vol dans l''année', '10 h dans le mois', 'Aucune', 'Au moins 3 décollages et 3 atterrissages dans les 90 jours précédents sur le même type ou la même classe', 'd', 'Ces décollages et atterrissages doivent être faits en tant que pilote aux commandes.', 'reglementation'),
    ('Quelles conditions d''expérience récente pour exercer les privilèges du LAPL(A) ?', '1 h par an', 'Un contrôle tous les 6 mois', 'Dans les 24 derniers mois, 12 h de vol comme CDB dont 12 décollages et atterrissages, et 1 h de vol d''entraînement avec un instructeur', 'Aucune', 'c', 'Le LAPL n''a pas de qualification de classe à proroger, mais ces conditions doivent être remplies.', 'reglementation'),
    ('Quel certificat médical faut-il pour le PPL(A) ?', 'Un certificat de classe 2 au minimum', 'Un certificat de classe 1 obligatoirement', 'Un simple certificat du médecin traitant', 'Aucun', 'a', 'Le LAPL peut être exercé avec un certificat médical LAPL.', 'reglementation'),
    ('Quelle est la durée de validité d''un certificat médical de classe 2 pour un pilote de moins de 40 ans ?', '12 mois', '60 mois', '24 mois', '10 ans', 'b', 'Entre 40 et 50 ans, elle est de 24 mois ; après 50 ans, de 12 mois.', 'reglementation'),
    ('Quelle est la durée de validité d''un certificat médical de classe 2 après 50 ans ?', '12 mois', '24 mois', '60 mois', '6 mois', 'a', 'Elle décroît avec l''âge pour assurer un suivi plus régulier.', 'reglementation'),
    ('Le titulaire d''un PPL peut-il être rémunéré pour piloter ?', 'Oui, librement', 'Oui, s''il a 100 h', 'Non, sauf exceptions précises (instruction, certains vols à frais partagés…)', 'Oui, en transport public', 'c', 'Le PPL ne permet pas le transport commercial.', 'reglementation'),
    ('Qu''est-ce qu''un vol à frais partagés ?', 'Un vol où le coût direct est réparti entre les occupants, pilote compris', 'Un vol où les passagers paient tout au pilote', 'Un vol commercial', 'Un vol gratuit', 'a', 'Le pilote doit payer sa part ; le nombre de personnes partageant les frais est limité (6 au maximum, pilote compris).', 'reglementation'),
    ('Quels documents la licence de pilote doit-elle être accompagnée en vol ?', 'Le carnet de vol uniquement', 'Le certificat médical valide et une pièce d''identité avec photo', 'La carte de l''aéroclub', 'Rien', 'b', 'Le pilote doit présenter licence, certificat médical et pièce d''identité en cas de contrôle.', 'reglementation'),
    ('Que doit contenir le carnet de vol du pilote ?', 'Uniquement la date', 'Les comptes de l''aéroclub', 'Ses heures de vol et les éléments de chaque vol (date, avion, trajet, fonction, durée)', 'Le carnet de route de l''avion', 'c', 'Il sert à justifier l''expérience pour les licences et prorogations.', 'reglementation'),
    ('Qu''est-ce qu''une CTR ?', 'Une zone de contrôle qui s''étend du sol jusqu''à une limite supérieure', 'Une région de contrôle en altitude', 'Une zone interdite', 'Une zone militaire temporaire', 'a', 'Elle protège les arrivées et départs d''un ou plusieurs aérodromes.', 'reglementation'),
    ('Que signifie le préfixe « P » sur une carte (par exemple P 23) ?', 'Zone de parachutage', 'Zone interdite', 'Zone dangereuse', 'Zone de protection animale', 'b', 'P (prohibited) : zone interdite ; R (restricted) : réglementée ; D (danger) : dangereuse.', 'reglementation'),
    ('Que signifie une zone « R » ?', 'Zone interdite en permanence', 'Zone réglementée, pénétrable sous conditions', 'Zone de repos', 'Zone radio', 'b', 'Les conditions de pénétration figurent dans l''AIP et sur les cartes ; elles peuvent être actives à certains horaires.', 'reglementation'),
    ('Une zone « D » (dangereuse) :', 'Est interdite en permanence', 'Est réservée aux planeurs', 'Est un aérodrome', 'Signale une activité dangereuse ; sa pénétration n''est pas interdite mais déconseillée quand elle est active', 'd', 'C''est au pilote d''évaluer le risque à partir des informations disponibles.', 'reglementation'),
    ('Que sont les zones du réseau RTBA ?', 'Des zones de parachutage', 'Des zones de vol à voile', 'Des zones réglementées pour les vols militaires à très basse altitude', 'Des zones touristiques', 'c', 'Leur activité est publiée et consultable (AZBA) ; il faut la vérifier avant chaque vol.', 'reglementation'),
    ('Qu''est-ce qu''un SIV ?', 'Un service de maintenance', 'Une zone interdite', 'Un secteur d''information de vol, fournissant information et alerte aux vols qui le demandent', 'Un type de NOTAM', 'c', 'Le contact avec le SIV n''est pas obligatoire, mais fortement recommandé.', 'reglementation'),
    ('Le VFR est-il en principe autorisé au-dessus du FL195 ?', 'Non, sauf dérogations particulières', 'Oui, toujours', 'Oui, de jour', 'Oui, avec un transpondeur', 'a', 'L''espace au-dessus du FL195 est réservé en principe aux vols IFR.', 'reglementation'),
    ('Quand le dépôt d''un plan de vol est-il obligatoire en VFR ?', 'Pour tout vol local', 'Jamais', 'Seulement en été', 'Notamment pour franchir une frontière, survoler la mer au-delà de la distance de plané ou voler de nuit hors des abords de l''aérodrome', 'd', 'Il est aussi exigé pour certains espaces contrôlés. Il améliore l''efficacité du service d''alerte.', 'reglementation'),
    ('Qu''est-ce qui se passe si un plan de vol n''est pas clôturé ?', 'Rien', 'Une amende automatique', 'Les phases de recherche (INCERFA, ALERFA, DETRESFA) sont déclenchées', 'Le pilote perd sa licence', 'c', 'D''où l''importance de clôturer son plan de vol à l''arrivée.', 'reglementation'),
    ('Quelles sont les trois phases d''urgence du service d''alerte ?', 'Phase 1, 2 et 3', 'INCERFA (incertitude), ALERFA (alerte), DETRESFA (détresse)', 'Vert, orange, rouge', 'Mayday, Pan, Sécurité', 'b', 'Elles sont déclenchées successivement selon la gravité supposée.', 'reglementation'),
    ('Qu''est-ce que le BRIA ?', 'La brigade de recherche', 'Le bureau régional d''information aéronautique et d''assistance au vol', 'Un organisme de maintenance', 'Une école de pilotage', 'b', 'On peut y déposer ou clôturer un plan de vol et obtenir des informations.', 'reglementation'),
    ('Qu''est-ce qu''un « AFIL » ?', 'Un plan de vol déposé en vol', 'Un plan de vol annulé', 'Un aérodrome fermé', 'Un message météo', 'a', 'On le transmet par radio à un organisme ATS.', 'reglementation'),
    ('Qui est responsable de la conduite du vol à bord ?', 'Le contrôleur aérien', 'Le commandant de bord', 'Le propriétaire de l''avion', 'Le chef pilote', 'b', 'Le commandant de bord a l''autorité finale ; il peut déroger aux règles en cas d''urgence pour la sécurité.', 'reglementation'),
    ('Le commandant de bord peut-il s''écarter d''une clairance ?', 'Jamais', 'Oui, quand il veut', 'Seulement de nuit', 'Oui, en cas d''urgence, en informant le contrôle dès que possible', 'd', 'Il doit ensuite justifier son action si on le lui demande.', 'reglementation'),
    ('Quelle quantité minimale de carburant (réserve finale) en VFR de jour pour un avion (règles NCO) ?', '10 minutes', '1 heure', 'Le carburant pour rejoindre la destination plus 30 minutes à l''altitude de croisière normale', 'Aucune', 'c', 'De nuit en VFR, la réserve est de 45 minutes.', 'reglementation'),
    ('Quelle réserve de carburant en VFR de nuit (règles NCO) ?', '30 minutes', '45 minutes', '10 minutes', '2 heures', 'b', 'Elle s''ajoute au carburant nécessaire pour rejoindre la destination.', 'reglementation'),
    ('Quel code transpondeur afficher en VFR en France hors instruction particulière ?', '7000', '2000', '7700', '1200', 'a', 'Le 1200 est utilisé aux États-Unis.', 'reglementation'),
    ('Quel code transpondeur en cas de panne radio ?', '7700', '7600', '7500', '7000', 'b', '7700 : détresse ; 7500 : intervention illicite.', 'reglementation'),
    ('Quel code transpondeur en cas d''intervention illicite (détournement) ?', '7600', '7700', '7500', '7000', 'c', 'Ce code ne doit jamais être affiché par erreur.', 'reglementation'),
    ('Sans gilets de sauvetage à bord, jusqu''où un monomoteur peut-il s''éloigner de la côte ?', 'Sans limite', 'Jusqu''à 100 NM', 'Jusqu''à la distance de plané de la côte', 'Jusqu''à 10 minutes de vol', 'c', 'Au-delà de la distance de plané, des gilets de sauvetage sont exigés, et d''autres équipements selon la distance.', 'reglementation'),
    ('Le survol d''un rassemblement de personnes en plein air à basse hauteur est :', 'Autorisé librement', 'Autorisé le dimanche', 'Interdit, sauf autorisation', 'Autorisé au-dessus de 300 ft', 'c', 'On respecte les hauteurs minimales de survol des agglomérations et rassemblements.', 'reglementation'),
    ('Est-il permis de larguer des objets en vol ?', 'Oui, librement', 'Oui, au-dessus de la mer', 'Non, sauf autorisation et cas prévus (parachutage, épandage…)', 'Oui, au-dessus d''un champ', 'c', 'Le largage est réglementé pour la sécurité des personnes au sol.', 'reglementation'),
    ('Que doit faire un pilote impliqué dans un accident ou un incident grave ?', 'Ne rien dire', 'Le notifier sans délai au BEA et à l''autorité', 'Prévenir uniquement l''assureur', 'Attendre une semaine', 'b', 'Le BEA enquête sur les accidents et incidents graves dans un but de prévention, pas de recherche de responsabilité.', 'reglementation'),
    ('Quel est le rôle du BEA ?', 'Délivrer les licences', 'Contrôler la circulation aérienne', 'Enquêter sur les accidents et incidents graves pour améliorer la sécurité', 'Vendre du carburant', 'c', 'Le Bureau d''Enquêtes et d''Analyses publie ses rapports et recommandations.', 'reglementation'),
    ('Quel est le rôle de l''EASA ?', 'L''aéroclub national', 'L''agence de l''Union européenne pour la sécurité aérienne, qui élabore les règles communes', 'Le contrôle aérien français', 'La météo européenne', 'b', 'Les règles Part-FCL (licences), Part-MED (médical), SERA (règles de l''air) en découlent.', 'reglementation'),
    ('Que sont les règles SERA ?', 'Un règlement de l''aéroclub', 'Une carte VAC', 'Les règles de l''air européennes standardisées', 'Une marque de moteur', 'c', 'SERA = Standardised European Rules of the Air.', 'reglementation'),
    ('Que réglemente la Part-FCL ?', 'Les licences et qualifications des pilotes', 'La maintenance', 'Les aérodromes', 'La météorologie', 'a', 'FCL = Flight Crew Licensing.', 'reglementation'),
    ('Que signifie DTO ?', 'Direction technique opérationnelle', 'Délégation de transport officiel', 'Organisme de formation déclaré (Declared Training Organisation)', 'Document de transport obligatoire', 'c', 'Beaucoup d''aéroclubs dispensent la formation LAPL/PPL en tant que DTO ; un ATO est un organisme de formation approuvé.', 'reglementation'),
    ('Que signifie l''abréviation « FI » ?', 'Fiche d''information', 'Instructeur de vol (Flight Instructor)', 'Fréquence internationale', 'Facteur d''incidence', 'b', 'Le FI signe le carnet de vol et le livret de progression de l''élève.', 'reglementation'),
    ('Que signifie l''abréviation « FE » ?', 'Facteur d''essai', 'Fiche d''entretien', 'Examinateur de vol (Flight Examiner)', 'Fréquence d''urgence', 'c', 'C''est l''examinateur qui fait passer l''épreuve pratique de la licence.', 'reglementation'),
    ('Que sont les « privilèges » d''une licence ?', 'Une réduction de prix', 'Le droit de voler sans médical', 'Ce que la licence permet de faire', 'Un titre honorifique', 'c', 'Exemple : le LAPL(A) permet de piloter des avions jusqu''à 2000 kg de MTOM avec au plus 3 passagers.', 'reglementation'),
    ('Avec un LAPL(A), combien de personnes au maximum à bord, pilote compris ?', '2', '6', '4', '9', 'c', 'Le LAPL(A) limite à 3 passagers et à une masse maximale au décollage de 2000 kg.', 'reglementation'),
    ('Le LAPL(A) est-il valable dans les autres pays de l''Union européenne ?', 'Non, seulement en France', 'Oui, c''est une licence européenne', 'Oui, dans le monde entier', 'Non, nulle part', 'b', 'Hors UE, il n''est en général pas reconnu, contrairement au PPL conforme OACI.', 'reglementation'),
    ('Que faut-il pour transporter des passagers de nuit avec un PPL ?', 'Rien de plus', 'Une licence CPL', 'La qualification de vol de nuit', 'Un avion bimoteur', 'c', 'La qualification de vol de nuit comprend une formation théorique et pratique.', 'reglementation'),
    ('Qu''est-ce qu''une zone de parachutage sur une carte ?', 'Une zone pour les avions en panne', 'Une zone de stationnement', 'Une zone de ravitaillement', 'Une zone où des parachutistes peuvent être largués ; à éviter ou à contacter', 'd', 'Leur activité est souvent signalée par NOTAM et sur les fréquences.', 'reglementation'),
    ('Une CTR est de classe D. Que faut-il avant d''y entrer en VFR ?', 'Rien', 'Un plan de vol IFR', 'Un transpondeur mode S seulement', 'Une clairance du contrôle', 'd', 'La clairance s''obtient par radio, souvent au point d''entrée publié sur la VAC.', 'reglementation'),
    ('Que veut dire « VMC » ?', 'Vitesse minimale de contrôle', 'Vol en montée continue', 'Vent moyen calculé', 'Conditions météorologiques de vol à vue', 'd', 'IMC désigne les conditions de vol aux instruments.', 'reglementation'),
    ('Que veut dire « VFR » ?', 'Vol à faible rayon', 'Vitesse finale réduite', 'Les règles de vol à vue', 'Vol en formation', 'c', 'Le vol VFR exige des conditions VMC.', 'reglementation'),
    ('Peut-on piloter sous l''effet de médicaments pouvant altérer la vigilance ?', 'Oui, si on se sent bien', 'Oui, de jour', 'Oui, en double commande', 'Non', 'd', 'En cas de doute, on demande l''avis d''un médecin aéronautique.', 'reglementation'),
    ('Quel document permet d''exploiter la station radio de l''avion ?', 'La licence de station d''aéronef (LSA)', 'Le certificat d''immatriculation', 'Le carnet de route', 'La carte VAC', 'a', 'Le pilote doit aussi avoir la qualification radiotéléphonie appropriée.', 'reglementation'),
    ('Que signifie l''immatriculation commençant par « F- » ?', 'Que c''est un avion de formation', 'Que c''est un avion fédéral', 'Que l''avion est immatriculé en France', 'Que c''est un avion de fret', 'c', 'Exemples : D- Allemagne, G- Royaume-Uni, N États-Unis, I- Italie, EC- Espagne.', 'reglementation'),
    ('Un avion immatriculé « D-EABC » est immatriculé :', 'Au Danemark', 'En France', 'En Allemagne', 'Aux Pays-Bas', 'c', 'PH- correspond aux Pays-Bas, OY- au Danemark.', 'reglementation'),
    ('Peut-on fumer à bord pendant l''avitaillement ?', 'Oui, si les portes sont ouvertes', 'Non, jamais', 'Oui, à plus de 10 m', 'Oui, cabine fermée', 'b', 'Les vapeurs d''essence sont très inflammables.', 'reglementation'),
    ('Quelles qualités doit avoir la phraséologie radio ?', 'Longue et détaillée', 'Familière', 'Improvisée', 'Concise et précise', 'd', 'Concise pour ne pas encombrer la fréquence, précise pour ne laisser aucune ambiguïté.', 'radio'),
    ('Avant d''émettre, que doit faire le pilote ?', 'Appuyer immédiatement sur l''alternat', 'Monter le volume au maximum', 'Écouter la fréquence pour ne pas couper une communication en cours', 'Changer de fréquence', 'c', 'On réfléchit aussi à son message avant de parler.', 'radio'),
    ('Comment épelle-t-on la lettre « G » en alphabet aéronautique ?', 'Georges', 'Gamma', 'Golf', 'Gold', 'c', 'L''alphabet OACI : Alfa, Bravo, Charlie, Delta, Echo, Foxtrot, Golf, Hotel, India, Juliett, Kilo, Lima, Mike…', 'radio'),
    ('Comment épelle-t-on la lettre « Y » en alphabet aéronautique ?', 'Yankee', 'Yellow', 'Yoga', 'Yvonne', 'a', '… Victor, Whiskey, X-ray, Yankee, Zulu.', 'radio'),
    ('Comment épelle-t-on la lettre « Q » en alphabet aéronautique ?', 'Queen', 'Quebec', 'Quiz', 'Quentin', 'b', '… Oscar, Papa, Quebec, Romeo, Sierra, Tango, Uniform…', 'radio'),
    ('Comment épelle-t-on la lettre « J » ?', 'Juliett', 'Jack', 'Japan', 'Jules', 'a', '… Hotel, India, Juliett, Kilo…', 'radio'),
    ('Comment épelle-t-on la lettre « K » ?', 'King', 'Kayak', 'Kappa', 'Kilo', 'd', '… Juliett, Kilo, Lima, Mike…', 'radio'),
    ('Comment épelle-t-on la lettre « O » ?', 'Omega', 'Olive', 'Ontario', 'Oscar', 'd', '… November, Oscar, Papa…', 'radio'),
    ('Comment l''indicatif F-GRFY est-il abrégé une fois le contact établi, si le contrôle l''a abrégé le premier ?', 'F-FY', 'F-GR', 'GRFY', 'FY', 'a', 'Abréviation : première lettre et deux dernières. Le pilote n''abrège qu''après que l''organisme l''a fait.', 'radio'),
    ('Qui peut abréger l''indicatif d''un avion le premier ?', 'Le pilote, dès le premier message', 'Personne', 'L''organisme au sol', 'N''importe quel autre avion', 'c', 'Le pilote utilise ensuite l''indicatif abrégé.', 'radio'),
    ('Que signifie « Collationnez » ?', 'Attendez', 'Répétez-moi tout ou partie du message pour vérifier qu''il a été bien reçu', 'Changez de fréquence', 'Message terminé', 'b', 'Le collationnement permet de détecter les erreurs de compréhension.', 'radio'),
    ('Que doit-on obligatoirement collationner ?', 'Uniquement le bonjour', 'La météo complète', 'Les clairances, la piste en service, le calage altimétrique, le code transpondeur, les caps, niveaux et fréquences', 'Rien', 'c', 'Ces éléments de sécurité sont toujours répétés, suivis de l''indicatif.', 'radio'),
    ('Que signifie « Wilco » ?', 'Message compris, je m''y conformerai', 'Je ne comprends pas', 'Répétez', 'Attendez', 'a', 'C''est l''abréviation de « will comply ».', 'radio'),
    ('Que signifie « Roger » ou « Reçu » ?', 'Je vais m''y conformer', 'Oui', 'J''ai bien reçu votre dernier message', 'Je ne peux pas', 'c', '« Reçu » ne remplace pas un collationnement obligatoire ni une réponse « affirm » ou « négatif ».', 'radio'),
    ('Que signifie « Affirm » ?', 'Non', 'Oui', 'Reçu', 'Attendez', 'b', 'Le contraire est « Négatif ».', 'radio'),
    ('Que signifie « Standby » ou « Attendez » ?', 'Message terminé', 'Autorisé', 'Attendez, je vous rappelle', 'Je quitte la fréquence', 'c', 'Ce n''est pas une autorisation : on attend que l''organisme rappelle.', 'radio'),
    ('Que signifie « Dites à nouveau » (« Say again ») ?', 'Collationnez', 'Parlez plus fort', 'Changez de fréquence', 'Répétez votre dernier message', 'd', 'En phraséologie, on ne dit pas « répétez » en anglais (repeat a un autre sens militaire).', 'radio'),
    ('Comment prononce-t-on le chiffre 9 en phraséologie anglaise ?', 'Niner', 'Nine', 'Nein', 'Nana', 'a', 'Pour éviter la confusion avec l''allemand « nein » et le chiffre 5.', 'radio'),
    ('Comment annonce-t-on la fréquence 118,755 en français ?', '« Un un huit décimale sept cinq cinq »', '« Cent dix-huit sept cent cinquante-cinq »', '« Onze huit sept cinq »', '« Un un huit point cinq »', 'a', 'Les chiffres s''énoncent un par un, avec « décimale » pour la virgule.', 'radio'),
    ('Comment énonce-t-on un niveau de vol 65 ?', '« Niveau soixante-cinq »', '« Niveau six cinq »', '« Six mille cinq cents »', '« Flight six »', 'b', 'Les niveaux s''énoncent chiffre par chiffre.', 'radio'),
    ('Comment énonce-t-on une altitude de 2500 ft ?', '« Deux mille cinq cents pieds »', '« Deux cinq zéro zéro »', '« Niveau deux cinq »', '« Vingt-cinq »', 'a', 'Les altitudes et hauteurs en milliers et centaines s''énoncent ainsi.', 'radio'),
    ('Quel est l''ordre normal d''un premier message à un organisme ?', 'Indicatif, puis météo', 'Bonjour, puis nom du pilote', 'Message, puis organisme', 'Organisme appelé, indicatif de l''avion, puis le message', 'd', 'Exemple : « Aix Tour, F-GABC, bonjour ».', 'radio'),
    ('Dans un premier contact pour transit, quels éléments donne-t-on ?', 'Uniquement le nom du pilote', 'Le numéro de licence', 'Type d''avion, provenance, destination, position, altitude et intentions', 'La couleur de l''avion', 'c', 'Le contrôleur a besoin de ces informations pour vous intégrer dans le trafic.', 'radio'),
    ('Que signifie l''annonce « information Charlie reçue » au premier contact ?', 'Que l''on a écouté le bulletin ATIS identifié par la lettre C', 'Qu''on a reçu la clairance C', 'Qu''on vole en classe C', 'Qu''on demande la piste C', 'a', 'Le contrôleur sait ainsi que le pilote connaît la piste, le vent et le QNH.', 'radio'),
    ('Que signifie ATIS ?', 'Service automatique d''information de région terminale', 'Assistance au trafic international', 'Alerte trafic en instruction', 'Aide technique d''information sol', 'a', 'L''ATIS diffuse en boucle les informations d''aérodrome, avec une lettre qui change à chaque mise à jour.', 'radio'),
    ('Que signifie AFIS ?', 'Service de contrôle d''aérodrome', 'Service automatique de météo', 'Assistance au vol en formation', 'Service d''information de vol d''aérodrome', 'd', 'L''agent AFIS informe, mais ne délivre pas de clairance.', 'radio'),
    ('Sur un aérodrome AFIS, l''agent peut-il vous donner une autorisation de décoller ?', 'Non, il donne des informations ; le pilote décide', 'Oui, toujours', 'Oui, s''il voit la piste', 'Oui, en été', 'a', 'Il n''y a pas de clairance en AFIS : le pilote annonce ses intentions.', 'radio'),
    ('Quel indicatif radio utilise une tour de contrôle ?', '« Information »', '« Tour »', '« Approche »', '« Contrôle »', 'b', 'Exemples : « Aix Tour », « Marseille Approche », « Provence Information ».', 'radio'),
    ('Quel indicatif radio utilise un service AFIS ?', '« Tour »', '« Information »', '« Sol »', '« Radar »', 'b', 'Exemple : « Arcachon Information ».', 'radio'),
    ('Sur un aérodrome sans organisme ni fréquence propre en France, quelle fréquence utilise-t-on ?', '121,500 MHz', '123,500 MHz en auto-information', '118,000 MHz', '123,450 MHz', 'b', 'Les messages commencent alors par le nom de l''aérodrome.', 'radio'),
    ('Comment commence le message de détresse ?', '« Pan Pan, Pan Pan, Pan Pan »', '« Mayday, Mayday, Mayday »', '« Sécurité » trois fois', '« Urgence »', 'b', 'Il est suivi de l''organisme appelé, de l''indicatif, de la nature de la détresse, des intentions, de la position, de l''altitude et du cap.', 'radio'),
    ('Sur quelle fréquence lancer un message de détresse ?', 'D''abord sur la fréquence en cours, sinon sur 121,500 MHz', 'Uniquement sur 123,450', 'Sur l''ATIS', 'Sur la fréquence de l''aéroclub', 'a', 'On garde la fréquence où l''on est déjà en contact, ce qui fait gagner du temps.', 'radio'),
    ('Qu''est-ce qu''un message « Pan Pan » ?', 'Un message de détresse', 'Un message de sécurité météo', 'Une annulation de plan de vol', 'Un message d''urgence : situation préoccupante sans danger grave et imminent', 'd', 'Exemple : passager malade, panne partielle qui impose un déroutement.', 'radio'),
    ('Que faire en cas de panne radio en vol VFR, hors espace contrôlé ?', 'Afficher 7500', 'Entrer dans la CTR la plus proche sans autorisation', 'Faire des cercles au-dessus d''une ville', 'Afficher 7600, continuer en VMC et se poser sur l''aérodrome le plus approprié', 'd', 'On applique la procédure publiée de l''aérodrome de destination si elle existe.', 'radio'),
    ('Que signifie l''instruction « Squawk ident » ?', 'Changer de code', 'Éteindre le transpondeur', 'Donner son indicatif', 'Appuyer sur le bouton IDENT du transpondeur', 'd', 'Le plot de l''avion est alors mis en évidence sur l''écran du contrôleur.', 'radio'),
    ('Que signifie « Rappelez vent arrière » ?', 'Faites demi-tour', 'Restez en vent arrière', 'Annoncez-vous à votre arrivée en vent arrière', 'Atterrissez', 'c', 'Le contrôleur attend un nouveau message à cette position.', 'radio'),
    ('Que veut dire « Autorisé à l''atterrissage » ?', 'Vous pouvez vous intégrer', 'Vous pouvez atterrir sur la piste indiquée', 'Vous pouvez rouler', 'Vous devez attendre', 'b', 'Le pilote collationne : « Autorisé atterrissage piste 32, F-FY ».', 'radio'),
    ('Que veut dire « Alignez-vous et attendez » ?', 'Vous êtes autorisé à décoller', 'Entrez sur la piste, alignez-vous et attendez l''autorisation de décoller', 'Restez au point d''arrêt', 'Faites un 360°', 'b', 'Ce n''est pas une autorisation de décoller.', 'radio'),
    ('Que faire si l''on n''est pas sûr d''avoir compris une clairance ?', 'L''appliquer au mieux', 'L''ignorer', 'Changer de fréquence', 'Demander au contrôleur de la répéter', 'd', 'Le doute doit toujours être levé avant d''agir.', 'radio'),
    ('Que signifie « Numéro deux » dans le circuit ?', 'Vous êtes autorisé à atterrir', 'Vous devez faire deux tours de piste', 'Vous êtes le deuxième dans l''ordre d''atterrissage, suivez l''avion qui vous précède', 'Piste numéro 2', 'c', 'On doit avoir en vue l''avion précédent et le suivre.', 'radio'),
    ('Que signifie « Remettez les gaz » ?', 'Augmentez légèrement la puissance en finale', 'Atterrissez vite', 'Coupez le moteur', 'Interrompez l''approche et montez', 'd', 'C''est une instruction à exécuter immédiatement.', 'radio'),
    ('Comment s''annonce-t-on en finale sur un aérodrome en auto-information ?', '« [Aérodrome], F-ABCD, finale piste 27, pour un complet »', '« Mayday »', '« Tour, autorisez-moi »', 'On ne s''annonce pas en finale', 'a', 'Les autres usagers savent ainsi où vous êtes et ce que vous allez faire.', 'radio'),
    ('Quand annonce-t-on « piste dégagée » ?', 'En finale', 'Au point d''arrêt avant décollage', 'Jamais', 'Après avoir quitté la piste', 'd', 'Cela informe les avions en approche que la piste est libre.', 'radio'),
    ('Quelle est la portée approximative d''une émission VHF ?', 'Illimitée', 'Toujours 10 km', 'Elle traverse les montagnes', 'La portée optique : elle augmente avec l''altitude', 'd', 'Ordre de grandeur : environ 1,23 × √(hauteur en ft) en NM, soit environ 60 NM à 2500 ft.', 'radio'),
    ('Pourquoi monter en altitude améliore-t-il la réception radio VHF ?', 'La VHF se propage en ligne droite ; plus haut, l''horizon radio est plus loin', 'L''air est plus sec', 'Le moteur fait moins de bruit', 'Ce n''est pas vrai', 'a', 'Les reliefs et la courbure de la Terre masquent les émissions en basse altitude.', 'radio'),
    ('Qu''est-ce que le mode S d''un transpondeur ?', 'Un mode qui transmet l''altitude, une adresse unique de l''avion et d''autres données', 'Un mode sans altitude', 'Un mode de secours', 'Un mode réservé aux militaires', 'a', 'Le mode C transmet le code et l''altitude pression ; le mode S y ajoute une adresse unique et des données.', 'radio'),
    ('Quand doit-on passer le transpondeur sur ALT (mode C ou S) ?', 'Jamais', 'Seulement en cas d''urgence', 'Seulement de nuit', 'En vol, et dans la plupart des cas dès le roulage selon les consignes de l''aérodrome', 'd', 'Il alimente les systèmes anticollision des autres aéronefs et l''écran radar.', 'radio'),
    ('En France, en VFR sans instruction particulière, quel code transpondeur ?', '7000', '7600', '2000', '0000', 'a', 'On affiche le code donné par le contrôleur lorsqu''il en attribue un.', 'radio'),
    ('Qu''est-ce qu''un « QSY » ?', 'Un changement de fréquence', 'Une demande de QNH', 'Une demande de relèvement', 'Une panne radio', 'a', 'On annonce par exemple : « Je quitte la fréquence, QSY 124,355 ».', 'radio'),
    ('Qu''est-ce que le QNH dans un message radio ?', 'La pression au sol de l''aérodrome', 'Le calage altimétrique pour lire l''altitude', 'Le relèvement de la station', 'La température', 'b', 'Il fait partie des éléments à collationner.', 'radio'),
    ('Qu''est-ce que le QFU ?', 'Le carburant restant', 'La fréquence de l''ATIS', 'L''orientation magnétique de la piste en service', 'La pression standard', 'c', 'Exemple : piste 14, QFU 143°.', 'radio'),
    ('Qu''est-ce que le QDM dans un message radio ?', 'Le cap magnétique à suivre par vent nul pour rejoindre la station', 'L''altitude', 'La vitesse', 'La distance', 'a', 'Le contrôleur peut le fournir grâce au radiogoniomètre.', 'radio'),
    ('Quelle annonce faire avant un exercice de panne simulée à la radio ?', '« Pour exercice »', '« Mayday »', '« Urgence »', 'Aucune', 'a', 'Cela évite le déclenchement d''une procédure réelle.', 'radio'),
    ('Sur un grand aérodrome contrôlé, quel organisme contacte-t-on en général pour rouler ?', 'L''Approche', 'Le SIV', 'Le Sol (GND)', 'Le BRIA', 'c', 'Exemple : à LFMA, le Sol est sur 121,605 ; on passe ensuite avec la Tour au point d''arrêt.', 'radio'),
    ('Que signifie « Quittez la fréquence, transpondeur 7000 » ?', 'Restez en contact', 'Appelez la tour', 'Panne radio', 'Vous n''êtes plus suivi, affichez 7000 et changez de fréquence', 'd', 'Le pilote collationne puis passe sur la fréquence suivante, par exemple celle du SIV.', 'radio'),
    ('Pourquoi garder ses messages courts dans le circuit d''aérodrome ?', 'Pour laisser la fréquence libre aux autres, notamment en cas d''urgence', 'Pour économiser la batterie', 'Pour la confidentialité', 'C''est interdit de parler longtemps', 'a', 'Une fréquence encombrée empêche les messages importants de passer.', 'radio'),
    ('Peut-on utiliser le français et l''anglais en radiotéléphonie en France ?', 'Non, seulement l''anglais', 'Non, seulement le français partout', 'Oui, sauf aérodromes ou fréquences publiés en français seulement', 'Oui, toutes les langues', 'c', 'Exemple : à LFMA, l''auto-information hors horaires ATS se fait en français seulement.', 'radio'),
    ('Quelle qualification faut-il pour communiquer en anglais en radiotéléphonie ?', 'Aucune', 'Un diplôme d''anglais universitaire', 'Une mention de compétence linguistique en anglais (FCL.055)', 'Une licence CPL', 'c', 'Le niveau minimal est le niveau 4 de l''OACI.', 'radio'),
    ('Que signifie l''expression « vent calme » ?', 'Un vent de 5 kt', 'Un vent inférieur à 1 kt environ', 'Un vent de face', 'Un vent variable', 'b', 'Dans les messages, on annonce « vent calme » quand le vent est négligeable.', 'radio'),
    ('Quelles sont les quatre forces qui s''exercent sur un avion en vol ?', 'Portance, gravité, vitesse, pression', 'Portance, poids, traction, traînée', 'Poussée, inertie, frottement, poids', 'Traction, compression, torsion, poids', 'b', 'En vol stabilisé rectiligne, la portance équilibre le poids et la traction équilibre la traînée.', 'aerodynamique'),
    ('Sur un profil d''aile, où la pression est-elle la plus faible en vol normal ?', 'Sur l''intrados (dessous de l''aile)', 'Sur l''extrados (dessus de l''aile)', 'Au bord de fuite', 'Elle est identique partout', 'b', 'La dépression sur l''extrados fournit la plus grande part de la portance.', 'aerodynamique'),
    ('Comment s''appelle le dessous de l''aile ?', 'L''extrados', 'Le saumon', 'L''intrados', 'L''emplanture', 'c', 'L''extrados est le dessus de l''aile.', 'aerodynamique'),
    ('Qu''est-ce que la corde d''un profil ?', 'L''épaisseur maximale du profil', 'La longueur de l''aile', 'La droite qui joint le bord d''attaque au bord de fuite', 'Le câble des ailerons', 'c', 'C''est la référence pour mesurer l''incidence.', 'aerodynamique'),
    ('Qu''est-ce que l''envergure ?', 'La distance d''un saumon d''aile à l''autre', 'La longueur du fuselage', 'La largeur de la corde', 'La hauteur de la dérive', 'a', 'Elle intervient dans le calcul de l''allongement.', 'aerodynamique'),
    ('Qu''est-ce que le saumon d''une aile ?', 'La jonction aile-fuselage', 'L''extrémité de l''aile', 'Le bord d''attaque', 'Un réservoir', 'b', 'La jonction avec le fuselage s''appelle l''emplanture.', 'aerodynamique'),
    ('Qu''est-ce qu''un tourbillon marginal ?', 'Un tourbillon en bout d''aile, dû au passage de l''air de l''intrados vers l''extrados', 'Une turbulence au sol', 'Un tourbillon d''hélice', 'Un courant ascendant', 'a', 'Il est à l''origine de la traînée induite et de la turbulence de sillage.', 'aerodynamique'),
    ('Quels avions génèrent la turbulence de sillage la plus forte ?', 'Les avions lourds, lents et en configuration lisse', 'Les avions légers rapides', 'Les planeurs', 'Les avions au roulage', 'a', 'La turbulence est maximale au décollage et à l''atterrissage des gros porteurs.', 'aerodynamique'),
    ('Comment se comportent les tourbillons de sillage derrière un gros avion ?', 'Ils descendent et dérivent avec le vent', 'Ils montent rapidement', 'Ils restent fixes au-dessus de la piste', 'Ils disparaissent instantanément', 'a', 'Près du sol ils s''étalent latéralement ; un léger vent traversier peut en maintenir un sur la piste.', 'aerodynamique'),
    ('Pour éviter la turbulence de sillage d''un gros avion qui vient d''atterrir, où se poser ?', 'Avant son point de toucher', 'Exactement au même point', 'Au-delà de son point de toucher', 'Sur le côté de la piste', 'c', 'Les tourbillons cessent au toucher. Au décollage derrière lui, on décolle avant son point de rotation.', 'aerodynamique'),
    ('Que se passe-t-il pour la traînée induite quand la vitesse augmente (en palier) ?', 'Elle augmente', 'Elle reste constante', 'Elle double', 'Elle diminue', 'd', 'À plus grande vitesse, l''incidence nécessaire est plus faible.', 'aerodynamique'),
    ('À quelle vitesse la traînée totale est-elle minimale ?', 'À la vitesse où traînées induite et parasite sont égales (finesse maximale)', 'À la vitesse maximale', 'À la vitesse de décrochage', 'Au roulage', 'a', 'C''est aussi la vitesse de meilleur plané.', 'aerodynamique'),
    ('Qu''est-ce que la finesse maximale ?', 'Le meilleur rapport portance sur traînée, qui donne la plus grande distance de plané', 'La vitesse maximale', 'La vitesse de décrochage', 'Le meilleur taux de montée', 'a', 'Un avion de finesse 10 parcourt 10 fois sa hauteur en plané.', 'aerodynamique'),
    ('Un avion de finesse 10 est à 3000 ft sol, moteur en panne, sans vent. Quelle distance peut-il parcourir environ ?', 'Environ 30 NM', 'Environ 5 NM', 'Environ 1 NM', 'Environ 15 NM', 'b', '3000 ft × 10 = 30 000 ft, soit environ 4,9 NM.', 'aerodynamique'),
    ('La masse de l''avion change-t-elle la distance maximale de plané ?', 'Oui, un avion lourd plane beaucoup plus loin', 'Oui, un avion léger plane deux fois plus loin', 'Non, seule la vitesse de meilleur plané change (plus élevée quand l''avion est lourd)', 'Oui, un avion lourd ne plane pas', 'c', 'La finesse dépend de l''incidence, pas de la masse.', 'aerodynamique'),
    ('Un vent de face en plané :', 'Réduit la distance parcourue par rapport au sol', 'Augmente la distance parcourue', 'N''a pas d''effet', 'Fait décrocher', 'a', 'La finesse air ne change pas, mais la vitesse sol diminue.', 'aerodynamique'),
    ('Qu''est-ce que le dièdre d''une aile ?', 'L''angle de calage', 'L''angle formé par les ailes relevées par rapport à l''horizontale', 'L''angle de flèche', 'L''angle de braquage des ailerons', 'b', 'Le dièdre améliore la stabilité en roulis.', 'aerodynamique'),
    ('Qu''est-ce que la flèche d''une aile ?', 'La courbure du profil', 'L''angle des ailes vers l''arrière par rapport à la perpendiculaire au fuselage', 'L''épaisseur', 'L''angle de dièdre', 'b', 'On la trouve surtout sur les avions rapides.', 'aerodynamique'),
    ('Que fait un volet de bord de fuite ?', 'Il réduit la portance', 'Il sert à virer', 'Il augmente la courbure du profil, donc la portance et la traînée', 'Il sert à freiner au sol uniquement', 'c', 'Les volets permettent de voler plus lentement et de descendre plus fort.', 'aerodynamique'),
    ('Qu''est-ce qu''un bec de bord d''attaque ?', 'Un dispositif qui retarde le décollement des filets d''air et augmente l''incidence de décrochage', 'Un réservoir', 'Un feu de navigation', 'Une antenne', 'a', 'Il permet de voler à plus forte incidence sans décrocher.', 'aerodynamique'),
    ('Quel est le rôle de l''empennage horizontal ?', 'Assurer l''équilibre et la stabilité en tangage', 'Assurer la portance principale', 'Virer', 'Freiner au sol', 'a', 'Il porte la gouverne de profondeur.', 'aerodynamique'),
    ('Quel est le rôle de la dérive ?', 'La stabilité en tangage', 'Assurer la stabilité en lacet', 'La portance', 'Le freinage', 'b', 'Elle porte la gouverne de direction.', 'aerodynamique'),
    ('Qu''est-ce qu''un tab (compensateur) sur une gouverne ?', 'Un feu de position', 'Une petite surface mobile qui annule l''effort du pilote sur la commande', 'Un aérofrein', 'Un réservoir d''huile', 'b', 'Il est actionné par la molette ou la commande de compensation.', 'aerodynamique'),
    ('Sur quel axe agit la gouverne de direction en effet secondaire ?', 'Le roulis : un lacet entraîne un roulis du même côté', 'Le tangage', 'Aucun', 'Le lacet inverse', 'a', 'En lacet, l''aile extérieure va plus vite et porte plus : l''avion s''incline du côté du lacet.', 'aerodynamique'),
    ('Qu''est-ce qu''un avion stable en tangage ?', 'Un avion qui revient de lui-même à son équilibre après une perturbation', 'Un avion qui garde la perturbation', 'Un avion qui diverge', 'Un avion sans profondeur', 'a', 'La stabilité dépend surtout de la position du centre de gravité devant le foyer.', 'aerodynamique'),
    ('Que se passe-t-il pour la vitesse de décrochage quand on sort les volets ?', 'Elle diminue', 'Elle augmente', 'Elle ne change pas', 'Elle double', 'a', 'C''est l''intérêt principal des volets à l''atterrissage.', 'aerodynamique'),
    ('Sur l''anémomètre, que représente la limite inférieure de l''arc blanc ?', 'Vs1, la vitesse de décrochage lisse', 'Vso, la vitesse de décrochage en configuration atterrissage', 'La VFE', 'La VNO', 'b', 'La limite basse de l''arc vert est Vs1 (décrochage configuration lisse).', 'aerodynamique'),
    ('Sur l''anémomètre, que représente l''arc jaune ?', 'La plage volets sortis', 'La plage d''utilisation avec prudence, en air calme seulement, entre VNO et VNE', 'La plage normale', 'La zone interdite', 'b', 'Au-delà du trait rouge (VNE), on risque la rupture de la structure.', 'aerodynamique'),
    ('Que représente la VNO ?', 'La vitesse maximale en utilisation normale, limite haute de l''arc vert', 'La vitesse à ne jamais dépasser', 'La vitesse de décrochage', 'La vitesse de rotation', 'a', 'Au-dessus de la VNO, on ne vole qu''en air calme.', 'aerodynamique'),
    ('En turbulence forte, à quelle vitesse vaut-il mieux voler ?', 'À la VNE', 'Dans l''arc jaune', 'À la vitesse de manœuvre (Va) ou en dessous', 'À la vitesse de décrochage', 'c', 'Au-dessous de Va, l''avion décroche avant de dépasser son facteur de charge limite.', 'aerodynamique'),
    ('Quel facteur de charge limite positif est exigé pour un avion de catégorie normale (CS-23) ?', '2 g', '6 g', '3,8 g', '10 g', 'c', 'La catégorie utilitaire va jusqu''à 4,4 g et la catégorie acrobatique jusqu''à 6 g.', 'aerodynamique'),
    ('La vitesse de manœuvre Va diminue-t-elle quand la masse de l''avion diminue ?', 'Non, elle augmente', 'Elle ne change jamais', 'Oui', 'Elle devient nulle', 'c', 'Plus léger, l''avion atteint plus vite son facteur de charge limite avant de décrocher.', 'aerodynamique'),
    ('Qu''est-ce que la masse volumique de l''air (ρ) ?', 'La pression de l''air', 'La vitesse du vent', 'La masse d''air par unité de volume', 'La température', 'c', 'Elle diminue avec l''altitude, la chaleur et l''humidité, ce qui réduit portance et puissance.', 'aerodynamique'),
    ('La vitesse indiquée (Vi) de décrochage change-t-elle avec l''altitude ?', 'Oui, elle double à 10 000 ft', 'Non, pour une masse donnée elle reste à peu près la même', 'Oui, elle devient nulle', 'Oui, elle diminue fortement', 'b', 'C''est la vitesse vraie de décrochage qui augmente avec l''altitude.', 'aerodynamique'),
    ('Pourquoi un avion peut-il « flotter » au-dessus de la piste juste avant le toucher ?', 'À cause d''une rafale descendante', 'Parce que le moteur accélère seul', 'À cause du gradient de température', 'À cause de l''effet de sol, qui réduit la traînée induite à moins d''une envergure du sol', 'd', 'Il fait « flotter » l''avion à l''arrondi et peut faire décoller un avion avant qu''il puisse vraiment monter.', 'aerodynamique'),
    ('Un virage au taux standard (taux 1) correspond à :', '3° par seconde, soit 360° en 2 minutes', '1° par seconde', '10° par seconde', '360° en 30 secondes', 'a', 'L''indicateur de virage porte un repère pour ce taux.', 'mecanique'),
    ('Quelle inclinaison approximative donne un virage au taux standard ?', 'Environ vitesse propre/10 + 7 (en degrés)', 'Toujours 45°', 'Toujours 10°', 'Vitesse × 2', 'a', 'Exemple : à 100 kt, environ 17° d''inclinaison.', 'mecanique'),
    ('À vitesse égale, comment varie le rayon de virage avec l''inclinaison ?', 'Il diminue quand l''inclinaison augmente', 'Il augmente', 'Il est constant', 'Il devient nul', 'a', 'Plus d''inclinaison donne plus de force déviatrice, donc un virage plus serré.', 'mecanique'),
    ('Pourquoi un demi-tour à basse hauteur après une panne au décollage est-il si dangereux ?', 'Il est trop long', 'Il fait consommer du carburant', 'Il n''est pas dangereux', 'Il fait perdre beaucoup de hauteur, à faible vitesse, avec un fort risque de décrochage et de vrille', 'd', 'C''est pour cela que l''on se pose à peu près droit devant.', 'mecanique'),
    ('En ressource (sortie de piqué), le facteur de charge :', 'Augmente, ainsi que la vitesse de décrochage', 'Diminue', 'Reste à 1', 'Devient négatif', 'a', 'Une ressource trop vive peut faire décrocher à vitesse élevée.', 'mecanique'),
    ('Que signifie un facteur de charge de 2 ?', 'L''avion vole deux fois plus vite', 'Les ailes portent deux fois le poids de l''avion', 'L''avion consomme deux fois plus', 'L''avion est à moitié plein', 'b', 'Les occupants se sentent deux fois plus lourds.', 'mecanique'),
    ('Quelle vitesse donne la meilleure pente de montée ?', 'Vy', 'Vne', 'Vx', 'Vno', 'c', 'Vx sert à franchir un obstacle ; Vy à prendre de l''altitude le plus vite possible.', 'mecanique'),
    ('En altitude, comment évoluent Vx et Vy (en vitesse indiquée) ?', 'Elles s''écartent', 'Elles se rapprochent jusqu''à se confondre au plafond absolu', 'Elles ne changent pas', 'Elles deviennent nulles', 'b', 'Au plafond absolu, l''excédent de puissance est nul.', 'mecanique'),
    ('Qu''est-ce que le plafond pratique d''un avion ?', 'L''altitude où le taux de montée maximal tombe à environ 100 ft/min', 'L''altitude maximale autorisée en VFR', 'L''altitude de la tropopause', 'L''altitude des nuages', 'a', 'Au plafond absolu, le taux de montée est nul.', 'mecanique'),
    ('En palier, pour voler plus vite, que doit-on faire ?', 'Augmenter l''assiette', 'Réduire la puissance', 'Sortir les volets', 'Augmenter la puissance et diminuer l''assiette', 'd', 'À plus grande vitesse, l''incidence nécessaire diminue.', 'mecanique'),
    ('Pourquoi la vitesse de décrochage augmente-t-elle en virage ?', 'La masse de l''avion change', 'Le facteur de charge augmente : il faut plus de portance', 'Le moteur est moins efficace', 'Elle n''augmente pas', 'b', 'Vs en virage = Vs × √n.', 'mecanique'),
    ('Comment varie la vitesse de décrochage avec un centrage avant ?', 'Elle diminue', 'Elle ne change pas', 'Elle augmente légèrement', 'Elle devient nulle', 'c', 'La déportance de l''empennage, plus forte, augmente la charge que l''aile doit porter.', 'mecanique'),
    ('Pourquoi un centrage arrière réduit-il la consommation ?', 'Il diminue la déportance de l''empennage, donc la traînée', 'Il augmente la puissance du moteur', 'Il allège l''avion', 'Il ne la réduit pas', 'a', 'Le guide ENAC en parle au niveau CPL, mais la stabilité diminue : rester dans les limites.', 'mecanique'),
    ('Qu''est-ce que le second régime de vol en approche ?', 'Une zone où il faut plus de puissance pour voler moins vite', 'Une zone où l''avion accélère seul', 'La vitesse de croisière', 'Un régime moteur', 'a', 'En approche lente, la vitesse se tient donc à la puissance.', 'mecanique'),
    ('Quelle force équilibre le poids en descente moteur réduit à vitesse constante ?', 'La traction', 'La portance seule', 'Aucune', 'La résultante de la portance et de la traînée', 'd', 'Sans traction, c''est une composante du poids qui entretient la vitesse ; la résultante aérodynamique équilibre le poids.', 'mecanique'),
    ('Quels sont les quatre temps d''un moteur à pistons ?', 'Allumage, refroidissement, graissage, échappement', 'Aspiration, injection, refroidissement, détente', 'Admission, compression, combustion-détente, échappement', 'Démarrage, montée, croisière, arrêt', 'c', 'Le cycle complet se fait en deux tours de vilebrequin.', 'moteur'),
    ('Pourquoi les moteurs d''avion ont-ils deux magnétos ?', 'Pour démarrer plus vite', 'Pour charger la batterie', 'Pour alimenter la radio', 'Pour la redondance et une meilleure combustion (deux bougies par cylindre)', 'd', 'Si une magnéto tombe en panne, le moteur continue de tourner sur l''autre.', 'moteur'),
    ('La magnéto a-t-elle besoin de la batterie pour fonctionner ?', 'Oui, toujours', 'Oui, en vol seulement', 'Non, elle produit son propre courant d''allumage', 'Oui, au démarrage seulement', 'c', 'C''est pour cela qu''un moteur peut tourner même avec la batterie coupée.', 'moteur'),
    ('Pourquoi ne faut-il jamais toucher une hélice même contact coupé ?', 'L''hélice est brûlante', 'Une magnéto mal reliée à la masse peut rester « chaude » et provoquer un démarrage', 'L''hélice est fragile', 'Pour ne pas la salir', 'b', 'On considère toujours une hélice comme dangereuse.', 'moteur'),
    ('À l''essai des magnétos, que contrôle-t-on ?', 'La pression d''huile seulement', 'La chute de régime sur chaque magnéto et l''écart entre les deux', 'Le niveau d''essence', 'La radio', 'b', 'Les valeurs admissibles sont données dans le manuel de vol ; une absence totale de chute est aussi anormale.', 'moteur'),
    ('Quand utilise-t-on le réchauffage carburateur ?', 'Uniquement au décollage', 'En permanence', 'Jamais', 'En cas de risque ou de symptôme de givrage, notamment à puissance réduite en air humide', 'd', 'On suit les consignes du manuel de vol.', 'moteur'),
    ('Quels sont les symptômes du givrage carburateur sur un moteur à hélice à pas fixe ?', 'Une hausse du régime', 'Une hausse de la pression d''huile', 'Une baisse progressive du régime et un fonctionnement irrégulier', 'Aucun', 'c', 'En appliquant le réchauffage, le régime baisse encore un peu puis remonte quand la glace fond.', 'moteur'),
    ('Pourquoi le réchauffage carburateur fait-il baisser un peu la puissance ?', 'Il coupe une magnéto', 'L''air chaud est moins dense et le mélange s''enrichit', 'Il ferme le papillon', 'Il ne la fait pas baisser', 'b', 'C''est aussi pour cela qu''on ne l''utilise pas à pleine puissance au décollage, sauf indication du manuel.', 'moteur'),
    ('Le réchauffage carburateur filtre-t-il l''air ?', 'Oui, toujours', 'Non, l''air chaud n''est en général pas filtré', 'Oui, deux fois', 'Il n''y a pas d''air', 'b', 'C''est pourquoi on évite de l''utiliser au sol sur terrain poussiéreux.', 'moteur'),
    ('Pourquoi appauvrit-on le mélange en altitude ?', 'Pour refroidir le moteur', 'Pour augmenter la vitesse', 'L''air est moins dense : sans réglage, le mélange devient trop riche', 'Ce n''est jamais nécessaire', 'c', 'Un mélange trop riche fait perdre de la puissance et encrasse les bougies.', 'moteur'),
    ('Qu''arrive-t-il si le mélange est trop pauvre à forte puissance ?', 'Le moteur tourne mieux', 'Surchauffe, détonation et risque de dommages moteur', 'Le moteur consomme plus', 'Rien', 'b', 'À forte puissance, un mélange riche aide à refroidir le moteur.', 'moteur'),
    ('Qu''est-ce que la détonation ?', 'Un allumage normal', 'Le bruit de l''échappement', 'Une combustion explosive et anormale du mélange dans le cylindre', 'Une panne de batterie', 'c', 'Elle est favorisée par un carburant inadapté, un mélange trop pauvre ou une surchauffe.', 'moteur'),
    ('Peut-on mettre du Jet A1 dans un moteur à essence d''avion léger classique ?', 'Oui, sans problème', 'Oui, en petite quantité', 'Oui, l''hiver', 'Non, cela provoque une panne moteur grave', 'd', 'Le Jet A1 est du kérosène, pour turbines et moteurs diesel aéronautiques. Toujours vérifier le carburant à l''avitaillement.', 'moteur'),
    ('Quelles sont les fonctions de l''huile moteur ?', 'Lubrifier, refroidir, nettoyer et assurer l''étanchéité', 'Uniquement lubrifier', 'Servir de carburant', 'Chauffer la cabine', 'a', 'On vérifie son niveau à chaque visite prévol.', 'moteur'),
    ('En vol, la pression d''huile chute et la température d''huile monte. Que faire ?', 'Ignorer', 'Monter en altitude', 'Se préparer à une panne moteur et se poser dès que possible', 'Réduire le mélange à fond', 'c', 'C''est le signe d''une perte d''huile ou d''une panne de lubrification.', 'moteur'),
    ('Que mesure l''EGT ?', 'La pression d''huile', 'La température de l''eau', 'La température des gaz d''échappement', 'La quantité d''essence', 'c', 'Elle aide à régler le mélange.', 'moteur'),
    ('Que mesure la CHT ?', 'La température des culasses', 'La pression d''admission', 'La tension électrique', 'Le débit d''essence', 'a', 'Une CHT trop élevée signale un mauvais refroidissement.', 'moteur'),
    ('Sur une hélice à calage variable (vitesse constante), quelle commande fixe le régime ?', 'La manette des gaz', 'La manette d''hélice', 'Le mélange', 'Le réchauffage carburateur', 'b', 'La manette des gaz règle alors la pression d''admission.', 'moteur'),
    ('Sur une hélice à vitesse constante, pour augmenter la puissance, quel ordre respecter ?', 'Mélange, hélice (régime), puis gaz', 'Gaz, puis hélice, puis mélange', 'Hélice seule', 'Gaz seuls', 'a', 'Pour réduire, on fait l''inverse : gaz, puis hélice, puis mélange.', 'moteur'),
    ('Sur un moteur à hélice à pas fixe, quel instrument indique la puissance ?', 'Le manomètre d''admission', 'L''EGT', 'Le voltmètre', 'Le compte-tours', 'd', 'Avec une hélice à vitesse constante, on utilise la pression d''admission et le régime.', 'moteur'),
    ('À quoi sert l''alternateur ?', 'À démarrer le moteur', 'À allumer les bougies', 'À produire le courant électrique et recharger la batterie en vol', 'À entraîner l''hélice', 'c', 'En cas de panne, la batterie seule n''alimente les équipements que pour une durée limitée.', 'moteur'),
    ('En cas de panne d''alternateur, que faire ?', 'Couper la batterie', 'Délester les équipements électriques non indispensables et écourter le vol', 'Rien', 'Monter plus haut', 'b', 'On garde l''énergie pour la radio et l''essentiel. Le moteur continue de tourner grâce aux magnétos.', 'moteur'),
    ('À quoi servent les disjoncteurs (breakers) ?', 'À protéger les circuits électriques contre les surintensités', 'À démarrer le moteur', 'À régler le mélange', 'À mesurer l''essence', 'a', 'Un disjoncteur déclenché peut être réenclenché une fois ; s''il déclenche à nouveau, on le laisse ouvert.', 'moteur'),
    ('Odeur de brûlé électrique en vol. Première action en général ?', 'Couper le contact général (master) selon la procédure du manuel', 'Ouvrir les portes', 'Augmenter la puissance', 'Couper les magnétos', 'a', 'Le moteur continue de tourner sans batterie ; on suit la check-list feu électrique.', 'moteur'),
    ('Feu moteur en vol : que prévoit en général la procédure ?', 'Augmenter la vitesse et continuer', 'Fermer l''essence, plein gaz jusqu''à l''arrêt du moteur, mélange étouffoir, couper le contact, puis atterrissage forcé', 'Ouvrir le capot', 'Relancer le moteur', 'b', 'Toujours appliquer la procédure exacte du manuel de vol de l''avion.', 'moteur'),
    ('Que signifie « avgas 100LL » ?', 'Essence sans plomb', 'Kérosène', 'Huile moteur', 'Essence aviation indice 100, à faible teneur en plomb (Low Lead)', 'd', 'D''autres carburants existent, comme l''UL91 sans plomb, pour les moteurs certifiés.', 'moteur'),
    ('Quelle est la masse volumique approximative de l''avgas ?', '1 kg par litre', '0,3 kg par litre', '1,5 kg par litre', 'Environ 0,72 kg par litre', 'd', '100 litres d''avgas pèsent donc environ 72 kg.', 'moteur'),
    ('Combien de litres dans un gallon américain (US gallon) ?', 'Environ 3,79 litres', '4,55 litres', '1 litre', '10 litres', 'a', 'Le gallon impérial (britannique) vaut environ 4,55 litres.', 'moteur'),
    ('Qu''est-ce que le potentiel d''un moteur ?', 'La puissance maximale', 'La consommation horaire', 'La durée de fonctionnement prévue avant révision générale', 'La durée de vie de l''hélice', 'c', 'On le suit dans les documents de l''avion.', 'moteur'),
    ('Quels instruments utilisent la pression statique ?', 'Uniquement l''anémomètre', 'Le compas', 'L''horizon artificiel', 'L''altimètre, le variomètre et l''anémomètre', 'd', 'L''anémomètre utilise aussi la pression totale de la prise Pitot.', 'instruments'),
    ('La prise statique se bouche en montée. Que fait l''altimètre ?', 'Il reste figé à l''altitude où le bouchage s''est produit', 'Il indique trop', 'Il tombe à zéro', 'Il oscille', 'a', 'Le variomètre indique alors zéro et l''anémomètre devient faux.', 'instruments'),
    ('La prise statique est bouchée et l''avion descend. L''anémomètre indique :', 'Une vitesse trop faible', 'Une vitesse trop élevée', 'Une vitesse juste', 'Zéro', 'b', 'La pression statique emprisonnée est plus faible que la pression réelle : l''écart mesuré augmente. En montée, il indique trop peu.', 'instruments'),
    ('Que se passe-t-il si l''on utilise la prise statique de secours dans la cabine (non pressurisée) ?', 'La pression y est un peu plus faible : altimètre et anémomètre indiquent légèrement trop', 'Rien ne change', 'Les instruments s''arrêtent', 'Le compas devient faux', 'a', 'Les corrections figurent dans le manuel de vol.', 'instruments'),
    ('Qu''est-ce que la vitesse indiquée (Vi ou IAS) ?', 'La vitesse lue sur l''anémomètre', 'La vitesse par rapport au sol', 'La vitesse vraie dans l''air', 'La vitesse du vent', 'a', 'C''est la vitesse qui compte pour le pilotage (décrochage, limitations).', 'instruments'),
    ('Comment évolue la vitesse vraie par rapport à la vitesse indiquée en altitude ?', 'Elle est plus faible', 'Elle est identique', 'Elle est plus élevée, d''environ 2 % par 1000 ft', 'Elle double à 1000 ft', 'c', 'Exemple : 100 kt indiqués à 5000 ft font environ 110 kt de vitesse vraie.', 'instruments'),
    ('Qu''est-ce que la vitesse sol ?', 'La vitesse indiquée', 'La vitesse sur la piste uniquement', 'La vitesse de l''avion par rapport au sol, vitesse vraie corrigée du vent', 'La vitesse du son', 'c', 'C''est elle qui détermine le temps de vol.', 'instruments'),
    ('Quelle est la propriété d''un gyroscope utilisée par l''horizon artificiel ?', 'La précession', 'La gravité', 'La rigidité dans l''espace', 'L''inertie thermique', 'c', 'La précession est à l''origine des dérives du directionnel.', 'instruments'),
    ('Comment sont souvent entraînés les gyroscopes de l''horizon et du directionnel sur un avion classique ?', 'Par la batterie uniquement', 'Par la prise Pitot', 'Par dépression (pompe à vide)', 'Par le vent', 'c', 'Un indicateur de dépression permet de vérifier leur alimentation. L''indicateur de virage est souvent électrique.', 'instruments'),
    ('Que vérifie-t-on sur l''indicateur de dépression ?', 'Que la dépression est dans la plage verte, pour le fonctionnement des gyroscopes', 'La pression d''huile', 'La pression cabine', 'La vitesse', 'a', 'Une dépression insuffisante rend l''horizon et le directionnel peu fiables.', 'instruments'),
    ('Que montre l''indicateur de virage et de dérapage ?', 'Le taux de virage et la symétrie (bille)', 'L''altitude', 'La vitesse', 'Le cap', 'a', 'L''aiguille ou la maquette indique le taux, la bille le dérapage.', 'instruments'),
    ('Quel est le principe de l''altimètre ?', 'Un radar vers le sol', 'Un baromètre anéroïde gradué en altitude selon l''atmosphère standard', 'Un GPS', 'Un gyroscope', 'b', 'C''est pour cela qu''il faut le caler correctement (QNH, QFE ou 1013).', 'instruments'),
    ('Le QNH passe de 1013 à 1003 hPa sans que le pilote recale l''altimètre. L''altimètre indique environ :', '280 ft de moins', 'La bonne altitude', '1000 ft de trop', '280 ft de trop', 'd', '10 hPa × 28 ft ≈ 280 ft. L''avion est plus bas que ce qu''indique l''altimètre.', 'instruments'),
    ('Qu''est-ce que l''altitude pression ?', 'L''altitude au-dessus du sol', 'L''altitude GPS', 'L''altitude lue avec l''altimètre calé sur 1013,25 hPa', 'L''altitude de l''aérodrome', 'c', 'Elle sert au calcul des performances.', 'instruments'),
    ('Qu''est-ce que l''altitude-densité ?', 'L''altitude au QNH', 'La hauteur des nuages', 'L''altitude de transition', 'L''altitude pression corrigée de l''écart de température à l''atmosphère standard', 'd', 'Plus elle est élevée, moins l''avion est performant.', 'instruments'),
    ('Pourquoi le variomètre présente-t-il un retard ?', 'Il est électrique', 'Il dépend du GPS', 'Il fonctionne par une fuite calibrée qui met un peu de temps à équilibrer les pressions', 'Il n''a pas de retard', 'c', 'D''où l''intérêt de piloter à l''assiette et non « aux aiguilles ».', 'instruments'),
    ('Dans l''hémisphère nord, face à l''est, on accélère. Que fait le compas ?', 'Il indique un virage vers le sud', 'Il indique un virage vers le nord', 'Il ne bouge pas', 'Il tourne de 180°', 'b', 'Moyen mnémotechnique : on accélère, il dévie vers le nord ; on décélère, il dévie vers le sud.', 'instruments'),
    ('Pourquoi un compas magnétique est-il rempli de liquide ?', 'Pour le refroidir', 'Pour amortir les oscillations de la rose', 'Pour le lubrifier', 'Pour éviter le gel', 'b', 'Le liquide stabilise la lecture.', 'instruments'),
    ('Qu''est-ce qu''un EFIS ou un PFD ?', 'Un moteur électrique', 'Un écran qui regroupe les instruments de vol principaux', 'Une radio', 'Un pilote automatique', 'b', 'Les avions récents (par exemple équipés de Garmin G1000) en sont dotés, avec des instruments de secours.', 'instruments'),
    ('Qu''est-ce qu''un AHRS ?', 'La centrale qui fournit l''attitude et le cap aux écrans électroniques', 'Une antenne radio', 'Un réservoir', 'Un type de carburant', 'a', 'Elle remplace les gyroscopes mécaniques sur les cockpits modernes.', 'instruments'),
    ('Que surveille-t-on sur l''ampèremètre ?', 'La charge ou la décharge de la batterie', 'La pression d''huile', 'L''altitude', 'La consommation d''essence', 'a', 'Une décharge en vol peut signaler une panne d''alternateur.', 'instruments'),
    ('Pourquoi faut-il chauffer la sonde Pitot en conditions givrantes sur les avions équipés ?', 'Pour réchauffer la cabine', 'Pour éviter qu''elle ne se bouche de glace', 'Pour améliorer la radio', 'Ce n''est jamais utile', 'b', 'Un Pitot givré fausse l''anémomètre.', 'instruments'),
    ('Qu''est-ce que la vitesse indiquée corrigée (Vc ou CAS) ?', 'La vitesse sol', 'La vitesse vraie', 'La vitesse du vent', 'La vitesse indiquée corrigée des erreurs d''installation et d''instrument', 'd', 'Le manuel de vol fournit un tableau de correction.', 'instruments'),
    ('Une jauge à essence d''avion léger est-elle une source fiable unique de la quantité de carburant ?', 'Oui, toujours', 'Oui, si elle est électrique', 'Non, on vérifie visuellement au sol et on gère le carburant au temps de vol', 'Oui, en croisière', 'c', 'Les jauges peuvent être imprécises : la gestion carburant se fait à la montre.', 'instruments'),
    ('À quoi sert la balise de détresse (ELT) ?', 'À guider l''atterrissage', 'À émettre un signal de détresse pour localiser l''avion après un accident', 'À communiquer avec la tour', 'À mesurer l''altitude', 'b', 'Les ELT modernes émettent sur 406 MHz (satellites) et 121,5 MHz (radioralliement).', 'instruments'),
    ('Que signifie l''acronyme IMSAFE, utilisé pour s''auto-évaluer avant un vol ?', 'Instruments, Moteur, Sécurité, Altitude, Fuel, Essence', 'Inspection, Météo, Sol, Avion, Fréquence, Équipage', 'Il n''existe pas', 'Illness, Medication, Stress, Alcohol, Fatigue, Emotion', 'd', 'C''est une check-list personnelle : maladie, médicaments, stress, alcool, fatigue, émotions.', 'securite'),
    ('Quelle règle pratique est couramment admise pour l''alcool avant un vol ?', 'Un verre est toléré juste avant le vol', 'L''alcool n''a pas d''effet en vol', 'Aucune boisson alcoolisée dans les 8 heures précédant le vol, et une alcoolémie nulle au départ', 'On peut boire si le vol est court', 'c', 'L''alcool dégrade le jugement et augmente la sensibilité à l''hypoxie et à la désorientation.', 'securite'),
    ('Combien de temps attendre avant de voler après une plongée sous-marine avec paliers de décompression ?', '1 heure', 'Aucun délai', 'Au moins 24 heures', '10 minutes', 'c', 'Sans paliers, on recommande au moins 12 heures. La baisse de pression en altitude favorise l''accident de décompression.', 'securite'),
    ('Quels sont les premiers symptômes d''une intoxication au monoxyde de carbone ?', 'Maux de tête, somnolence, nausées', 'Une forte faim', 'Une meilleure vision', 'Des douleurs aux genoux', 'a', 'Le CO, inodore, peut provenir du chauffage cabine ; on coupe le chauffage et on aère.', 'securite'),
    ('Pourquoi l''hypoxie est-elle si dangereuse ?', 'Elle est toujours douloureuse', 'Elle n''existe qu''au-dessus de 30 000 ft', 'Ses effets (euphorie, baisse du jugement) passent souvent inaperçus pour la personne atteinte', 'Elle donne faim', 'c', 'Le tabac et l''alcool abaissent le seuil d''apparition.', 'securite'),
    ('Qu''est-ce que l''« objectif destination » en facteurs humains ?', 'Un point de navigation', 'La piste en service', 'La volonté d''arriver à tout prix malgré une situation qui se dégrade', 'Un objectif de l''examen', 'c', 'C''est une cause fréquente d''accidents par météo dégradée.', 'securite'),
    ('Une piste qui monte vers le fond donne en approche l''illusion d''être :', 'Trop bas', 'À la bonne hauteur', 'Trop haut, ce qui pousse à descendre trop bas', 'Trop à gauche', 'c', 'À l''inverse, une piste en descente donne l''impression d''être trop bas.', 'securite'),
    ('Une piste plus étroite que d''habitude donne l''impression d''être :', 'Plus bas', 'Plus haut qu''en réalité, avec le risque d''une approche trop basse', 'Plus lent', 'Plus rapide', 'b', 'Une piste plus large donne l''impression d''être trop bas, d''où une approche haute.', 'securite'),
    ('Qu''est-ce que l''illusion somatogravique ?', 'Une sensation de virage en ligne droite', 'Une illusion d''optique sur la piste', 'Une accélération donne la sensation de cabrer, ce qui pousse à piquer', 'Un trouble de l''oreille dû au bruit', 'c', 'Elle est dangereuse au décollage de nuit ou sans visibilité : on fait confiance aux instruments.', 'securite'),
    ('En perte de références visuelles, pourquoi ne faut-il pas se fier à ses sensations ?', 'Parce qu''on a faim', 'Parce que la radio est coupée', 'L''oreille interne peut donner de fausses informations d''attitude', 'Il faut s''y fier', 'c', 'L''unique solution est de faire confiance à l''horizon artificiel.', 'securite'),
    ('Entrée involontaire en IMC en VFR. Quelle est la priorité ?', 'Continuer tout droit en espérant', 'Piloter aux instruments, ailes horizontales, puis faire demi-tour vers les conditions VMC', 'Descendre rapidement', 'Monter à pleine puissance', 'b', 'Le guide ENAC rappelle l''ordre : piloter, naviguer, communiquer. C''est une situation de détresse.', 'securite'),
    ('Selon le guide ENAC, à quelle inclinaison faire des virages en vol sans visibilité ?', '60°', '45°', '5°', 'Entre 15° et 20°', 'd', 'De faibles inclinaisons gardent une meilleure maîtrise de la trajectoire.', 'securite'),
    ('Pourquoi un avion sur trajectoire de collision est-il difficile à voir ?', 'Il reste immobile dans le champ de vision, alors que l''œil détecte surtout le mouvement', 'Il est toujours derrière vous', 'Il est toujours transparent', 'Il émet un bruit fort', 'a', 'Il peut aussi être caché par un montant de pare-brise.', 'securite'),
    ('Comment balayer efficacement le ciel ?', 'En regardant fixement un seul point', 'En balayant très vite', 'Par secteurs successifs, en marquant un temps d''arrêt sur chacun pour que l''œil accommode', 'En regardant uniquement devant', 'c', 'Le guide ENAC insiste sur la surveillance permanente, pas seulement avant les virages.', 'securite'),
    ('En montée ou en descente prolongée, comment améliorer la surveillance du ciel ?', 'Fermer les yeux un instant', 'Faire de légers virages pour voir sous le capot ou sous les ailes', 'Accélérer', 'Ne rien faire', 'b', 'Le fuselage masque une partie du ciel dans ces phases.', 'securite'),
    ('Qu''est-ce que le principe « voir et éviter » ?', 'Une procédure IFR', 'La responsabilité du pilote VFR de détecter et éviter les autres aéronefs', 'Une règle radio', 'Un système automatique', 'b', 'Le transpondeur et les dispositifs anticollision ne remplacent pas la surveillance visuelle.', 'securite'),
    ('Qu''est-ce qu''un REX ?', 'Un retour d''expérience, volontaire et en principe anonyme, partagé pour améliorer la sécurité', 'Un rapport d''examen', 'Une sanction', 'Un relevé d''heures', 'a', 'Il permet de partager une erreur ou une bonne pratique au bénéfice de tous.', 'securite'),
    ('Pourquoi la fatigue est-elle dangereuse en vol ?', 'Elle ralentit les réactions et dégrade le jugement', 'Elle améliore la concentration', 'Elle n''a aucun effet', 'Elle réduit la consommation', 'a', 'Le guide ENAC met en garde contre la saturation en fin de journée et la routine.', 'securite'),
    ('Qu''est-ce que la complaisance (excès de confiance) en facteurs humains ?', 'Un relâchement de la vigilance lié à la routine', 'Une politesse envers le contrôleur', 'Une technique de pilotage', 'Une procédure d''urgence', 'a', 'C''est une attitude dangereuse, au même titre que l''invulnérabilité ou l''impulsivité.', 'securite'),
    ('Quelles sont les cinq attitudes dangereuses classiques en facteurs humains ?', 'Prudence, patience, rigueur, calme, écoute', 'Fatigue, faim, soif, froid, chaleur', 'Anti-autorité, impulsivité, invulnérabilité, machisme, résignation', 'Il n''y en a pas', 'c', 'Chacune a son antidote : par exemple « ça n''arrive pas qu''aux autres » contre l''invulnérabilité.', 'securite'),
    ('Qu''appelle-t-on la conscience de la situation ?', 'La connaissance de la check-list', 'La lecture de la carte', 'Le niveau de carburant', 'La perception et la compréhension de ce qui se passe autour de soi, et l''anticipation de son évolution', 'd', 'Elle est nécessaire pour envisager les options et prendre la bonne décision.', 'securite'),
    ('Pourquoi la remise de gaz n''est-elle pas un échec ?', 'Elle prouve un manque de niveau', 'Elle est interdite', 'Elle coûte trop cher', 'C''est une bonne décision qui donne le temps de préparer une meilleure approche', 'd', 'Le guide ENAC insiste : l''instructeur ne doit pas inciter à atterrir après une approche non stabilisée.', 'securite'),
    ('Qu''est-ce que la pression temporelle ?', 'Le sentiment de devoir agir vite, qui pousse à des décisions hâtives', 'La pression de l''air', 'La pression d''huile', 'Le temps de vol restant', 'a', '« L''avion léger est un moyen de transport rapide pour gens peu pressés. »', 'securite'),
    ('Qu''est-ce qui distingue une panne sèche d''une panne d''alimentation en carburant ?', 'C''est la même chose', 'La panne sèche concerne l''huile', 'Aucune n''arrive en avion léger', 'Panne sèche : plus de carburant à bord ; panne d''alimentation : il en reste mais il n''arrive pas au moteur (mauvais réservoir, robinet…)', 'd', 'Une bonne gestion carburant et le choix du réservoir évitent les deux.', 'securite'),
    ('Avant la descente et l''atterrissage, sur quel réservoir se place-t-on en général ?', 'Sur le réservoir le moins plein', 'Les deux fermés', 'Sur le réservoir le plus plein', 'Peu importe', 'c', 'Le guide ENAC le cite dans la préparation de la descente.', 'securite'),
    ('Un passager se sent mal (nausées) en vol. Que faire en premier ?', 'Faire des virages serrés', 'Monter plus haut', 'Ignorer', 'Aérer la cabine, réduire les évolutions et envisager de rentrer', 'd', 'Les évolutions en basse couche turbulente et à température élevée favorisent les malaises.', 'securite'),
    ('Que doit contenir le briefing passagers avant le vol ?', 'Ceintures, portes et évacuation, objets à ne pas toucher, comportement en cas d''urgence', 'Uniquement l''heure d''arrivée', 'La météo complète', 'Rien', 'a', 'Le passager peut aussi aider à la surveillance du ciel.', 'securite'),
    ('Pourquoi fixer les objets et vérifier qu''aucun ne flotte en cabine avant un exercice ?', 'Pour le centrage seulement', 'Un objet libre peut bloquer les commandes ou blesser lors d''une évolution', 'Pour la radio', 'Ce n''est pas utile', 'b', 'Le guide ENAC le rappelle avant les décrochages et autres exercices.', 'securite'),
    ('Que faire en cas de collision aviaire au décollage avant la rotation ?', 'Continuer quoi qu''il arrive', 'Faire un virage', 'Couper la radio', 'Interrompre le décollage si la longueur de piste le permet', 'd', 'Le guide ENAC cite la collision avec un oiseau parmi les causes d''arrêt du décollage.', 'securite'),
    ('Porte mal verrouillée qui s''ouvre en vol sur un avion léger. Que faire ?', 'Lâcher les commandes pour fermer la porte', 'Sauter', 'Accélérer au maximum', 'Garder le contrôle de l''avion, réduire la vitesse et revenir se poser, sans chercher à refermer à tout prix', 'd', 'Sur la plupart des avions légers, une porte ouverte est bruyante mais rarement dangereuse si l''on continue à piloter.', 'securite'),
    ('Comment s''appelle la méthode de gestion des priorités « Aviate, Navigate, Communicate » en français ?', 'Parler, voler, rouler', 'Communiquer, piloter, atterrir', 'Piloter, naviguer, communiquer', 'Calculer, voler, communiquer', 'c', 'Le guide ENAC rappelle « Fly, navigate, communicate » en cas de perte des références extérieures.', 'securite'),
    ('Selon le guide ENAC, un vol en IMC involontaire doit être traité comme :', 'Une situation normale', 'Un exercice', 'Une situation de détresse (communications, transpondeur)', 'Une panne mineure', 'c', 'On utilise alors les services du contrôle aérien (radar, gonio) pour se faire aider.', 'securite'),
    ('Quels facteurs allongent la distance de décollage ?', 'Vent de face', 'Piste descendante', 'Température basse', 'Masse élevée, altitude et température élevées, herbe haute ou mouillée, vent arrière, piste montante', 'd', 'On utilise les abaques du manuel de vol avec une marge de sécurité.', 'performances'),
    ('Qu''est-ce que la TODA ?', 'La distance de roulement', 'La distance d''atterrissage', 'La distance utilisable au décollage : TORA plus le prolongement dégagé (clearway)', 'La longueur totale de l''aérodrome', 'c', 'ASDA = TORA + prolongement d''arrêt (stopway).', 'performances'),
    ('Qu''est-ce que l''ASDA ?', 'La distance d''atterrissage', 'La distance de roulement au décollage', 'La distance utilisable pour l''accélération-arrêt', 'La largeur de piste', 'c', 'C''est la TORA augmentée du prolongement d''arrêt éventuel.', 'performances'),
    ('Qu''est-ce que la LDA ?', 'La distance de décollage', 'La distance de roulage', 'La distance de visibilité', 'La distance utilisable à l''atterrissage', 'd', 'Elle peut être réduite par un seuil décalé.', 'performances'),
    ('Jusqu''à quelle hauteur la distance de décollage d''un avion léger est-elle en général mesurée ?', '300 m', '1 m', '15 m (50 ft)', '100 ft', 'c', 'Les distances d''atterrissage sont mesurées depuis le passage des 15 m.', 'performances'),
    ('Comment calcule-t-on l''altitude pression d''un aérodrome ?', 'Altitude du terrain × QNH', 'Altitude du terrain + (1013 - QNH) × environ 28 ft', 'Altitude du terrain - 1013', 'QNH × 10', 'b', 'Exemple : terrain à 500 ft, QNH 1003 : 500 + 10 × 28 = 780 ft.', 'performances'),
    ('Terrain à 1000 ft, QNH 1023. Quelle altitude pression environ ?', '720 ft', '1280 ft', '1000 ft', '23 ft', 'a', '1000 + (1013 - 1023) × 28 = 1000 - 280 = 720 ft.', 'performances'),
    ('À une altitude pression de 2000 ft, quelle est la température standard ?', '15°C', '7°C', '13°C', '11°C', 'd', '15 - 2 × 2 = 11°C.', 'performances'),
    ('Comment estimer l''altitude-densité ?', 'Altitude pression + environ 120 ft par degré au-dessus de la température standard', 'Altitude pression - 1000 ft', 'Altitude du terrain × 2', 'QNH + température', 'a', 'Exemple : Zp 1000 ft, 33°C (ISA + 20°C) : environ 1000 + 2400 = 3400 ft.', 'performances'),
    ('Une composante de vent de face au décollage :', 'L''allonge', 'Raccourcit la distance de décollage', 'N''a pas d''effet', 'Interdit le décollage', 'b', 'L''avion atteint plus tôt sa vitesse air de rotation.', 'performances'),
    ('Un vent arrière au décollage :', 'La raccourcit', 'N''a pas d''effet', 'Améliore la montée', 'Allonge fortement la distance de décollage', 'd', 'Quelques nœuds de vent arrière augmentent sensiblement la distance : on préfère la piste face au vent.', 'performances'),
    ('Une piste en herbe mouillée par rapport à une piste revêtue sèche :', 'Allonge la distance de décollage et d''atterrissage', 'La raccourcit', 'N''a pas d''effet', 'Améliore le freinage', 'a', 'Les manuels de vol donnent souvent des majorations pour l''herbe.', 'performances'),
    ('La vitesse maximale de vent traversier démontrée figure :', 'Dans le manuel de vol', 'Sur la VAC', 'Dans le carnet de route', 'Sur l''ATIS', 'a', 'C''est une valeur démontrée en essais, pas forcément une limite structurale, mais on la respecte.', 'performances'),
    ('Vent 270/20 pour une piste 22. Quelle composante traversière environ ?', '20 kt', '10 kt', '15 kt', '5 kt', 'c', 'Angle 50° : sin 50° ≈ 0,77 ; 20 × 0,77 ≈ 15 kt.', 'performances'),
    ('Pour une autonomie maximale (rester le plus longtemps en vol), à quelle vitesse vole-t-on ?', 'À la vitesse maximale', 'Près de la vitesse de puissance minimale nécessaire', 'À la vitesse de décrochage', 'À la VNE', 'b', 'Pour la distance maximale franchissable, on vole plutôt près de la vitesse de finesse maximale.', 'performances'),
    ('Consommation 25 l/h, vol prévu de 1 h 30 et réserve de 30 min. Quelle quantité minimale ?', '37,5 litres', '50 litres', '25 litres', '75 litres', 'b', '2 heures × 25 l/h = 50 litres, sans compter le roulage et une marge.', 'performances'),
    ('Avion avec 80 litres utilisables, consommation 20 l/h. Quelle autonomie ?', '2 heures', '8 heures', '4 heures', '1 heure', 'c', '80 / 20 = 4 heures, exemple classique de gestion carburant.', 'performances'),
    ('Comment calcule-t-on la position du centre de gravité ?', 'Masse totale divisée par les bras de levier', 'Somme des moments divisée par la masse totale', 'Somme des masses', 'Moyenne des bras de levier', 'b', 'Le résultat doit se trouver dans l''enveloppe du manuel de vol, au décollage comme à l''atterrissage.', 'performances'),
    ('Pourquoi vérifier le centrage aussi à l''atterrissage ?', 'Ce n''est pas nécessaire', 'Le carburant consommé déplace le centre de gravité', 'Pour le prix de l''atterrissage', 'Parce que les passagers changent de place', 'b', 'Selon la position des réservoirs, le centrage peut évoluer pendant le vol.', 'performances'),
    ('Une masse de 80 kg est placée à 2,0 m de la référence. Quel est son moment ?', '160 kg.m', '40 kg.m', '82 kg.m', '1600 kg.m', 'a', 'Moment = masse × bras de levier = 80 × 2,0 = 160 kg.m.', 'performances'),
    ('Masse totale 1000 kg, somme des moments 2300 kg.m. Où est le centre de gravité ?', 'À 23 m', 'À 0,43 m', 'À 2,30 m de la référence', 'À 230 m', 'c', 'CG = 2300 / 1000 = 2,30 m.', 'performances'),
    ('Qu''est-ce que la masse à vide d''un avion ?', 'La masse avec les pleins', 'La masse maximale', 'La masse de l''avion équipé, avec le carburant inutilisable et les fluides prévus, sans charge', 'La masse du moteur', 'c', 'Elle est déterminée par pesée et figure dans le dossier de masse et centrage.', 'performances'),
    ('Pourquoi ne pas dépasser la masse maximale au décollage ?', 'C''est seulement une recommandation', 'Pour économiser le carburant', 'Pour la radio', 'Elle garantit structure et performances certifiées', 'd', 'Au-delà, distances et taux de montée deviennent imprévisibles et la structure peut être en danger.', 'performances'),
    ('Quels documents de l''avion doivent être à bord ?', 'Certificat d''immatriculation, certificat de navigabilité et son examen de navigabilité valide (ARC), licence de station, assurance, carnet de route, manuel de vol', 'Uniquement le carnet de route', 'La facture d''achat', 'Aucun', 'a', 'On y ajoute le certificat acoustique et les documents de masse et centrage selon les cas.', 'documents'),
    ('Que signifie ARC ?', 'L''attestation de radio', 'Un plan de vol', 'Un certificat médical', 'Le certificat d''examen de navigabilité', 'd', 'Il atteste que l''avion a été examiné et reste navigable ; il doit être en cours de validité.', 'documents'),
    ('À quoi sert le carnet de route de l''avion ?', 'À noter les heures du pilote', 'À préparer la navigation', 'Au plan de vol', 'À consigner les vols, heures, carburant, huile et anomalies de l''avion', 'd', 'On y reporte aussi les incidents techniques constatés.', 'documents'),
    ('Quelle est la différence entre le carnet de route et le carnet de vol ?', 'C''est le même document', 'Le carnet de vol suit l''avion', 'Le carnet de route suit l''avion, le carnet de vol suit le pilote', 'Le carnet de route est facultatif', 'c', 'Chacun a son usage réglementaire.', 'documents'),
    ('Où trouve-t-on les procédures d''urgence d''un avion ?', 'Sur la VAC', 'Dans l''AIP', 'Sur le certificat d''immatriculation', 'Dans le manuel de vol (section 3 au format GAMA) et les check-lists', 'd', 'Les check-lists du club sont tirées du manuel de vol.', 'documents'),
    ('Que contient la section 2 d''un manuel de vol au format GAMA ?', 'Les procédures d''urgence', 'Les performances', 'La description des systèmes', 'Les limitations', 'd', 'Section 1 généralités, 2 limitations, 3 urgences, 4 procédures normales, 5 performances, 6 masse et centrage, 7 systèmes, 8 entretien, 9 suppléments.', 'documents'),
    ('Que contient la section 5 d''un manuel de vol au format GAMA ?', 'Les limitations', 'La masse et le centrage', 'Les performances', 'Les suppléments', 'c', 'Elle donne les abaques de décollage, montée, croisière et atterrissage.', 'documents'),
    ('Que contient la section 6 d''un manuel de vol au format GAMA ?', 'Les procédures normales', 'Les performances', 'L''entretien', 'La masse et le centrage', 'd', 'On y trouve l''enveloppe de centrage et les bras de levier.', 'documents'),
    ('Qu''est-ce qu''un SUP AIP ?', 'Un NOTAM d''urgence', 'Un supplément à l''AIP pour des modifications temporaires de longue durée ou comportant des cartes', 'Un plan de vol', 'Un manuel de vol', 'b', 'Exemple : activation d''une zone temporaire pour un meeting.', 'documents'),
    ('Qu''est-ce qu''une AIC ?', 'Un plan de vol', 'Une carte VAC', 'Une licence', 'Une circulaire d''information aéronautique', 'd', 'Elle diffuse des informations générales (techniques, administratives, réglementaires).', 'documents'),
    ('Qui édite l''AIP et les cartes VAC en France ?', 'Météo-France', 'L''aéroclub', 'Le SIA (Service de l''information aéronautique)', 'Le BEA', 'c', 'Les VAC sont disponibles gratuitement sur le site du SIA, à jour du cycle AIRAC.', 'documents'),
    ('Que contient la partie AD de l''AIP ?', 'Les règles de l''air générales', 'Les informations sur les aérodromes', 'Les espaces en route', 'Les tarifs', 'b', 'GEN : généralités ; ENR : en route ; AD : aérodromes.', 'documents'),
    ('Que contient la partie ENR de l''AIP ?', 'Les aérodromes', 'Les généralités administratives', 'Les cartes météo', 'Les informations en route : espaces aériens, zones réglementées, routes', 'd', 'Les zones de parachutage sont décrites en ENR 5.5.', 'documents'),
    ('Qu''est-ce qu''une fiche ICARUS de la FFA ?', 'Un plan de vol', 'Une licence', 'Une carte météo', 'Une fiche récapitulant les menaces identifiées sur un aérodrome', 'd', 'ICARUS : informations complémentaires d''aérodrome utiles à la sécurité.', 'documents'),
    ('Avant l''avitaillement, que faut-il faire pour éviter l''électricité statique ?', 'Relier l''avion à la masse (prise de terre)', 'Allumer la radio', 'Démarrer le moteur', 'Ouvrir les portes', 'a', 'Un extincteur doit être à proximité ; on ne fume pas.', 'sol'),
    ('Après l''avitaillement, pourquoi refaire une purge ?', 'Pour vérifier l''absence d''eau et la nature du carburant livré', 'Pour vider le réservoir', 'Pour refroidir le carburant', 'Ce n''est pas utile', 'a', 'Il faut aussi laisser décanter quelques minutes si possible.', 'sol'),
    ('Que vérifie-t-on sur l''hélice lors de la visite prévol ?', 'Uniquement sa couleur', 'Sa température', 'Rien', 'L''absence de criques, d''impacts et de jeu, et la bonne fixation du cône', 'd', 'Un impact sur une pale peut conduire à une rupture.', 'sol'),
    ('Pourquoi retirer la housse de la prise Pitot avant le vol ?', 'Sinon l''anémomètre ne fonctionne pas', 'Pour la propreté', 'Pour gagner du poids', 'Ce n''est pas nécessaire', 'a', 'L''oubli de la housse Pitot est un classique : elle fait partie de la check-list prévol.', 'sol'),
    ('Pourquoi enlever le givre ou la neige des ailes avant le décollage ?', 'Pour l''esthétique', 'Même une fine couche dégrade fortement la portance et augmente la vitesse de décrochage', 'Pour la radio', 'Ce n''est pas nécessaire', 'b', 'On ne décolle jamais avec des surfaces contaminées.', 'sol'),
    ('Que vérifie-t-on sur les pneus à la prévol ?', 'Leur couleur', 'Leur température', 'Le gonflage, l''usure et l''absence de coupures', 'Rien', 'c', 'Un pneu sous-gonflé dégrade le roulage et peut éclater.', 'sol'),
    ('Que signifie un marshaller qui croise les bras au-dessus de la tête ?', 'Avancez', 'Stop', 'Tournez à gauche', 'Coupez le moteur', 'b', 'C''est le signal d''arrêt ; on garde les freins prêts en suivant ses instructions.', 'sol'),
    ('À la fin du vol, quelles actions sont prévues avant de quitter l''avion ?', 'Couper les magnétos et le contact général, mettre les protections (housse Pitot…), remplir le carnet de route', 'Laisser la batterie branchée', 'Laisser les clés sur le tableau de bord', 'Partir sans rien noter', 'a', 'Le vol n''est vraiment terminé qu''avion au parking, moteur coupé, documents remplis.', 'sol'),
    ('Pourquoi amarrer un avion stationné dehors ?', 'Pour le protéger du vol', 'Pour la radio', 'Pour éviter qu''un coup de vent ne le déplace ou ne le retourne', 'Ce n''est jamais utile', 'c', 'On place aussi des cales et on bloque les commandes si l''avion en est équipé.', 'sol'),
    ('Pourquoi faut-il démarrer le moteur en ayant crié « hélice » ou « dégagez » et vérifié les abords ?', 'Pour s''assurer que personne n''est près de l''hélice', 'Pour prévenir la tour', 'Pour chauffer le moteur', 'C''est une tradition sans intérêt', 'a', 'L''hélice est le danger principal au sol.', 'sol'),
    ('Pourquoi ne pas mettre trop de puissance au roulage derrière un autre avion ou près d''un hangar ?', 'Pour économiser le moteur', 'Pour la radio', 'Le souffle de l''hélice peut endommager ou projeter des objets', 'Ce n''est pas un problème', 'c', 'On pense aussi aux personnes et aux avions derrière soi.', 'sol'),
    ('Avant le décollage, que vérifie-t-on lors des essais moteur ?', 'Uniquement la radio', 'La pression des pneus', 'Le niveau d''huile en le mesurant', 'Les magnétos, le réchauffage carburateur, les paramètres moteur et le ralenti', 'd', 'Les essais se font face au vent, freins serrés, sans souffler sur d''autres avions.', 'sol'),
    ('Que vérifie-t-on sur les commandes avant le décollage ?', 'Leur liberté et leur débattement complet dans le bon sens', 'Uniquement la couleur', 'Leur température', 'Rien', 'a', 'On vérifie aussi que les blocages de commandes ont été retirés.', 'sol'),
    ('Qui a réalisé le premier vol en hydravion depuis l''eau, en 1910 près de Martigues ?', 'Louis Blériot', 'Henri Fabre', 'Roland Garros', 'Clément Ader', 'b', 'Le 28 mars 1910, sur l''étang de Berre, avec son « Canard ».', 'culture'),
    ('Quel aviateur a traversé la Méditerranée pour la première fois en avion, en 1913 ?', 'Jean Mermoz', 'Louis Blériot', 'Charles Lindbergh', 'Roland Garros', 'd', 'Il a relié Fréjus à Bizerte le 23 septembre 1913.', 'culture'),
    ('Quel écrivain aviateur a disparu en mer en 1944 au large de Marseille ?', 'Jean Mermoz', 'Antoine de Saint-Exupéry', 'Henri Guillaumet', 'Joseph Kessel', 'b', 'Il a disparu le 31 juillet 1944 à bord d''un P-38 lors d''une mission de reconnaissance.', 'culture'),
    ('Quel livre a écrit Antoine de Saint-Exupéry sur le vol de nuit postal ?', 'L''Équipage', 'Vol de nuit', 'Le Grand Cirque', 'Les Chevaliers du ciel', 'b', 'Il a aussi écrit « Terre des hommes », « Courrier sud » et « Le Petit Prince ».', 'culture'),
    ('Pour quelle compagnie Mermoz, Saint-Exupéry et Guillaumet ont-ils volé ?', 'L''Aéropostale (Lignes Latécoère)', 'Air France dès sa création seulement', 'Air Inter', 'La Patrouille de France', 'a', 'Ils ont ouvert les lignes postales vers l''Afrique et l''Amérique du Sud.', 'culture'),
    ('Où est basée la Patrouille de France ?', 'À Orange', 'À Istres', 'À Salon-de-Provence', 'À Cognac', 'c', 'Elle est rattachée à la base aérienne 701, qui accueille aussi l''École de l''air et de l''espace.', 'culture'),
    ('Quel avion utilise la Patrouille de France ?', 'Le Rafale', 'Le Mirage 2000', 'Le Fouga Magister', 'L''Alpha Jet', 'd', 'Elle a volé sur Fouga Magister avant l''Alpha Jet, adopté en 1981.', 'culture'),
    ('Qui a réalisé le premier vol humain en montgolfière libre, en 1783 ?', 'Les frères Wright', 'Clément Ader', 'Pilâtre de Rozier et le marquis d''Arlandes', 'Louis Blériot', 'c', 'Le 21 novembre 1783, au départ du château de la Muette à Paris.', 'culture'),
    ('Comment s''appelait l''appareil de Clément Ader qui a quitté le sol en 1890 ?', 'L''Éole', 'Le Flyer', 'Le 14-bis', 'Le Spirit of St. Louis', 'a', 'C''est un saut sur une cinquantaine de mètres, non contrôlé, considéré comme le premier décollage d''un plus lourd que l''air motorisé.', 'culture'),
    ('Qui a franchi le premier le mur du son, en 1947 ?', 'Neil Armstrong', 'Charles Lindbergh', 'Chuck Yeager', 'Amelia Earhart', 'c', 'À bord du Bell X-1, le 14 octobre 1947.', 'culture'),
    ('Quelle aviatrice a traversé l''Atlantique seule pour la première fois en 1932 ?', 'Hélène Boucher', 'Adrienne Bolland', 'Amelia Earhart', 'Jacqueline Auriol', 'c', 'Elle a disparu en 1937 au-dessus du Pacifique lors d''un tour du monde.', 'culture'),
    ('Quelle aviatrice française a franchi la cordillère des Andes en 1921 ?', 'Maryse Bastié', 'Adrienne Bolland', 'Hélène Boucher', 'Jacqueline Auriol', 'b', 'Elle a traversé les Andes sur un Caudron G.3 le 1er avril 1921.', 'culture'),
    ('En quelle année le Concorde a-t-il effectué son premier vol ?', '1969', '1976', '1959', '1985', 'a', 'Le premier vol a eu lieu le 2 mars 1969 à Toulouse ; la mise en service commercial date de 1976.', 'culture'),
    ('Quel avion Alberto Santos-Dumont a-t-il fait voler à Bagatelle en 1906 ?', 'L''Éole', 'Le Flyer', 'Le 14-bis', 'Le Blériot XI', 'c', 'C''est l''un des premiers vols homologués en Europe.', 'culture'),
    ('Que signifie FFA ?', 'Force française aérienne', 'Fédération française aéronautique', 'Formation fédérale avion', 'Fédération des fabricants d''avions', 'b', 'Elle fédère les aéroclubs et organise la formation, les compétitions et le REX.', 'culture'),
    ('Que signifie BIA ?', 'Brevet d''initiation aéronautique', 'Bureau d''information aéronautique', 'Brevet international d''aviateur', 'Base d''instruction aérienne', 'a', 'C''est un diplôme destiné surtout aux jeunes, qui ouvre à la culture aéronautique.', 'culture'),
    ('Quel constructeur français fabrique les avions DR400 ?', 'Dassault', 'Airbus', 'Socata', 'Robin', 'd', 'Les Robin DR400 sont issus des Jodel et produits près de Dijon.', 'culture'),
    ('Quelle est la particularité de l''aile des Robin DR400 ?', 'Une aile haute', 'Une partie centrale plate et des extrémités relevées (dièdre en bout d''aile, aile « Jodel »)', 'Une aile en flèche', 'Une aile delta', 'b', 'Cette aile à dièdre externe est typique des Jodel et des Robin.', 'culture'),
    ('Le Cessna 152 est :', 'Un quadriplace à aile basse', 'Un biplace à aile haute', 'Un bimoteur', 'Un hydravion', 'b', 'C''est l''un des avions école les plus répandus au monde.', 'flotte'),
    ('Le Robin DR400 est en général :', 'Un biplace à aile haute', 'Un bimoteur à train rentrant', 'Un planeur', 'Un quadriplace à aile basse et train tricycle fixe', 'd', 'Sa structure est en bois et toile pour les versions classiques.', 'flotte'),
    ('Quelle est la particularité du Cirrus SR22 en matière de sécurité ?', 'Deux moteurs', 'Une aile haute', 'Un train classique', 'Un parachute de cellule (CAPS) qui peut descendre tout l''avion', 'd', 'Le parachute s''utilise selon des critères précis décrits dans le manuel.', 'flotte'),
    ('Le Diamond DA40 est construit principalement en :', 'Matériaux composites', 'Bois et toile', 'Acier', 'Aluminium riveté uniquement', 'a', 'Il existe en version essence et en version diesel (Jet A1).', 'flotte'),
    ('Qu''est-ce qu''un avion à train classique ?', 'Un avion à roulette de queue', 'Un avion à roue avant', 'Un avion à flotteurs', 'Un avion à train rentrant', 'a', 'Il est plus délicat au roulage et à l''atterrissage, car son centre de gravité est derrière le train principal.', 'flotte'),
    ('Qu''est-ce qu''un avion à train tricycle ?', 'Un avion à roulette de queue', 'Un avion à trois moteurs', 'Un avion avec une roue avant et deux roues principales', 'Un hydravion', 'c', 'Il est stable au roulage, son centre de gravité étant devant le train principal.', 'flotte'),
    ('Le Piper PA-28 et le Cessna 172 diffèrent principalement par :', 'La position de l''aile : basse sur le PA-28, haute sur le C172', 'Le nombre de moteurs', 'Le type de train', 'Le carburant', 'a', 'L''aile haute offre une bonne visibilité vers le bas, l''aile basse une meilleure visibilité vers le haut en virage.', 'flotte'),
    ('Sur un avion à aile haute, où se trouvent en général les réservoirs ?', 'Dans les ailes, au-dessus du moteur, ce qui permet souvent une alimentation par gravité', 'Sous le plancher', 'Dans le moteur', 'Il n''y en a pas', 'a', 'Sur aile basse, une pompe est nécessaire pour monter le carburant au moteur.', 'flotte'),
    ('Pourquoi un avion à aile basse a-t-il une pompe à carburant électrique de secours ?', 'Pour remplir les réservoirs', 'Pour refroidir le moteur', 'Pour la radio', 'Le carburant doit être aspiré vers le moteur situé au-dessus des réservoirs', 'd', 'On l''utilise en général au décollage, à l''atterrissage et lors des changements de réservoir.', 'flotte'),
    ('Combien d''heures de double commande minimum dans la formation PPL(A) ?', '25 heures', '10 heures', '45 heures', '5 heures', 'a', 'Sur les 45 h minimales, au moins 25 h en double commande et 10 h en solo supervisé.', 'general'),
    ('Combien d''heures de solo supervisé minimum dans la formation PPL(A) ?', '10 heures', '25 heures', '3 heures', '20 heures', 'a', 'Dont au moins 5 h de navigation en solo.', 'general'),
    ('Combien d''heures de double commande minimum dans la formation LAPL(A) ?', '25 heures', '5 heures', '15 heures', '30 heures', 'c', 'Sur 30 h minimum, dont 6 h de solo supervisé.', 'general'),
    ('Qu''est-ce que le livret de progression de l''élève ?', 'Le carnet de route de l''avion', 'Le manuel de vol', 'La licence', 'Le document où l''instructeur consigne les leçons, commentaires et acquis', 'd', 'Il accompagne l''élève tout au long de sa formation.', 'general'),
    ('Combien de sections compte l''épreuve pratique de la licence LAPL ou PPL ?', '5 sections', '2 sections', '10 sections', '1 seule', 'a', 'Si 4 sections sur 5 sont réussies, on ne repasse que la section échouée.', 'general'),
    ('Lors de l''épreuve pratique, que se passe-t-il en cas d''échec à deux rubriques de deux sections différentes ?', 'On repasse seulement une rubrique', 'Le test est un échec', 'Rien', 'On obtient la licence quand même', 'b', 'Une rubrique échouée peut être retentée une fois ; au second échec, elle et sa section sont invalidées.', 'general'),
    ('Dans quel ordre le guide ENAC structure-t-il chaque leçon en vol ?', 'Exercices, perception, briefing', 'Bilan, briefing, vol', 'Vol, débriefing, briefing', 'Perception (montrer), actions (guider), exercices (demander)', 'd', 'Pendant les exercices, l''instructeur devient un observateur silencieux pour évaluer objectivement l''élève.', 'general'),
    ('Selon le guide ENAC, quelle erreur classique commet l''instructeur pendant la phase d''exercices ?', 'Laisser l''élève voler seul', 'Continuer à guider l''élève', 'Faire un bilan', 'Préparer le vol suivant', 'b', 'Si des guidages sont nécessaires, c''est qu''il faut revenir à la phase « actions ».', 'general'),
    ('Quelles sont les grandes parties de la progression du pilote VFR selon le guide ENAC ?', 'Pilotage élémentaire, pilotage précis, phases et procédures particulières du vol, puis navigation', 'Théorie seule', 'Navigation d''abord, pilotage ensuite', 'Radio uniquement', 'a', 'La phraséologie et la navigation se superposent à la progression en pilotage.', 'general'),
    ('Que doit maîtriser l''élève en radio avant le premier lâcher, selon le guide ENAC ?', 'Rien, l''instructeur s''en charge', 'Uniquement le bonjour', 'Toute la phraséologie adaptée aux organismes locaux', 'Uniquement l''anglais', 'c', 'Toutes les procédures radio et la phraséologie doivent être maîtrisées avant le test.', 'general'),
    ('Qu''appelle-t-on « lâcher » en aéroclub ?', 'La remise de la licence', 'Un atterrissage sans moteur', 'Le premier vol seul à bord, ou l''autorisation de piloter seul un type d''avion', 'L''arrêt de la formation', 'c', 'Au club, on parle aussi de lâcher machine : l''autorisation de voler seul sur un avion donné.', 'general'),
    ('Pourquoi un pilote doit-il être lâché sur chaque type d''avion du club ?', 'Chaque avion a ses particularités (vitesses, systèmes, procédures) qu''il faut connaître', 'C''est une obligation commerciale', 'Pour payer moins cher', 'Ce n''est pas nécessaire', 'a', 'La formation aux différences ou de familiarisation est prévue par la réglementation (FCL.710).', 'general'),
    ('Que sont les « compétences de base » du pilote selon l''approche moderne de la formation ?', 'Pilotage, trajectoire, communication, conscience de la situation, décision, gestion des menaces', 'Uniquement le pilotage manuel', 'La lecture de la carte', 'La mécanique', 'a', 'Le guide ENAC insiste sur le TEM, la conscience de situation et la prise de décision à côté du pilotage.', 'general'),
    ('Sur quelle fréquence écoute-t-on l''ATIS d''Aix-les-Milles ?', '118,755', '136,230', '121,605', '124,355', 'b', 'D''après la carte VAC LFMA, l''ATIS est sur 136,230. On l''écoute avant le premier contact pour connaître la piste en service et le QNH.', 'lfma'),
    ('Quelle est la fréquence du SOL (GND) d''Aix-les-Milles ?', '118,755', '136,230', '123,500', '121,605', 'd', 'Carte VAC LFMA : GND (SOL) 121,605, TWR 118,755.', 'lfma'),
    ('En l''absence des services ATS à Aix-les-Milles, quelle fréquence utilise-t-on en auto-information ?', '118,755, en français seulement', '123,500', '121,500', '136,230', 'a', 'La VAC indique : absence ATS, A/A sur 118,755, en français uniquement.', 'lfma'),
    ('Quelle est la fréquence de PROVENCE Approche indiquée sur la VAC de LFMA ?', '118,755', '136,230', '124,355', '121,605', 'c', 'PROVENCE Approche 124,355, au-dessus de 2500 ft et sur instruction du contrôle seulement.', 'lfma'),
    ('Quelle est la déclinaison magnétique indiquée sur la carte VAC de LFMA ?', '3° Ouest', '3° Est', '10° Est', '0°', 'b', 'La VAC donne VAR 3° E (2025).', 'lfma'),
    ('La VAC indique « ALT AD : 368 (14 hPa) ». Que représentent les 14 hPa ?', 'L''écart approximatif entre QNH et QFE à l''altitude du terrain', 'La pression à l''altitude de transition', 'L''erreur de l''altimètre de bord', 'Le QNH du jour', 'a', '368 ft divisés par environ 27 ft/hPa donnent environ 14 hPa : le QFE vaut environ QNH - 14 hPa.', 'lfma'),
    ('Quelle piste est préférentielle à Aix-les-Milles ?', 'La piste 14', 'Aucune', 'La piste 32, en raison des conditions météorologiques locales', 'La piste en herbe', 'c', 'Consignes particulières de la VAC : RWY 32 préférentielle, cause conditions météorologiques locales.', 'lfma'),
    ('Quels sont les QFU exacts des pistes d''Aix-les-Milles ?', '143° et 323°', '140° et 320°', '130° et 310°', '090° et 270°', 'a', 'D''après la VAC (AMDT 11/26), la piste 14 a un QFU de 143° et la piste 32 de 323°.', 'lfma'),
    ('Quelle est la LDA de la piste 32 à Aix-les-Milles ?', '1248 m', '1481 m', '1604 m', '1124 m', 'd', 'Carte VAC LFMA : LDA 1124 m en piste 32 et 1248 m en piste 14.', 'lfma'),
    ('Quelle est la TODA de la piste 32 à Aix-les-Milles ?', '1124 m', '1248 m', '2000 m', '1481 m', 'd', 'Carte VAC LFMA : TODA et ASDA de 1481 m en piste 32 ; en piste 14, TODA 1372 m et ASDA 1475 m.', 'lfma'),
    ('Quel est l''angle du PAPI à Aix-les-Milles ?', '2,0°', '4,5°', '3,0° (5,2 %)', 'Il n''y a pas de PAPI', 'c', 'La VAC indique PAPI 3,0° (5,2 %) sur les deux pistes.', 'lfma'),
    ('Quel type d''aéronef est interdit sur l''aérodrome d''Aix-les-Milles ?', 'Les hélicoptères', 'Les avions de plus de 3 t', 'Les planeurs', 'Les avions électriques', 'c', 'Conditions d''utilisation de la VAC : AD réservé aux aéronefs munis de radio et interdit aux planeurs.', 'lfma'),
    ('Quels ULM sont autorisés à Aix-les-Milles ?', 'Toutes les classes', 'Aucun ULM', 'Seulement les paramoteurs', 'Seulement les classes 3 et 6', 'd', 'D''après la VAC, seuls les ULM de classes 3 (multiaxes) et 6 (hélicoptères ultralégers) sont autorisés.', 'lfma'),
    ('Côté piste à Aix-les-Milles, quel équipement est obligatoire pour les personnes ?', 'Un casque antibruit', 'Une radio portable', 'Un badge de l''aéroclub', 'Un gilet haute visibilité', 'd', 'La VAC impose le port d''un gilet haute visibilité côté piste.', 'lfma'),
    ('À LFMA, combien de temps avant d''entrer dans la CTR faut-il établir le premier contact ?', 'Au moins 30 secondes avant', 'Au moins 15 minutes avant', 'Au moins 3 minutes avant', 'Après l''entrée', 'c', 'Arrivées : le premier contact doit être établi au moins 3 minutes avant l''entrée dans la CTR.', 'lfma'),
    ('À l''arrivée sur LFMA, de quel côté se fait le circuit standard, pour les deux pistes ?', 'À l''Ouest des installations', 'Au Nord', 'À l''Est des installations', 'Au choix du pilote', 'c', 'ARR RWY 14 et 32 : circuit à l''Est des installations, à 1500 ft AMSL (1100 ft sol).', 'lfma'),
    ('À quelle altitude se fait le circuit d''arrivée à l''Est de LFMA ?', '1000 ft AMSL', '2500 ft AMSL', '1500 ft AMSL, soit 1100 ft au-dessus du terrain', '900 ft AMSL', 'c', 'La VAC indique 1500 ft AMSL (1100 ft) en passant à la verticale du centre commercial.', 'lfma'),
    ('À l''arrivée en piste 32 à LFMA, quel site faut-il éviter de survoler ?', 'Le centre commercial', 'La prison de Luynes, à éviter par le Sud', 'La gare TGV', 'L''autoroute A8', 'b', 'Consigne VAC : ARR RWY 32, éviter la prison de Luynes par le Sud.', 'lfma'),
    ('Au départ de la piste 14 à LFMA, quelle trajectoire suivre ?', 'Virer à droite immédiatement', 'Monter dans l''axe, puis virer à gauche au-delà de la prison de Luynes en la contournant par le Sud', 'Virer à gauche dès 300 ft', 'Monter dans l''axe jusqu''à 3000 ft', 'b', 'Départ RWY 14 : monter dans l''axe puis virer à gauche après avoir contourné la prison de Luynes par le Sud.', 'lfma'),
    ('Au départ de la piste 32 à LFMA, sauf clairance contraire, que fait-on ?', 'Monter dans l''axe puis virer à droite', 'Virer à gauche immédiatement', 'Faire un tour de piste obligatoire', 'Monter vers AW', 'a', 'Départ RWY 32 : sauf clairance contraire, monter dans l''axe puis virer à droite.', 'lfma'),
    ('À LFMA, les départs et arrivées par AW et AS sont possibles :', 'Librement', 'Jamais', 'Sur clairance ATC uniquement', 'Seulement le week-end', 'c', 'AS (Ouest de Cabriès) et AW (aqueduc de Roquefavour) ne sont utilisés que sur instruction du contrôle.', 'lfma'),
    ('Que représente le point de compte rendu AW autour de LFMA ?', 'La cheminée de Gardanne', 'Le carrefour Est d''Eguilles', 'La bretelle A8 Aix Ouest', 'L''aqueduc de Roquefavour', 'd', 'AW est l''aqueduc de Roquefavour, utilisé sur instruction ATC.', 'lfma'),
    ('Que représente le point de compte rendu AE autour de LFMA ?', 'Le Nord de la cheminée de Gardanne', 'L''aqueduc de Roquefavour', 'L''Ouest de Cabriès', 'Le carrefour Est d''Eguilles', 'a', 'AE : Nord cheminée de Gardanne.', 'lfma'),
    ('Que représente le point de compte rendu AT autour de LFMA ?', 'La cheminée de Gardanne', 'Le carrefour Est d''Eguilles', 'L''aqueduc de Roquefavour', 'L''Ouest de Cabriès', 'b', 'AT : carrefour Est d''Eguilles. AN est au travers Est de la tour de guet incendie Ouest d''Eguilles.', 'lfma'),
    ('Quel point de compte rendu de LFMA est associé à la procédure de panne radio ?', 'AW', 'AR, la bretelle de l''A8 Aix Ouest', 'AE', 'AN', 'b', 'AR est la bretelle autoroute A8 Aix Ouest, point de la procédure panne radio.', 'lfma'),
    ('En panne radio à l''arrivée, avant tout contact, que faut-il faire selon la VAC de LFMA ?', 'Afficher 7600 et ne pas pénétrer dans la CTR', 'Entrer dans la CTR et se poser', 'Afficher 7700 et faire un tour de piste', 'Survoler la tour en battant des ailes', 'a', 'Hors CTR, sans autorisation préalable, on ne pénètre pas dans la CTR.', 'lfma'),
    ('En panne radio après avoir été autorisé à entrer dans la CTR de LFMA, que faire ?', 'Rejoindre AW et attendre', 'Atterrir directement en piste 14', 'Quitter la CTR par le Nord', 'Rejoindre AR à 2200 ft AMSL maximum, phares allumés, puis suivre le 228° jusqu''à la verticale et faire un circuit à l''Ouest', 'd', 'C''est la procédure panne radio publiée sur la VAC, transpondeur sur 7600.', 'lfma'),
    ('En panne radio au départ de LFMA, avant le décollage, que faut-il faire ?', 'Décoller quand même', 'Attendre au point d''arrêt', 'Faire des signaux lumineux', 'Retourner au parking', 'd', 'Avant décollage, on retourne au parking. Après décollage, on exécute la dernière clairance reçue.', 'lfma'),
    ('Après l''atterrissage à LFMA, sauf instruction particulière, par où dégage-t-on la piste ?', 'Par le 2e taxiway', 'Par le 1er taxiway', 'En bout de piste uniquement', 'Par l''herbe', 'a', 'Mouvements au sol : dégager la piste par le 2e TWY, sauf instruction contraire.', 'lfma'),
    ('À LFMA, le circuit à l''Ouest des installations est :', 'Le circuit normal de tous les avions', 'Interdit en permanence', 'Effectué à 900 ft AMSL', 'Interdit hors horaires ATS, sur clairance à 2000 ft AMSL', 'd', 'Circuit Ouest : interdit hors horaires ATS, sur clairance ATC, à 2000 ft AMSL, en évitant le survol de la Duranne par l''Ouest.', 'lfma'),
    ('À LFMA, le circuit basse hauteur à l''Ouest de la piste se fait à :', '500 ft AMSL pour tous', '900 ft AMSL, réservé à la formation avec instructeur à bord', '1500 ft AMSL', '2000 ft AMSL', 'b', 'Il est limité à 3 circuits par séance, sur clairance ATC, pendant les horaires ATS, en suivant le tracé de la carte.', 'lfma'),
    ('À LFMA, combien de circuits basse hauteur au maximum par séance ?', '1', '3', '5', 'Illimité', 'b', 'La VAC limite le circuit basse hauteur à 3 circuits par séance, instructeur à bord.', 'lfma'),
    ('À LFMA, pendant quelles heures les tours de piste sont-ils autorisés (heure d''hiver UTC) ?', 'À toute heure', 'Entre 0900 et 1200 UTC', 'Entre 0700 et 1900 UTC (une heure plus tôt en été)', 'Uniquement la nuit', 'c', 'La VAC autorise les tours de piste entre 0700 et 1900 UTC, -1 h en été.', 'lfma'),
    ('À LFMA, du 1er juin au 15 septembre, les week-ends et jours fériés, quels avions peuvent faire des tours de piste ?', 'Tous les avions', 'Aucun avion', 'Les avions électriques et les avions légers classés A+, A ou B (CALIPSO)', 'Uniquement les avions non basés', 'c', 'Cette limitation vise à réduire les nuisances sonores ; le classement CALIPSO repose sur l''indice de performance sonore.', 'lfma'),
    ('À LFMA, pour un avion non basé, les tours de piste le week-end et les jours fériés sont :', 'Interdits toute l''année', 'Autorisés sans limite', 'Autorisés l''été seulement', 'Limités à 5', 'a', 'Les autres jours, un avion non basé est limité à 2 tours de piste successifs, pendant les horaires ATS.', 'lfma'),
    ('Un avion non basé peut faire combien de tours de piste successifs au maximum en semaine à LFMA ?', '1', '2', '5', '10', 'b', 'La VAC fixe un maximum de 2 tours de piste successifs pour les aéronefs non basés, pendant les horaires ATS.', 'lfma'),
    ('Que signifie le classement CALIPSO cité sur la VAC de LFMA ?', 'Un type de licence', 'Une zone réglementée', 'Une procédure radio', 'Une classification des avions légers selon leur indice de performance sonore', 'd', 'Les catégories CALIPSO (A+, A, B…) conditionnent l''accès aux tours de piste en période sensible.', 'lfma'),
    ('À LFMA, à quels moments les essais moteurs hors procédure de décollage sont-ils interdits ?', 'Jamais', 'La nuit de 1900 à 0700, le samedi de 1100 à 1500 et de 1630 à 1900, le dimanche et les jours fériés', 'Uniquement le dimanche matin', 'Tous les jours de 1200 à 1400', 'b', 'Horaires en UTC, une heure plus tôt en été. Une aire d''essai moteur avec mur antibruit existe.', 'lfma'),
    ('Quelles sont les minima de visibilité du VFR spécial à LFMA pour un avion ?', '1500 m', '5000 m', '800 m', '3000 m', 'd', 'La VAC (TXT 04) indique VIS 3000 m pour les avions en VFR spécial.', 'lfma'),
    ('Le VFR de nuit est-il possible à Aix-les-Milles ?', 'Non, jamais', 'Seulement pour les hélicoptères', 'Oui, l''aérodrome est agréé VFR de nuit', 'Seulement en été', 'c', 'La VAC indique « VFR de nuit : agréé ». Les itinéraires VFR de nuit suivent l''ENR 3.3.5.', 'lfma'),
    ('Hors horaires ATS à LFMA, combien de coups d''alternat pour allumer le balisage à pleine brillance (PCL) ?', '3 coups', '7 coups', '1 coup', '5 coups', 'd', 'PCL : 3 coups pour la brillance 2/4, 5 coups pour 4/4, 7 coups pour éteindre. Il est soumis à PPR 12 h.', 'lfma'),
    ('Quels carburants sont disponibles à Aix-les-Milles ?', 'Uniquement 100LL', 'UL91 et SP98', '100LL et JET A1', 'Aucun', 'c', 'La VAC (TXT 05) indique 100LL et JET A1, carte bancaire H24.', 'lfma'),
    ('Où se situe l''aérodrome d''Aix-les-Milles par rapport à Aix-en-Provence ?', 'À 20 km au Nord', 'À 2 km à l''Est', 'Au centre-ville', 'À 6 km à l''Ouest-Sud-Ouest', 'd', 'La VAC indique : 6 km WSW d''Aix-en-Provence.', 'lfma'),
    ('Qui est l''exploitant de l''aérodrome d''Aix-les-Milles ?', 'La DGAC', 'EDEIS', 'L''aéroclub', 'Air France', 'b', 'La VAC cite EDEIS Aéroport Aix, chemin de la Badesse.', 'lfma'),
    ('Quels numéros de zones de parachutage sont signalés sur la VAC de LFMA ?', '101 et 102', '1 et 2', 'Il n''y en a pas', '445 et 401', 'd', 'Parachutage n°445 (dangers à la navigation) et n°401 (activités diverses) : voir AIP ENR 5.5.', 'lfma'),
    ('À LFMA, où les hélicoptères non basés doivent-ils stationner ?', 'Sur l''aire SIERRA', 'Sur la piste', 'Sur l''aire non revêtue NOVEMBRE', 'Où ils veulent', 'c', 'Le stationnement des hélicoptères non basés est obligatoire sur l''aire NOVEMBRE en herbe.', 'lfma'),
    ('À LFMA, pour un aéronef de MTOW égale ou supérieure à 3 t, que faut-il ?', 'Rien de particulier', 'Une licence de pilote de ligne', 'Un plan de vol IFR', 'Une assistance obligatoire et une notification sur le site Myhandling', 'd', 'La VAC impose l''assistance et la notification Myhandling au-delà de 3 t.', 'lfma'),
    ('Sur la VAC de LFMA, combien mesure la bande utilisable au décollage entre l''extrémité de piste et le seuil 32, pour la piste 14 ?', '123 m', '232 m', '50 m', '500 m', 'b', 'RWY 14 : 232 m de roulement utilisable au décollage avant le seuil 32 ; RWY 32 : 123 m avant le seuil 14.', 'lfma'),
    ('Que doit-on faire avant de s''intégrer à LFMA pour connaître la piste en service ?', 'Écouter l''ATIS sur 136,230', 'Survoler la manche à air', 'Appeler la tour par téléphone', 'Rien, c''est toujours la 14', 'a', 'L''ATIS donne la piste en service, le vent, le QNH et la lettre d''information à annoncer au premier contact.', 'lfma'),
    ('En panne radio à LFMA, quelle route suit-on depuis le point AR vers la verticale de l''aérodrome ?', '048°', '228°', '143°', '323°', 'b', 'Procédure panne radio : depuis AR, poursuivre au 228° jusqu''à la verticale de l''aérodrome.', 'lfma')
  ) as v(question, option_a, option_b, option_c, option_d, correct, explanation, category)
  where not exists (select 1 from public.quiz_questions x where lower(btrim(x.question)) = lower(btrim(v.question)));
end $seed$;

notify pgrst, 'reload schema';

-- Vérification
select
  exists (select 1 from pg_proc where proname = 'quiz_today_set')
  and exists (select 1 from pg_indexes where indexname = 'quiz_answers_user_day_question')
  and (select count(*) from public.quiz_questions) >= 900 as "MISE A JOUR 34 OK",
  (select count(*) from public.quiz_questions where active) as "questions actives";


-- =====================================================================
-- migration-35-quiz-flotte.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°35 : questions « Flotte » consacrées aux avions du club
--  - La catégorie Flotte du quiz ne parle plus que des avions de l'AFPA :
--    PS28 Cruiser, Robin DR400/180, WT9 Dynamic, Diamond DA40, Bristell B23.
--    Les questions sur d'autres avions passent en Culture, Documents ou Général.
--  - 48 nouvelles questions tirées des manuels de vol (sections 2, 5 et 6,
--    telles que reprises dans le calculateur de performances et la masse et
--    centrage du site) : 50 questions Flotte au total.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Questions générales sorties de la catégorie Flotte ---------------------------
update public.quiz_questions set category = 'culture'
 where category = 'flotte' and question in (
   'Le Piper PA-28 Warrior est un avion :',
   'Le moteur Lycoming O-320 qui équipe de nombreux avions école est un moteur :',
   'Le Cessna 172 Skyhawk est :',
   'Le Cessna 152 est :',
   'Quelle est la particularité du Cirrus SR22 en matière de sécurité ?',
   'Le Piper PA-28 et le Cessna 172 diffèrent principalement par :');
update public.quiz_questions set category = 'documents'
 where category = 'flotte' and question in (
   'Que signifie l''acronyme POH ?',
   'Dans le manuel de vol, la section 3 concerne généralement :');
update public.quiz_questions set category = 'general'
 where category = 'flotte' and question in (
   'Qu''est-ce qu''un avion à train classique ?',
   'Qu''est-ce qu''un avion à train tricycle ?',
   'Sur un avion à aile haute, où se trouvent en général les réservoirs ?',
   'Pourquoi un avion à aile basse a-t-il une pompe à carburant électrique de secours ?');



-- 2. Banque de questions (posée une seule fois) ----------------------------------
do $seed$ begin
  if not public._seed_once('quiz-flotte-35') then return; end if;
  insert into public.quiz_questions (question, option_a, option_b, option_c, option_d, correct, explanation, category)
  select v.question, v.option_a, v.option_b, v.option_c, v.option_d, v.correct, v.explanation, v.category
  from (values
    ('Quelle est la masse maximale au décollage du Robin DR400/180 F-HCLI ?', '900 kg', '1045 kg', '1200 kg', '1100 kg', 'd', 'Manuel de vol DR400/180 : 1100 kg au décollage et 1045 kg à l''atterrissage.', 'flotte'),
    ('Quelle est la masse maximale à l''atterrissage du Robin DR400/180 F-HCLI ?', '1100 kg', '1000 kg', '1045 kg', '900 kg', 'c', 'Le manuel limite l''atterrissage à 1045 kg : après un décollage à 1100 kg, il faut avoir consommé du carburant avant de se poser.', 'flotte'),
    ('Quel vent de travers démontré le manuel du DR400/180 indique-t-il ?', '12 kt', '22 kt', '15 kt', '30 kt', 'b', 'C''est le plus élevé de la flotte du club, au décollage comme à l''atterrissage.', 'flotte'),
    ('Dans quelle unité les vitesses sont-elles données dans le manuel du DR400/180 ?', 'En km/h', 'En nœuds', 'En mph', 'En m/s', 'a', 'Attention à la conversion : par exemple 130 km/h correspondent à environ 70 kt.', 'flotte'),
    ('Selon le manuel du DR400/180, à quelle vitesse l''avion décolle-t-il ?', 'Environ 60 km/h', 'Environ 100 km/h (54 kt)', 'Environ 160 km/h', 'Environ 200 km/h', 'b', 'Section 5 du manuel : décollage vers 100 km/h, passage des 15 m vers 130 km/h.', 'flotte'),
    ('Selon le manuel du DR400/180, quelle vitesse au passage des 15 m à l''atterrissage ?', '125 km/h (68 kt)', '95 km/h', '150 km/h', '110 km/h', 'a', 'La vitesse d''impact (toucher) indiquée est d''environ 95 km/h (51 kt).', 'flotte'),
    ('Quels crans de volets le manuel du DR400/180 utilise-t-il pour ses performances ?', 'Volets rentrés au décollage et à l''atterrissage', '2e cran au décollage, 1er cran à l''atterrissage', '1er cran au décollage, 2e cran à l''atterrissage', 'Volets sortis à fond dans les deux cas', 'c', 'Ce sont les configurations dans lesquelles les distances du manuel ont été établies.', 'flotte'),
    ('DR400/180 à 1100 kg, au niveau de la mer, en atmosphère standard, sans vent, piste en dur : distance de décollage jusqu''à 15 m ?', 'Environ 250 m', 'Environ 800 m', 'Environ 515 m', 'Environ 330 m', 'c', 'Le roulement vaut environ 250 m. Le guide ENAC conseille une marge d''environ 20 % sur ces valeurs.', 'flotte'),
    ('DR400/180 à 1045 kg, niveau de la mer, atmosphère standard, sans vent, piste en dur : distance d''atterrissage depuis 15 m ?', 'Environ 250 m', 'Environ 900 m', 'Environ 400 m', 'Environ 530 m', 'd', 'Section 5 du manuel ; le roulement seul vaut environ 250 m.', 'flotte'),
    ('Quelle majoration le manuel du DR400/180 prévoit-il pour une piste en herbe ?', '+50 %', '+15 %', 'Aucune', '+5 %', 'b', 'La correction herbe s''ajoute aux corrections d''altitude, de température et de vent.', 'flotte'),
    ('Quelle correction pour le vent arrière dans le manuel du DR400/180 ?', '+1 % par kt', 'Aucune', '+50 % dès 1 kt', '+10 % par tranche de 2 kt', 'd', 'Quelques nœuds de vent arrière suffisent donc à allonger nettement les distances.', 'flotte'),
    ('Quelle est la capacité du réservoir principal du DR400/180 F-HCLI (masse et centrage du site) ?', '50 litres', '110 litres', '200 litres', '80 litres', 'b', 'S''y ajoutent les réservoirs d''aile, 80 litres au total, avec un autre bras de levier.', 'flotte'),
    ('Quelle est la masse maximale au décollage du WT9 Dynamic F-HVXD ?', '750 kg', '472,5 kg', '600 kg', '1100 kg', 'c', 'Le manuel donne ses performances à cette masse unique de 600 kg.', 'flotte'),
    ('Quel vent de travers démontré retient-on pour le WT9 Dynamic ?', '22 kt', '12 kt', '15 kt', '25 kt', 'c', 'Valeur retenue par le club au décollage et à l''atterrissage.', 'flotte'),
    ('Selon le manuel du WT9 Dynamic, quelle est la vitesse de décollage (Vlof) ?', '80 km/h (43 kt)', '120 km/h', '60 km/h', '100 kt', 'a', 'Le passage des 50 ft se fait à 100 km/h (54 kt).', 'flotte'),
    ('Selon le manuel du WT9 Dynamic, quelle est la vitesse de décrochage en configuration atterrissage (Vso) ?', '90 km/h', '45 km/h', '61 km/h (33 kt)', '120 km/h', 'c', 'Les vitesses du manuel du WT9 sont données en km/h.', 'flotte'),
    ('Que prévoit le manuel du WT9 Dynamic pour le vent de face dans le calcul des distances ?', 'Aucune réduction de distance', '-15 % par 5 kt', '-50 % dès 10 kt', '-1 % par kt', 'a', 'Le manuel ne donne qu''une pénalité de vent arrière : le vent de face n''est pas pris en compte (marge supplémentaire).', 'flotte'),
    ('WT9 Dynamic à 600 kg, niveau de la mer, atmosphère standard, piste en dur : distance de décollage jusqu''à 50 ft ?', 'Environ 263 m', 'Environ 515 m', 'Environ 136 m', 'Environ 600 m', 'a', 'Le roulement vaut environ 136 m ; sur herbe la distance passe à environ 285 m.', 'flotte'),
    ('Quelle est la capacité carburant du WT9 Dynamic F-HVXD (masse et centrage du site) ?', '80 litres', '128 litres', '190 litres', '50 litres', 'a', 'C''est la plus petite capacité de la flotte, à prendre en compte dans le devis carburant.', 'flotte'),
    ('Qui construit le PS-28 Cruiser du club ?', 'Robin', 'Czech Sport Aircraft', 'Diamond', 'Aerospool', 'b', 'Le PS-28 Cruiser est un biplace LSA construit en République tchèque.', 'flotte'),
    ('Quelle est la masse maximale au décollage du PS-28 Cruiser ?', '600 kg', '750 kg', '900 kg', '472,5 kg', 'a', 'Masse maximale au décollage et à l''atterrissage : 600 kg (manuel de vol, section 2).', 'flotte'),
    ('Quel vent de travers démontré le manuel du PS-28 Cruiser indique-t-il ?', '22 kt', '20 kt', '30 kt', '12 kt', 'd', 'C''est le plus faible de la flotte : prudence par vent de travers.', 'flotte'),
    ('Quel vent de face maximal démontré le manuel du PS-28 Cruiser indique-t-il ?', '24 kt', '12 kt', '40 kt', '10 kt', 'a', 'Le vent de travers démontré est, lui, de 12 kt.', 'flotte'),
    ('Selon le manuel du PS-28 Cruiser, à quelle vitesse fait-on la rotation ?', 'Entre 60 et 65 kt', 'Vers 80 kt', 'Vers 30 kt', 'Entre 40 et 44 kt', 'd', 'La montée se fait ensuite à Vy, 62 kt.', 'flotte'),
    ('Quelle est la vitesse de meilleur taux de montée (Vy) du PS-28 Cruiser ?', '44 kt', '80 kt', '100 kt', '62 kt', 'd', 'Valeur du manuel de vol, utilisée pour la montée normale.', 'flotte'),
    ('Quelle est la vitesse de décrochage en configuration atterrissage (Vso) du PS-28 Cruiser ?', '31 kt', '44 kt', '49 kt', '60 kt', 'a', 'C''est la plus faible de la flotte du club.', 'flotte'),
    ('PS-28 Cruiser à 600 kg, niveau de la mer, atmosphère standard, piste en dur : distance de décollage jusqu''à 15 m ?', 'Environ 141 m', 'Environ 387 m', 'Environ 515 m', 'Environ 700 m', 'b', 'Le roulement vaut environ 141 m ; sur herbe, le manuel donne environ 457 m.', 'flotte'),
    ('PS-28 Cruiser à 600 kg, niveau de la mer, atmosphère standard, piste en dur : distance d''atterrissage depuis 15 m ?', 'Environ 146 m', 'Environ 530 m', 'Environ 362 m', 'Environ 900 m', 'c', 'Le manuel ne donne qu''une valeur de référence : il faut majorer pour l''altitude, la chaleur et le vent.', 'flotte'),
    ('Quelle charge maximale dans le coffre à bagages arrière du PS-28 Cruiser ?', '60 kg', '18 kg', '5 kg', '40 kg', 'b', 'Le coffre arrière est limité à 18 kg ; la masse et centrage du site reprend cette limite.', 'flotte'),
    ('Entre quelles valeurs se situe le domaine de centrage du PS-28 Cruiser ?', 'Entre 420 et 525 mm du point de référence (28 à 35 % de la corde moyenne)', 'Entre 100 et 200 mm', 'Entre 1,7 et 1,8 m', 'Il n''y a pas de limite', 'a', 'Le site vérifie que le centre de gravité reste dans ce domaine au décollage comme sans carburant.', 'flotte'),
    ('Quel écran équipe le PS-28 F-HSAA d''après sa documentation ?', 'Un Garmin G1000', 'Aucun écran', 'Un Garmin G3X', 'Un Dynon (D1000)', 'd', 'Le manuel du Dynon D1000 est rangé dans les documents de l''avion sur le site.', 'flotte'),
    ('Quel instrument numérique équipe les PS-28 F-HNLR et F-HSAC d''après leur documentation ?', 'Un Garmin G1000', 'Un uAvionix AV-30', 'Un horizon à dépression', 'Aucun', 'b', 'Les manuels de l''AV-30 sont disponibles dans les documents de ces avions sur le site.', 'flotte'),
    ('Quelle suite avionique équipe le Bristell B23 F-HUFA ?', 'Un Dynon D1000', 'Un Garmin G3X', 'Des instruments classiques uniquement', 'Un Garmin G1000 NXi', 'b', 'Un guide rapide et le manuel d''utilisation du G3X sont dans les documents de l''avion.', 'flotte'),
    ('Que désigne le « 915 » du Bristell B23-915 du club ?', 'Sa masse maximale', 'Son numéro de série', 'Son moteur Rotax 915 iS', 'Sa vitesse maximale en km/h', 'c', 'Le B23-915 est motorisé par un Rotax 915 iS turbocompressé.', 'flotte'),
    ('Quelle est la masse maximale au décollage du Bristell B23 F-HUFA ?', '600 kg', '1100 kg', '750 kg', '900 kg', 'c', 'Les performances du manuel sont données à cette masse de 750 kg.', 'flotte'),
    ('Quel vent de travers démontré le manuel du Bristell B23 indique-t-il ?', '12 kt', '22 kt', '15 kt', '20 kt', 'c', 'Valeur valable au décollage et à l''atterrissage.', 'flotte'),
    ('Selon le manuel du Bristell B23, quelle est la vitesse de décollage ?', '45 KIAS', '80 KIAS', '100 KIAS', '60 KIAS', 'd', 'Le passage des 50 ft se fait à 70 KIAS.', 'flotte'),
    ('Selon le manuel du Bristell B23, quelle vitesse d''approche finale ?', '70 KIAS', '44 KIAS', '58 KIAS', '80 KIAS', 'c', 'La vitesse de décrochage en configuration atterrissage (Vso) est de 44 KIAS.', 'flotte'),
    ('Selon le manuel du Bristell B23, quelle correction de vent de face au décollage ?', '-5 % par tranche de 5 kt', 'Aucune', '-15 % par tranche de 5 kt', '-50 % dès 10 kt', 'c', 'Par vent arrière, le manuel ajoute 20 % par tranche de 5 kt. À l''atterrissage : -5 % et +10 % par 5 kt.', 'flotte'),
    ('Quel facteur le manuel du Bristell B23 applique-t-il pour une piste en herbe au décollage ?', '×1,50', '×1,14', '×1,02', '×2', 'b', 'À l''atterrissage, le facteur herbe est de ×1,18. Ces corrections portent sur la distance jusqu''à 50 ft.', 'flotte'),
    ('Quelle est la capacité carburant du Bristell B23 F-HUFA (masse et centrage du site) ?', '80 litres', '190 litres', '50 litres', '120 litres', 'd', 'Le carburant est logé dans les ailes.', 'flotte'),
    ('Quel vent de travers démontré le manuel du Diamond DA40 indique-t-il ?', '12 kt', '15 kt', '30 kt', '20 kt', 'd', 'Valeur retenue par le club au décollage et à l''atterrissage.', 'flotte'),
    ('Selon le manuel du DA40, quelle vitesse d''approche à 1150 kg ?', '71 KIAS', '58 KIAS', '90 KIAS', '49 KIAS', 'a', 'La vitesse de montée initiale indiquée par le manuel est de 67 KIAS.', 'flotte'),
    ('DA40 à 1150 kg, niveau de la mer, atmosphère standard, sans vent, volets atterrissage : distance d''atterrissage depuis 15 m ?', 'Environ 352 m', 'Environ 638 m', 'Environ 300 m', 'Environ 1000 m', 'b', 'Le roulement vaut environ 352 m. C''est la plus longue distance d''atterrissage de la flotte.', 'flotte'),
    ('Selon le manuel du DA40, de combien majorer le roulement au décollage sur herbe courte et sèche ?', '50 %', '0 %', '25 %', '10 %', 'd', 'À l''atterrissage, la majoration du roulement sur herbe est de 5 %.', 'flotte'),
    ('Parmi les avions du club, lequel a le vent de travers démontré le plus faible ?', 'Le DR400/180', 'Le PS-28 Cruiser (12 kt)', 'Le DA40', 'Le Bristell B23', 'b', 'DR400 : 22 kt ; DA40 : 20 kt ; WT9 et B23 : 15 kt ; PS-28 : 12 kt.', 'flotte'),
    ('Parmi les avions du club, lesquels ont des manuels donnant les vitesses en km/h ?', 'Le DA40 et le B23', 'Le PS-28 et le DA40', 'Tous', 'Le DR400/180 et le WT9 Dynamic', 'd', 'Les manuels du DA40, du B23 et du PS-28 donnent les vitesses en nœuds : attention aux conversions en passant d''un avion à l''autre.', 'flotte'),
    ('Parmi les avions du club, lesquels sont des quadriplaces ?', 'Le DR400/180 et le DA40', 'Le PS-28 et le WT9', 'Le B23 et le DA40', 'Tous', 'a', 'Le PS-28 Cruiser, le WT9 Dynamic et le Bristell B23 sont des biplaces.', 'flotte')
  ) as v(question, option_a, option_b, option_c, option_d, correct, explanation, category)
  where not exists (select 1 from public.quiz_questions x where lower(btrim(x.question)) = lower(btrim(v.question)));
end $seed$;

notify pgrst, 'reload schema';

-- Vérification
select
  (select count(*) from public.quiz_questions where category = 'flotte') as "questions Flotte",
  exists (select 1 from public._seeds where name = 'quiz-flotte-35') as "MISE A JOUR 35 OK";


-- =====================================================================
-- migration-36-shop-stock.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°36 : shop — gestion des stocks et suivi des ventes
--  - Stock par article et par variante (taille / couleur), journal de tous
--    les mouvements (réception, vente, retour, inventaire).
--  - Prix d'achat des articles (pour la marge) et seuil d'alerte de stock.
--  - Date de vente (livraison) mémorisée sur chaque commande.
--  - Une commande livrée sort automatiquement du stock (une seule fois) ;
--    si elle repasse à un autre statut, le stock est rendu.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Articles : prix d'achat, suivi du stock, seuil d'alerte -----------------------
alter table public.shop_items
  add column if not exists cost_cents      int,
  add column if not exists track_stock     boolean not null default true,
  add column if not exists low_stock_alert int not null default 2;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'shop_items_cost_check') then
    alter table public.shop_items add constraint shop_items_cost_check
      check ((cost_cents is null or cost_cents >= 0) and low_stock_alert >= 0 and price_cents >= 0) not valid;
  end if;
end $$;

-- 2. Commandes : date de vente et sortie de stock -----------------------------------
alter table public.shop_orders
  add column if not exists delivered_at   timestamptz,
  add column if not exists stock_deducted boolean not null default false;
update public.shop_orders set delivered_at = updated_at where status = 'delivered' and delivered_at is null;
create index if not exists shop_orders_status on public.shop_orders (status);
create index if not exists shop_orders_delivered_at on public.shop_orders (delivered_at);

-- 3. Stock par variante ---------------------------------------------------------------
create table if not exists public.shop_stock (
  item_id    uuid not null references public.shop_items (id) on delete cascade,
  size       text not null default '',
  color      text not null default '',
  quantity   int  not null default 0,
  updated_at timestamptz not null default now(),
  primary key (item_id, size, color)
);
create table if not exists public.shop_stock_moves (
  id               bigint generated always as identity primary key,
  item_id          uuid not null references public.shop_items (id) on delete cascade,
  size             text not null default '',
  color            text not null default '',
  delta            int  not null check (delta <> 0),
  reason           text not null check (reason in ('reception', 'vente', 'retour', 'inventaire', 'correction')),
  unit_cost_cents  int check (unit_cost_cents is null or unit_cost_cents >= 0),
  order_id         uuid references public.shop_orders (id) on delete set null,
  note             text check (note is null or length(note) <= 300),
  created_by       uuid references public.profiles (id) on delete set null,
  created_at       timestamptz not null default now()
);
create index if not exists shop_stock_moves_item on public.shop_stock_moves (item_id, created_at desc);

alter table public.shop_stock enable row level security;
alter table public.shop_stock_moves enable row level security;
revoke all on public.shop_stock, public.shop_stock_moves from anon;
grant select on public.shop_stock, public.shop_stock_moves to authenticated;
-- Stock : lisible par les membres (pour afficher « en stock »), modifiable seulement par les fonctions ci-dessous
drop policy if exists shop_stock_read on public.shop_stock;
create policy shop_stock_read on public.shop_stock for select to authenticated using (public.is_approved());
-- Journal : administrateurs uniquement
drop policy if exists shop_stock_moves_admin on public.shop_stock_moves;
create policy shop_stock_moves_admin on public.shop_stock_moves for select to authenticated
  using (public.app_role() = 'admin');

-- Mouvement de stock (interne) : met à jour la quantité et journalise
create or replace function public._shop_stock_apply(p_item uuid, p_size text, p_color text, p_delta int,
  p_reason text, p_cost int, p_order uuid, p_note text)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare v_qty int;
begin
  if coalesce(p_delta, 0) = 0 then
    select quantity into v_qty from public.shop_stock
     where item_id = p_item and size = coalesce(p_size, '') and color = coalesce(p_color, '');
    return coalesce(v_qty, 0);
  end if;
  insert into public.shop_stock (item_id, size, color, quantity, updated_at)
  values (p_item, coalesce(p_size, ''), coalesce(p_color, ''), p_delta, now())
  on conflict (item_id, size, color)
  do update set quantity = public.shop_stock.quantity + excluded.quantity, updated_at = now()
  returning quantity into v_qty;
  insert into public.shop_stock_moves (item_id, size, color, delta, reason, unit_cost_cents, order_id, note, created_by)
  values (p_item, coalesce(p_size, ''), coalesce(p_color, ''), p_delta, p_reason, p_cost, p_order,
          nullif(btrim(coalesce(p_note, '')), ''), auth.uid());
  return v_qty;
end;
$$;
revoke execute on function public._shop_stock_apply(uuid, text, text, int, text, int, uuid, text) from public, anon, authenticated;

-- Réception de marchandise (entrée) ou correction (+/-), par un administrateur
create or replace function public.shop_stock_add(p_item uuid, p_size text, p_color text, p_qty int,
  p_unit_cost_cents int default null, p_note text default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.app_role() is distinct from 'admin' then raise exception 'Réservé aux administrateurs.'; end if;
  if p_qty is null or p_qty = 0 or abs(p_qty) > 100000 then raise exception 'Quantité invalide.'; end if;
  if not exists (select 1 from public.shop_items where id = p_item) then raise exception 'Article introuvable.'; end if;
  if p_unit_cost_cents is not null and p_unit_cost_cents < 0 then raise exception 'Prix d''achat invalide.'; end if;
  return public._shop_stock_apply(p_item, p_size, p_color, p_qty,
    case when p_qty > 0 then 'reception' else 'correction' end, p_unit_cost_cents, null, p_note);
end;
$$;

-- Inventaire : fixe la quantité comptée, l'écart est journalisé
create or replace function public.shop_stock_set(p_item uuid, p_size text, p_color text, p_qty int, p_note text default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare v_cur int;
begin
  if public.app_role() is distinct from 'admin' then raise exception 'Réservé aux administrateurs.'; end if;
  if p_qty is null or p_qty < 0 or p_qty > 100000 then raise exception 'Quantité invalide.'; end if;
  if not exists (select 1 from public.shop_items where id = p_item) then raise exception 'Article introuvable.'; end if;
  select quantity into v_cur from public.shop_stock
   where item_id = p_item and size = coalesce(p_size, '') and color = coalesce(p_color, '') for update;
  return public._shop_stock_apply(p_item, p_size, p_color, p_qty - coalesce(v_cur, 0), 'inventaire', null, null,
    coalesce(nullif(btrim(coalesce(p_note, '')), ''), 'Inventaire'));
end;
$$;

revoke execute on function public.shop_stock_add(uuid, text, text, int, int, text), public.shop_stock_set(uuid, text, text, int, text) from public, anon;
grant execute on function public.shop_stock_add(uuid, text, text, int, int, text), public.shop_stock_set(uuid, text, text, int, text) to authenticated;

-- 4. Statut d'une commande : ardoise (déjà en place) + date de vente + stock ---------
create or replace function public.set_shop_order_status(p_id uuid, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order   public.shop_orders;
  v_label   text;
  v_variant text;
  v_charged boolean := false;
  v_track   boolean;
begin
  if public.app_role() is distinct from 'admin' then raise exception 'Réservé aux administrateurs.'; end if;
  if p_status not in ('pending', 'confirmed', 'ready', 'delivered', 'cancelled') then
    raise exception 'Statut inconnu.';
  end if;
  select * into v_order from public.shop_orders where id = p_id for update;
  if not found then raise exception 'Commande introuvable.'; end if;
  if v_order.status = p_status then return jsonb_build_object('charged', false); end if;
  select track_stock into v_track from public.shop_items where id = v_order.item_id;

  if p_status = 'delivered' and not v_order.ardoise_charged and coalesce(v_order.price_cents, 0) > 0 then
    v_variant := concat_ws(' / ', nullif(v_order.size, ''), nullif(v_order.color, ''));
    v_label := 'Shop – ' || coalesce(v_order.item_name, 'Article')
               || case when v_variant <> '' then ' (' || v_variant || ')' else '' end;
    insert into public.bar_consumptions (user_id, product_id, product_name, unit_price_cents, quantity, created_by)
    values (v_order.user_id, null, v_label, v_order.price_cents, v_order.quantity, auth.uid());
    v_charged := true;
  end if;

  -- Sortie de stock à la livraison, rendue si la commande quitte l'état « livrée »
  if p_status = 'delivered' and not v_order.stock_deducted and coalesce(v_track, true) then
    perform public._shop_stock_apply(v_order.item_id, v_order.size, v_order.color, -v_order.quantity,
      'vente', null, v_order.id, null);
    v_order.stock_deducted := true;
  elsif p_status <> 'delivered' and v_order.stock_deducted then
    perform public._shop_stock_apply(v_order.item_id, v_order.size, v_order.color, v_order.quantity,
      'retour', null, v_order.id, 'Commande sortie de l''état « livrée »');
    v_order.stock_deducted := false;
  end if;

  update public.shop_orders
     set status = p_status,
         ardoise_charged = ardoise_charged or v_charged,
         stock_deducted = v_order.stock_deducted,
         delivered_at = case when p_status = 'delivered' then now() else null end,
         updated_at = now()
   where id = p_id;
  return jsonb_build_object('charged', v_charged);
end;
$$;
revoke execute on function public.set_shop_order_status(uuid, text) from public, anon;
grant execute on function public.set_shop_order_status(uuid, text) to authenticated;

-- 5. Chiffre d'affaires du shop : compté à la date de livraison ----------------------
create or replace function public.revenue_stats(p_months int default 12)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_from date := (date_trunc('month', now() at time zone 'Europe/Paris') - make_interval(months => greatest(p_months, 1) - 1))::date;
begin
  if not (public.app_role() = 'admin' or public.is_treasurer()) then
    raise exception 'Réservé aux administrateurs et au trésorier.';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('month', to_char(m, 'YYYY-MM'), 'bar', bar, 'shop', shop) order by m)
    from (
      select m::date,
             (select coalesce(sum(c.unit_price_cents * c.quantity), 0) from public.bar_consumptions c
               where c.product_id is not null   -- les lignes « Shop – … » débitées sur l'ardoise sont comptées côté shop
                 and date_trunc('month', c.created_at at time zone 'Europe/Paris') = m)::bigint as bar,
             (select coalesce(sum(o.price_cents * o.quantity), 0) from public.shop_orders o
               where o.status = 'delivered'
                 and date_trunc('month', coalesce(o.delivered_at, o.updated_at) at time zone 'Europe/Paris') = m)::bigint as shop
      from generate_series(v_from, (now() at time zone 'Europe/Paris')::date, interval '1 month') as m
    ) t), '[]'::jsonb);
end;
$$;
revoke execute on function public.revenue_stats(int) from public, anon;
grant execute on function public.revenue_stats(int) to authenticated;

-- 6. Journal d'audit sur le stock (comme les autres tables sensibles) -----------------
do $$ begin
  if exists (select 1 from pg_proc where proname = '_audit' and pronamespace = 'public'::regnamespace) then
    execute 'drop trigger if exists zz_audit on public.shop_stock_moves';
    execute 'create trigger zz_audit after update or delete on public.shop_stock_moves for each row execute function public._audit()';
  end if;
end $$;

notify pgrst, 'reload schema';

-- Vérification
select
  to_regclass('public.shop_stock') is not null
  and to_regclass('public.shop_stock_moves') is not null
  and exists (select 1 from pg_proc where proname = 'shop_stock_set')
  and exists (select 1 from information_schema.columns where table_name = 'shop_orders' and column_name = 'delivered_at')
  as "MISE A JOUR 36 OK";


-- =====================================================================
-- migration-37-quiz-tirage-fige.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°37 : les 3 questions du jour ne changent plus dans la journée
--  Avant : le tirage du jour dépendait du nombre de questions actives. Ajouter,
--  retirer ou réactiver une question dans la journée changeait le tirage, et un
--  membre pouvait alors répondre à 3 nouvelles questions.
--  Désormais :
--   - le tirage est enregistré au premier affichage de la journée et ne bouge plus ;
--   - un membre ne peut jamais répondre à plus de 3 questions par jour.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Tirage figé de chaque jour (commun à tous les membres)
create table if not exists public.quiz_daily_set (
  day        date primary key,
  ids        int[] not null,
  created_at timestamptz not null default now()
);
alter table public.quiz_daily_set enable row level security;
-- aucune policy : lecture et écriture uniquement via les fonctions ci-dessous
revoke all on public.quiz_daily_set from anon, authenticated;

-- Le tirage d'aujourd'hui est figé avec les questions déjà proposées aujourd'hui
-- (celles auxquelles des membres ont répondu en priorité, pour ne léser personne).
insert into public.quiz_daily_set (day, ids)
select public.quiz_day(), public._quiz_set(public.quiz_day())
on conflict (day) do nothing;

-- Questions d'un jour : lues dans le tirage enregistré, sinon tirées puis enregistrées
create or replace function public._quiz_day_ids(p_day date)
returns int[]
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_ids int[];
begin
  select ids into v_ids from public.quiz_daily_set where day = p_day;
  if v_ids is not null then return v_ids; end if;
  v_ids := public._quiz_set(p_day);
  if coalesce(array_length(v_ids, 1), 0) = 0 then return v_ids; end if;
  insert into public.quiz_daily_set (day, ids) values (p_day, v_ids)
  on conflict (day) do nothing;
  select ids into v_ids from public.quiz_daily_set where day = p_day;
  return v_ids;
end;
$$;
revoke execute on function public._quiz_day_ids(date) from public, anon, authenticated;

-- 2. Questions du jour (sans la bonne réponse tant que le membre n'a pas répondu)
create or replace function public.quiz_today_set()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_ids int[];
begin
  if not public.is_approved() then return null; end if;
  v_ids := public._quiz_day_ids(public.quiz_day());
  if coalesce(array_length(v_ids, 1), 0) = 0 then return null; end if;
  return jsonb_build_object(
    'day', public.quiz_day(),
    'questions', (
      select jsonb_agg(jsonb_build_object(
               'id', q.id, 'question', q.question, 'category', q.category,
               'option_a', q.option_a, 'option_b', q.option_b, 'option_c', q.option_c, 'option_d', q.option_d,
               'already_answered', a.id is not null,
               'my_answer', a.answer,
               'is_correct', a.is_correct,
               'correct', case when a.id is not null then q.correct end,
               'explanation', case when a.id is not null then q.explanation end)
             order by s.ord)
        from unnest(v_ids) with ordinality as s(id, ord)
        join public.quiz_questions q on q.id = s.id
        left join public.quiz_answers a
          on a.user_id = auth.uid() and a.answered_on = public.quiz_day() and a.question_id = q.id)
  );
end;
$$;

-- Ancien format (une seule question) : première question du jour pas encore répondue
create or replace function public.quiz_today()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_set jsonb := public.quiz_today_set();
  v_q   jsonb;
begin
  if v_set is null then return null; end if;
  select x into v_q from jsonb_array_elements(v_set->'questions') x
   where not (x->>'already_answered')::boolean limit 1;
  return coalesce(v_q, v_set->'questions'->0);
end;
$$;

-- 3. Enregistrer une réponse : question du tirage du jour, 3 réponses par jour au maximum
create or replace function public.quiz_answer(p_question int, p_answer text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_q   public.quiz_questions;
  v_ok  boolean;
  v_ans text := lower(btrim(coalesce(p_answer, '')));
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  if v_ans not in ('a', 'b', 'c', 'd') then raise exception 'Réponse invalide.'; end if;
  -- verrou par membre : deux réponses envoyées en même temps ne passent pas la limite
  perform pg_advisory_xact_lock(hashtext('quiz:' || auth.uid()::text));
  if exists (select 1 from public.quiz_answers
              where user_id = auth.uid() and answered_on = public.quiz_day() and question_id = p_question) then
    raise exception 'Vous avez déjà répondu à cette question.';
  end if;
  if (select count(*) from public.quiz_answers
       where user_id = auth.uid() and answered_on = public.quiz_day()) >= public.quiz_per_day() then
    raise exception 'Vous avez déjà répondu à vos % questions du jour. Rendez-vous demain !', public.quiz_per_day();
  end if;
  if not (p_question = any (public._quiz_day_ids(public.quiz_day()))) then
    raise exception 'Cette question ne fait plus partie des questions du jour : rechargez la page.';
  end if;
  select * into v_q from public.quiz_questions where id = p_question;
  v_ok := v_q.correct = v_ans;
  insert into public.quiz_answers (user_id, question_id, answered_on, is_correct, answer)
  values (auth.uid(), p_question, public.quiz_day(), v_ok, v_ans)
  on conflict (user_id, answered_on, question_id) do nothing;
  return jsonb_build_object('correct', v_ok, 'answer', v_q.correct, 'explanation', v_q.explanation);
end;
$$;

revoke execute on function public.quiz_today_set(), public.quiz_today(), public.quiz_answer(int, text)
  from public, anon;
grant execute on function public.quiz_today_set(), public.quiz_today(), public.quiz_answer(int, text)
  to authenticated;

-- Vérification
select 'MISE A JOUR 37 OK' as resultat,
       (select ids from public.quiz_daily_set where day = public.quiz_day()) as questions_du_jour;


-- =====================================================================
-- migration-38-projets-sans-date.sql
-- =====================================================================
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


-- =====================================================================
-- migration-39-suppression-compte.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°39 : suppression de l'identifiant de connexion d'un membre
--  Avant : supprimer un utilisateur dans Supabase (Authentication → Users) échouait
--  (« Database error deleting user ») ou, pire, aurait effacé avec lui son historique
--  (bar, commandes, inscriptions) que la comptabilité doit conserver.
--  Désormais :
--   - la fiche du membre n'est plus liée à son identifiant de connexion : supprimer
--     l'identifiant garde la fiche « Ancien membre » et son historique comptable ;
--   - si l'identifiant est supprimé sans anonymisation préalable, la fiche est
--     anonymisée automatiquement (aucune donnée personnelle ne reste).
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Anonymisation interne (sans contrôle de droits) : utilisée par l'admin et à la suppression
create or replace function public._anonymize_profile(p_user uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare r record;
begin
  -- Désinscription des événements à venir (les places libérées sont réattribuées)
  for r in
    select distinct g.outing_id from public.registrations g join public.outings o on o.id = g.outing_id
    where g.user_id = p_user and g.status <> 'cancelled' and (o.departure_at is null or o.departure_at > now())
  loop
    update public.registrations set status = 'cancelled'
     where outing_id = r.outing_id and user_id = p_user and status <> 'cancelled';
    perform public._rebalance_outing(r.outing_id);
  end loop;

  delete from public.pilot_weights where user_id = p_user;
  -- accompagnants annoncés, REX signés, messages : plus rien ne le relie à une personne
  update public.registrations set guest_name = 'Accompagnant', guest_weight_kg = null
   where user_id = p_user and guest_of is not null;
  update public.rex_reports set author_id = null where author_id = p_user;
  update public.flight_share_seats set message = null where member_id = p_user;
  update public.shop_orders set note = null where user_id = p_user;
  delete from public.pilot_types where user_id = p_user;

  update public.profiles set
    full_name = 'Ancien membre',
    email = 'anonyme-' || left(p_user::text, 8) || '@invalid.local',
    phone = null, address = null, emergency_name = null, emergency_phone = null,
    avatar_url = null,
    role = 'pending',
    is_instructor = false, is_board = false, is_treasurer = false, is_secretary = false, is_maintenance = false,
    is_chief_pilot = false, is_compliance = false,
    notify_events = false, show_phone = false,
    anonymized_at = coalesce(anonymized_at, now())
  where id = p_user;
end;
$$;
revoke execute on function public._anonymize_profile(uuid) from public, anon, authenticated;

create or replace function public.anonymize_member(p_user uuid)
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
    raise exception 'Vous ne pouvez pas anonymiser votre propre compte.';
  end if;
  if not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'Membre introuvable.';
  end if;
  perform public._anonymize_profile(p_user);
end;
$$;
revoke execute on function public.anonymize_member(uuid) from public, anon;
grant execute on function public.anonymize_member(uuid) to authenticated;

-- 2. La fiche survit à la suppression de l'identifiant de connexion
alter table public.profiles drop constraint if exists profiles_id_fkey;

-- 3. Suppression d'un identifiant : la fiche est anonymisée si elle ne l'était pas déjà
create or replace function public._on_auth_user_deleted()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.profiles where id = old.id and anonymized_at is null) then
    perform public._anonymize_profile(old.id);
  end if;
  return old;
end;
$$;
revoke execute on function public._on_auth_user_deleted() from public, anon, authenticated;

drop trigger if exists on_auth_user_deleted on auth.users;
create trigger on_auth_user_deleted
  before delete on auth.users
  for each row execute function public._on_auth_user_deleted();

-- Vérification
select 'MISE A JOUR 39 OK' as resultat,
       not exists (select 1 from pg_constraint where conname = 'profiles_id_fkey') as fiche_independante,
       exists (select 1 from pg_trigger where tgname = 'on_auth_user_deleted') as anonymisation_auto;


-- =====================================================================
-- migration-40-shop-bientot.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°40 : mode « Bientôt disponible » du shop
--  Un administrateur peut l'activer depuis la gestion du shop : la page « Le shop »
--  affiche alors les articles marqués « Bientôt disponible » et plus aucune commande n'est
--  possible (refusée par la base, pas seulement masquée sur la page).
--  Les commandes déjà passées restent visibles et gérées normalement.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Réglages du shop (une seule ligne)
create table if not exists public.shop_settings (
  id           boolean primary key default true check (id),
  coming_soon  boolean not null default false,
  message      text check (message is null or length(message) <= 300),
  updated_at   timestamptz not null default now(),
  updated_by   uuid references public.profiles (id) on delete set null
);
insert into public.shop_settings (id) values (true) on conflict (id) do nothing;
alter table public.shop_settings enable row level security;
revoke all on public.shop_settings from anon, authenticated;
grant select on public.shop_settings to authenticated;
drop policy if exists shop_settings_read on public.shop_settings;
create policy shop_settings_read on public.shop_settings for select to authenticated using (public.is_approved());

-- Le shop est-il en « Bientôt disponible » ?
create or replace function public.shop_coming_soon()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$ select coalesce((select coming_soon from public.shop_settings where id), false) $$;
revoke execute on function public.shop_coming_soon() from public, anon;
grant execute on function public.shop_coming_soon() to authenticated;

-- 2. Activer / désactiver (administrateurs)
create or replace function public.set_shop_coming_soon(p_on boolean, p_message text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  insert into public.shop_settings (id, coming_soon, message, updated_at, updated_by)
  values (true, coalesce(p_on, false), nullif(btrim(left(coalesce(p_message, ''), 300)), ''), now(), auth.uid())
  on conflict (id) do update set
    coming_soon = excluded.coming_soon,
    message = excluded.message,
    updated_at = excluded.updated_at,
    updated_by = excluded.updated_by;
end;
$$;
revoke execute on function public.set_shop_coming_soon(boolean, text) from public, anon;
grant execute on function public.set_shop_coming_soon(boolean, text) to authenticated;

-- 3. Aucune nouvelle commande tant que le mode est actif
drop policy if exists "shop_orders_insert" on public.shop_orders;
create policy "shop_orders_insert" on public.shop_orders
  for insert with check (user_id = auth.uid() and public.is_approved() and not public.shop_coming_soon());

-- Journal des modifications
do $$ begin
  if exists (select 1 from pg_proc where proname = '_audit' and pronamespace = 'public'::regnamespace) then
    execute 'drop trigger if exists zz_audit on public.shop_settings';
    execute 'create trigger zz_audit after update on public.shop_settings for each row execute function public._audit()';
  end if;
end $$;

-- Vérification
select 'MISE A JOUR 40 OK' as resultat, (select coming_soon from public.shop_settings) as bientot_en_ligne;


-- =====================================================================
-- migration-41-affiche-evenement.sql
-- =====================================================================
-- =====================================================================
--  Mise à jour n°41 : affiche (photo) des événements
--  L'organisateur d'un événement peut y joindre une affiche, montrée en haut de la
--  page de l'événement. Sans affiche, rien n'est affiché.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Adresse de l'affiche
alter table public.outings add column if not exists poster_url text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'outings_poster_url_check'
                   and conrelid = 'public.outings'::regclass) then
    alter table public.outings add constraint outings_poster_url_check
      check (poster_url is null or (length(poster_url) <= 500 and poster_url ~ '^https?://'));
  end if;
end $$;

-- Peut gérer l'affiche : les organisateurs du club, et l'organisateur de l'événement
create or replace function public._can_manage_outing_poster(p_outing uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_approved() and (
           public.can_organize()
           or exists (select 1 from public.outings o
                       where o.id = p_outing and o.instructor_id = auth.uid() and o.status <> 'cancelled'))
$$;
revoke execute on function public._can_manage_outing_poster(uuid) from public, anon;
grant execute on function public._can_manage_outing_poster(uuid) to authenticated;

-- 2. Enregistrer / retirer l'affiche (l'image doit être celle déposée pour cet événement)
create or replace function public.set_outing_poster(p_outing uuid, p_url text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.outings where id = p_outing) then
    raise exception 'Événement introuvable.';
  end if;
  if not public._can_manage_outing_poster(p_outing) then
    raise exception 'Seul l''organisateur de l''événement peut changer son affiche.';
  end if;
  if p_url is not null and position('/storage/v1/object/public/documents/events/' || p_outing::text || '/' in p_url) = 0 then
    raise exception 'Affiche invalide.';
  end if;
  update public.outings set poster_url = p_url, updated_at = now() where id = p_outing;
end;
$$;
revoke execute on function public.set_outing_poster(uuid, text) from public, anon;
grant execute on function public.set_outing_poster(uuid, text) to authenticated;

-- 3. Fichiers : dossier events/<id de l'événement>/ du stockage « documents » (images, 5 Mo max)
drop policy if exists event_posters_insert on storage.objects;
create policy event_posters_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'documents' and name like 'events/%'
              and public._can_manage_outing_poster(nullif(split_part(name, '/', 2), '')::uuid));
drop policy if exists event_posters_delete on storage.objects;
create policy event_posters_delete on storage.objects for delete to authenticated
  using (bucket_id = 'documents' and name like 'events/%'
         and public._can_manage_outing_poster(nullif(split_part(name, '/', 2), '')::uuid));

-- 4. La page d'un événement renvoie son affiche
do $$
declare d text;
begin
  select pg_get_functiondef('public.get_outing(uuid)'::regprocedure) into d;
  if position('''poster_url''' in d) = 0 then
    d := regexp_replace(d, '''title'',(\s*)v_row\.title,', '''title'',\1v_row.title,' || E'\n    ''poster_url'', v_row.poster_url,');
    if position('''poster_url''' in d) = 0 then raise exception 'get_outing : emplacement introuvable'; end if;
    execute d;
  end if;
end $$;

-- Vérification
select 'MISE A JOUR 41 OK' as resultat,
       exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'outings' and column_name = 'poster_url') as colonne_affiche;


-- ===================== Vérification finale =====================
notify pgrst, 'reload schema';
select
  (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'aircraft' and column_name = 'available') = 1
    and exists (select 1 from pg_proc where proname = 'set_aircraft_availability')
    and exists (select 1 from pg_proc where proname = 'set_maintenance')
    and exists (select 1 from pg_proc where proname = 'review_outing')
    and to_regclass('public.announcements') is not null
    and to_regclass('public.bar_products') is not null
    and to_regclass('public.pilot_weights') is not null
    and to_regclass('public.aircraft_documents') is not null
    and exists (select 1 from information_schema.columns where table_name = 'outings' and column_name = 'kind')
    and exists (select 1 from information_schema.columns where table_name = 'bar_products' and column_name = 'category')
    and exists (select 1 from pg_proc where proname = 'set_function')
    and exists (select 1 from pg_proc where proname = 'event_mail_recipients')
    and exists (select 1 from pg_proc where proname = 'can_manage_docs')
    and exists (select 1 from pg_proc where proname = 'anonymize_member')
    and to_regclass('public.audit_log') is not null
    and to_regclass('public.club_links') is not null
    and to_regclass('public.aircraft_mb') is not null
    and exists (select 1 from information_schema.columns where table_name = 'aircraft_mb' and column_name = 'mzfw')
    and to_regclass('public.airfield_tips') is not null
    and exists (select 1 from pg_proc where proname = 'move_crew')
    and exists (select 1 from information_schema.columns where table_name = 'outings' and column_name = 'referent_instructor_id')
    and to_regclass('public.shop_orders') is not null
    and to_regclass('public.flight_shares') is not null
    and exists (select 1 from pg_proc where proname = 'set_shop_order_status')
    and exists (select 1 from pg_proc where proname = 'quiz_today')
    and to_regclass('public.rex_reports') is not null
    and exists (select 1 from pg_proc where proname = '_can_fly_in')
    and exists (select 1 from pg_proc where proname = 'set_guest_count')
    and exists (select 1 from pg_proc where proname = 'place_waitlisted')
    and exists (select 1 from pg_proc where proname = 'admin_export')
    and to_regclass('public._seeds') is not null
    and exists (select 1 from pg_policies where policyname = 'quiz_questions_teach_update')
    and exists (select 1 from pg_proc where proname = 'quiz_today_set')
    and exists (select 1 from public._seeds where name = 'quiz-flotte-35')
    and to_regclass('public.shop_stock') is not null and to_regclass('public.quiz_daily_set') is not null and exists (select 1 from pg_trigger where tgname = 'on_auth_user_deleted') and to_regclass('public.shop_settings') is not null and exists (select 1 from pg_proc where proname = 'set_outing_poster') and (select is_nullable from information_schema.columns where table_schema = 'public' and table_name = 'outings' and column_name = 'departure_at') = 'YES'
  as "TOUT EST A JOUR",
  (select count(*) from public.profiles) as membres,
  (select string_agg(registration, ', ' order by registration) from public.aircraft) as avions,
  (select count(*) from public.aircraft_mb where empty_mass is not null and jsonb_array_length(envelope) >= 3) as "avions M&C prêts";
