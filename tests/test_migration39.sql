\set ON_ERROR_STOP on
set client_min_messages = warning;

-- Un membre avec un historique (bar, inscription créée par lui-même)
insert into auth.users (id, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-00000000d39a', 'depart@club.fr', '{"full_name":"Denis Départ"}');
update public.profiles set role = 'member', phone = '0611223344' where id = '00000000-0000-0000-0000-00000000d39a';
insert into public.bar_consumptions (user_id, product_id, product_name, unit_price_cents, quantity, created_by)
select '00000000-0000-0000-0000-00000000d39a', id, name, price_cents, 2, '00000000-0000-0000-0000-00000000d39a'
  from public.bar_products order by name limit 1;

-- Suppression de l'identifiant sans anonymisation préalable : la fiche est anonymisée, l'historique reste
delete from auth.users where id = '00000000-0000-0000-0000-00000000d39a';
do $$ begin
  assert (select full_name from public.profiles where id = '00000000-0000-0000-0000-00000000d39a') = 'Ancien membre', 'anonymisé';
  assert (select phone from public.profiles where id = '00000000-0000-0000-0000-00000000d39a') is null, 'téléphone effacé';
  assert (select role from public.profiles where id = '00000000-0000-0000-0000-00000000d39a') = 'pending', 'plus aucun accès';
  assert (select count(*) from public.bar_consumptions where user_id = '00000000-0000-0000-0000-00000000d39a') = 1, 'historique du bar conservé';
end $$;

-- Membre déjà anonymisé par un admin : la suppression passe aussi, sans rien changer d'autre
insert into auth.users (id, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-00000000d39b', 'depart2@club.fr', '{"full_name":"Diane Départ"}');
update public.profiles set role = 'member' where id = '00000000-0000-0000-0000-00000000d39b';
select set_config('t.adm', (select id::text from public.profiles where role = 'admin' order by email limit 1), false);
set role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.adm'), false);
select public.anonymize_member('00000000-0000-0000-0000-00000000d39b');
do $$ begin
  begin perform public._anonymize_profile('00000000-0000-0000-0000-00000000d39b'); raise exception 'ATTENDU';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
delete from auth.users where id = '00000000-0000-0000-0000-00000000d39b';
do $$ begin
  assert (select anonymized_at from public.profiles where id = '00000000-0000-0000-0000-00000000d39b') is not null, 'fiche gardée';
end $$;
select 'TEST MIGRATION 39 OK';
