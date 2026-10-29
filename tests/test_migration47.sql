\set ON_ERROR_STOP on
set client_min_messages = warning;
select set_config('t.m', (select id::text from public.profiles where role = 'member' and anonymized_at is null order by email limit 1), false);
select set_config('t.m2', (select id::text from public.profiles where role = 'member' and anonymized_at is null order by email offset 1 limit 1), false);
set role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
insert into public.logbook_settings (licence_type, licence_number, licence_issued, night_rating) values ('LAPL', 'FRA.FCL.123456', current_date - 400, true)
  on conflict (user_id) do update set licence_type = excluded.licence_type, licence_number = excluded.licence_number;
do $$ begin
  assert (select licence_type from public.logbook_settings) = 'LAPL', 'licence enregistrée';
  begin update public.logbook_settings set licence_type = 'ATPL'; raise exception 'ATTENDU';
  exception when check_violation then null; end;
end $$;
select set_config('request.jwt.claim.sub', current_setting('t.m2'), false);
do $$ begin assert (select count(*) from public.logbook_settings where licence_number = 'FRA.FCL.123456') = 0, 'numéro de licence privé'; end $$;
select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
delete from public.logbook_settings;
reset role;
select 'TEST MIGRATION 47 OK';
