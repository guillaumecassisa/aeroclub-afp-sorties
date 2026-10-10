\set ON_ERROR_STOP on
set client_min_messages = warning;
update public.profiles set role='member', is_instructor=false, is_board=false, is_treasurer=false, is_secretary=false, is_maintenance=false
 where id in ('00000000-0000-0000-0000-000000000105','00000000-0000-0000-0000-000000000106');
update public.profiles set is_treasurer = true where id = '00000000-0000-0000-0000-000000000106';
create or replace function pg_temp.try_ann(u text) returns boolean language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', u, false);
  execute 'set role authenticated';
  begin
    insert into public.announcements (title) values ('Test annonce');
    execute 'reset role'; return true;
  exception when insufficient_privilege then execute 'reset role'; return false; end;
end $$;
do $$ begin
  assert not pg_temp.try_ann('00000000-0000-0000-0000-000000000105'), 'simple membre refusé';
  assert pg_temp.try_ann('00000000-0000-0000-0000-000000000106'), 'trésorier autorisé';
  assert pg_temp.try_ann((select id::text from public.profiles where role='admin' limit 1)), 'admin autorisé';
end $$;
delete from public.announcements where title = 'Test annonce';
select 'test_migration17 OK';
