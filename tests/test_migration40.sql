\set ON_ERROR_STOP on
set client_min_messages = warning;
select set_config('t.m', (select id::text from public.profiles where role = 'member' and anonymized_at is null order by email limit 1), false);
select set_config('t.adm', (select id::text from public.profiles where role = 'admin' order by email limit 1), false);
select set_config('t.item', (select id::text from public.shop_items order by position limit 1), false);

set role authenticated;
-- Un membre ne peut pas activer le mode, ni modifier la table directement
select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
do $$ begin
  begin perform public.set_shop_coming_soon(true, null); raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; assert sqlerrm like '%administrateurs%', sqlerrm; end;
  begin update public.shop_settings set coming_soon = true; raise exception 'ATTENDU';
  exception when insufficient_privilege then null; end;
  assert not public.shop_coming_soon(), 'shop ouvert par défaut';
end $$;

-- L'admin active le mode : plus aucune commande, même en passant par la base
select set_config('request.jwt.claim.sub', current_setting('t.adm'), false);
select public.set_shop_coming_soon(true, '  Ouverture le 1er décembre  ');
select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
do $$ begin
  assert public.shop_coming_soon(), 'mode actif';
  assert (select message from public.shop_settings) = 'Ouverture le 1er décembre', 'message lisible par les membres';
  begin
    insert into public.shop_orders (user_id, item_id, item_name, price_cents, quantity)
    values (current_setting('t.m')::uuid, current_setting('t.item')::uuid, 'Test', 100, 1);
    raise exception 'ATTENDU';
  exception when insufficient_privilege then null; end;
end $$;

-- L'admin rouvre : la commande passe
select set_config('request.jwt.claim.sub', current_setting('t.adm'), false);
select public.set_shop_coming_soon(false, null);
select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
insert into public.shop_orders (user_id, item_id, item_name, price_cents, quantity)
values (current_setting('t.m')::uuid, current_setting('t.item')::uuid, 'Test bientôt', 100, 1);
reset role;
delete from public.shop_orders where item_name = 'Test bientôt';
select 'TEST MIGRATION 40 OK';
