-- =====================================================================
--  Mise à jour n°12 : carte du bar en deux sections (Boissons / Snacks).
--  Prix provisoires, modifiables par le trésorier (Mon compte → Trésorerie).
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

alter table public.bar_products add column if not exists category text not null default 'boissons';
alter table public.bar_products drop constraint if exists bar_products_category_check;
alter table public.bar_products add constraint bar_products_category_check check (category in ('boissons', 'snacks'));

-- Carte : on ajoute ce qui manque (sans toucher aux prix déjà saisis)
insert into public.bar_products (name, price_cents, position, category)
select v.name, v.price, v.pos, v.cat
from (values
  ('Tourtel',       200,  1, 'boissons'),
  ('Panaché',       250,  2, 'boissons'),
  ('Desperados',    350,  3, 'boissons'),
  ('BrewDog IPA',   400,  4, 'boissons'),
  ('KitKat',        150, 11, 'snacks'),
  ('Kinder Bueno',  150, 12, 'snacks'),
  ('Mars',          150, 13, 'snacks'),
  ('Snickers',      150, 14, 'snacks')
) v(name, price, pos, cat)
where not exists (select 1 from public.bar_products p where lower(p.name) = lower(v.name));

update public.bar_products set category = 'snacks', active = true
 where lower(name) in ('kitkat', 'kinder bueno', 'mars', 'snickers');
update public.bar_products set category = 'boissons', active = true
 where lower(name) in ('tourtel', 'panaché', 'desperados', 'brewdog ipa');
-- Anciennes boissons retirées de la carte (l'historique des consommations est conservé)
update public.bar_products set active = false where lower(name) in ('bière', 'coca', 'eau');

notify pgrst, 'reload schema';
