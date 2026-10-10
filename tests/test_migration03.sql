\set ON_ERROR_STOP on
set client_min_messages = warning;

-- types déduits du modèle
do $$ begin
  assert (select type from public.aircraft where registration = 'F-GAAA') = 'DR400', 'DR400-180 -> DR400';
  assert (select type from public.aircraft where registration = 'F-GCCC') = 'WT9', 'WT9 -> WT9';
  assert to_regclass('public.pilot_aircraft') is null, 'ancienne table supprimée';
  -- le lâcher F-GAAA du membre 4 (migration 02) devient un lâcher DR400
  assert exists (select 1 from public.pilot_types
                 where user_id = '00000000-0000-0000-0000-000000000104' and aircraft_type = 'DR400'), 'reprise';
end $$;

-- lâché DR400 => lâché sur les deux DR400 de la sortie
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
do $$ declare d jsonb; o uuid; n int; begin
  select id into o from public.outings where title = 'Sortie Corse';
  d := public.get_outing(o);
  select count(*) into n from jsonb_array_elements(d->'aircraft') a, jsonb_array_elements(a->'occupants') p
   where p->>'user_id' = '00000000-0000-0000-0000-000000000104'
     and (p->>'released')::boolean = (a->>'type' = 'DR400');
  assert n = 1, 'lâcher par type exposé';
end $$;

-- un membre gère ses types, pas ceux des autres
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000105', false);
set role authenticated;
insert into public.pilot_types (user_id, aircraft_type) values (auth.uid(), 'PS28');
do $$ begin
  begin
    insert into public.pilot_types (user_id, aircraft_type) values ('00000000-0000-0000-0000-000000000106', 'PS28');
    raise exception 'devait échouer';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

\echo '=== TESTS MIGRATION 03 PASSÉS ==='
