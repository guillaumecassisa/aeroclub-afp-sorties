\set ON_ERROR_STOP on
set client_min_messages = warning;

-- Données : un membre, l'admin de test, une question
select set_config('t.m', (select id::text from public.profiles where role = 'member' order by email limit 1), false);
select set_config('t.m2', (select id::text from public.profiles where role = 'member' order by email limit 1 offset 1), false);
select set_config('t.adm', (select id::text from public.profiles where role = 'admin' order by email limit 1), false);
insert into public.quiz_questions (question, option_a, option_b, option_c, option_d, correct, explanation)
values ('Combien de pieds dans un mètre ?', '1,5', '3,28', '10', '0,3', 'b', 'Environ 3,28 ft.');

-- ===== Shop =====
select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
insert into public.shop_orders (user_id, item_id, item_name, price_cents, quantity, size)
select current_setting('t.m')::uuid, id, name, 2500, 2, 'M' from public.shop_items order by position limit 1;
select set_config('t.order', (select id::text from public.shop_orders where user_id = current_setting('t.m')::uuid
                                order by created_at desc limit 1), false);

-- Un autre membre ne peut pas annuler la commande
select set_config('request.jwt.claim.sub', current_setting('t.m2'), false);
do $$ begin
  begin perform public.cancel_shop_order(current_setting('t.order')::uuid); raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; assert sqlerrm like '%pas votre commande%', sqlerrm; end;
  -- ni la livrer
  begin perform public.set_shop_order_status(current_setting('t.order')::uuid, 'delivered'); raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; assert sqlerrm like '%administrateurs%', sqlerrm; end;
end $$;

-- L'admin la livre deux fois : l'ardoise n'est débitée qu'une fois
select set_config('request.jwt.claim.sub', current_setting('t.adm'), false);
select public.set_shop_order_status(current_setting('t.order')::uuid, 'delivered');
select public.set_shop_order_status(current_setting('t.order')::uuid, 'delivered');
do $$ begin
  assert (select count(*) from public.bar_consumptions where user_id = current_setting('t.m')::uuid
            and product_name like 'Shop –%') = 1, 'ardoise débitée une fois';
  assert (select unit_price_cents * quantity from public.bar_consumptions where user_id = current_setting('t.m')::uuid
            and product_name like 'Shop –%') = 5000, 'montant';
  assert (select ardoise_charged from public.shop_orders where id = current_setting('t.order')::uuid), 'commande marquée';
end $$;

-- Le membre annule une commande en attente ; pas une commande livrée
select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
insert into public.shop_orders (user_id, item_id, item_name, price_cents, quantity)
select current_setting('t.m')::uuid, id, name, 1200, 1 from public.shop_items order by position limit 1;
select public.cancel_shop_order((select id from public.shop_orders where user_id = current_setting('t.m')::uuid and status = 'pending' limit 1));
do $$ begin
  assert not exists (select 1 from public.shop_orders where user_id = current_setting('t.m')::uuid and status = 'pending'), 'annulée';
  begin perform public.cancel_shop_order(current_setting('t.order')::uuid); raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; end;
end $$;

-- ===== Stats =====
do $$ begin
  begin perform public.revenue_stats(12); raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; assert sqlerrm like '%trésorier%', sqlerrm; end;
end $$;
select set_config('request.jwt.claim.sub', current_setting('t.adm'), false);
do $$ begin
  assert jsonb_array_length(public.revenue_stats(12)) = 12, '12 mois';
  assert (public.revenue_stats(1) -> 0 ->> 'shop')::int = 5000, 'shop livré compté';
end $$;

-- ===== Quiz =====
select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
do $$
declare v jsonb := public.quiz_today(); r jsonb;
begin
  assert v is not null, 'question du jour';
  assert v ->> 'correct' is null, 'bonne réponse cachée avant de répondre';
  r := public.quiz_answer((v ->> 'id')::int, 'a');
  assert r ? 'answer', 'correction renvoyée';
  assert (public.quiz_today() ->> 'already_answered')::boolean, 'déjà répondu';
  begin perform public.quiz_answer((v ->> 'id')::int, 'b'); raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; assert sqlerrm like '%déjà répondu%', sqlerrm; end;
  assert jsonb_array_length(public.quiz_leaderboard()) >= 1, 'classement';
  assert public.quiz_leaderboard() -> 0 ->> 'full_name' is not null, 'noms visibles';
  assert jsonb_array_length(public.quiz_my_history()) = 1, 'historique';
end $$;

-- Plus d'accès direct aux tables du quiz
set role authenticated;
do $$ begin
  begin perform 1 from public.quiz_questions; raise exception 'ATTENDU';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

select 'test_migration28 OK';
