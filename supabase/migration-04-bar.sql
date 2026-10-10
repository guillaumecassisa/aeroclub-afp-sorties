-- =====================================================================
--  Mise à jour n°4 : le Bar de l'aéroclub
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Trésorier : un membre (de n'importe quel rôle) désigné par un admin --
alter table public.profiles add column if not exists is_treasurer boolean not null default false;

create or replace function public.is_treasurer()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select is_treasurer or role = 'admin' from public.profiles where id = auth.uid()), false)
$$;

create or replace function public.set_treasurer(p_user uuid, p_value boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  update public.profiles set is_treasurer = p_value where id = p_user;
end;
$$;

-- 2. Carte du bar ---------------------------------------------------------
create table if not exists public.bar_products (
  id           uuid primary key default gen_random_uuid(),
  name         text not null check (length(btrim(name)) > 0),
  price_cents  integer not null check (price_cents >= 0),
  active       boolean not null default true,
  position     smallint not null default 0,
  created_at   timestamptz not null default now()
);

insert into public.bar_products (name, price_cents, position)
select * from (values ('Tourtel', 200, 1), ('Bière', 300, 2), ('Coca', 100, 3), ('Eau', 50, 4)) v(name, price, pos)
where not exists (select 1 from public.bar_products);

-- 3. Consommations (le prix est figé au moment de la consommation) --------
create table if not exists public.bar_consumptions (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles (id) on delete cascade,
  product_id        uuid references public.bar_products (id) on delete set null,
  product_name      text not null,
  unit_price_cents  integer not null,
  quantity          smallint not null check (quantity between 1 and 50),
  created_at        timestamptz not null default now(),
  created_by        uuid references public.profiles (id)
);
create index if not exists bar_consumptions_user_date on public.bar_consumptions (user_id, created_at);
create index if not exists bar_consumptions_date on public.bar_consumptions (created_at);

-- 4. Règlements mensuels (coché par le trésorier) -------------------------
create table if not exists public.bar_settlements (
  user_id    uuid not null references public.profiles (id) on delete cascade,
  month      date not null check (extract(day from month) = 1),
  paid_at    timestamptz not null default now(),
  paid_by    uuid references public.profiles (id),
  primary key (user_id, month)
);

-- Mois "comptable" d'une consommation, à l'heure de Paris
create or replace function public.bar_month_of(ts timestamptz)
returns date language sql immutable
as $$ select date_trunc('month', ts at time zone 'Europe/Paris')::date $$;

-- 5. Droits ---------------------------------------------------------------
alter table public.bar_products     enable row level security;
alter table public.bar_consumptions enable row level security;
alter table public.bar_settlements  enable row level security;

drop policy if exists bar_products_select on public.bar_products;
create policy bar_products_select on public.bar_products for select to authenticated
  using (public.is_approved());
drop policy if exists bar_products_write on public.bar_products;
create policy bar_products_write on public.bar_products for all to authenticated
  using (public.is_treasurer()) with check (public.is_treasurer());

drop policy if exists bar_consumptions_select on public.bar_consumptions;
create policy bar_consumptions_select on public.bar_consumptions for select to authenticated
  using (user_id = auth.uid() or public.is_treasurer());

drop policy if exists bar_settlements_select on public.bar_settlements;
create policy bar_settlements_select on public.bar_settlements for select to authenticated
  using (user_id = auth.uid() or public.is_treasurer());

revoke all on public.bar_products, public.bar_consumptions, public.bar_settlements from anon;
revoke insert, update, delete on public.bar_consumptions, public.bar_settlements from authenticated;
grant select on public.bar_consumptions, public.bar_settlements to authenticated;
grant select, insert, update, delete on public.bar_products to authenticated;
revoke update on public.profiles from authenticated;
grant update (full_name, phone, avatar_url, address, emergency_name, emergency_phone)
  on public.profiles to authenticated;

-- 6. Enregistrer / annuler une consommation -------------------------------
create or replace function public.add_consumption(p_product uuid, p_quantity integer default 1, p_user uuid default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_target uuid := coalesce(p_user, auth.uid());
  v_prod   public.bar_products;
  v_id     uuid;
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  if v_target <> v_uid and not public.is_treasurer() then
    raise exception 'Seul le trésorier peut enregistrer pour un autre membre.';
  end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 50 then
    raise exception 'Quantité invalide.';
  end if;
  select * into v_prod from public.bar_products where id = p_product;
  if not found or not v_prod.active then raise exception 'Boisson indisponible.'; end if;

  insert into public.bar_consumptions (user_id, product_id, product_name, unit_price_cents, quantity, created_by)
  values (v_target, v_prod.id, v_prod.name, v_prod.price_cents, p_quantity, v_uid)
  returning id into v_id;
  return v_id;
end;
$$;

-- Un membre peut annuler une erreur dans les 30 minutes ; le trésorier toujours
-- (sauf si le mois est déjà réglé).
create or replace function public.cancel_consumption(p_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_c public.bar_consumptions;
begin
  select * into v_c from public.bar_consumptions where id = p_id;
  if not found then raise exception 'Consommation introuvable.'; end if;
  if not public.is_treasurer() then
    if v_c.user_id <> auth.uid() then raise exception 'Action non autorisée.'; end if;
    if v_c.created_at < now() - interval '30 minutes' then
      raise exception 'Trop tard pour annuler : demandez au trésorier.';
    end if;
  end if;
  if exists (select 1 from public.bar_settlements s
             where s.user_id = v_c.user_id and s.month = public.bar_month_of(v_c.created_at)) then
    raise exception 'Ce mois est déjà réglé : annulation impossible.';
  end if;
  delete from public.bar_consumptions where id = p_id;
end;
$$;

-- 7. Trésorerie : totaux du mois par membre -------------------------------
create or replace function public.bar_month_summary(p_month date)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_month date := date_trunc('month', p_month)::date;
begin
  if not public.is_treasurer() then raise exception 'Réservé au trésorier.'; end if;

  return jsonb_build_object(
    'month', v_month,
    'total_cents', coalesce((select sum(unit_price_cents * quantity) from public.bar_consumptions
                             where public.bar_month_of(created_at) = v_month), 0),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object('name', product_name, 'quantity', q, 'total_cents', t) order by product_name)
      from (select product_name, sum(quantity) q, sum(unit_price_cents * quantity) t
            from public.bar_consumptions where public.bar_month_of(created_at) = v_month
            group by product_name) x), '[]'::jsonb),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
               'user_id', p.id, 'full_name', p.full_name, 'email', p.email, 'avatar_url', p.avatar_url,
               'total_cents', m.total, 'items', m.items,
               'paid', s.user_id is not null, 'paid_at', s.paid_at) order by p.full_name)
      from (
        select user_id, sum(t) total,
               jsonb_object_agg(product_name, q order by product_name) items
        from (select user_id, product_name, sum(quantity) q, sum(unit_price_cents * quantity) t
              from public.bar_consumptions where public.bar_month_of(created_at) = v_month
              group by user_id, product_name) y
        group by user_id
      ) m
      join public.profiles p on p.id = m.user_id
      left join public.bar_settlements s on s.user_id = m.user_id and s.month = v_month), '[]'::jsonb)
  );
