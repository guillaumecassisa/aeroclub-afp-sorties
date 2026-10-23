-- =====================================================================
--  Mise à jour n°12 : carte du bar en deux sections (Boissons / Snacks).
--  Prix provisoires, modifiables par le trésorier (Mon compte → Trésorerie).
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- Données d'exemple : posées une seule fois, à la première installation.
-- Relancer ce fichier plus tard ne les recrée pas et ne touche pas aux données saisies sur le site.
create table if not exists public._seeds (name text primary key, done_at timestamptz not null default now());
alter table public._seeds enable row level security;
revoke all on public._seeds from public, anon, authenticated;
create or replace function public._seed_once(p_name text)
returns boolean language plpgsql set search_path = '' as $fn$
begin
  insert into public._seeds (name) values (p_name) on conflict (name) do nothing;
  return found;
end;
$fn$;
revoke execute on function public._seed_once(text) from public, anon, authenticated;

alter table public.bar_products add column if not exists category text not null default 'boissons';
alter table public.bar_products drop constraint if exists bar_products_category_check;
alter table public.bar_products add constraint bar_products_category_check check (category in ('boissons', 'snacks'));

do $seed$ begin
  if not public._seed_once('bar-12') then return; end if;
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
end $seed$;

notify pgrst, 'reload schema';
