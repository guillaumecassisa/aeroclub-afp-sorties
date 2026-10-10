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

do $$ begin assert (select count(*) from public.bar_products) = 4, 'carte initiale'; end $$;

-- Membre 4 consomme 2 bières + 1 eau
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000104', false);
set role authenticated;
select public.add_consumption((select id from public.bar_products where name = 'Bière'), 2);
select public.add_consumption((select id from public.bar_products where name = 'Eau'));
select pg_temp.expect_error($q$ select public.add_consumption((select id from public.bar_products where name='Coca'), 1,
  '00000000-0000-0000-0000-000000000105') $q$, 'trésorier');
select pg_temp.expect_error($q$ insert into public.bar_consumptions (user_id, product_name, unit_price_cents, quantity)
  values (auth.uid(), 'x', 0, 1) $q$, 'permission denied');
select pg_temp.expect_error($q$ select public.bar_month_summary(current_date) $q$, 'trésorier');
update public.bar_products set price_cents = 0;  -- 0 ligne (RLS)
select pg_temp.expect_error($q$ update public.profiles set is_treasurer = true where id = auth.uid() $q$, 'permission denied');
do $$ begin
  assert (select count(*) from public.bar_consumptions) = 2, 'ne voit que les siennes';
  assert (select min(price_cents) from public.bar_products) = 50, 'un membre ne change pas les prix';
  assert (select sum(unit_price_cents*quantity) from public.bar_consumptions) = 650, '2x3€ + 0,50€';
end $$;
-- annulation de sa propre saisie récente
select public.cancel_consumption((select id from public.bar_consumptions where product_name = 'Eau'));
reset role;
-- une vieille saisie ne peut plus être annulée par le membre
update public.bar_consumptions set created_at = now() - interval '2 hours';
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000104', false);
select pg_temp.expect_error($q$ select public.cancel_consumption((select id from public.bar_consumptions limit 1)) $q$, 'Trop tard');

-- Membre 5 : 1 coca
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000105', false);
select public.add_consumption((select id from public.bar_products where name = 'Coca'));

-- Instructeur non trésorier : refusé ; l'admin le nomme trésorier
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
select pg_temp.expect_error($q$ select public.bar_month_summary(current_date) $q$, 'trésorier');
select pg_temp.expect_error($q$ select public.set_treasurer('00000000-0000-0000-0000-0000000000b1', true) $q$, 'administrateurs');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', false);
select public.set_treasurer('00000000-0000-0000-0000-0000000000b1', true);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
do $$ declare s jsonb; begin
  s := public.bar_month_summary(current_date);
  assert (s->>'total_cents')::int = 700, format('total mois %s', s->>'total_cents');
  assert jsonb_array_length(s->'members') = 2;
  assert (select (m->>'total_cents')::int from jsonb_array_elements(s->'members') m where m->>'email' = 'm4@club.fr') = 600;
  assert (select (m->'items'->>'Bière')::int from jsonb_array_elements(s->'members') m where m->>'email' = 'm4@club.fr') = 2;
end $$;
-- changement de prix : les consommations passées gardent l'ancien prix
set role authenticated;
update public.bar_products set price_cents = 350 where name = 'Bière';
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
do $$ begin assert (public.bar_month_summary(current_date)->>'total_cents')::int = 700, 'prix figé'; end $$;
-- règlement : le mois réglé bloque l'annulation
select public.set_bar_paid('00000000-0000-0000-0000-000000000104', current_date, true);
do $$ begin
  assert (select (m->>'paid')::boolean from jsonb_array_elements(public.bar_month_summary(current_date)->'members') m
          where m->>'email' = 'm4@club.fr');
end $$;
select pg_temp.expect_error($q$ select public.cancel_consumption((select id from public.bar_consumptions
  where user_id = '00000000-0000-0000-0000-000000000104' limit 1)) $q$, 'réglé');
select public.set_bar_paid('00000000-0000-0000-0000-000000000104', current_date, false);
select public.cancel_consumption((select id from public.bar_consumptions where user_id = '00000000-0000-0000-0000-000000000104' limit 1));

\echo '=== TESTS BAR PASSÉS ==='
