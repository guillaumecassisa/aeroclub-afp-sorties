\set ON_ERROR_STOP on
set client_min_messages = warning;

select set_config('t.m', (select id::text from public.profiles where role = 'member' and anonymized_at is null order by email limit 1), false);
select set_config('t.m2', (select id::text from public.profiles where role = 'member' and anonymized_at is null order by email offset 1 limit 1), false);
select set_config('t.adm', (select id::text from public.profiles where role = 'admin' order by email limit 1), false);
select set_config('t.ac', (select id::text from public.aircraft order by registration limit 1), false);

set role authenticated;
-- Un organisateur crée une sortie avion « date à définir »
select set_config('request.jwt.claim.sub', current_setting('t.adm'), false);
select set_config('t.o', (public.save_outing(null, 'Projet Corse', 'LFKC', 'À caler', null, null, null, null,
         array[current_setting('t.ac')::uuid], null, 'vol', null) ->> 'outing_id'), false);
do $$ begin
  -- un retour sans départ est refusé
  begin perform public.save_outing(null, 'X', null, null, null, null, now() + interval '3 days', null,
                                   null, null, 'activite', null); raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; assert sqlerrm like '%départ%', sqlerrm; end;
end $$;

-- Un membre le voit dans les événements à venir et s'inscrit pour montrer son intérêt
select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
do $$
declare l jsonb := public.list_outings(false); r jsonb;
begin
  assert exists (select 1 from jsonb_array_elements(l) x where x ->> 'id' = current_setting('t.o') and x ->> 'departure_at' is null), 'projet listé';
  assert (l -> -1 ->> 'id') = current_setting('t.o') or exists (select 1 from jsonb_array_elements(l) x where x ->> 'departure_at' is null), 'projets en fin de liste';
  assert not exists (select 1 from jsonb_array_elements(public.list_outings(true)) x where x ->> 'id' = current_setting('t.o')), 'pas dans les passés';
  r := public.register_for_outing(current_setting('t.o')::uuid);
  assert r ->> 'status' in ('confirmed', 'waitlist'), 'inscrit';
  perform set_config('t.st', r ->> 'status', false);
  assert (public.get_outing(current_setting('t.o')::uuid) ->> 'departure_at') is null, 'détail sans date';
end $$;

-- L'organisateur fixe la date plus tard : l'inscription est conservée
select set_config('request.jwt.claim.sub', current_setting('t.adm'), false);
do $$ begin
  perform public.save_outing(current_setting('t.o')::uuid, 'Projet Corse', 'LFKC', 'Date calée', null,
                             now() + interval '20 days', now() + interval '20 days 8 hours', null,
                             array[current_setting('t.ac')::uuid], null, 'vol', null);
  assert (public.get_outing(current_setting('t.o')::uuid) ->> 'departure_at') is not null, 'date fixée';
end $$;
select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
do $$ begin
  assert (public.get_outing(current_setting('t.o')::uuid) -> 'my_registration' ->> 'status') = current_setting('t.st'), 'inscription conservée';
end $$;
reset role;

-- La suppression d'un compte désinscrit aussi des projets sans date
update public.outings set departure_at = null, return_at = null where id = current_setting('t.o')::uuid;
do $$ begin
  assert position('o.departure_at is null or o.departure_at > now()' in
                  pg_get_functiondef('public.anonymize_member(uuid)'::regprocedure)) > 0, 'anonymisation : projets inclus';
end $$;
delete from public.outings where id = current_setting('t.o')::uuid;
select 'TEST MIGRATION 38 OK';
