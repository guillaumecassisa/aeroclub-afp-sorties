\set ON_ERROR_STOP on
set client_min_messages = warning;
select set_config('t.a', (select id::text from public.aircraft where registration = 'F-HUIT'), false);
-- membre simple : refusé
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000107', false);
do $$ begin
  begin perform public.set_aircraft_availability(current_setting('t.a')::uuid, true); raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; end;
end $$;
-- admin le nomme responsable maintenance
select set_config('request.jwt.claim.sub', (select id::text from public.profiles where role='admin' limit 1), false);
select public.set_maintenance('00000000-0000-0000-0000-000000000107', true);
-- il peut changer la dispo
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000107', false);
select public.set_aircraft_availability(current_setting('t.a')::uuid, true);
do $$ begin assert (select available from public.aircraft where id = current_setting('t.a')::uuid); end $$;
select public.set_aircraft_availability(current_setting('t.a')::uuid, false, 'Visite 100 h');
do $$ begin assert (select unavailable_reason = 'Visite 100 h' and not available from public.aircraft where id = current_setting('t.a')::uuid); end $$;
set role authenticated;
update public.aircraft set type = 'PS28' where id = current_setting('t.a')::uuid;
reset role;
-- un instructeur non maintenance : refusé via RLS (0 ligne)
select set_config('request.jwt.claim.sub', (select id::text from public.profiles where role='instructor' and not is_maintenance limit 1), false);
set role authenticated;
do $$ declare n int; begin
  update public.aircraft set type = 'XX' where id = current_setting('t.a')::uuid; get diagnostics n = row_count;
  assert n = 0, 'instructeur ne modifie pas la flotte';
end $$;
reset role;
\echo '=== TESTS MAINTENANCE PASSÉS ==='
