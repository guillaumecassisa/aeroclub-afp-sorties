\set ON_ERROR_STOP on
set client_min_messages = warning;
select set_config('t.a', (select id::text from public.aircraft where registration = 'F-HUIT'), false);
update public.profiles set role='member', is_instructor=false, is_board=false, is_treasurer=false, is_secretary=false, is_maintenance=false
 where id = '00000000-0000-0000-0000-000000000105';
create or replace function pg_temp.try_insert(p_user text, p_path text) returns boolean language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_user, false);
  execute 'set role authenticated';
  begin
    insert into public.aircraft_documents (aircraft_id, category, title, file_path, file_name)
    values (current_setting('t.a')::uuid, 'checklist', 'x', p_path, 'x.pdf');
    execute 'reset role'; return true;
  exception when insufficient_privilege then execute 'reset role'; return false; end;
end $$;
do $$ begin assert not pg_temp.try_insert('00000000-0000-0000-0000-000000000105', 'u/1.pdf'), 'membre refusé'; end $$;
update public.profiles set is_treasurer=true where id='00000000-0000-0000-0000-000000000105';
do $$ begin assert pg_temp.try_insert('00000000-0000-0000-0000-000000000105', 'u/2.pdf'), 'trésorier autorisé'; end $$;
delete from public.aircraft_documents where file_path like 'u/%';
select 'test_migration18 OK';
