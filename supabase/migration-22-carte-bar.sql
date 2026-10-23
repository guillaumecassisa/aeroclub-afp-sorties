-- =====================================================================
--  Mise à jour n°22 : carte du bar (prix de septembre 2026)
--  Les produits existants sont renommés / mis à jour (l'historique des
--  consommations garde le nom et le prix de l'époque). Les produits qui ne
--  sont plus à la carte sont masqués, jamais supprimés.
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

do $seed$ begin
  if not public._seed_once('bar-22') then return; end if;
with carte (name, aliases, price, pos, cat) as (values
  ('Tourtel',          array['tourtel'],                                150,  1, 'boissons'),
  ('Bud',              array['bud'],                                    200,  2, 'boissons'),
  ('1664 blanche',     array['1664 blanche','1664'],                    200,  3, 'boissons'),
  ('Heineken',         array['heineken'],                               200,  4, 'boissons'),
  ('Leffe 0° 25cl',    array['leffe 0° 25cl','leffe 0°','leffe'],       200,  5, 'boissons'),
  ('Brewdog Punk IPA', array['brewdog punk ipa','brewdog ipa'],         400,  6, 'boissons'),
  ('Panaché 33cl',     array['panaché 33cl','panaché','panache'],       150,  7, 'boissons'),
  ('Desperados 50cl',  array['desperados 50cl','desperados'],           400,  8, 'boissons'),
  ('Coca Cola',        array['coca cola','coca'],                       150,  9, 'boissons'),
  ('Coca Cola 0',      array['coca cola 0','coca zéro','coca zero'],    150, 10, 'boissons'),
  ('Ice tea',          array['ice tea'],                                150, 11, 'boissons'),
  ('Café',             array['café','cafe'],                             75, 12, 'boissons'),
  ('Thé / Infusion',   array['thé / infusion','thé','infusion'],         75, 13, 'boissons'),
  ('Glace Bounty',     array['glace bounty'],                           200, 21, 'snacks'),
  ('Glace Snickers',   array['glace snickers'],                         200, 22, 'snacks'),
  ('Glace Twix',       array['glace twix'],                             200, 23, 'snacks'),
  ('Kinder Bueno',     array['kinder bueno'],                           175, 24, 'snacks'),
  ('Kit Kat',          array['kit kat','kitkat'],                       175, 25, 'snacks'),
  ('Lion',             array['lion'],                                   175, 26, 'snacks'),
  ('Snickers',         array['snickers'],                               175, 27, 'snacks')
),
-- produit existant correspondant (priorité au nom exact, puis au produit actif)
match as (
  select distinct on (c.name) c.name, c.price, c.pos, c.cat, p.id as pid
  from carte c
  left join public.bar_products p on lower(p.name) = any (c.aliases)
  order by c.name, (lower(p.name) = lower(c.name)) desc nulls last, p.active desc nulls last
),
upd as (
  update public.bar_products p
     set name = m.name, price_cents = m.price, position = m.pos, category = m.cat, active = true
    from match m
   where p.id = m.pid
  returning p.id
),
ins as (
  insert into public.bar_products (name, price_cents, position, category, active)
  select m.name, m.price, m.pos, m.cat, true from match m where m.pid is null
  returning id
)
update public.bar_products p set active = false
 where p.active
   and p.id not in (select id from upd union all select id from ins);
end $seed$;

notify pgrst, 'reload schema';
