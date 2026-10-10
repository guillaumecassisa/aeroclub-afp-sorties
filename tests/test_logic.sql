-- Tests de la logique d'inscription / liste d'attente.
\set ON_ERROR_STOP on
set client_min_messages = warning;

create or replace function pg_temp.as_user(p uuid) returns void language sql as
$$ select set_config('request.jwt.claim.sub', coalesce(p::text, ''), false) $$;

create or replace function pg_temp.expect_error(p_sql text, p_like text) returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception 'ATTENDU une erreur contenant "%", aucune levée : %', p_like, p_sql;
exception when others then
  if sqlerrm like 'ATTENDU%' then raise; end if;
  if sqlerrm not like '%' || p_like || '%' then
    raise exception 'Erreur inattendue pour % : % (attendu %)', p_sql, sqlerrm, p_like;
  end if;
end $$;

create or replace function pg_temp.st(p_outing uuid, p_user uuid) returns text language sql as
$$ select status::text from public.registrations where outing_id = p_outing and user_id = p_user and status <> 'cancelled' $$;

-- ---- Données : 1 admin, 1 instructeur, 14 membres, 1 en attente de validation
insert into auth.users (id, email, raw_user_meta_data) values
 ('00000000-0000-0000-0000-0000000000a1', 'admin@club.fr', '{"full_name":"Alice Admin"}'),
 ('00000000-0000-0000-0000-0000000000b1', 'instr@club.fr', '{"full_name":"Ivan Instructeur","phone":"0600000000"}'),
 ('00000000-0000-0000-0000-0000000000c1', 'pending@club.fr', '{"full_name":"Paul Pending"}');
insert into auth.users (id, email, raw_user_meta_data)
select ('00000000-0000-0000-0000-0000000001' || lpad(i::text, 2, '0'))::uuid,
       'm' || i || '@club.fr', jsonb_build_object('full_name', 'Membre ' || i)
from generate_series(1, 14) i;

do $$ begin
  assert (select count(*) from public.profiles) = 17, 'profils créés par trigger';
  assert (select role from public.profiles where email='m1@club.fr') = 'pending', 'rôle par défaut pending';
end $$;

update public.profiles set role = 'admin' where email = 'admin@club.fr';
update public.profiles set role = 'instructor' where email = 'instr@club.fr';
update public.profiles set role = 'member' where email like 'm%@club.fr';

insert into public.aircraft (id, registration, model, seats) values
 ('aaaaaaaa-0000-0000-0000-000000000004', 'F-GAAA', 'DR400-180', 4),
 ('bbbbbbbb-0000-0000-0000-000000000004', 'F-GBBB', 'DR400-140', 4),
 ('cccccccc-0000-0000-0000-000000000002', 'F-GCCC', 'WT9', 2);

-- ---- Un membre ne peut pas créer de sortie
select pg_temp.as_user('00000000-0000-0000-0000-000000000101');
select pg_temp.expect_error($q$ select public.save_outing(null,'X',null,null,null, now()+interval '5 days', null, null,
  array['aaaaaaaa-0000-0000-0000-000000000004']::uuid[], null) $q$, 'réservée aux instructeurs');

-- ---- L'instructeur crée une sortie : 2×4 places + 1×2 places = 10 places, il ne vole pas
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select (public.save_outing(null, 'Sortie Corse', 'LFKC Calvi', 'Déjeuner', 'Hangar',
        now() + interval '10 days', now() + interval '10 days 8 hours', now() + interval '8 days',
        array['aaaaaaaa-0000-0000-0000-000000000004','bbbbbbbb-0000-0000-0000-000000000004','cccccccc-0000-0000-0000-000000000002']::uuid[],
        null) ->> 'outing_id') as outing \gset
select set_config('t.outing', :'outing', false) \g /dev/null

-- ---- 12 inscriptions : 10 confirmés, 2 en attente
do $$
declare i int; v jsonb; o uuid := current_setting('t.outing')::uuid;
begin
  for i in 1..12 loop
    perform pg_temp.as_user(('00000000-0000-0000-0000-0000000001' || lpad(i::text,2,'0'))::uuid);
    v := public.register_for_outing(o);
    if i <= 10 then
      assert v->>'status' = 'confirmed', format('membre %s devrait être confirmé: %s', i, v);
    else
      assert v->>'status' = 'waitlist', format('membre %s devrait être en attente: %s', i, v);
      assert (v->>'waitlist_position')::int = i - 10, format('position attente %s: %s', i, v);
    end if;
  end loop;
