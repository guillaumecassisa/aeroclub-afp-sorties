\set ON_ERROR_STOP on
set client_min_messages = warning;
do $$ begin assert (select count(*) from public.airfield_tips where icao='LFTF') = 1, 'bon plan initial'; end $$;
-- un membre validé ajoute un bon plan
update public.profiles set role='member' where id = '00000000-0000-0000-0000-000000000105';
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000105', false);
set role authenticated;
insert into public.airfield_tips (icao, airfield_name, lat, lon, category, title, contact)
  values ('LFMA', 'Aix Les Milles', 43.5063, 5.3664, 'resto', 'Test resto', '04 42 00 00 00');
do $$ declare n int; begin
  assert (select count(*) from public.airfield_tips) = 2, 'lecture';
  -- il ne peut pas modifier celui d'un autre
  update public.airfield_tips set title = 'x' where icao = 'LFTF'; get diagnostics n = row_count; assert n = 0, 'pas le bon plan d''un autre';
  -- il peut archiver le sien
  update public.airfield_tips set archived_at = now() where title = 'Test resto'; get diagnostics n = row_count; assert n = 1, 'archive le sien';
end $$;
-- pas d'effacement
do $$ begin
  begin delete from public.airfield_tips; raise exception 'delete permis'; exception when insufficient_privilege then null; end;
end $$;
-- lien javascript: refusé
do $$ begin
  begin insert into public.airfield_tips (icao, airfield_name, lat, lon, title, contact) values ('LFMA','Aix',43.5,5.3,'x','javascript:alert(1)');
    raise exception 'contact non filtré'; exception when check_violation then null; end;
end $$;
reset role;
-- un membre en attente ne voit rien
update public.profiles set role='pending' where id = '00000000-0000-0000-0000-000000000105';
set role authenticated;
do $$ begin assert (select count(*) from public.airfield_tips) = 0, 'pending ne voit rien'; end $$;
reset role;
update public.profiles set role='member' where id = '00000000-0000-0000-0000-000000000105';
do $$ begin assert exists (select 1 from public.audit_log where table_name = 'airfield_tips'), 'journal'; end $$;
\i supabase/migration-23-bons-plans.sql
select 'test_migration23 OK';
