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
