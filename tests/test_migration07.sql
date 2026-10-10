\set ON_ERROR_STOP on
set client_min_messages = warning;
select set_config('t.o', (select id::text from public.outings where title like 'Balade Verdon%'), false);

-- 107 (inscrit) et 106 (organisateur) renseignent leur poids
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000107', false);
set role authenticated;
insert into public.pilot_weights (user_id, weight_kg) values (auth.uid(), 82.5);
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000106', false);
set role authenticated;
insert into public.pilot_weights (user_id, weight_kg) values (auth.uid(), 75);
do $$ begin assert (select count(*) from public.pilot_weights) = 1, 'ne voit que le sien'; end $$;
reset role;

-- Un autre membre : ne lit rien, ne peut rien écrire pour autrui
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000108', false);
set role authenticated;
do $$ begin assert (select count(*) from public.pilot_weights) = 0, 'invisible'; end $$;
do $$ begin
  begin
    insert into public.pilot_weights (user_id, weight_kg) values ('00000000-0000-0000-0000-000000000107', 50);
    raise exception 'ATTENDU erreur';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ declare o jsonb := public.get_outing(current_setting('t.o')::uuid); begin
  assert (select bool_and(p->'weight_kg' = 'null'::jsonb) from jsonb_array_elements(o->'aircraft') a, jsonb_array_elements(a->'occupants') p), 'membre: pas de poids';
end $$;

-- Un admin qui n'est pas l'organisateur : pas de poids
select set_config('request.jwt.claim.sub', (select id::text from public.profiles where role = 'admin' limit 1), false);
do $$ declare o jsonb := public.get_outing(current_setting('t.o')::uuid); begin
  assert (select bool_and(p->'weight_kg' = 'null'::jsonb) from jsonb_array_elements(o->'aircraft') a, jsonb_array_elements(a->'occupants') p), 'admin: pas de poids';
end $$;

-- L'organisateur voit les poids
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000106', false);
do $$ declare o jsonb := public.get_outing(current_setting('t.o')::uuid); begin
  assert (o->>'is_organizer')::boolean;
  assert (o->>'organizer_weight_kg')::numeric = 75;
  assert (select (p->>'weight_kg')::numeric from jsonb_array_elements(o->'aircraft') a, jsonb_array_elements(a->'occupants') p
          where p->>'user_id' = '00000000-0000-0000-0000-000000000107') = 82.5, 'organisateur voit';
end $$;
\echo '=== TESTS POIDS PASSÉS ==='
