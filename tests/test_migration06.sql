\set ON_ERROR_STOP on
set client_min_messages = warning;
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

-- Un membre propose une sortie
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000106', false);
select (public.save_outing(null, 'Balade Verdon', 'Verdon', null, null, now() + interval '5 days', null, null,
        array['aaaaaaaa-0000-0000-0000-000000000004']::uuid[], 'aaaaaaaa-0000-0000-0000-000000000004')) as r \gset
select set_config('t.r', :'r', false);
do $$ declare r jsonb := current_setting('t.r')::jsonb; begin
  assert r->>'approval' = 'pending', 'en attente';
  assert jsonb_array_length(r->'notify_staff') >= 2, 'instructeurs + admin prévenus';
end $$;
select set_config('t.o', (select id::text from public.outings where title = 'Balade Verdon'), false);

-- Invisible et fermée aux autres membres
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000107', false);
do $$ begin
  assert public.get_outing(current_setting('t.o')::uuid) is null, 'invisible';
  assert not exists (select 1 from jsonb_array_elements(public.list_outings(false)) e where e->>'title' = 'Balade Verdon'), 'pas listée';
end $$;
select pg_temp.expect_error(format('select public.register_for_outing(%L)', current_setting('t.o')), 'pas encore été validée');
select pg_temp.expect_error(format('select public.review_outing(%L, true)', current_setting('t.o')), 'instructeurs');

-- Le proposant la voit et peut la modifier
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000106', false);
do $$ begin
  assert (public.get_outing(current_setting('t.o')::uuid)->>'can_edit')::boolean, 'proposant peut modifier';
  assert (select e->>'approval' from jsonb_array_elements(public.list_outings(false)) e where e->>'title' = 'Balade Verdon') = 'pending';
end $$;
select public.save_outing(current_setting('t.o')::uuid, 'Balade Verdon (modifiée)', 'Verdon', null, null, now() + interval '5 days', null, null,
        array['aaaaaaaa-0000-0000-0000-000000000004']::uuid[], null);

-- Refus puis correction => repart en attente, puis approbation
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
do $$ declare r jsonb; begin
  r := public.review_outing(current_setting('t.o')::uuid, false, 'Météo incertaine, proposez une autre date');
  assert r->>'email' = 'm6@club.fr', 'proposant à prévenir';
  assert (select approval from public.outings where id = current_setting('t.o')::uuid) = 'rejected';
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000106', false);
select public.save_outing(current_setting('t.o')::uuid, 'Balade Verdon', 'Verdon', null, null, now() + interval '6 days', null, null,
        array['aaaaaaaa-0000-0000-0000-000000000004']::uuid[], null);
do $$ begin assert (select approval from public.outings where id = current_setting('t.o')::uuid) = 'pending', 'resoumise'; end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
select public.review_outing(current_setting('t.o')::uuid, true);

-- Publiée : visible, ouverte aux inscriptions, plus modifiable par le membre
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000107', false);
do $$ begin
  assert public.get_outing(current_setting('t.o')::uuid) is not null, 'visible';
  assert (public.register_for_outing(current_setting('t.o')::uuid)->>'status') = 'confirmed';
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000106', false);
select pg_temp.expect_error(format($f$select public.save_outing(%L, 'X', null, null, null, now() + interval '5 days', null, null,
  array['aaaaaaaa-0000-0000-0000-000000000004']::uuid[], null)$f$, current_setting('t.o')), 'publiée');

-- Retrait de sa propre proposition
select public.save_outing(null, 'Idée à retirer', null, null, null, now() + interval '9 days', null, null,
        array['aaaaaaaa-0000-0000-0000-000000000004']::uuid[], null);
select public.cancel_outing((select id from public.outings where title = 'Idée à retirer'));
select pg_temp.expect_error(format('select public.cancel_outing(%L)', current_setting('t.o')), 'instructeurs');

-- RLS : un autre membre ne voit pas les propositions en direct
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000107', false);
select public.save_outing(null, 'Proposition privée', null, null, null, now() + interval '9 days', null, null,
        array['aaaaaaaa-0000-0000-0000-000000000004']::uuid[], null);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000108', false);
set role authenticated;
do $$ begin assert not exists (select 1 from public.outings where title = 'Proposition privée'), 'RLS'; end $$;
reset role;

\echo '=== TESTS PROPOSITIONS PASSÉS ==='
