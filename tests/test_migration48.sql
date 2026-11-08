\set ON_ERROR_STOP on
set client_min_messages = warning;
do $$
declare st jsonb;
begin
  -- plus de doublon réservoir principal + poste carburant
  assert (select count(*) from public.aircraft_mb m
           where coalesce(m.fuel_capacity_l, 0) > 0
             and exists (select 1 from jsonb_array_elements(m.stations) s where (s->>'fuel')::boolean)) = 0, 'doublon carburant';
  -- PS28 : deux réservoirs d'aile de 57 L
  select m.stations into st from public.aircraft_mb m join public.aircraft a on a.id = m.aircraft_id where a.registration = 'F-HNLR';
  assert (select count(*) from jsonb_array_elements(st) s where (s->>'fuel')::boolean) = 2, 'PS28 : 2 réservoirs';
  assert (select bool_and((s->>'max')::numeric = 57) from jsonb_array_elements(st) s where (s->>'fuel')::boolean), 'PS28 : 57 L par aile';
  assert st::text like '%aile gauche%' and st::text like '%aile droite%', 'PS28 : gauche et droite';
  -- DR400 : principal + 2 ailes de 40 L
  select m.stations into st from public.aircraft_mb m join public.aircraft a on a.id = m.aircraft_id where a.registration = 'F-HCLI';
  assert (select count(*) from jsonb_array_elements(st) s where (s->>'fuel')::boolean) = 3, 'DR400 : 3 réservoirs';
  assert (select count(*) from jsonb_array_elements(st) s where (s->>'max')::numeric = 40 and (s->>'fuel')::boolean) = 2, 'DR400 : 2 × 40 L';
  -- WT9 inchangé (réservoir unique)
  assert (select fuel_capacity_l from public.aircraft_mb m join public.aircraft a on a.id = m.aircraft_id where a.registration = 'F-HVXD') = 80, 'WT9 inchangé';
end $$;
select 'TEST MIGRATION 48 OK';
