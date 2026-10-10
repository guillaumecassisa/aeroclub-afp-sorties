\set ON_ERROR_STOP on
set client_min_messages = warning;
do $$ begin
  assert (select count(*) from public.bar_products where active) = 20, 'carte : 20 produits actifs';
  assert (select price_cents from public.bar_products where name = 'Desperados 50cl' and active) = 400, 'Desperados renommé';
  assert (select count(*) from public.bar_products where lower(name) in ('desperados','panaché','kitkat','brewdog ipa')) = 0, 'anciens noms renommés';
  assert (select not active from public.bar_products where name = 'Mars'), 'Mars retiré de la carte';
  assert (select price_cents from public.bar_products where name = 'Café') = 75, 'café 0,75';
  assert (select category from public.bar_products where name = 'Glace Twix') = 'snacks', 'glaces en snacks';
end $$;
\i supabase/migration-22-carte-bar.sql
do $$ begin assert (select count(*) from public.bar_products where active) = 20, 'idempotent'; end $$;
select 'test_migration22 OK';
