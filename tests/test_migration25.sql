\set ON_ERROR_STOP on
set client_min_messages = warning;

-- Colonne présente
do $$ begin
  assert exists (select 1 from information_schema.columns
                  where table_name = 'outings' and column_name = 'referent_instructor_id'), 'colonne référent';
end $$;

-- get_outing fonctionne avec le poids (updated_at) pour l'organisateur
select set_config('request.jwt.claim.sub', (select id::text from public.profiles where role = 'member' order by email limit 1), false);
insert into public.pilot_weights (user_id, weight_kg) values (current_setting('request.jwt.claim.sub')::uuid, 80)
  on conflict (user_id) do update set weight_kg = 80, updated_at = now();
select public.save_outing(null, 'Test 25', 'LFMV', null, null, now() + interval '30 days', null, null,
       null, null, 'activite', 10);
select set_config('t.o25', (select id::text from public.outings where title = 'Test 25'), false);
do $$ begin
  assert (public.get_outing(current_setting('t.o25')::uuid) ->> 'organizer_weight_kg')::numeric = 80, 'poids organisateur';
end $$;

select 'test_migration25 OK';
