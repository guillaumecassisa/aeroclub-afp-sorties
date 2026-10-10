\set ON_ERROR_STOP on
set client_min_messages = warning;
-- 106 devient membre du CA
select set_config('request.jwt.claim.sub', (select id::text from public.profiles where role='admin' limit 1), false);
update public.profiles set role = 'member', is_board = false, is_treasurer = false, is_secretary = false, is_maintenance = false
 where id in ('00000000-0000-0000-0000-000000000106', '00000000-0000-0000-0000-000000000108');
select public.set_board('00000000-0000-0000-0000-000000000106', true);

-- Le membre du CA crée une activité sans avion, 2 places : publiée directement
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000106', false);
select (public.save_outing(null, 'Balade moto Luberon', 'Lourmarin', null, 'Parking club', now() + interval '10 days',
        null, null, '{}'::uuid[], null, 'activite', 2)) as r \gset
select set_config('t.r', :'r', false);
do $$ declare r jsonb := current_setting('t.r')::jsonb; begin
  assert r->>'approval' = 'approved', 'CA : publié directement';
end $$;
select set_config('t.o', (select id::text from public.outings where title = 'Balade moto Luberon'), false);

-- 3 inscrits : 2 confirmés, 1 en attente
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000107', false);
select public.register_for_outing(current_setting('t.o')::uuid);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000108', false);
select public.register_for_outing(current_setting('t.o')::uuid);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000105', false);
do $$ begin assert (public.register_for_outing(current_setting('t.o')::uuid)->>'status') = 'waitlist', '3e en attente'; end $$;
do $$ declare o jsonb := public.get_outing(current_setting('t.o')::uuid); begin
  assert o->>'kind' = 'activite';
  assert jsonb_array_length(o->'participants') = 2, 'participants';
  assert jsonb_array_length(o->'waitlist') = 1, 'attente';
end $$;
-- un désistement : le 3e est promu
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000107', false);
do $$ declare c jsonb; begin
  c := public.cancel_registration((select id from public.registrations where outing_id = current_setting('t.o')::uuid
                                   and user_id = auth.uid() and status <> 'cancelled'))->'changes';
  assert c->0->>'change' = 'promoted', 'promotion';
end $$;
-- passage à illimité : tout le monde confirmé
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000106', false);
select public.save_outing(current_setting('t.o')::uuid, 'Balade moto Luberon', 'Lourmarin', null, 'Parking club',
        now() + interval '10 days', null, null, '{}'::uuid[], null, 'activite', null);
do $$ begin assert (select count(*) from public.registrations where outing_id = current_setting('t.o')::uuid and status = 'waitlist') = 0; end $$;

-- Événement convivial illimité (barbapéro)
select public.save_outing(null, 'Barbapéro', null, null, 'Club-house', now() + interval '20 days', null, null,
        '{}'::uuid[], null, 'evenement', null);
do $$ begin
  assert (select e->>'kind' from jsonb_array_elements(public.list_outings(false)) e where e->>'title' = 'Barbapéro') = 'evenement';
  assert (select e->'total_capacity' from jsonb_array_elements(public.list_outings(false)) e where e->>'title' = 'Barbapéro') = 'null'::jsonb;
end $$;

-- Un vol exige toujours un avion
do $$ begin
  begin
    perform public.save_outing(null, 'Vol sans avion', null, null, null, now() + interval '5 days', null, null, '{}'::uuid[], null, 'vol', null);
    raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; end;
end $$;

-- Un membre simple propose : en attente
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000108', false);
do $$ begin
  assert (public.save_outing(null, 'Resto', null, null, null, now() + interval '6 days', null, null, '{}'::uuid[], null, 'evenement', 20)->>'approval') = 'pending';
end $$;
\echo '=== TESTS ÉVÉNEMENTS PASSÉS ==='
