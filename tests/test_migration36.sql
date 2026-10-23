\set ON_ERROR_STOP on
set client_min_messages = warning;

select set_config('t.m', (select id::text from public.profiles where role = 'member' order by email limit 1), false);
select set_config('t.adm', (select id::text from public.profiles where role = 'admin' order by email limit 1), false);
select set_config('t.item', (select id::text from public.shop_items order by position limit 1), false);

do $$ begin
  assert (select count(*) from public.shop_orders where status = 'delivered' and delivered_at is null) = 0, 'date de vente reprise';
end $$;

-- Un membre ne gère pas le stock, mais peut le lire ; le journal lui est invisible
set role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
do $$ begin
  begin perform public.shop_stock_add(current_setting('t.item')::uuid, 'M', '', 5, null, null); raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; assert sqlerrm like '%administrateurs%', sqlerrm; end;
  begin insert into public.shop_stock (item_id, size, color, quantity) values (current_setting('t.item')::uuid, 'M', '', 99); raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; end;
end $$;

-- L'admin réceptionne 10 articles, fait un inventaire à 7
select set_config('request.jwt.claim.sub', current_setting('t.adm'), false);
do $$ begin
  assert public.shop_stock_add(current_setting('t.item')::uuid, 'M', null, 10, 800, 'Livraison fournisseur') = 10, 'réception';
  assert public.shop_stock_set(current_setting('t.item')::uuid, 'M', '', 7, null) = 7, 'inventaire';
  assert public.shop_stock_set(current_setting('t.item')::uuid, 'M', '', 7, null) = 7, 'inventaire sans écart';
  assert (select count(*) from public.shop_stock_moves where item_id = current_setting('t.item')::uuid) = 2, 'deux mouvements';
  begin perform public.shop_stock_set(current_setting('t.item')::uuid, 'M', '', -1, null); raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; assert sqlerrm like '%invalide%', sqlerrm; end;
end $$;
reset role;

-- Une commande de 2, livrée : le stock passe à 5 ; remise en « prêt » : retour à 7 ; relivrée : 5, ardoise débitée une fois
insert into public.shop_orders (user_id, item_id, item_name, price_cents, quantity, size, status)
values (current_setting('t.m')::uuid, current_setting('t.item')::uuid, 'Article test', 1500, 2, 'M', 'ready');
select set_config('t.o', (select id::text from public.shop_orders where item_name = 'Article test'), false);
set role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.adm'), false);
select public.set_shop_order_status(current_setting('t.o')::uuid, 'delivered');
do $$ begin
  assert (select quantity from public.shop_stock where item_id = current_setting('t.item')::uuid and size = 'M') = 5, 'sortie de stock';
  assert (select delivered_at is not null and stock_deducted from public.shop_orders where id = current_setting('t.o')::uuid), 'livrée';
end $$;
select public.set_shop_order_status(current_setting('t.o')::uuid, 'ready');
do $$ begin
  assert (select quantity from public.shop_stock where item_id = current_setting('t.item')::uuid and size = 'M') = 7, 'stock rendu';
  assert (select delivered_at is null and not stock_deducted from public.shop_orders where id = current_setting('t.o')::uuid), 'plus livrée';
end $$;
select public.set_shop_order_status(current_setting('t.o')::uuid, 'delivered');
reset role;
do $$ begin
  assert (select quantity from public.shop_stock where item_id = current_setting('t.item')::uuid and size = 'M') = 5, 'ressortie';
  assert (select count(*) from public.bar_consumptions where product_name like 'Shop – Article test%') = 1, 'ardoise débitée une fois';
  assert (select count(*) from public.shop_stock_moves where order_id = current_setting('t.o')::uuid) = 3, 'vente, retour, vente';
end $$;

select 'test_migration36 OK';