end;
$$;

create or replace function public.set_bar_paid(p_user uuid, p_month date, p_paid boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_month date := date_trunc('month', p_month)::date;
begin
  if not public.is_treasurer() then raise exception 'Réservé au trésorier.'; end if;
  if p_paid then
    insert into public.bar_settlements (user_id, month, paid_by) values (p_user, v_month, auth.uid())
    on conflict (user_id, month) do nothing;
  else
    delete from public.bar_settlements where user_id = p_user and month = v_month;
  end if;
end;
$$;

revoke execute on function public.set_treasurer(uuid, boolean) from public, anon;
revoke execute on function public.add_consumption(uuid, integer, uuid) from public, anon;
revoke execute on function public.cancel_consumption(uuid) from public, anon;
revoke execute on function public.bar_month_summary(date) from public, anon;
revoke execute on function public.set_bar_paid(uuid, date, boolean) from public, anon;
grant execute on function public.set_treasurer(uuid, boolean) to authenticated;
grant execute on function public.add_consumption(uuid, integer, uuid) to authenticated;
grant execute on function public.cancel_consumption(uuid) to authenticated;
grant execute on function public.bar_month_summary(date) to authenticated;
grant execute on function public.set_bar_paid(uuid, date, boolean) to authenticated;

-- Rafraîchit l'API
notify pgrst, 'reload schema';
