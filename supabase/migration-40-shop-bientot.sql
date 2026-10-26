-- =====================================================================
--  Mise à jour n°40 : mode « Bientôt disponible » du shop
--  Un administrateur peut l'activer depuis la gestion du shop : la page « Le shop »
--  affiche alors un filigrane « Bientôt disponible » et plus aucune commande n'est
--  possible (refusée par la base, pas seulement masquée sur la page).
--  Les commandes déjà passées restent visibles et gérées normalement.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Réglages du shop (une seule ligne)
create table if not exists public.shop_settings (
  id           boolean primary key default true check (id),
  coming_soon  boolean not null default false,
  message      text check (message is null or length(message) <= 300),
  updated_at   timestamptz not null default now(),
  updated_by   uuid references public.profiles (id) on delete set null
);
insert into public.shop_settings (id) values (true) on conflict (id) do nothing;
alter table public.shop_settings enable row level security;
revoke all on public.shop_settings from anon, authenticated;
grant select on public.shop_settings to authenticated;
drop policy if exists shop_settings_read on public.shop_settings;
create policy shop_settings_read on public.shop_settings for select to authenticated using (public.is_approved());

-- Le shop est-il en « Bientôt disponible » ?
create or replace function public.shop_coming_soon()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$ select coalesce((select coming_soon from public.shop_settings where id), false) $$;
revoke execute on function public.shop_coming_soon() from public, anon;
grant execute on function public.shop_coming_soon() to authenticated;

-- 2. Activer / désactiver (administrateurs)
create or replace function public.set_shop_coming_soon(p_on boolean, p_message text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  insert into public.shop_settings (id, coming_soon, message, updated_at, updated_by)
  values (true, coalesce(p_on, false), nullif(btrim(left(coalesce(p_message, ''), 300)), ''), now(), auth.uid())
  on conflict (id) do update set
    coming_soon = excluded.coming_soon,
    message = excluded.message,
    updated_at = excluded.updated_at,
    updated_by = excluded.updated_by;
end;
$$;
revoke execute on function public.set_shop_coming_soon(boolean, text) from public, anon;
grant execute on function public.set_shop_coming_soon(boolean, text) to authenticated;

-- 3. Aucune nouvelle commande tant que le mode est actif
drop policy if exists "shop_orders_insert" on public.shop_orders;
create policy "shop_orders_insert" on public.shop_orders
  for insert with check (user_id = auth.uid() and public.is_approved() and not public.shop_coming_soon());

-- Journal des modifications
do $$ begin
  if exists (select 1 from pg_proc where proname = '_audit' and pronamespace = 'public'::regnamespace) then
    execute 'drop trigger if exists zz_audit on public.shop_settings';
    execute 'create trigger zz_audit after update on public.shop_settings for each row execute function public._audit()';
  end if;
end $$;

-- Vérification
select 'MISE A JOUR 40 OK' as resultat, (select coming_soon from public.shop_settings) as bientot_en_ligne;
