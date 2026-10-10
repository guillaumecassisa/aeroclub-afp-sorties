\set ON_ERROR_STOP on
set client_min_messages = warning;
do $$ begin assert (select empty_mass = 393.5 and mtow = 600 and jsonb_array_length(stations) = 3
  from public.aircraft_mb m join public.aircraft a on a.id = m.aircraft_id where a.registration = 'F-HSAA'), 'préremplissage'; end $$;
update public.profiles set role='member', is_instructor=false, is_board=false, is_treasurer=false, is_secretary=false, is_maintenance=false
 where id = '00000000-0000-0000-0000-000000000105';
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000105', false);
set role authenticated;
do $$ declare n int; begin
  assert (select count(*) from public.aircraft_mb) >= 1, 'lecture membre';
  update public.aircraft_mb set mtow = 900; get diagnostics n = row_count; assert n = 0, 'membre ne modifie pas';
end $$;
reset role;
update public.profiles set is_maintenance = true where id = '00000000-0000-0000-0000-000000000105';
set role authenticated;
do $$ declare n int; begin
  update public.aircraft_mb set fuel_arm = 0.68 where aircraft_id = (select id from public.aircraft where registration='F-HSAA');
  get diagnostics n = row_count; assert n = 1, 'maintenance modifie';
end $$;
reset role;
update public.profiles set is_maintenance = false where id = '00000000-0000-0000-0000-000000000105';
do $$ begin assert exists (select 1 from public.audit_log where table_name = 'aircraft_mb'), 'journal'; end $$;
select 'test_migration20 OK';
