\set ON_ERROR_STOP on
set client_min_messages = warning;
-- F-HSAA était pré-rempli (source Inside) : il est mis à jour
do $$ begin assert (select empty_moment = 169.789 and fuel_arm = 0.18 and jsonb_array_length(stations) = 5 and jsonb_array_length(envelope) = 4
  from public.aircraft_mb m join public.aircraft a on a.id = m.aircraft_id where a.registration = 'F-HSAA'), 'F-HSAA mis à jour'; end $$;
-- toute la flotte a ses données type
do $$ begin assert (select count(*) from public.aircraft_mb m join public.aircraft a on a.id = m.aircraft_id
  where a.registration in ('F-HSAA','F-HNLR','F-HUIT','F-HSAC','F-HPSA','F-HSAG','F-HVXD','F-HUFA','F-HCLI','F-HXAF')) = 10, '10 avions'; end $$;
do $$ begin assert (select mzfw = 660 and (stations->4->>'wing')::boolean from public.aircraft_mb m join public.aircraft a on a.id = m.aircraft_id where a.registration='F-HUFA'), 'B23'; end $$;
do $$ begin assert (select (stations->4->>'fuel')::boolean and mlw = 1045 from public.aircraft_mb m join public.aircraft a on a.id = m.aircraft_id where a.registration='F-HCLI'), 'DR400'; end $$;
do $$ begin assert (select empty_mass is null from public.aircraft_mb m join public.aircraft a on a.id = m.aircraft_id where a.registration='F-HSAG'), 'F-HSAG sans pesée'; end $$;
-- une fiche retouchée à la main n'est pas écrasée par une nouvelle exécution
update public.aircraft_mb set source = 'Saisie manuelle', empty_mass = 400 where aircraft_id = (select id from public.aircraft where registration='F-HUIT');
\i supabase/migration-21-documents-masse-centrage.sql
do $$ begin assert (select empty_mass = 400 from public.aircraft_mb m join public.aircraft a on a.id = m.aircraft_id where a.registration='F-HUIT'), 'pas d''écrasement'; end $$;
-- nouvelle catégorie de documents
insert into public.aircraft_documents (aircraft_id, category, title, file_path, file_name)
  values ((select id from public.aircraft where registration='F-HUFA'), 'equipements', 'Garmin G3X', 'x/y.pdf', 'y.pdf');
select 'test_migration21 OK';
