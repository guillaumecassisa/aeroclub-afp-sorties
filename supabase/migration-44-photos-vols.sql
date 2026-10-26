-- =====================================================================
--  Mise à jour n°44 : photos de vol (onglet « Photos » de Shareflight)
--  Les membres partagent les photos de leurs vols avec une légende, le trajet
--  et l'avion. Chacun peut supprimer ses photos ; un administrateur peut
--  retirer n'importe quelle photo. Visibles des seuls membres validés.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Les photos
create table if not exists public.flight_photos (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  path        text not null unique check (path like 'photos/%' and length(path) <= 300),
  url         text not null check (url ~ '^https?://' and length(url) <= 500),
  caption     text check (caption is null or length(caption) <= 300),
  route       text check (route is null or length(route) <= 80),
  aircraft    text check (aircraft is null or length(aircraft) <= 40),
  taken_on    date,
  created_at  timestamptz not null default now()
);
create index if not exists flight_photos_created on public.flight_photos (created_at desc);
alter table public.flight_photos enable row level security;
revoke all on public.flight_photos from anon, authenticated;
grant select, insert, delete on public.flight_photos to authenticated;

drop policy if exists flight_photos_select on public.flight_photos;
create policy flight_photos_select on public.flight_photos for select to authenticated using (public.is_approved());
drop policy if exists flight_photos_insert on public.flight_photos;
create policy flight_photos_insert on public.flight_photos for insert to authenticated
  with check (public.is_approved() and user_id = auth.uid() and path like 'photos/' || auth.uid()::text || '/%');
drop policy if exists flight_photos_delete on public.flight_photos;
create policy flight_photos_delete on public.flight_photos for delete to authenticated
  using (user_id = auth.uid() or public.app_role() = 'admin');

-- 2. Fichiers : stockage « documents », dossier photos/<identifiant du membre>/
drop policy if exists flight_photos_files_insert on storage.objects;
create policy flight_photos_files_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'documents' and name like 'photos/%'
              and split_part(name, '/', 2) = auth.uid()::text and public.is_approved());
drop policy if exists flight_photos_files_delete on storage.objects;
create policy flight_photos_files_delete on storage.objects for delete to authenticated
  using (bucket_id = 'documents' and name like 'photos/%'
         and (split_part(name, '/', 2) = auth.uid()::text or public.app_role() = 'admin'));

-- 3. Anonymisation d'un membre : ses photos partent avec ses données
do $$
declare d text;
begin
  select pg_get_functiondef('public._anonymize_profile(uuid)'::regprocedure) into d;
  if position('flight_photos' in d) = 0 then
    d := replace(d, 'delete from public.pilot_types where user_id = p_user;',
                    'delete from public.pilot_types where user_id = p_user;' || E'\n  delete from public.flight_photos where user_id = p_user;');
    if position('flight_photos' in d) = 0 then raise exception '_anonymize_profile : emplacement introuvable'; end if;
    execute d;
  end if;
end $$;

-- Journal des modifications
do $$ begin
  if exists (select 1 from pg_proc where proname = '_audit' and pronamespace = 'public'::regnamespace) then
    execute 'drop trigger if exists zz_audit on public.flight_photos';
    execute 'create trigger zz_audit after delete on public.flight_photos for each row execute function public._audit()';
  end if;
end $$;

-- Vérification
select 'MISE A JOUR 44 OK' as resultat, to_regclass('public.flight_photos') is not null as table_photos;
