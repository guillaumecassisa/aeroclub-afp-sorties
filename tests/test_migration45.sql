\set ON_ERROR_STOP on
set client_min_messages = warning;
select set_config('t.m', (select id::text from public.profiles where role = 'member' and anonymized_at is null order by email limit 1), false);
select set_config('t.m2', (select id::text from public.profiles where role = 'member' and anonymized_at is null order by email offset 1 limit 1), false);
select set_config('t.adm', (select id::text from public.profiles where role = 'admin' order by email limit 1), false);
select set_config('t.p', (select id::text from public.profiles where role = 'pending' limit 1), false);

set role authenticated;
-- Un membre note un vol dans son carnet
select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
insert into public.logbook_entries (flight_date, dep_place, arr_place, aircraft_model, aircraft_reg, se_min, total_min, pic_min, landings_day, remarks)
values (current_date, 'LFMA', 'LFKC', 'DR400', 'F-HCLI', 95, 95, 95, 1, 'Carnet test');
insert into public.logbook_settings (sep_expiry) values (current_date + 200)
  on conflict (user_id) do update set sep_expiry = excluded.sep_expiry;
do $$ begin
  assert (select count(*) from public.logbook_entries where remarks = 'Carnet test') = 1, 'visible par son pilote';
  -- pas au nom d'un autre
  begin insert into public.logbook_entries (user_id, flight_date) values (current_setting('t.m2')::uuid, current_date); raise exception 'ATTENDU';
  exception when insufficient_privilege then null; end;
  -- valeurs contrôlées
  begin insert into public.logbook_entries (flight_date, total_min) values (current_date, -5); raise exception 'ATTENDU';
  exception when check_violation then null; end;
end $$;
update public.logbook_entries set landings_day = 3 where remarks = 'Carnet test';

-- Un autre membre ne le voit pas et ne peut pas le modifier
select set_config('request.jwt.claim.sub', current_setting('t.m2'), false);
do $$ begin
  assert (select count(*) from public.logbook_entries where remarks = 'Carnet test') = 0, 'invisible des autres membres';
  assert (select count(*) from public.logbook_settings) = 0, 'réglages invisibles des autres';
end $$;
update public.logbook_entries set landings_day = 99 where remarks = 'Carnet test';
delete from public.logbook_entries where remarks = 'Carnet test';

-- L'administrateur non plus
select set_config('request.jwt.claim.sub', current_setting('t.adm'), false);
do $$ begin assert (select count(*) from public.logbook_entries where remarks = 'Carnet test') = 0, 'invisible de l''admin'; end $$;

-- Un compte non validé ne peut rien noter
select set_config('request.jwt.claim.sub', current_setting('t.p'), false);
do $$ begin
  begin insert into public.logbook_entries (flight_date) values (current_date); raise exception 'ATTENDU';
  exception when insufficient_privilege then null; end;
end $$;

-- Le pilote retrouve son vol intact, puis le supprime
select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
do $$ begin
  assert (select landings_day from public.logbook_entries where remarks = 'Carnet test') = 3, 'non modifié par un autre';
end $$;
delete from public.logbook_entries where remarks = 'Carnet test';
delete from public.logbook_settings;
do $$ begin assert (select count(*) from public.logbook_entries where remarks = 'Carnet test') = 0, 'supprimé par son pilote'; end $$;
reset role;
do $$ begin
  assert position('logbook_entries' in pg_get_functiondef('public._anonymize_profile(uuid)'::regprocedure)) > 0, 'anonymisation : carnet';
end $$;
select 'TEST MIGRATION 45 OK';
