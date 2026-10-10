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
