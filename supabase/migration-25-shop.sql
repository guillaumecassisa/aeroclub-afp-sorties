-- =====================================================================
--  Mise à jour n°25 : Le Shop — articles, commandes
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- Table des articles du shop
create table if not exists public.shop_items (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  description text,
  price_cents int not null default 0,   -- prix en centimes (0 = gratuit/sur devis)
  category    text not null default 'vetement', -- vetement | accessoire
  image_url   text,
  sizes       text,                     -- 'XS,S,M,L,XL,XXL' séparés par virgule, ou null
  colors      text,                     -- 'Blanc,Marine,Rouge' séparés par virgule, ou null
  active      boolean not null default true,
  position    int not null default 0,
  created_at  timestamptz not null default now()
);

-- Table des commandes
create table if not exists public.shop_orders (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  item_id     uuid not null references public.shop_items(id) on delete restrict,
  quantity    int not null default 1,
  size        text,
  color       text,
  note        text,
  status      text not null default 'pending', -- pending | confirmed | ready | delivered | cancelled
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- RLS
alter table public.shop_items enable row level security;
alter table public.shop_orders enable row level security;

-- shop_items : lisibles par tous les membres, modifiables par admin
drop policy if exists "shop_items_read"   on public.shop_items;
drop policy if exists "shop_items_write"  on public.shop_items;

create policy "shop_items_read" on public.shop_items
  for select using (public.is_approved());

create policy "shop_items_write" on public.shop_items
  for all using (
    exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
  );

-- shop_orders : chaque membre voit ses commandes ; admin voit tout
drop policy if exists "shop_orders_self"   on public.shop_orders;
drop policy if exists "shop_orders_admin"  on public.shop_orders;
drop policy if exists "shop_orders_insert" on public.shop_orders;

create policy "shop_orders_insert" on public.shop_orders
  for insert with check (user_id = auth.uid() and public.is_approved());

create policy "shop_orders_self" on public.shop_orders
  for select using (user_id = auth.uid());

create policy "shop_orders_admin" on public.shop_orders
  for all using (
    exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
  );

-- Trigger updated_at
create or replace function public.touch_shop_order()
returns trigger language plpgsql security definer set search_path = '' as $$
begin new.updated_at := now(); return new; end; $$;

drop trigger if exists touch_shop_order on public.shop_orders;
create trigger touch_shop_order
  before update on public.shop_orders
  for each row execute function public.touch_shop_order();

-- Quelques articles d'exemple (à adapter / supprimer)
insert into public.shop_items (name, description, price_cents, category, sizes, colors, position) values
  ('T-shirt club', 'T-shirt coton 100% aux couleurs du club, logo brodé au cœur', 2500, 'Vêtements', 'XS,S,M,L,XL,XXL', 'Blanc,Marine', 1),
  ('Polaire softshell', 'Veste softshell légère avec logo club, idéale pour les briefings sur le tarmac', 5500, 'Vêtements', 'S,M,L,XL,XXL', 'Marine,Gris', 2),
  ('Casquette brodée', 'Casquette ajustable avec logo club brodé', 2000, 'Accessoires', null, 'Marine,Blanc', 3),
  ('Mug "Pilote"', 'Mug céramique 350 ml, motif avion et indicatif LFMA', 1200, 'Accessoires', null, 'Blanc', 4),
  ('Sticker pack', 'Pack de 5 stickers vinyle : logo club, LFMA, avions de la flotte…', 500, 'Accessoires', null, null, 5)
on conflict do nothing;

notify pgrst, 'reload schema';