end $$;

do $$ declare o uuid := current_setting('t.outing')::uuid; begin
  assert (select count(*) from registrations where outing_id=o and status='confirmed' and aircraft_id='aaaaaaaa-0000-0000-0000-000000000004') = 4;
  assert (select count(*) from registrations where outing_id=o and status='confirmed' and aircraft_id='bbbbbbbb-0000-0000-0000-000000000004') = 4;
  assert (select count(*) from registrations where outing_id=o and status='confirmed' and aircraft_id='cccccccc-0000-0000-0000-000000000002') = 2;
end $$;

-- ---- Double inscription refusée, compte non validé refusé
select pg_temp.as_user('00000000-0000-0000-0000-000000000101');
select pg_temp.expect_error(format('select public.register_for_outing(%L)', :'outing'), 'Déjà inscrit');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
select pg_temp.expect_error(format('select public.register_for_outing(%L)', :'outing'), 'pas encore validé');

-- ---- Un membre ne peut pas annuler l'inscription d'un autre
select pg_temp.as_user('00000000-0000-0000-0000-000000000102');
select pg_temp.expect_error(format(
  'select public.cancel_registration((select id from registrations where outing_id=%L and user_id=%L))',
  :'outing', '00000000-0000-0000-0000-000000000103'), 'autre membre');

-- ---- Le membre 3 (dans F-GAAA) se désiste : membre 11 promu, dans F-GAAA
select pg_temp.as_user('00000000-0000-0000-0000-000000000103');
select public.cancel_registration((select id from registrations where outing_id = :'outing'
        and user_id = '00000000-0000-0000-0000-000000000103' and status <> 'cancelled'))::text as res \gset
select set_config('t.res', :'res', false) \g /dev/null
\echo désistement membre 3 -> :res
do $$ declare o uuid := current_setting('t.outing')::uuid; v jsonb := current_setting('t.res')::jsonb;
begin
  assert jsonb_array_length(v->'changes') = 1, 'une promotion';
  assert v->'changes'->0->>'email' = 'm11@club.fr' and v->'changes'->0->>'change' = 'promoted', 'm11 promu';
  assert pg_temp.st(o, '00000000-0000-0000-0000-000000000111') = 'confirmed';
  assert (select aircraft_id from registrations where outing_id=o and user_id='00000000-0000-0000-0000-000000000111' and status<>'cancelled')
         = 'aaaaaaaa-0000-0000-0000-000000000004', 'm11 prend le siège libéré';
  assert pg_temp.st(o, '00000000-0000-0000-0000-000000000112') = 'waitlist';
end $$;

-- ---- Il se réinscrit : il passe en fin de liste d'attente (position 2)
select public.register_for_outing(:'outing')::text as res \gset
select set_config('t.res', :'res', false) \g /dev/null
do $$ declare v jsonb := current_setting('t.res')::jsonb; begin
  assert v->>'status' = 'waitlist' and (v->>'waitlist_position')::int = 2, format('réinscription: %s', v);
end $$;

-- ---- L'instructeur décide de voler dans F-GBBB : capacité 9 -> le dernier confirmé repasse en attente
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select public.save_outing(:'outing', 'Sortie Corse', 'LFKC Calvi', 'Déjeuner', 'Hangar',
        now() + interval '10 days', now() + interval '10 days 8 hours', now() + interval '8 days',
        array['aaaaaaaa-0000-0000-0000-000000000004','bbbbbbbb-0000-0000-0000-000000000004','cccccccc-0000-0000-0000-000000000002']::uuid[],
        'bbbbbbbb-0000-0000-0000-000000000004')::text as res \gset
