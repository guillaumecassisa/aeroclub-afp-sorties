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
grant execute on function pg_temp.expect_error(text, text) to authenticated;

-- Membre 4 : met à jour ses coordonnées, se déclare lâché sur F-GAAA
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000104', false);
set role authenticated;
update public.profiles set address = '1 rue des Pilotes', emergency_name = 'Marie', emergency_phone = '0700000000',
  avatar_url = 'https://x/avatars/00000000-0000-0000-0000-000000000104/a.jpg' where id = auth.uid();
insert into public.pilot_aircraft (user_id, aircraft_id) values (auth.uid(), 'aaaaaaaa-0000-0000-0000-000000000004');
-- ne peut pas déclarer un autre membre
select pg_temp.expect_error($q$ insert into public.pilot_aircraft (user_id, aircraft_id)
  values ('00000000-0000-0000-0000-000000000105', 'aaaaaaaa-0000-0000-0000-000000000004') $q$, 'row-level security');
-- photo : seulement dans son propre dossier
insert into storage.objects (bucket_id, name) values ('avatars', '00000000-0000-0000-0000-000000000104/a.jpg');
select pg_temp.expect_error($q$ insert into storage.objects (bucket_id, name)
  values ('avatars', '00000000-0000-0000-0000-000000000105/a.jpg') $q$, 'row-level security');
-- toujours pas de changement de rôle possible
select pg_temp.expect_error($q$ update public.profiles set role = 'admin' where id = auth.uid() $q$, 'permission denied');
do $$ begin
  assert (select count(*) from public.pilot_aircraft) = 1;
end $$;
reset role;

-- get_outing expose la photo et le lâcher
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
do $$ declare d jsonb; o uuid; begin
  select id into o from public.outings where title = 'Sortie Corse';
  d := public.get_outing(o);
  assert (select count(*) from jsonb_array_elements(d->'aircraft') a, jsonb_array_elements(a->'occupants') p
          where p->>'user_id' = '00000000-0000-0000-0000-000000000104'
            and (p->>'released')::boolean = (a->>'id' = 'aaaaaaaa-0000-0000-0000-000000000004')
            and p->>'avatar_url' like 'https://x/%') = 1, 'photo + lâché exposés';
end $$;

\echo '=== TESTS MIGRATION 02 PASSÉS ==='
