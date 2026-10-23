-- =====================================================================
--  Mise à jour n°36 : shop — gestion des stocks et suivi des ventes
--  - Stock par article et par variante (taille / couleur), journal de tous
--    les mouvements (réception, vente, retour, inventaire).
--  - Prix d'achat des articles (pour la marge) et seuil d'alerte de stock.
--  - Date de vente (livraison) mémorisée sur chaque commande.
--  - Une commande livrée sort automatiquement du stock (une seule fois) ;
--    si elle repasse à un autre statut, le stock est rendu.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Articles : prix d'achat, suivi du stock, seuil d'alerte -----------------------
alter table public.shop_items
  add column if not exists cost_cents      int,
  add column if not exists track_stock     boolean not null default true,
  add column if not exists low_stock_alert int not null default 2;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'shop_items_cost_check') then
    alter table public.shop_items add constraint shop_items_cost_check
      check ((cost_cents is null or cost_cents >= 0) and low_stock_alert >= 0 and price_cents >= 0) not valid;
  end if;
end $$;

-- 2. Commandes : date de vente et sortie de stock -----------------------------------
alter table public.shop_orders
  add column if not exists delivered_at   timestamptz,
  add column if not exists stock_deducted boolean not null default false;
update public.shop_orders set delivered_at = updated_at where status = 'delivered' and delivered_at is null;
create index if not exists shop_orders_status on public.shop_orders (status);
create index if not exists shop_orders_delivered_at on public.shop_orders (delivered_at);

-- 3. Stock par variante ---------------------------------------------------------------
create table if not exists public.shop_stock (
  item_id    uuid not null references public.shop_items (id) on delete cascade,
  size       text not null default '',
  color      text not null default '',
  quantity   int  not null default 0,
  updated_at timestamptz not null default now(),
  primary key (item_id, size, color)
);
create table if not exists public.shop_stock_moves (
  id               bigint generated always as identity primary key,
  item_id          uuid not null references public.shop_items (id) on delete cascade,
  size             text not null default '',
  color            text not null default '',
  delta            int  not null check (delta <> 0),
  reason           text not null check (reason in ('reception', 'vente', 'retour', 'inventaire', 'correction')),
  unit_cost_cents  int check (unit_cost_cents is null or unit_cost_cents >= 0),
  order_id         uuid references public.shop_orders (id) on delete set null,
  note             text check (note is null or length(note) <= 300),
  created_by       uuid references public.profiles (id) on delete set null,
  created_at       timestamptz not null default now()
);
create index if not exists shop_stock_moves_item on public.shop_stock_moves (item_id, created_at desc);

alter table public.shop_stock enable row level security;
alter table public.shop_stock_moves enable row level security;
revoke all on public.shop_stock, public.shop_stock_moves from anon;
grant select on public.shop_stock, public.shop_stock_moves to authenticated;
-- Stock : lisible par les membres (pour afficher « en stock »), modifiable seulement par les fonctions ci-dessous
drop policy if exists shop_stock_read on public.shop_stock;
create policy shop_stock_read on public.shop_stock for select to authenticated using (public.is_approved());
-- Journal : administrateurs uniquement
drop policy if exists shop_stock_moves_admin on public.shop_stock_moves;
create policy shop_stock_moves_admin on public.shop_stock_moves for select to authenticated
  using (public.app_role() = 'admin');

-- Mouvement de stock (interne) : met à jour la quantité et journalise
create or replace function public._shop_stock_apply(p_item uuid, p_size text, p_color text, p_delta int,
  p_reason text, p_cost int, p_order uuid, p_note text)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare v_qty int;
