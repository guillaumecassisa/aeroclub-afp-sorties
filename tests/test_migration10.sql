\set ON_ERROR_STOP on
set client_min_messages = warning;
select set_config('t.a', (select id::text from public.aircraft where registration = 'F-HUIT'), false);
-- membre simple : lit mais ne peut pas ajouter
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000106', false);
update public.profiles set is_maintenance = false where id = '00000000-0000-0000-0000-000000000106';
set role authenticated;
do $$ begin
  begin
    insert into public.aircraft_documents (aircraft_id, category, title, file_path, file_name)
    values (current_setting('t.a')::uuid, 'manuel', 'x', 'x/y.pdf', 'y.pdf');
    raise exception 'ATTENDU';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
-- resp. maintenance (107, nommé au test 09) : ajoute
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000107', false);
set role authenticated;
insert into public.aircraft_documents (aircraft_id, category, title, file_path, file_name)
values (current_setting('t.a')::uuid, 'manuel', 'Manuel de vol PS28', 'a/manuel.pdf', 'manuel.pdf');
reset role;
-- le membre simple le voit
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000106', false);
set role authenticated;
do $$ begin assert (select count(*) from public.aircraft_documents) = 1, 'visible par les membres'; end $$;
do $$ declare n int; begin
  delete from public.aircraft_documents; get diagnostics n = row_count; assert n = 0, 'membre ne supprime pas';
end $$;
reset role;
\echo '=== TESTS DOCUMENTS PASSÉS ==='