select set_config('t.res', :'res', false) \g /dev/null
\echo instructeur à bord -> :res
do $$ declare o uuid := current_setting('t.outing')::uuid; v jsonb := current_setting('t.res')::jsonb;
begin
  assert jsonb_array_length(v->'changes') = 1, 'une rétrogradation';
  -- ordre d'inscription des confirmés : 1,2,4,5,6,7,8,9,10,11 -> le 10e (m11) repasse en attente
  assert v->'changes'->0->>'email' = 'm11@club.fr' and v->'changes'->0->>'change' = 'demoted', 'm11 rétrogradé';
  assert (select count(*) from registrations where outing_id=o and status='confirmed') = 9;
  assert (select count(*) from registrations where outing_id=o and status='confirmed' and aircraft_id='bbbbbbbb-0000-0000-0000-000000000004') <= 3;
  -- m11 inscrit avant m12 : il est 1er en liste d'attente
  assert (public.get_outing(o)->'waitlist'->0->>'full_name') = 'Membre 11', 'm11 en tête de liste';
end $$;

-- ---- Retrait de l'avion 2 places : 2 confirmés de plus en attente, réaffectation cohérente
select public.save_outing(:'outing', 'Sortie Corse', 'LFKC Calvi', null, null,
        now() + interval '10 days', null, null,
        array['aaaaaaaa-0000-0000-0000-000000000004','bbbbbbbb-0000-0000-0000-000000000004']::uuid[],
        'bbbbbbbb-0000-0000-0000-000000000004')::text as res \gset
select set_config('t.res', :'res', false) \g /dev/null
do $$ declare o uuid := current_setting('t.outing')::uuid; v jsonb := current_setting('t.res')::jsonb;
begin
  assert jsonb_array_length(v->'changes') = 2, format('2 rétrogradations: %s', v);
  assert (select count(*) from registrations where outing_id=o and status='confirmed') = 7;
  assert not exists (select 1 from registrations where outing_id=o and aircraft_id='cccccccc-0000-0000-0000-000000000002');
  assert (select count(*) from registrations where outing_id=o and status='confirmed' and aircraft_id='aaaaaaaa-0000-0000-0000-000000000004') = 4;
  assert (select count(*) from registrations where outing_id=o and status='confirmed' and aircraft_id='bbbbbbbb-0000-0000-0000-000000000004') = 3;
end $$;

-- ---- Remise de l'avion 2 places + instructeur ne vole plus : 3 promotions
select public.save_outing(:'outing', 'Sortie Corse', 'LFKC Calvi', null, null,
        now() + interval '10 days', null, null,
        array['aaaaaaaa-0000-0000-0000-000000000004','bbbbbbbb-0000-0000-0000-000000000004','cccccccc-0000-0000-0000-000000000002']::uuid[],
        null)::text as res \gset
select set_config('t.res', :'res', false) \g /dev/null
do $$ declare o uuid := current_setting('t.outing')::uuid; v jsonb := current_setting('t.res')::jsonb;
begin
  assert jsonb_array_length(v->'changes') = 3, format('3 promotions: %s', v);
  assert (select bool_and(c->>'change' = 'promoted') from jsonb_array_elements(v->'changes') c);
  assert (select count(*) from registrations where outing_id=o and status='confirmed') = 10;
  assert (select count(*) from registrations where outing_id=o and status='waitlist') = 2;
end $$;

-- ---- L'instructeur inscrit un membre à sa place ; un membre ne peut pas
select pg_temp.as_user('00000000-0000-0000-0000-000000000101');
select pg_temp.expect_error(format('select public.register_for_outing(%L, %L)', :'outing', '00000000-0000-0000-0000-000000000113'), 'Seul un instructeur');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
do $$ declare v jsonb; begin
  v := public.register_for_outing(current_setting('t.outing')::uuid, '00000000-0000-0000-0000-000000000113');
  assert v->>'status' = 'waitlist' and (v->>'waitlist_position')::int = 3, format('m13 attente 3: %s', v);
end $$;

-- ---- L'instructeur retire un participant confirmé -> premier de la liste promu
do $$ declare v jsonb; o uuid := current_setting('t.outing')::uuid; begin
  v := public.cancel_registration((select id from registrations where outing_id=o and user_id='00000000-0000-0000-0000-000000000101' and status<>'cancelled'));
  assert jsonb_array_length(v->'changes') = 1 and v->'changes'->0->>'change' = 'promoted', format('%s', v);
