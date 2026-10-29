\set ON_ERROR_STOP on
set client_min_messages = warning;
select set_config('t.m', (select id::text from public.profiles where role = 'member' and anonymized_at is null order by email limit 1), false);
set role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
insert into public.logbook_entries (flight_date, sim_date, sim_type, sim_min, remarks) values (current_date, current_date, 'FNPT II', 60, 'Sim test');
do $$ begin assert (select sim_date from public.logbook_entries where remarks = 'Sim test') = current_date, 'date simulateur'; end $$;
delete from public.logbook_entries where remarks = 'Sim test';
reset role;
select 'TEST MIGRATION 46 OK';
