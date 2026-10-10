\set ON_ERROR_STOP on
set client_min_messages = warning;

-- Un membre non-instructeur propose une sortie
select set_config('request.jwt.claim.sub', (select id::text from public.profiles where role = 'member' order by email limit 1), false);
select public.save_outing(null, 'Test référent', 'LFMV', null, null, now() + interval '30 days', null, null,
       null, null, 'activite', 10);
select set_config('t.o25', (select id::text from public.outings where title = 'Test référent'), false);
do $$ begin
  assert (select approval from public.outings where id = current_setting('t.o25')::uuid) = 'pending', 'proposal pending';
end $$;

-- L'instructeur valide avec un référent
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
select set_config('t.ref', (select id::text from public.profiles where role = 'instructor' order by email limit 1), false);
select public.review_outing(
  current_setting('t.o25')::uuid,
  true,
  null,
  current_setting('t.ref')::uuid
);
do $$ begin
  assert (select approval from public.outings where id = current_setting('t.o25')::uuid) = 'approved', 'approuvé';
  assert (select referent_instructor_id from public.outings where id = current_setting('t.o25')::uuid)
       = current_setting('t.ref')::uuid, 'référent enregistré';
end $$;

-- get_outing expose le référent
do $$ begin
  assert (public.get_outing(current_setting('t.o25')::uuid) -> 'referent_instructor') is not null, 'référent dans get_outing';
  assert (public.get_outing(current_setting('t.o25')::uuid) -> 'referent_instructor' ->> 'id')
       = current_setting('t.ref'), 'id référent correct';
end $$;

-- Valider avec un non-instructeur échoue
do $$ begin
  -- D'abord remettre la sortie en pending (trick : insérer une nouvelle sortie)
  perform public.save_outing(null, 'Test référent 2', 'LFMV', null, null, now() + interval '31 days', null, null,
         null, null, 'activite', 5);
  declare v_id uuid := (select id from public.outings where title = 'Test référent 2');
  begin
    perform public.review_outing(v_id, true, null,
      (select id from public.profiles where role = 'member' order by email limit 1));
    raise exception 'ATTENDU';
  exception when others then
    if sqlerrm = 'ATTENDU' then raise; end if;
    assert sqlerrm like '%rôle%', sqlerrm;
  end;
end $$;

-- Sans référent : fonctionne normalement (référent null)
select set_config('request.jwt.claim.sub', (select id::text from public.profiles where role = 'member' order by email limit 1 offset 1), false);
select public.save_outing(null, 'Test sans référent', 'LFMV', null, null, now() + interval '32 days', null, null,
       null, null, 'activite', 5);
select set_config('t.o25b', (select id::text from public.outings where title = 'Test sans référent'), false);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
select public.review_outing(current_setting('t.o25b')::uuid, true, null, null);
do $$ begin
  assert (select referent_instructor_id from public.outings where id = current_setting('t.o25b')::uuid) is null,
    'référent null ok';
end $$;

select 'test_migration25 OK';
