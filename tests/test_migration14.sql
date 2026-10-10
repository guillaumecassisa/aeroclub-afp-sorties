\set ON_ERROR_STOP on
set client_min_messages = warning;
-- un organisateur publie : tout le monde sauf lui, et sauf les désabonnés
select set_config('request.jwt.claim.sub', (select id::text from public.profiles where role='admin' limit 1), false);
select set_config('t.o', (select id::text from public.outings where approval='approved' and status='open' limit 1), false);
select set_config('t.n', (select count(*)::text from public.profiles where role<>'pending' and id <> auth.uid()), false);
do $$ begin assert jsonb_array_length(public.event_mail_recipients(current_setting('t.o')::uuid)) = current_setting('t.n')::int, 'tous les membres'; end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000105', false);
select public.set_event_notifications(false);
select set_config('request.jwt.claim.sub', (select id::text from public.profiles where role='admin' limit 1), false);
do $$ begin assert jsonb_array_length(public.event_mail_recipients(current_setting('t.o')::uuid)) = current_setting('t.n')::int - 1, 'désabonné exclu'; end $$;
-- un simple membre ne peut pas obtenir la liste
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000105', false);
select public.set_event_notifications(true);
update public.profiles set role='member', is_instructor=false, is_board=false, is_treasurer=false, is_secretary=false, is_maintenance=false where id='00000000-0000-0000-0000-000000000105';
do $$ begin
  begin perform public.event_mail_recipients(current_setting('t.o')::uuid); assert false, 'aurait dû échouer';
  exception when raise_exception then null; end;
end $$;
select 'test_migration14 OK';
