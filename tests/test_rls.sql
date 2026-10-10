-- Tests des droits (RLS / privilèges) avec le rôle "authenticated" de Supabase.
\set ON_ERROR_STOP on
set client_min_messages = warning;

do $$ begin
  begin assert false; exception when assert_failure then return; end;
  raise exception 'les assertions plpgsql sont désactivées';
end $$;

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
grant execute on function pg_temp.expect_error(text, text) to authenticated, anon;

-- Membre 4
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000104', false);
set role authenticated;

select pg_temp.expect_error($q$ insert into public.registrations (outing_id, user_id, status)
  select id, '00000000-0000-0000-0000-000000000104', 'confirmed' from public.outings limit 1 $q$, 'permission denied');
select pg_temp.expect_error($q$ update public.registrations set status = 'confirmed' $q$, 'permission denied');
select pg_temp.expect_error($q$ update public.profiles set role = 'admin' where id = auth.uid() $q$, 'permission denied');
select pg_temp.expect_error($q$ select public._rebalance_outing(gen_random_uuid()) $q$, 'permission denied');
select pg_temp.expect_error($q$ insert into public.aircraft (registration, model, seats) values ('F-XXXX','X',4) $q$, 'row-level security');

do $$ begin
  assert (select count(*) from public.profiles) = 1, 'un membre ne voit que son profil';
  assert (select count(*) from public.aircraft) = 3, 'un membre voit la flotte';
end $$;
update public.profiles set full_name = 'Membre Quatre', phone = '0611111111' where id = auth.uid();
update public.profiles set full_name = 'Pirate' where email = 'm5@club.fr';  -- 0 ligne (RLS)
reset role;
do $$ begin
  assert (select full_name from public.profiles where email = 'm4@club.fr') = 'Membre Quatre';
  assert (select full_name from public.profiles where email = 'm5@club.fr') = 'Membre 5';
end $$;

-- Instructeur : voit tous les profils, gère la flotte
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
set role authenticated;
insert into public.aircraft (registration, model, seats) values ('F-HTST', 'PS28', 2);
do $$ begin
  assert (select count(*) from public.profiles) = 17, 'instructeur voit tous les profils';
end $$;
select pg_temp.expect_error($q$ insert into public.aircraft (registration, model, seats) values ('F-HBAD','X',3) $q$, 'check constraint');
reset role;

-- Compte en attente : ne voit rien
update public.profiles set role = 'pending' where email = 'm14@club.fr';
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000114', false);
set role authenticated;
do $$ begin
  assert (select count(*) from public.outings) = 0, 'pending ne voit pas les sorties';
  assert (select count(*) from public.aircraft) = 0, 'pending ne voit pas la flotte';
end $$;
select pg_temp.expect_error($q$ select public.list_outings(false) $q$, 'pas encore validé');
reset role;

-- Anonyme : aucun accès
select set_config('request.jwt.claim.sub', '', false);
set role anon;
select pg_temp.expect_error($q$ select public.list_outings(false) $q$, 'permission denied');
select pg_temp.expect_error($q$ select * from public.outings $q$, 'permission denied');
select pg_temp.expect_error($q$ select * from public.profiles $q$, 'permission denied');
reset role;

\echo '=== TOUS LES TESTS DE DROITS SONT PASSÉS ==='