end $$;

-- ---- Détail et liste
do $$ declare d jsonb; l jsonb; o uuid := current_setting('t.outing')::uuid; begin
  d := public.get_outing(o);
  assert jsonb_array_length(d->'aircraft') = 3;
  assert (select sum(jsonb_array_length(a->'occupants')) from jsonb_array_elements(d->'aircraft') a) = 10;
  assert jsonb_array_length(d->'waitlist') = 2;
  assert (d->>'can_manage')::boolean;
  l := public.list_outings(false);
  assert jsonb_array_length(l) = 1;
  assert (l->0->>'total_capacity')::int = 10 and (l->0->>'confirmed_count')::int = 10 and (l->0->>'waitlist_count')::int = 2, format('%s', l);
end $$;

-- ---- Un membre voit le détail mais pas les téléphones des autres
select pg_temp.as_user('00000000-0000-0000-0000-000000000104');
do $$ declare d jsonb; begin
  d := public.get_outing(current_setting('t.outing')::uuid);
  assert not (d->>'can_manage')::boolean;
  assert (select count(*) from jsonb_array_elements(d->'aircraft') a, jsonb_array_elements(a->'occupants') p
          where p->>'phone' is not null and p->>'user_id' <> '00000000-0000-0000-0000-000000000104') = 0;
  assert d->'my_registration'->>'status' = 'confirmed';
end $$;

-- ---- Date limite dépassée : membre refusé, instructeur accepté
update public.outings set registration_deadline = now() - interval '1 hour' where id = :'outing';
select pg_temp.as_user('00000000-0000-0000-0000-000000000114');
select pg_temp.expect_error(format('select public.register_for_outing(%L)', :'outing'), 'closes');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select (public.register_for_outing(:'outing', '00000000-0000-0000-0000-000000000114') ->> 'status') = 'waitlist' as ok \gset
\if :ok
\else
  \echo ÉCHEC inscription par instructeur après date limite
  select 1/0;
\endif

-- ---- Annulation de la sortie : liste des personnes à prévenir
select public.cancel_outing(:'outing')::text as res \gset
select set_config('t.res', :'res', false) \g /dev/null
do $$ declare v jsonb := current_setting('t.res')::jsonb; begin
  assert jsonb_array_length(v->'recipients') = 13, format('13 à prévenir: %s', jsonb_array_length(v->'recipients'));
end $$;
select pg_temp.as_user('00000000-0000-0000-0000-000000000101');
select pg_temp.expect_error(format('select public.register_for_outing(%L)', :'outing'), 'annulée');

-- ---- Rôles : seul l'admin change les rôles
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select pg_temp.expect_error($q$ select public.set_user_role('00000000-0000-0000-0000-0000000000c1', 'member') $q$, 'administrateurs');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select public.set_user_role('00000000-0000-0000-0000-0000000000c1', 'member');
select pg_temp.expect_error($q$ select public.set_user_role('00000000-0000-0000-0000-0000000000a1', 'member') $q$, 'propre rôle');

-- ---- Concurrence simulée : 2 places, 5 inscrits "simultanés" -> jamais plus de 2 confirmés
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select (public.save_outing(null, 'Vol local', null, null, null, now() + interval '3 days', null, null,
        array['cccccccc-0000-0000-0000-000000000002']::uuid[], null) ->> 'outing_id') as outing2 \gset
select set_config('t.outing2', :'outing2', false) \g /dev/null
do $$ declare i int; begin
  for i in 1..5 loop
    perform pg_temp.as_user(('00000000-0000-0000-0000-0000000001' || lpad(i::text,2,'0'))::uuid);
    perform public.register_for_outing(current_setting('t.outing2')::uuid);
  end loop;
  assert (select count(*) from registrations where outing_id=current_setting('t.outing2')::uuid and status='confirmed') = 2;
  assert (select count(*) from registrations where outing_id=current_setting('t.outing2')::uuid and status='waitlist') = 3;
end $$;

\echo '=== TOUS LES TESTS DE LOGIQUE SONT PASSÉS ==='
