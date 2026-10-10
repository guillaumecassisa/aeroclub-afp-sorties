\set ON_ERROR_STOP on
set client_min_messages = warning;
-- L'instructeur crée une sortie : F-GCCC (2 places, lui à bord) + F-GBBB (4 places)
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
update public.aircraft set active = true where registration in ('F-GCCC', 'F-GBBB');
select public.save_outing(null, 'Test répartition', 'LFMV', null, null, now() + interval '12 days', null, null,
       array['cccccccc-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000004']::uuid[],
       'cccccccc-0000-0000-0000-000000000002', 'vol', null);
select set_config('t.o', (select id::text from public.outings where title = 'Test répartition'), false);
select set_config('t.a', 'cccccccc-0000-0000-0000-000000000002', false);
select set_config('t.b', 'bbbbbbbb-0000-0000-0000-000000000004', false);

-- 5 inscrits (le 1er va dans F-GCCC, les 4 suivants dans F-GBBB)
do $$ declare u uuid; begin
  for u in select id from public.profiles where role = 'member' and email like 'm%@club.fr' order by email limit 5 loop
    perform public.register_for_outing(current_setting('t.o')::uuid, u);
  end loop;
  assert (select count(*) from public.registrations where outing_id = current_setting('t.o')::uuid and status = 'confirmed') = 5, '5 confirmés';
  assert (select count(*) from public.registrations where outing_id = current_setting('t.o')::uuid and aircraft_id = current_setting('t.a')::uuid) = 1, '1 dans A';
end $$;
select set_config('t.r1', (select id::text from public.registrations where outing_id = current_setting('t.o')::uuid and aircraft_id = current_setting('t.a')::uuid), false);
select set_config('t.r2', (select id::text from public.registrations where outing_id = current_setting('t.o')::uuid and aircraft_id = current_setting('t.b')::uuid order by created_at limit 1), false);

-- A et B sont pleins : déplacement simple refusé
do $$ begin
  begin perform public.move_crew(current_setting('t.o')::uuid, current_setting('t.r2'), current_setting('t.a')::uuid);
    raise exception 'ATTENDU'; exception when others then if sqlerrm = 'ATTENDU' then raise; end if;
    assert sqlerrm like '%complet%', sqlerrm; end;
end $$;

-- Échange r2 (B) <-> r1 (A)
select public.move_crew(current_setting('t.o')::uuid, current_setting('t.r2'), current_setting('t.a')::uuid, current_setting('t.r1'));
do $$ begin
  assert (select aircraft_id from public.registrations where id = current_setting('t.r2')::uuid) = current_setting('t.a')::uuid, 'r2 dans A';
  assert (select aircraft_id from public.registrations where id = current_setting('t.r1')::uuid) = current_setting('t.b')::uuid, 'r1 dans B';
end $$;

-- Un désistement dans B libère une place : r2 peut y retourner seul (A a alors 1 place libre)
do $$ begin
  perform public.cancel_registration((select id from public.registrations where outing_id = current_setting('t.o')::uuid
     and aircraft_id = current_setting('t.b')::uuid and id <> current_setting('t.r1')::uuid order by created_at desc limit 1));
end $$;
select public.move_crew(current_setting('t.o')::uuid, current_setting('t.r2'), current_setting('t.b')::uuid);
do $$ begin
  assert (select aircraft_id from public.registrations where id = current_setting('t.r2')::uuid) = current_setting('t.b')::uuid, 'r2 de retour dans B';
end $$;

-- L'organisateur échange sa place avec r1 (B) : il passe dans B, r1 dans A
select public.move_crew(current_setting('t.o')::uuid, 'organizer', current_setting('t.b')::uuid, current_setting('t.r1'));
do $$ begin
  assert (select instructor_aircraft_id from public.outings where id = current_setting('t.o')::uuid) = current_setting('t.b')::uuid, 'orga dans B';
  assert (select aircraft_id from public.registrations where id = current_setting('t.r1')::uuid) = current_setting('t.a')::uuid, 'r1 dans A';
  -- get_outing reflète la nouvelle répartition, capacités cohérentes
  assert (select bool_and(jsonb_array_length(a->'occupants') <= (a->>'capacity')::int)
            from jsonb_array_elements(public.get_outing(current_setting('t.o')::uuid)->'aircraft') a), 'capacités';
end $$;
-- un nouveau passage de rééquilibrage ne change rien
do $$ begin assert jsonb_array_length(public._rebalance_outing(current_setting('t.o')::uuid)) = 0, 'stable'; end $$;

-- Un simple membre ne peut pas déplacer
select set_config('request.jwt.claim.sub', (select user_id::text from public.registrations where id = current_setting('t.r2')::uuid), false);
do $$ begin
  begin perform public.move_crew(current_setting('t.o')::uuid, current_setting('t.r2'), current_setting('t.a')::uuid);
    raise exception 'ATTENDU'; exception when others then if sqlerrm = 'ATTENDU' then raise; end if;
    assert sqlerrm like '%organisateur%', sqlerrm; end;
end $$;
-- Avion hors sortie refusé
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
do $$ begin
  begin perform public.move_crew(current_setting('t.o')::uuid, current_setting('t.r2'), 'aaaaaaaa-0000-0000-0000-000000000004');
    raise exception 'ATTENDU'; exception when others then if sqlerrm = 'ATTENDU' then raise; end if;
    assert sqlerrm like '%ne fait pas partie%', sqlerrm; end;
end $$;
do $$ begin assert exists (select 1 from public.audit_log where table_name = 'outings' and action = 'update' and row_id = current_setting('t.o')), 'journal (organisateur déplacé)'; end $$;
\i supabase/migration-24-deplacer-equipage.sql
select 'test_migration24 OK';
