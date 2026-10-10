\set ON_ERROR_STOP on
set client_min_messages = warning;
select set_config('t.admin', (select id::text from public.profiles where role='admin' limit 1), false);
select set_config('request.jwt.claim.sub', current_setting('t.admin'), false);
update public.profiles set role='member', is_instructor=false, is_board=false, is_treasurer=false, is_secretary=false, is_maintenance=false
 where id = '00000000-0000-0000-0000-000000000107';
-- instructeur puis admin : les deux fonctions coexistent
select public.set_function('00000000-0000-0000-0000-000000000107', 'instructeur', true);
do $$ begin assert (select role from public.profiles where id='00000000-0000-0000-0000-000000000107')='instructor'; end $$;
select public.set_function('00000000-0000-0000-0000-000000000107', 'admin', true);
do $$ begin assert (select role::text||is_instructor::text from public.profiles where id='00000000-0000-0000-0000-000000000107')='admintrue'; end $$;
select public.set_function('00000000-0000-0000-0000-000000000107', 'admin', false);
do $$ begin assert (select role from public.profiles where id='00000000-0000-0000-0000-000000000107')='instructor', 'retour instructeur'; end $$;
select public.set_function('00000000-0000-0000-0000-000000000107', 'instructeur', false);
do $$ begin assert (select role from public.profiles where id='00000000-0000-0000-0000-000000000107')='member'; end $$;
-- secrétaire => admin ; retirer admin retire secrétaire
select public.set_function('00000000-0000-0000-0000-000000000107', 'secretaire', true);
do $$ begin assert (select role::text||is_secretary::text from public.profiles where id='00000000-0000-0000-0000-000000000107')='admintrue'; end $$;
select public.set_function('00000000-0000-0000-0000-000000000107', 'admin', false);
do $$ begin assert (select role::text||is_secretary::text from public.profiles where id='00000000-0000-0000-0000-000000000107')='memberfalse'; end $$;
-- autres fonctions
select public.set_function('00000000-0000-0000-0000-000000000107', 'tresorier', true);
select public.set_function('00000000-0000-0000-0000-000000000107', 'ca', true);
select public.set_function('00000000-0000-0000-0000-000000000107', 'maintenance', true);
do $$ begin assert (select is_treasurer and is_board and is_maintenance and role='member' from public.profiles where id='00000000-0000-0000-0000-000000000107'); end $$;
-- on ne se retire pas soi-même l'admin
do $$ begin
  begin perform public.set_function(auth.uid(), 'admin', false); assert false, 'aurait dû échouer';
  exception when raise_exception then null; end;
end $$;
-- un non-admin ne peut rien attribuer
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000107', false);
do $$ begin
  begin perform public.set_function('00000000-0000-0000-0000-000000000105', 'admin', true); assert false;
  exception when raise_exception then null; end;
end $$;
do $$ begin assert jsonb_typeof(public.member_directory()->0->'is_instructor') = 'boolean'; end $$;
select 'test_migration13 OK';
