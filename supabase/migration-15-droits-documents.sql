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
