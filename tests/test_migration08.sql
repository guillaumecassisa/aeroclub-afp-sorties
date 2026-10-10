\set ON_ERROR_STOP on
set client_min_messages = warning;
-- un admin n'est plus trésorier par défaut
select set_config('request.jwt.claim.sub', (select id::text from public.profiles where role='admin' and not is_treasurer limit 1), false);
do $$ begin assert not public.is_treasurer(), 'admin non trésorier'; end $$;
-- secrétaire
select set_config('t.m', '00000000-0000-0000-0000-000000000108', false);
select public.set_secretary(current_setting('t.m')::uuid, true);
do $$ begin assert (select role = 'admin' and is_secretary from public.profiles where id = current_setting('t.m')::uuid); end $$;
-- annonces : membre lit, ne peut pas écrire
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000107', false);
set role authenticated;
do $$ begin
  begin insert into public.announcements (title) values ('x'); raise exception 'ATTENDU';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
set role authenticated;
insert into public.announcements (title, important) values ('Piste fermée samedi', true);
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000107', false);
set role authenticated;
do $$ begin assert (select count(*) from public.announcements) = 1; end $$;
reset role;
\echo '=== TESTS RÔLES/ANNONCES PASSÉS ==='