begin
  if coalesce(p_delta, 0) = 0 then
    select quantity into v_qty from public.shop_stock
     where item_id = p_item and size = coalesce(p_size, '') and color = coalesce(p_color, '');
    return coalesce(v_qty, 0);
  end if;
  insert into public.shop_stock (item_id, size, color, quantity, updated_at)
  values (p_item, coalesce(p_size, ''), coalesce(p_color, ''), p_delta, now())
  on conflict (item_id, size, color)
  do update set quantity = public.shop_stock.quantity + excluded.quantity, updated_at = now()
  returning quantity into v_qty;
  insert into public.shop_stock_moves (item_id, size, color, delta, reason, unit_cost_cents, order_id, note, created_by)
  values (p_item, coalesce(p_size, ''), coalesce(p_color, ''), p_delta, p_reason, p_cost, p_order,
          nullif(btrim(coalesce(p_note, '')), ''), auth.uid());
  return v_qty;
end;
$$;
revoke execute on function public._shop_stock_apply(uuid, text, text, int, text, int, uuid, text) from public, anon, authenticated;

-- Réception de marchandise (entrée) ou correction (+/-), par un administrateur
create or replace function public.shop_stock_add(p_item uuid, p_size text, p_color text, p_qty int,
  p_unit_cost_cents int default null, p_note text default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.app_role() is distinct from 'admin' then raise exception 'Réservé aux administrateurs.'; end if;
  if p_qty is null or p_qty = 0 or abs(p_qty) > 100000 then raise exception 'Quantité invalide.'; end if;
  if not exists (select 1 from public.shop_items where id = p_item) then raise exception 'Article introuvable.'; end if;
  if p_unit_cost_cents is not null and p_unit_cost_cents < 0 then raise exception 'Prix d''achat invalide.'; end if;
  return public._shop_stock_apply(p_item, p_size, p_color, p_qty,
    case when p_qty > 0 then 'reception' else 'correction' end, p_unit_cost_cents, null, p_note);
end;
$$;

-- Inventaire : fixe la quantité comptée, l'écart est journalisé
create or replace function public.shop_stock_set(p_item uuid, p_size text, p_color text, p_qty int, p_note text default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare v_cur int;
begin
  if public.app_role() is distinct from 'admin' then raise exception 'Réservé aux administrateurs.'; end if;
  if p_qty is null or p_qty < 0 or p_qty > 100000 then raise exception 'Quantité invalide.'; end if;
  if not exists (select 1 from public.shop_items where id = p_item) then raise exception 'Article introuvable.'; end if;
  select quantity into v_cur from public.shop_stock
   where item_id = p_item and size = coalesce(p_size, '') and color = coalesce(p_color, '') for update;
  return public._shop_stock_apply(p_item, p_size, p_color, p_qty - coalesce(v_cur, 0), 'inventaire', null, null,
    coalesce(nullif(btrim(coalesce(p_note, '')), ''), 'Inventaire'));
end;
$$;

revoke execute on function public.shop_stock_add(uuid, text, text, int, int, text), public.shop_stock_set(uuid, text, text, int, text) from public, anon;
grant execute on function public.shop_stock_add(uuid, text, text, int, int, text), public.shop_stock_set(uuid, text, text, int, text) to authenticated;

-- 4. Statut d'une commande : ardoise (déjà en place) + date de vente + stock ---------
create or replace function public.set_shop_order_status(p_id uuid, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order   public.shop_orders;
  v_label   text;
  v_variant text;
  v_charged boolean := false;
  v_track   boolean;
begin
  if public.app_role() is distinct from 'admin' then raise exception 'Réservé aux administrateurs.'; end if;
  if p_status not in ('pending', 'confirmed', 'ready', 'delivered', 'cancelled') then
    raise exception 'Statut inconnu.';
  end if;
  select * into v_order from public.shop_orders where id = p_id for update;
  if not found then raise exception 'Commande introuvable.'; end if;
  if v_order.status = p_status then return jsonb_build_object('charged', false); end if;
  select track_stock into v_track from public.shop_items where id = v_order.item_id;

  if p_status = 'delivered' and not v_order.ardoise_charged and coalesce(v_order.price_cents, 0) > 0 then
    v_variant := concat_ws(' / ', nullif(v_order.size, ''), nullif(v_order.color, ''));
    v_label := 'Shop – ' || coalesce(v_order.item_name, 'Article')
               || case when v_variant <> '' then ' (' || v_variant || ')' else '' end;
    insert into public.bar_consumptions (user_id, product_id, product_name, unit_price_cents, quantity, created_by)
    values (v_order.user_id, null, v_label, v_order.price_cents, v_order.quantity, auth.uid());
    v_charged := true;
  end if;

  -- Sortie de stock à la livraison, rendue si la commande quitte l'état « livrée »
  if p_status = 'delivered' and not v_order.stock_deducted and coalesce(v_track, true) then
    perform public._shop_stock_apply(v_order.item_id, v_order.size, v_order.color, -v_order.quantity,
      'vente', null, v_order.id, null);
    v_order.stock_deducted := true;
  elsif p_status <> 'delivered' and v_order.stock_deducted then
    perform public._shop_stock_apply(v_order.item_id, v_order.size, v_order.color, v_order.quantity,
      'retour', null, v_order.id, 'Commande sortie de l''état « livrée »');
    v_order.stock_deducted := false;
  end if;

  update public.shop_orders
     set status = p_status,
         ardoise_charged = ardoise_charged or v_charged,
         stock_deducted = v_order.stock_deducted,
         delivered_at = case when p_status = 'delivered' then now() else null end,
         updated_at = now()
   where id = p_id;
  return jsonb_build_object('charged', v_charged);
end;
$$;
revoke execute on function public.set_shop_order_status(uuid, text) from public, anon;
grant execute on function public.set_shop_order_status(uuid, text) to authenticated;

-- 5. Chiffre d'affaires du shop : compté à la date de livraison ----------------------
create or replace function public.revenue_stats(p_months int default 12)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_from date := (date_trunc('month', now() at time zone 'Europe/Paris') - make_interval(months => greatest(p_months, 1) - 1))::date;
begin
  if not (public.app_role() = 'admin' or public.is_treasurer()) then
    raise exception 'Réservé aux administrateurs et au trésorier.';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('month', to_char(m, 'YYYY-MM'), 'bar', bar, 'shop', shop) order by m)
    from (
      select m::date,
             (select coalesce(sum(c.unit_price_cents * c.quantity), 0) from public.bar_consumptions c
               where c.product_id is not null   -- les lignes « Shop – … » débitées sur l'ardoise sont comptées côté shop
                 and date_trunc('month', c.created_at at time zone 'Europe/Paris') = m)::bigint as bar,
             (select coalesce(sum(o.price_cents * o.quantity), 0) from public.shop_orders o
               where o.status = 'delivered'
                 and date_trunc('month', coalesce(o.delivered_at, o.updated_at) at time zone 'Europe/Paris') = m)::bigint as shop
      from generate_series(v_from, (now() at time zone 'Europe/Paris')::date, interval '1 month') as m
    ) t), '[]'::jsonb);
end;
$$;
revoke execute on function public.revenue_stats(int) from public, anon;
grant execute on function public.revenue_stats(int) to authenticated;

-- 6. Journal d'audit sur le stock (comme les autres tables sensibles) -----------------
do $$ begin
  if exists (select 1 from pg_proc where proname = '_audit' and pronamespace = 'public'::regnamespace) then
    execute 'drop trigger if exists zz_audit on public.shop_stock_moves';
    execute 'create trigger zz_audit after update or delete on public.shop_stock_moves for each row execute function public._audit()';
  end if;
end $$;

notify pgrst, 'reload schema';

-- Vérification
select
  to_regclass('public.shop_stock') is not null
  and to_regclass('public.shop_stock_moves') is not null
  and exists (select 1 from pg_proc where proname = 'shop_stock_set')
  and exists (select 1 from information_schema.columns where table_name = 'shop_orders' and column_name = 'delivered_at')
  as "MISE A JOUR 36 OK";
