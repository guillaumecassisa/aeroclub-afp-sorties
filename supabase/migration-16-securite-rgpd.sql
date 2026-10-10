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
