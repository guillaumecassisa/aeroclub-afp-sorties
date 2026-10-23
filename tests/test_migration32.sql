\set ON_ERROR_STOP on
set client_min_messages = warning;
-- Export : réservé aux administrateurs, contient toutes les tables
select set_config('request.jwt.claim.sub', (select id::text from public.profiles where role = 'member' and anonymized_at is null order by email limit 1), false);
do $$ begin
  begin perform public.admin_export(); raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; assert sqlerrm like '%administrateurs%', sqlerrm; end;
end $$;
select set_config('request.jwt.claim.sub', (select id::text from public.profiles where role = 'admin' and anonymized_at is null order by email limit 1), false);
do $$ declare e jsonb := public.admin_export(); begin
  assert e -> 'tables' ? 'profiles' and e -> 'tables' ? 'outings' and e -> 'tables' ? 'rex_reports', 'tables exportées';
  assert jsonb_typeof(e -> 'files') = 'array', 'liste des fichiers';
end $$;
-- Catégorie « taxes » acceptée
insert into public.airfield_tips (icao, airfield_name, lat, lon, category, title, created_by)
values ('LFMQ', 'Le Castellet', 43.2, 5.8, 'taxes', 'Taxe atterrissage', null);
select 'test_migration32 OK';
