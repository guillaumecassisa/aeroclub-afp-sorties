-- Mise à jour complète (n°2 à n°32) : peut être exécutée même si une partie a déjà été passée.
-- Elle ne contient aucune commande \i : elle se colle telle quelle dans Supabase > SQL Editor.
-- =====================================================================
--  Mise à jour n°2 : photo de profil, coordonnées, avions « lâchés »
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Nouvelles informations de profil ----------------------------------
alter table public.profiles
  add column if not exists avatar_url      text,
  add column if not exists address         text,
  add column if not exists emergency_name  text,
  add column if not exists emergency_phone text;

grant update (full_name, phone, avatar_url, address, emergency_name, emergency_phone)
  on public.profiles to authenticated;

-- 2. Avions sur lesquels chaque pilote est lâché ------------------------
create table if not exists public.pilot_aircraft (
  user_id      uuid not null references public.profiles (id) on delete cascade,
  aircraft_id  uuid not null references public.aircraft (id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (user_id, aircraft_id)
);

alter table public.pilot_aircraft enable row level security;

drop policy if exists pilot_aircraft_select on public.pilot_aircraft;
create policy pilot_aircraft_select on public.pilot_aircraft for select to authenticated
  using (public.is_approved());

drop policy if exists pilot_aircraft_insert on public.pilot_aircraft;
create policy pilot_aircraft_insert on public.pilot_aircraft for insert to authenticated
  with check (public.is_approved() and (user_id = auth.uid() or public.is_staff()));

drop policy if exists pilot_aircraft_delete on public.pilot_aircraft;
create policy pilot_aircraft_delete on public.pilot_aircraft for delete to authenticated
  using (user_id = auth.uid() or public.is_staff());

revoke all on public.pilot_aircraft from anon;
revoke update on public.pilot_aircraft from authenticated;
grant select, insert, delete on public.pilot_aircraft to authenticated;

-- 3. Stockage des photos (dossier « avatars », une photo par membre) ---
-- Protégé : si Supabase refuse une étape (droits), le reste de la mise à jour continue.
do $$
begin
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('avatars', 'avatars', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
  on conflict (id) do update set public = true;
exception when others then raise notice 'bucket avatars : %', sqlerrm;
end $$;

do $$
begin
  execute 'drop policy if exists avatars_select on storage.objects';
  execute 'create policy avatars_select on storage.objects for select to authenticated using (bucket_id = ''avatars'')';
  execute 'drop policy if exists avatars_insert on storage.objects';
  execute 'create policy avatars_insert on storage.objects for insert to authenticated with check (bucket_id = ''avatars'' and (storage.foldername(name))[1] = auth.uid()::text)';
  execute 'drop policy if exists avatars_update on storage.objects';
  execute 'create policy avatars_update on storage.objects for update to authenticated using (bucket_id = ''avatars'' and (storage.foldername(name))[1] = auth.uid()::text)';
  execute 'drop policy if exists avatars_delete on storage.objects';
  execute 'create policy avatars_delete on storage.objects for delete to authenticated using (bucket_id = ''avatars'' and (storage.foldername(name))[1] = auth.uid()::text)';
exception when others then raise notice 'règles photos : %', sqlerrm;
end $$;

-- 4. Détail d'une sortie : photo des participants + indication « lâché » -
create or replace function public.get_outing(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_staff  boolean := public.is_staff();
  v_outing public.outings;
  v_result jsonb;
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  select * into v_outing from public.outings where id = p_id;
  if not found then return null; end if;

  select jsonb_build_object(
    'id', o.id, 'title', o.title, 'destination', o.destination, 'description', o.description,
    'meeting_point', o.meeting_point, 'departure_at', o.departure_at, 'return_at', o.return_at,
    'registration_deadline', o.registration_deadline, 'status', o.status,
    'instructor_aircraft_id', o.instructor_aircraft_id,
    'instructor', jsonb_build_object('id', ip.id, 'full_name', ip.full_name,
                                     'phone', ip.phone, 'avatar_url', ip.avatar_url),
    'can_manage', v_staff,
    'aircraft', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', a.id, 'registration', a.registration, 'model', a.model, 'seats', a.seats,
               'instructor_onboard', a.id = o.instructor_aircraft_id,
               'capacity', greatest(a.seats - case when a.id = o.instructor_aircraft_id then 1 else 0 end, 0),
               'occupants', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'registration_id', r.id, 'user_id', p.id, 'full_name', p.full_name,
                          'avatar_url', p.avatar_url,
                          'released', exists (select 1 from public.pilot_aircraft pa
                                              where pa.user_id = p.id and pa.aircraft_id = a.id),
                          'phone', case when v_staff or p.id = v_uid then p.phone end)
                        order by r.created_at, r.id)
                 from public.registrations r join public.profiles p on p.id = r.user_id
                 where r.outing_id = o.id and r.status = 'confirmed' and r.aircraft_id = a.id), '[]'::jsonb)
             ) order by oa.position, a.registration)
      from public.outing_aircraft oa join public.aircraft a on a.id = oa.aircraft_id
      where oa.outing_id = o.id), '[]'::jsonb),
    'waitlist', coalesce((
      select jsonb_agg(jsonb_build_object(
               'registration_id', w.id, 'user_id', w.user_id, 'full_name', w.full_name,
               'avatar_url', w.avatar_url, 'released', false,
               'phone', case when v_staff or w.user_id = v_uid then w.phone end,
               'position', w.pos) order by w.pos)
      from (select r.id, r.user_id, p.full_name, p.phone, p.avatar_url,
                   row_number() over (order by r.created_at, r.id) as pos
            from public.registrations r join public.profiles p on p.id = r.user_id
            where r.outing_id = o.id and r.status = 'waitlist') w), '[]'::jsonb),
    'my_registration', (
      select jsonb_build_object('id', r.id, 'status', r.status, 'aircraft_id', r.aircraft_id)
      from public.registrations r
      where r.outing_id = o.id and r.user_id = v_uid and r.status <> 'cancelled')
  ) into v_result
  from public.outings o join public.profiles ip on ip.id = o.instructor_id
  where o.id = p_id;

  return v_result;
end;
$$;

revoke execute on function public.get_outing(uuid) from public, anon;
grant execute on function public.get_outing(uuid) to authenticated;

-- Rafraîchit l'API
notify pgrst, 'reload schema';
-- =====================================================================
--  Mise à jour n°3 : les lâchers se font par TYPE d'avion (DR400, PS28…)
--  et non plus par immatriculation.
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Chaque avion de la flotte reçoit un type (déduit du modèle, modifiable
--    ensuite dans la page Flotte) : "DR400-180" -> "DR400", "PS28 Cruiser" -> "PS28"
alter table public.aircraft add column if not exists type text;
update public.aircraft
   set type = upper(substring(btrim(model) from '^[^[:space:]-]+'))
 where type is null or btrim(type) = '';
alter table public.aircraft alter column type set not null;
grant update (type) on public.aircraft to authenticated;

-- 2. Lâchers par type
create table if not exists public.pilot_types (
  user_id        uuid not null references public.profiles (id) on delete cascade,
  aircraft_type  text not null check (length(btrim(aircraft_type)) > 0),
  created_at     timestamptz not null default now(),
  primary key (user_id, aircraft_type)
);

alter table public.pilot_types enable row level security;

drop policy if exists pilot_types_select on public.pilot_types;
create policy pilot_types_select on public.pilot_types for select to authenticated
  using (public.is_approved());

drop policy if exists pilot_types_insert on public.pilot_types;
create policy pilot_types_insert on public.pilot_types for insert to authenticated
  with check (public.is_approved() and (user_id = auth.uid() or public.is_staff()));

drop policy if exists pilot_types_delete on public.pilot_types;
create policy pilot_types_delete on public.pilot_types for delete to authenticated
  using (user_id = auth.uid() or public.is_staff());

revoke all on public.pilot_types from anon;
revoke update on public.pilot_types from authenticated;
grant select, insert, delete on public.pilot_types to authenticated;

-- 3. Reprise des lâchers déjà saisis par immatriculation, puis suppression
do $$
begin
  if to_regclass('public.pilot_aircraft') is not null then
    insert into public.pilot_types (user_id, aircraft_type)
    select distinct pa.user_id, a.type
    from public.pilot_aircraft pa join public.aircraft a on a.id = pa.aircraft_id
    on conflict do nothing;
    drop table public.pilot_aircraft;
  end if;
end $$;

-- 4. Détail d'une sortie : « lâché » = lâché sur le type de l'avion
create or replace function public.get_outing(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_staff  boolean := public.is_staff();
  v_outing public.outings;
  v_result jsonb;
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  select * into v_outing from public.outings where id = p_id;
  if not found then return null; end if;

  select jsonb_build_object(
    'id', o.id, 'title', o.title, 'destination', o.destination, 'description', o.description,
    'meeting_point', o.meeting_point, 'departure_at', o.departure_at, 'return_at', o.return_at,
    'registration_deadline', o.registration_deadline, 'status', o.status,
    'instructor_aircraft_id', o.instructor_aircraft_id,
    'instructor', jsonb_build_object('id', ip.id, 'full_name', ip.full_name,
                                     'phone', ip.phone, 'avatar_url', ip.avatar_url),
    'can_manage', v_staff,
    'aircraft', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', a.id, 'registration', a.registration, 'model', a.model, 'type', a.type, 'seats', a.seats,
               'instructor_onboard', a.id = o.instructor_aircraft_id,
               'capacity', greatest(a.seats - case when a.id = o.instructor_aircraft_id then 1 else 0 end, 0),
               'occupants', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'registration_id', r.id, 'user_id', p.id, 'full_name', p.full_name,
                          'avatar_url', p.avatar_url,
                          'released', exists (select 1 from public.pilot_types pt
                                              where pt.user_id = p.id and pt.aircraft_type = a.type),
                          'phone', case when v_staff or p.id = v_uid then p.phone end)
                        order by r.created_at, r.id)
                 from public.registrations r join public.profiles p on p.id = r.user_id
                 where r.outing_id = o.id and r.status = 'confirmed' and r.aircraft_id = a.id), '[]'::jsonb)
             ) order by oa.position, a.registration)
      from public.outing_aircraft oa join public.aircraft a on a.id = oa.aircraft_id
      where oa.outing_id = o.id), '[]'::jsonb),
    'waitlist', coalesce((
      select jsonb_agg(jsonb_build_object(
               'registration_id', w.id, 'user_id', w.user_id, 'full_name', w.full_name,
               'avatar_url', w.avatar_url, 'released', false,
               'phone', case when v_staff or w.user_id = v_uid then w.phone end,
               'position', w.pos) order by w.pos)
      from (select r.id, r.user_id, p.full_name, p.phone, p.avatar_url,
                   row_number() over (order by r.created_at, r.id) as pos
            from public.registrations r join public.profiles p on p.id = r.user_id
            where r.outing_id = o.id and r.status = 'waitlist') w), '[]'::jsonb),
    'my_registration', (
      select jsonb_build_object('id', r.id, 'status', r.status, 'aircraft_id', r.aircraft_id)
      from public.registrations r
      where r.outing_id = o.id and r.user_id = v_uid and r.status <> 'cancelled')
  ) into v_result
  from public.outings o join public.profiles ip on ip.id = o.instructor_id
  where o.id = p_id;

  return v_result;
end;
$$;

revoke execute on function public.get_outing(uuid) from public, anon;
grant execute on function public.get_outing(uuid) to authenticated;

-- Rafraîchit l'API
notify pgrst, 'reload schema';
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
-- =====================================================================
--  Mise à jour n°5 : annuaire des membres (nom, téléphone, lâchers)
--  Visible par tous les membres validés. L'adresse et la personne à
--  prévenir restent réservées aux instructeurs et administrateurs.
-- =====================================================================
create or replace function public.member_directory()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id, 'full_name', p.full_name, 'phone', p.phone, 'avatar_url', p.avatar_url,
             'role', p.role,
             'types', coalesce((select jsonb_agg(pt.aircraft_type order by pt.aircraft_type)
                                from public.pilot_types pt where pt.user_id = p.id), '[]'::jsonb))
           order by lower(p.full_name))
    from public.profiles p
    where p.role <> 'pending'), '[]'::jsonb);
end;
$$;

revoke execute on function public.member_directory() from public, anon;
grant execute on function public.member_directory() to authenticated;

-- Rafraîchit l'API
notify pgrst, 'reload schema';


-- ===================== Mise à jour n°6 : propositions de sorties =====================
-- =====================================================================
--  Mise à jour n°6 : propositions de sorties par les membres
--  Un membre propose ; un instructeur ou un administrateur approuve
--  (ou refuse) avant publication.
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

alter table public.outings
  add column if not exists approval text not null default 'approved'
    check (approval in ('pending', 'approved', 'rejected')),
  add column if not exists rejection_reason text,
  add column if not exists approved_by uuid references public.profiles (id),
  add column if not exists approved_at timestamptz;

-- Les membres ne voient que les sorties publiées (et leurs propres propositions)
drop policy if exists outings_select on public.outings;
create policy outings_select on public.outings for select to authenticated
  using (public.is_approved() and (approval = 'approved' or instructor_id = auth.uid() or public.is_staff()));

create or replace function public.save_outing(
  p_id                   uuid,
  p_title                text,
  p_destination          text,
  p_description          text,
  p_meeting_point        text,
  p_departure_at         timestamptz,
  p_return_at            timestamptz,
  p_deadline             timestamptz,
  p_aircraft             uuid[],
  p_instructor_aircraft  uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_outing public.outings;
  v_i      int;
  v_staff  boolean;
  v_notify jsonb := '[]'::jsonb;
begin
  v_staff := public.is_staff();
  if not public.is_approved() then
    raise exception 'Votre compte n''est pas encore validé.';
  end if;
  if p_title is null or length(btrim(p_title)) = 0 then raise exception 'Le titre est obligatoire.'; end if;
  if p_departure_at is null then raise exception 'La date de départ est obligatoire.'; end if;
  if p_return_at is not null and p_return_at < p_departure_at then
    raise exception 'Le retour doit être après le départ.';
  end if;
  if p_deadline is not null and p_deadline > p_departure_at then
    raise exception 'La date limite d''inscription doit précéder le départ.';
  end if;
  if coalesce(array_length(p_aircraft, 1), 0) = 0 then
    raise exception 'Sélectionnez au moins un avion.';
  end if;
  if (select count(distinct x) from unnest(p_aircraft) x) <> array_length(p_aircraft, 1) then
    raise exception 'Un avion est sélectionné deux fois.';
  end if;
  if (select count(*) from public.aircraft where id = any (p_aircraft)) <> array_length(p_aircraft, 1) then
    raise exception 'Avion inconnu.';
  end if;
  if p_instructor_aircraft is not null and not (p_instructor_aircraft = any (p_aircraft)) then
    raise exception 'L''avion de l''instructeur doit faire partie des avions de la sortie.';
  end if;

  if p_id is null then
    insert into public.outings (title, destination, description, meeting_point, departure_at,
                                return_at, registration_deadline, instructor_id, instructor_aircraft_id,
                                approval, approved_by, approved_at)
    values (btrim(p_title), nullif(btrim(p_destination), ''), nullif(btrim(p_description), ''),
            nullif(btrim(p_meeting_point), ''), p_departure_at, p_return_at, p_deadline,
            v_uid, p_instructor_aircraft,
            case when v_staff then 'approved' else 'pending' end,
            case when v_staff then v_uid end, case when v_staff then now() end)
    returning * into v_outing;
    -- Proposition d'un membre : on prévient les instructeurs et administrateurs
    if not v_staff then
      select coalesce(jsonb_agg(jsonb_build_object('email', email, 'full_name', full_name)), '[]'::jsonb)
        into v_notify from public.profiles where role in ('instructor', 'admin');
    end if;
  else
    select * into v_outing from public.outings where id = p_id for update;
    if not found then raise exception 'Sortie introuvable.'; end if;
    if v_outing.status = 'cancelled' then raise exception 'Sortie annulée : modification impossible.'; end if;
    if not v_staff and not (v_outing.instructor_id = v_uid and v_outing.approval <> 'approved') then
      raise exception 'Seul un instructeur peut modifier une sortie publiée.';
    end if;

    update public.outings set
      title = btrim(p_title),
      destination = nullif(btrim(p_destination), ''),
      description = nullif(btrim(p_description), ''),
      meeting_point = nullif(btrim(p_meeting_point), ''),
      departure_at = p_departure_at,
      return_at = p_return_at,
      registration_deadline = p_deadline,
      instructor_aircraft_id = p_instructor_aircraft,
      -- une proposition refusée puis corrigée repart en validation
      approval = case when approval = 'rejected' then 'pending' else approval end,
      updated_at = now()
    where id = p_id
    returning * into v_outing;

    delete from public.outing_aircraft
     where outing_id = p_id and not (aircraft_id = any (p_aircraft));
  end if;

  -- L'instructeur qui vole n'est pas aussi un "passager" inscrit
  if p_instructor_aircraft is not null then
    update public.registrations
       set status = 'cancelled', aircraft_id = null, cancelled_at = now()
     where outing_id = v_outing.id and user_id = v_outing.instructor_id and status <> 'cancelled';
  end if;

  for v_i in 1 .. array_length(p_aircraft, 1) loop
    insert into public.outing_aircraft (outing_id, aircraft_id, position)
    values (v_outing.id, p_aircraft[v_i], v_i)
    on conflict (outing_id, aircraft_id) do update set position = excluded.position;
  end loop;

  return jsonb_build_object('outing_id', v_outing.id,
                            'approval', (select approval from public.outings where id = v_outing.id),
                            'notify_staff', v_notify,
                            'changes', public._rebalance_outing(v_outing.id));
end;
$$;

create or replace function public.register_for_outing(p_outing uuid, p_user uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_target  uuid;
  v_outing  public.outings;
  v_reg     public.registrations;
  v_changes jsonb;
  v_pos     int;
begin
  if v_uid is null then raise exception 'Vous devez être connecté.'; end if;
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;

  v_target := coalesce(p_user, v_uid);
  if v_target <> v_uid and not public.is_staff() then
    raise exception 'Seul un instructeur peut inscrire un autre membre.';
  end if;

  select * into v_outing from public.outings where id = p_outing for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  if v_outing.status = 'cancelled' then raise exception 'Cette sortie est annulée.'; end if;
  if v_outing.approval <> 'approved' then raise exception 'Cette sortie n''a pas encore été validée par un instructeur.'; end if;
  if v_outing.departure_at <= now() then raise exception 'Cette sortie a déjà eu lieu.'; end if;
  if v_outing.registration_deadline is not null and now() > v_outing.registration_deadline
     and not public.is_staff() then
    raise exception 'Les inscriptions sont closes pour cette sortie.';
  end if;
  if not exists (select 1 from public.profiles where id = v_target and role <> 'pending') then
    raise exception 'Ce membre n''existe pas ou n''est pas encore validé.';
  end if;
  if v_target = v_outing.instructor_id and v_outing.instructor_aircraft_id is not null then
    raise exception 'L''instructeur de la sortie occupe déjà un siège.';
  end if;
  if exists (select 1 from public.registrations
             where outing_id = p_outing and user_id = v_target and status <> 'cancelled') then
    raise exception 'Déjà inscrit à cette sortie.';
  end if;

  insert into public.registrations (outing_id, user_id, status, created_by)
  values (p_outing, v_target, 'waitlist', v_uid)
  returning * into v_reg;

  v_changes := public._rebalance_outing(p_outing);

  select * into v_reg from public.registrations where id = v_reg.id;
  if v_reg.status = 'waitlist' then
    select count(*) into v_pos from public.registrations
     where outing_id = p_outing and status = 'waitlist'
       and (created_at, id) <= (v_reg.created_at, v_reg.id);
  end if;

  return jsonb_build_object(
    'registration_id', v_reg.id,
    'status', v_reg.status,
    'waitlist_position', v_pos,
    'changes', coalesce((select jsonb_agg(c) from jsonb_array_elements(v_changes) c
                         where (c ->> 'user_id')::uuid <> v_target), '[]'::jsonb)
  );
end;
$$;

create or replace function public.list_outings(p_past boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;

  return coalesce((
    select jsonb_agg(row_to_json(t) order by
             case when p_past then null else t.departure_at end asc,
             case when p_past then t.departure_at end desc)
    from (
      select o.id, o.title, o.destination, o.departure_at, o.return_at,
             o.registration_deadline, o.status,
             ip.full_name as instructor_name,
             (o.instructor_aircraft_id is not null) as instructor_flies,
             (select coalesce(sum(greatest(a.seats - case when a.id = o.instructor_aircraft_id then 1 else 0 end, 0)), 0)
                from public.outing_aircraft oa join public.aircraft a on a.id = oa.aircraft_id
               where oa.outing_id = o.id) as total_capacity,
             (select count(*) from public.registrations r
               where r.outing_id = o.id and r.status = 'confirmed') as confirmed_count,
             (select count(*) from public.registrations r
               where r.outing_id = o.id and r.status = 'waitlist') as waitlist_count,
             (select string_agg(a.registration || ' (' || a.seats || 'pl.)', ', ' order by oa.position)
                from public.outing_aircraft oa join public.aircraft a on a.id = oa.aircraft_id
               where oa.outing_id = o.id) as aircraft_summary,
             (select r.status from public.registrations r
               where r.outing_id = o.id and r.user_id = v_uid and r.status <> 'cancelled') as my_status,
             (o.instructor_id = v_uid) as i_am_instructor,
             o.approval, o.rejection_reason
      from public.outings o
      join public.profiles ip on ip.id = o.instructor_id
      where (o.approval = 'approved' or o.instructor_id = v_uid or public.is_staff())
        and case when p_past
                 then coalesce(o.return_at, o.departure_at) < now()
                 else coalesce(o.return_at, o.departure_at) >= now() end
      limit 200
    ) t), '[]'::jsonb);
end;
$$;

create or replace function public.get_outing(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_staff  boolean := public.is_staff();
  v_outing public.outings;
  v_result jsonb;
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  select * into v_outing from public.outings where id = p_id;
  if not found then return null; end if;
  if v_outing.approval <> 'approved' and v_outing.instructor_id <> v_uid and not v_staff then
    return null;
  end if;

  select jsonb_build_object(
    'id', o.id, 'title', o.title, 'destination', o.destination, 'description', o.description,
    'meeting_point', o.meeting_point, 'departure_at', o.departure_at, 'return_at', o.return_at,
    'registration_deadline', o.registration_deadline, 'status', o.status,
    'instructor_aircraft_id', o.instructor_aircraft_id,
    'instructor', jsonb_build_object('id', ip.id, 'full_name', ip.full_name,
                                     'phone', ip.phone, 'avatar_url', ip.avatar_url),
    'can_manage', v_staff,
    'approval', o.approval, 'rejection_reason', o.rejection_reason,
    'can_edit', v_staff or (o.instructor_id = v_uid and o.approval <> 'approved'),
    'aircraft', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', a.id, 'registration', a.registration, 'model', a.model, 'type', a.type, 'seats', a.seats,
               'instructor_onboard', a.id = o.instructor_aircraft_id,
               'capacity', greatest(a.seats - case when a.id = o.instructor_aircraft_id then 1 else 0 end, 0),
               'occupants', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'registration_id', r.id, 'user_id', p.id, 'full_name', p.full_name,
                          'avatar_url', p.avatar_url,
                          'released', exists (select 1 from public.pilot_types pt
                                              where pt.user_id = p.id and pt.aircraft_type = a.type),
                          'phone', case when v_staff or p.id = v_uid then p.phone end)
                        order by r.created_at, r.id)
                 from public.registrations r join public.profiles p on p.id = r.user_id
                 where r.outing_id = o.id and r.status = 'confirmed' and r.aircraft_id = a.id), '[]'::jsonb)
             ) order by oa.position, a.registration)
      from public.outing_aircraft oa join public.aircraft a on a.id = oa.aircraft_id
      where oa.outing_id = o.id), '[]'::jsonb),
    'waitlist', coalesce((
      select jsonb_agg(jsonb_build_object(
               'registration_id', w.id, 'user_id', w.user_id, 'full_name', w.full_name,
               'avatar_url', w.avatar_url, 'released', false,
               'phone', case when v_staff or w.user_id = v_uid then w.phone end,
               'position', w.pos) order by w.pos)
      from (select r.id, r.user_id, p.full_name, p.phone, p.avatar_url,
                   row_number() over (order by r.created_at, r.id) as pos
            from public.registrations r join public.profiles p on p.id = r.user_id
            where r.outing_id = o.id and r.status = 'waitlist') w), '[]'::jsonb),
    'my_registration', (
      select jsonb_build_object('id', r.id, 'status', r.status, 'aircraft_id', r.aircraft_id)
      from public.registrations r
      where r.outing_id = o.id and r.user_id = v_uid and r.status <> 'cancelled')
  ) into v_result
  from public.outings o join public.profiles ip on ip.id = o.instructor_id
  where o.id = p_id;

  return v_result;
end;
$$;

create or replace function public.cancel_outing(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_outing public.outings;
begin
  select * into v_outing from public.outings where id = p_id for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  -- un membre peut retirer sa propre proposition non publiée
  if not public.is_staff() and not (v_outing.instructor_id = auth.uid() and v_outing.approval <> 'approved') then
    raise exception 'Action réservée aux instructeurs.';
  end if;
  if v_outing.status = 'cancelled' then raise exception 'Sortie déjà annulée.'; end if;

  update public.outings set status = 'cancelled', updated_at = now() where id = p_id;

  return jsonb_build_object('recipients', coalesce((
    select jsonb_agg(jsonb_build_object('user_id', p.id, 'email', p.email, 'full_name', p.full_name))
    from public.registrations r join public.profiles p on p.id = r.user_id
    where r.outing_id = p_id and r.status <> 'cancelled'), '[]'::jsonb));
end;
$$;

-- Validation par un instructeur / administrateur
create or replace function public.review_outing(p_id uuid, p_approve boolean, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_outing public.outings;
begin
  if not public.is_staff() then raise exception 'Action réservée aux instructeurs.'; end if;
  select * into v_outing from public.outings where id = p_id for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  if v_outing.approval = 'approved' then raise exception 'Cette sortie est déjà publiée.'; end if;

  update public.outings set
    approval = case when p_approve then 'approved' else 'rejected' end,
    rejection_reason = case when p_approve then null else nullif(btrim(p_reason), '') end,
    approved_by = case when p_approve then auth.uid() end,
    approved_at = case when p_approve then now() end,
    updated_at = now()
  where id = p_id;

  return (select jsonb_build_object('email', p.email, 'full_name', p.full_name, 'title', v_outing.title,
                                    'departure_at', v_outing.departure_at)
          from public.profiles p where p.id = v_outing.instructor_id);
end;
$$;

revoke execute on function public.review_outing(uuid, boolean, text) from public, anon;
grant execute on function public.review_outing(uuid, boolean, text) to authenticated;

-- Rafraîchit l'API
notify pgrst, 'reload schema';


-- ===================== Mise à jour n°7 : poids =====================
-- =====================================================================
--  Mise à jour n°7 : poids des pilotes (facultatif)
--  Stocké à part : chaque membre ne voit que le sien ; seul l'organisateur
--  (instructeur référent) d'une sortie voit le poids de ses participants.
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

create table if not exists public.pilot_weights (
  user_id    uuid primary key references public.profiles (id) on delete cascade,
  weight_kg  numeric(5,1) check (weight_kg between 20 and 250),
  updated_at timestamptz not null default now()
);

alter table public.pilot_weights enable row level security;

drop policy if exists pilot_weights_own on public.pilot_weights;
create policy pilot_weights_own on public.pilot_weights for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

revoke all on public.pilot_weights from anon;
grant select, insert, update, delete on public.pilot_weights to authenticated;

create or replace function public.get_outing(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_staff  boolean := public.is_staff();
  v_outing public.outings;
  v_result jsonb;
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  select * into v_outing from public.outings where id = p_id;
  if not found then return null; end if;
  if v_outing.approval <> 'approved' and v_outing.instructor_id <> v_uid and not v_staff then
    return null;
  end if;

  select jsonb_build_object(
    'id', o.id, 'title', o.title, 'destination', o.destination, 'description', o.description,
    'meeting_point', o.meeting_point, 'departure_at', o.departure_at, 'return_at', o.return_at,
    'registration_deadline', o.registration_deadline, 'status', o.status,
    'instructor_aircraft_id', o.instructor_aircraft_id,
    'instructor', jsonb_build_object('id', ip.id, 'full_name', ip.full_name,
                                     'phone', ip.phone, 'avatar_url', ip.avatar_url),
    'can_manage', v_staff,
    'is_organizer', o.instructor_id = v_uid,
    'organizer_weight_kg', case when o.instructor_id = v_uid then
                             (select pw.weight_kg from public.pilot_weights pw where pw.user_id = o.instructor_id) end,
    'approval', o.approval, 'rejection_reason', o.rejection_reason,
    'can_edit', v_staff or (o.instructor_id = v_uid and o.approval <> 'approved'),
    'aircraft', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', a.id, 'registration', a.registration, 'model', a.model, 'type', a.type, 'seats', a.seats,
               'instructor_onboard', a.id = o.instructor_aircraft_id,
               'capacity', greatest(a.seats - case when a.id = o.instructor_aircraft_id then 1 else 0 end, 0),
               'occupants', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'registration_id', r.id, 'user_id', p.id, 'full_name', p.full_name,
                          'avatar_url', p.avatar_url,
                          'released', exists (select 1 from public.pilot_types pt
                                              where pt.user_id = p.id and pt.aircraft_type = a.type),
                          'phone', case when v_staff or p.id = v_uid then p.phone end,
                          'weight_kg', case when o.instructor_id = v_uid then
                                         (select pw.weight_kg from public.pilot_weights pw where pw.user_id = p.id) end)
                        order by r.created_at, r.id)
                 from public.registrations r join public.profiles p on p.id = r.user_id
                 where r.outing_id = o.id and r.status = 'confirmed' and r.aircraft_id = a.id), '[]'::jsonb)
             ) order by oa.position, a.registration)
      from public.outing_aircraft oa join public.aircraft a on a.id = oa.aircraft_id
      where oa.outing_id = o.id), '[]'::jsonb),
    'waitlist', coalesce((
      select jsonb_agg(jsonb_build_object(
               'registration_id', w.id, 'user_id', w.user_id, 'full_name', w.full_name,
               'avatar_url', w.avatar_url, 'released', false,
               'phone', case when v_staff or w.user_id = v_uid then w.phone end,
               'weight_kg', case when o.instructor_id = v_uid then
                              (select pw.weight_kg from public.pilot_weights pw where pw.user_id = w.user_id) end,
               'position', w.pos) order by w.pos)
      from (select r.id, r.user_id, p.full_name, p.phone, p.avatar_url,
                   row_number() over (order by r.created_at, r.id) as pos
            from public.registrations r join public.profiles p on p.id = r.user_id
            where r.outing_id = o.id and r.status = 'waitlist') w), '[]'::jsonb),
    'my_registration', (
      select jsonb_build_object('id', r.id, 'status', r.status, 'aircraft_id', r.aircraft_id)
      from public.registrations r
      where r.outing_id = o.id and r.user_id = v_uid and r.status <> 'cancelled')
  ) into v_result
  from public.outings o join public.profiles ip on ip.id = o.instructor_id
  where o.id = p_id;

  return v_result;
end;
$$;

revoke execute on function public.get_outing(uuid) from public, anon;
grant execute on function public.get_outing(uuid) to authenticated;

notify pgrst, 'reload schema';


-- ===================== Mise à jour n°8 : rôles, annonces, avions =====================
-- =====================================================================
--  Mise à jour n°8 : trésorier (seul accès aux comptes du bar),
--  secrétaire (administrateur complet), annonces du club.
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Trésorier : seule la personne nommée voit les consommations de tous
create or replace function public.is_treasurer()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select is_treasurer from public.profiles where id = auth.uid() and role <> 'pending'), false)
$$;

-- 2. Secrétaire = administrateur complet, avec son titre
alter table public.profiles add column if not exists is_secretary boolean not null default false;

create or replace function public.set_secretary(p_user uuid, p_value boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  if p_value then
    update public.profiles set is_secretary = true, role = 'admin' where id = p_user;
  else
    update public.profiles set is_secretary = false where id = p_user;
  end if;
end;
$$;
revoke execute on function public.set_secretary(uuid, boolean) from public, anon;
grant execute on function public.set_secretary(uuid, boolean) to authenticated;

-- 3. Annonces
create table if not exists public.announcements (
  id          uuid primary key default gen_random_uuid(),
  title       text not null check (length(btrim(title)) between 1 and 120),
  body        text check (body is null or length(body) <= 2000),
  important   boolean not null default false,
  expires_at  timestamptz,
  created_by  uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at  timestamptz not null default now()
);
alter table public.announcements enable row level security;

drop policy if exists announcements_select on public.announcements;
create policy announcements_select on public.announcements for select to authenticated
  using (public.is_approved());
drop policy if exists announcements_insert on public.announcements;
create policy announcements_insert on public.announcements for insert to authenticated
  with check (public.is_staff());
drop policy if exists announcements_delete on public.announcements;
create policy announcements_delete on public.announcements for delete to authenticated
  using (public.is_staff());

revoke all on public.announcements from anon;
revoke update on public.announcements from authenticated;
grant select, insert, delete on public.announcements to authenticated;

-- 4. Disponibilité des avions (en maintenance, immobilisé…), distincte de « actif »
alter table public.aircraft add column if not exists available boolean not null default true;
alter table public.aircraft add column if not exists unavailable_reason text;
grant update (available, unavailable_reason) on public.aircraft to authenticated;

-- 5. Avions du club
insert into public.aircraft (registration, model, type, seats, available) values
  ('F-HVXD', 'WT9 Dynamic', 'WT9', 2, false),
  ('F-HUIT', 'PS28 Cruiser', 'PS28', 2, false),
  ('F-HUFA', 'B23', 'B23', 2, false)
on conflict (registration) do update
  set model = excluded.model, type = excluded.type, seats = excluded.seats, active = true;

notify pgrst, 'reload schema';


-- ===================== Mise à jour n°9 : responsable maintenance =====================
-- =====================================================================
--  Mise à jour n°9 : responsable maintenance.
--  La flotte (ajout d'avion, disponibilité, types) est réservée aux
--  administrateurs et aux responsables maintenance.
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

alter table public.profiles add column if not exists is_maintenance boolean not null default false;
alter table public.aircraft add column if not exists available boolean not null default true;
alter table public.aircraft add column if not exists unavailable_reason text;

create or replace function public.can_manage_fleet()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select role = 'admin' or (is_maintenance and role <> 'pending')
                   from public.profiles where id = auth.uid()), false)
$$;

create or replace function public.set_maintenance(p_user uuid, p_value boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  update public.profiles set is_maintenance = p_value where id = p_user;
end;
$$;

drop policy if exists aircraft_insert on public.aircraft;
create policy aircraft_insert on public.aircraft for insert to authenticated
  with check (public.can_manage_fleet());
drop policy if exists aircraft_update on public.aircraft;
create policy aircraft_update on public.aircraft for update to authenticated
  using (public.can_manage_fleet()) with check (public.can_manage_fleet());
drop policy if exists aircraft_delete on public.aircraft;
create policy aircraft_delete on public.aircraft for delete to authenticated
  using (public.can_manage_fleet());

-- Disponibilité d'un avion (renvoie une erreur claire si refusé)
create or replace function public.set_aircraft_availability(p_id uuid, p_available boolean, p_reason text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.can_manage_fleet() then
    raise exception 'Réservé aux administrateurs et aux responsables maintenance.';
  end if;
  update public.aircraft
     set available = p_available,
         unavailable_reason = case when p_available then null else nullif(btrim(coalesce(p_reason, '')), '') end
   where id = p_id;
  if not found then raise exception 'Avion introuvable.'; end if;
end;
$$;

revoke execute on function public.set_maintenance(uuid, boolean) from public, anon;
grant execute on function public.set_maintenance(uuid, boolean) to authenticated;
revoke execute on function public.set_aircraft_availability(uuid, boolean, text) from public, anon;
grant execute on function public.set_aircraft_availability(uuid, boolean, text) to authenticated;
grant execute on function public.can_manage_fleet() to authenticated;

notify pgrst, 'reload schema';

-- ===================== Mise à jour n°10 : documentation des avions =====================
-- =====================================================================
--  Mise à jour n°10 : documentation des avions (onglet « Flotte »).
--  Lecture : tous les membres validés.
--  Ajout / suppression : administrateurs et responsables maintenance.
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

create table if not exists public.aircraft_documents (
  id           uuid primary key default gen_random_uuid(),
  aircraft_id  uuid not null references public.aircraft (id) on delete cascade,
  category     text not null default 'autre'
               check (category in ('manuel','checklist','masse_centrage','performances','procedures','administratif','maintenance','autre')),
  title        text not null check (length(btrim(title)) between 1 and 200),
  file_path    text not null unique,
  file_name    text not null,
  mime_type    text,
  size_bytes   bigint,
  created_by   uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at   timestamptz not null default now()
);
create index if not exists aircraft_documents_aircraft on public.aircraft_documents (aircraft_id, category, title);

alter table public.aircraft_documents enable row level security;

drop policy if exists aircraft_documents_select on public.aircraft_documents;
create policy aircraft_documents_select on public.aircraft_documents for select to authenticated
  using (public.is_approved());
drop policy if exists aircraft_documents_insert on public.aircraft_documents;
create policy aircraft_documents_insert on public.aircraft_documents for insert to authenticated
  with check (public.can_manage_fleet());
drop policy if exists aircraft_documents_update on public.aircraft_documents;
create policy aircraft_documents_update on public.aircraft_documents for update to authenticated
  using (public.can_manage_fleet()) with check (public.can_manage_fleet());
drop policy if exists aircraft_documents_delete on public.aircraft_documents;
create policy aircraft_documents_delete on public.aircraft_documents for delete to authenticated
  using (public.can_manage_fleet());

revoke all on public.aircraft_documents from anon;
grant select, insert, update, delete on public.aircraft_documents to authenticated;

-- Fichiers : dossier privé « aircraft-docs » (50 Mo max par fichier)
do $$
begin
  insert into storage.buckets (id, name, public, file_size_limit)
  values ('aircraft-docs', 'aircraft-docs', false, 52428800)
  on conflict (id) do update set public = false, file_size_limit = 52428800;
exception when others then raise notice 'bucket aircraft-docs : %', sqlerrm;
end $$;

do $$
begin
  execute 'drop policy if exists aircraft_docs_select on storage.objects';
  execute 'create policy aircraft_docs_select on storage.objects for select to authenticated using (bucket_id = ''aircraft-docs'' and public.is_approved())';
  execute 'drop policy if exists aircraft_docs_insert on storage.objects';
  execute 'create policy aircraft_docs_insert on storage.objects for insert to authenticated with check (bucket_id = ''aircraft-docs'' and public.can_manage_fleet())';
  execute 'drop policy if exists aircraft_docs_update on storage.objects';
  execute 'create policy aircraft_docs_update on storage.objects for update to authenticated using (bucket_id = ''aircraft-docs'' and public.can_manage_fleet())';
  execute 'drop policy if exists aircraft_docs_delete on storage.objects';
  execute 'create policy aircraft_docs_delete on storage.objects for delete to authenticated using (bucket_id = ''aircraft-docs'' and public.can_manage_fleet())';
exception when others then raise notice 'règles documents : %', sqlerrm;
end $$;

notify pgrst, 'reload schema';

-- ===================== Mise à jour n°11 : événements =====================
-- =====================================================================
--  Mise à jour n°11 : Événements
--  Trois types : sortie avion (avec avions), activité (sans avion : moto,
--  randonnée…), événement convivial (apéro, dîner, soirée).
--  Peuvent créer et gérer : administrateurs, instructeurs, membres du CA
--  et toute personne ayant une fonction (trésorier, secrétaire, maintenance).
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

alter table public.outings add column if not exists kind text not null default 'vol';
alter table public.outings drop constraint if exists outings_kind_check;
alter table public.outings add constraint outings_kind_check check (kind in ('vol', 'activite', 'evenement', 'formation')); -- 'formation' : n°29 (permet de rejouer le fichier)
alter table public.outings add column if not exists max_participants int check (max_participants is null or max_participants >= 1);
alter table public.profiles add column if not exists is_board boolean not null default false;

create or replace function public.can_organize()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select role in ('instructor', 'admin')
                          or (role <> 'pending' and (is_board or is_treasurer or is_secretary or is_maintenance))
                   from public.profiles where id = auth.uid()), false)
$$;
grant execute on function public.can_organize() to authenticated;

create or replace function public.set_board(p_user uuid, p_value boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  update public.profiles set is_board = p_value where id = p_user;
end;
$$;
revoke execute on function public.set_board(uuid, boolean) from public, anon;
grant execute on function public.set_board(uuid, boolean) to authenticated;

drop policy if exists outings_select on public.outings;
create policy outings_select on public.outings for select to authenticated
  using (public.is_approved() and (approval = 'approved' or instructor_id = auth.uid() or public.can_organize()));

drop function if exists public.save_outing(uuid, text, text, text, text, timestamptz, timestamptz, timestamptz, uuid[], uuid);

create or replace function public._rebalance_outing(p_outing uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_outing   public.outings;
  v_ac       uuid[] := '{}';
  v_cap      int[]  := '{}';
  v_used     int[]  := '{}';
  v_total    int := 0;
  v_idx      int := 0;
  v_pending  uuid[] := '{}';
  v_changes  jsonb := '[]'::jsonb;
  v_i        int;
  v_slot     int;
  r          record;
begin
  select * into v_outing from public.outings where id = p_outing;
  if not found or v_outing.status = 'cancelled' then
    return v_changes;
  end if;

  -- Activité / événement sans avion : les N premiers inscrits sont confirmés
  if coalesce(v_outing.kind, 'vol') <> 'vol' then
    v_total := coalesce(v_outing.max_participants, 1000000);
    for r in
      select reg.id, reg.status
      from public.registrations reg
      where reg.outing_id = p_outing and reg.status <> 'cancelled'
      order by reg.created_at, reg.id
    loop
      v_idx := v_idx + 1;
      if v_idx <= v_total then
        if r.status <> 'confirmed' then
          update public.registrations set status = 'confirmed', aircraft_id = null where id = r.id;
          v_changes := v_changes || jsonb_build_object('registration_id', r.id, 'change', 'promoted');
        end if;
      elsif r.status <> 'waitlist' then
        update public.registrations set status = 'waitlist', aircraft_id = null where id = r.id;
        v_changes := v_changes || jsonb_build_object('registration_id', r.id, 'change', 'demoted');
      end if;
    end loop;
    select coalesce(jsonb_agg(jsonb_build_object(
             'user_id', p.id, 'email', p.email, 'full_name', p.full_name,
             'change', c ->> 'change')), '[]'::jsonb)
      into v_changes
    from jsonb_array_elements(v_changes) c
    join public.registrations reg on reg.id = (c ->> 'registration_id')::uuid
    join public.profiles p on p.id = reg.user_id;
    return v_changes;
  end if;

  for r in
    select oa.aircraft_id,
           greatest(a.seats - case when v_outing.instructor_aircraft_id = oa.aircraft_id then 1 else 0 end, 0) as cap
    from public.outing_aircraft oa
    join public.aircraft a on a.id = oa.aircraft_id
    where oa.outing_id = p_outing
    order by oa.position, a.registration
  loop
    v_ac   := v_ac || r.aircraft_id;
    v_cap  := v_cap || r.cap;
    v_used := v_used || 0;
    v_total := v_total + r.cap;
  end loop;

  -- 1er passage : qui est confirmé, qui garde son avion, qui repasse en attente
  for r in
    select reg.id, reg.status, reg.aircraft_id
    from public.registrations reg
    where reg.outing_id = p_outing and reg.status <> 'cancelled'
    order by reg.created_at, reg.id
  loop
    v_idx := v_idx + 1;
    if v_idx <= v_total then
      v_i := array_position(v_ac, r.aircraft_id);
      if r.status = 'confirmed' and v_i is not null and v_used[v_i] < v_cap[v_i] then
        v_used[v_i] := v_used[v_i] + 1;
      else
        v_pending := v_pending || r.id;
      end if;
    elsif r.status <> 'waitlist' or r.aircraft_id is not null then
      update public.registrations set status = 'waitlist', aircraft_id = null where id = r.id;
      if r.status = 'confirmed' then
        v_changes := v_changes || jsonb_build_object('registration_id', r.id, 'change', 'demoted');
      end if;
    end if;
  end loop;

  -- 2e passage : placement dans les avions ayant des sièges libres
  for r in
    select reg.id, reg.status
    from public.registrations reg
    where reg.id = any (v_pending)
    order by reg.created_at, reg.id
  loop
    v_slot := null;
    for v_i in 1 .. coalesce(array_length(v_ac, 1), 0) loop
      if v_used[v_i] < v_cap[v_i] then
        v_slot := v_i;
        exit;
      end if;
    end loop;
    exit when v_slot is null; -- ne devrait pas arriver

    v_used[v_slot] := v_used[v_slot] + 1;
    update public.registrations
       set status = 'confirmed', aircraft_id = v_ac[v_slot]
     where id = r.id;
    if r.status = 'waitlist' then
      v_changes := v_changes || jsonb_build_object('registration_id', r.id, 'change', 'promoted');
    end if;
  end loop;

  -- Enrichit avec les coordonnées (pour l'envoi des emails côté serveur)
  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id', p.id, 'email', p.email, 'full_name', p.full_name,
           'change', c ->> 'change')), '[]'::jsonb)
    into v_changes
  from jsonb_array_elements(v_changes) c
  join public.registrations reg on reg.id = (c ->> 'registration_id')::uuid
  join public.profiles p on p.id = reg.user_id;

  return v_changes;
end;
$$;

create or replace function public.save_outing(
  p_id                   uuid,
  p_title                text,
  p_destination          text,
  p_description          text,
  p_meeting_point        text,
  p_departure_at         timestamptz,
  p_return_at            timestamptz,
  p_deadline             timestamptz,
  p_aircraft             uuid[],
  p_instructor_aircraft  uuid,
  p_kind                 text default 'vol',
  p_max_participants     int  default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_outing public.outings;
  v_i      int;
  v_staff  boolean;
  v_notify jsonb := '[]'::jsonb;
  v_kind   text := coalesce(nullif(p_kind, ''), 'vol');
  v_ac     uuid[] := coalesce(p_aircraft, '{}');
  v_ins_ac uuid := p_instructor_aircraft;
  v_max    int := p_max_participants;
begin
  v_staff := public.can_organize();
  if not public.is_approved() then
    raise exception 'Votre compte n''est pas encore validé.';
  end if;
  if p_title is null or length(btrim(p_title)) = 0 then raise exception 'Le titre est obligatoire.'; end if;
  if p_departure_at is null then raise exception 'La date de départ est obligatoire.'; end if;
  if p_return_at is not null and p_return_at < p_departure_at then
    raise exception 'Le retour doit être après le départ.';
  end if;
  if p_deadline is not null and p_deadline > p_departure_at then
    raise exception 'La date limite d''inscription doit précéder le départ.';
  end if;
  if v_kind not in ('vol', 'activite', 'evenement') then raise exception 'Type d''événement inconnu.'; end if;
  if v_kind <> 'vol' then
    v_ac := '{}'; v_ins_ac := null;
    if v_max is not null and v_max < 1 then raise exception 'Le nombre de places doit être d''au moins 1.'; end if;
  else
    v_max := null;
  end if;
  if v_kind = 'vol' and coalesce(array_length(v_ac, 1), 0) = 0 then
    raise exception 'Sélectionnez au moins un avion.';
  end if;
  if (select count(distinct x) from unnest(v_ac) x) <> coalesce(array_length(v_ac, 1), 0) then
    raise exception 'Un avion est sélectionné deux fois.';
  end if;
  if (select count(*) from public.aircraft where id = any (v_ac)) <> coalesce(array_length(v_ac, 1), 0) then
    raise exception 'Avion inconnu.';
  end if;
  if v_ins_ac is not null and not (v_ins_ac = any (v_ac)) then
    raise exception 'L''avion de l''instructeur doit faire partie des avions de la sortie.';
  end if;

  if p_id is null then
    insert into public.outings (title, destination, description, meeting_point, departure_at,
                                return_at, registration_deadline, instructor_id, instructor_aircraft_id,
                                approval, approved_by, approved_at, kind, max_participants)
    values (btrim(p_title), nullif(btrim(p_destination), ''), nullif(btrim(p_description), ''),
            nullif(btrim(p_meeting_point), ''), p_departure_at, p_return_at, p_deadline,
            v_uid, v_ins_ac,
            case when v_staff then 'approved' else 'pending' end,
            case when v_staff then v_uid end, case when v_staff then now() end, v_kind, v_max)
    returning * into v_outing;
    -- Proposition d'un membre : on prévient les instructeurs et administrateurs
    if not v_staff then
      select coalesce(jsonb_agg(jsonb_build_object('email', email, 'full_name', full_name)), '[]'::jsonb)
        into v_notify from public.profiles where role in ('instructor', 'admin');
    end if;
  else
    select * into v_outing from public.outings where id = p_id for update;
    if not found then raise exception 'Sortie introuvable.'; end if;
    if v_outing.status = 'cancelled' then raise exception 'Sortie annulée : modification impossible.'; end if;
    if not v_staff and not (v_outing.instructor_id = v_uid and v_outing.approval <> 'approved') then
      raise exception 'Seul un organisateur (instructeur, administrateur, membre du CA…) peut modifier un événement publié.';
    end if;

    update public.outings set
      title = btrim(p_title),
      destination = nullif(btrim(p_destination), ''),
      description = nullif(btrim(p_description), ''),
      meeting_point = nullif(btrim(p_meeting_point), ''),
      departure_at = p_departure_at,
      return_at = p_return_at,
      registration_deadline = p_deadline,
      instructor_aircraft_id = v_ins_ac,
      kind = v_kind,
      max_participants = v_max,
      -- une proposition refusée puis corrigée repart en validation
      approval = case when approval = 'rejected' then 'pending' else approval end,
      updated_at = now()
    where id = p_id
    returning * into v_outing;

    delete from public.outing_aircraft
     where outing_id = p_id and not (aircraft_id = any (v_ac));
  end if;

  -- L'instructeur qui vole n'est pas aussi un "passager" inscrit
  if v_ins_ac is not null then
    update public.registrations
       set status = 'cancelled', aircraft_id = null, cancelled_at = now()
     where outing_id = v_outing.id and user_id = v_outing.instructor_id and status <> 'cancelled';
  end if;

  for v_i in 1 .. coalesce(array_length(v_ac, 1), 0) loop
    insert into public.outing_aircraft (outing_id, aircraft_id, position)
    values (v_outing.id, v_ac[v_i], v_i)
    on conflict (outing_id, aircraft_id) do update set position = excluded.position;
  end loop;

  return jsonb_build_object('outing_id', v_outing.id,
                            'approval', (select approval from public.outings where id = v_outing.id),
                            'notify_staff', v_notify,
                            'changes', public._rebalance_outing(v_outing.id));
end;
$$;

create or replace function public.register_for_outing(p_outing uuid, p_user uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_target  uuid;
  v_outing  public.outings;
  v_reg     public.registrations;
  v_changes jsonb;
  v_pos     int;
begin
  if v_uid is null then raise exception 'Vous devez être connecté.'; end if;
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;

  v_target := coalesce(p_user, v_uid);
  if v_target <> v_uid and not public.can_organize() then
    raise exception 'Seul un organisateur peut inscrire un autre membre.';
  end if;

  select * into v_outing from public.outings where id = p_outing for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  if v_outing.status = 'cancelled' then raise exception 'Cette sortie est annulée.'; end if;
  if v_outing.approval <> 'approved' then raise exception 'Cette sortie n''a pas encore été validée par un instructeur.'; end if;
  if v_outing.departure_at <= now() then raise exception 'Cette sortie a déjà eu lieu.'; end if;
  if v_outing.registration_deadline is not null and now() > v_outing.registration_deadline
     and not public.can_organize() then
    raise exception 'Les inscriptions sont closes pour cette sortie.';
  end if;
  if not exists (select 1 from public.profiles where id = v_target and role <> 'pending') then
    raise exception 'Ce membre n''existe pas ou n''est pas encore validé.';
  end if;
  if v_target = v_outing.instructor_id and v_outing.instructor_aircraft_id is not null then
    raise exception 'L''instructeur de la sortie occupe déjà un siège.';
  end if;
  if exists (select 1 from public.registrations
             where outing_id = p_outing and user_id = v_target and status <> 'cancelled') then
    raise exception 'Déjà inscrit à cette sortie.';
  end if;

  insert into public.registrations (outing_id, user_id, status, created_by)
  values (p_outing, v_target, 'waitlist', v_uid)
  returning * into v_reg;

  v_changes := public._rebalance_outing(p_outing);

  select * into v_reg from public.registrations where id = v_reg.id;
  if v_reg.status = 'waitlist' then
    select count(*) into v_pos from public.registrations
     where outing_id = p_outing and status = 'waitlist'
       and (created_at, id) <= (v_reg.created_at, v_reg.id);
  end if;

  return jsonb_build_object(
    'registration_id', v_reg.id,
    'status', v_reg.status,
    'waitlist_position', v_pos,
    'changes', coalesce((select jsonb_agg(c) from jsonb_array_elements(v_changes) c
                         where (c ->> 'user_id')::uuid <> v_target), '[]'::jsonb)
  );
end;
$$;

create or replace function public.list_outings(p_past boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;

  return coalesce((
    select jsonb_agg(row_to_json(t) order by
             case when p_past then null else t.departure_at end asc,
             case when p_past then t.departure_at end desc)
    from (
      select o.id, o.title, o.destination, o.departure_at, o.return_at,
             o.registration_deadline, o.status,
             ip.full_name as instructor_name,
             (o.instructor_aircraft_id is not null) as instructor_flies,
             case when coalesce(o.kind, 'vol') = 'vol' then
             (select coalesce(sum(greatest(a.seats - case when a.id = o.instructor_aircraft_id then 1 else 0 end, 0)), 0)
                from public.outing_aircraft oa join public.aircraft a on a.id = oa.aircraft_id
               where oa.outing_id = o.id)
             else o.max_participants end as total_capacity,
             coalesce(o.kind, 'vol') as kind, o.max_participants, o.meeting_point,
             (select count(*) from public.registrations r
               where r.outing_id = o.id and r.status = 'confirmed') as confirmed_count,
             (select count(*) from public.registrations r
               where r.outing_id = o.id and r.status = 'waitlist') as waitlist_count,
             (select string_agg(a.registration || ' (' || a.seats || 'pl.)', ', ' order by oa.position)
                from public.outing_aircraft oa join public.aircraft a on a.id = oa.aircraft_id
               where oa.outing_id = o.id) as aircraft_summary,
             (select r.status from public.registrations r
               where r.outing_id = o.id and r.user_id = v_uid and r.status <> 'cancelled') as my_status,
             (o.instructor_id = v_uid) as i_am_instructor,
             o.approval, o.rejection_reason
      from public.outings o
      join public.profiles ip on ip.id = o.instructor_id
      where (o.approval = 'approved' or o.instructor_id = v_uid or public.can_organize())
        and case when p_past
                 then coalesce(o.return_at, o.departure_at) < now()
                 else coalesce(o.return_at, o.departure_at) >= now() end
      limit 200
    ) t), '[]'::jsonb);
end;
$$;

create or replace function public.get_outing(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_staff  boolean := public.can_organize();
  v_outing public.outings;
  v_result jsonb;
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  select * into v_outing from public.outings where id = p_id;
  if not found then return null; end if;
  if v_outing.approval <> 'approved' and v_outing.instructor_id <> v_uid and not v_staff then
    return null;
  end if;

  select jsonb_build_object(
    'id', o.id, 'title', o.title, 'destination', o.destination, 'description', o.description,
    'meeting_point', o.meeting_point, 'departure_at', o.departure_at, 'return_at', o.return_at,
    'registration_deadline', o.registration_deadline, 'status', o.status,
    'instructor_aircraft_id', o.instructor_aircraft_id,
    'instructor', jsonb_build_object('id', ip.id, 'full_name', ip.full_name,
                                     'phone', ip.phone, 'avatar_url', ip.avatar_url),
    'can_manage', v_staff,
    'kind', coalesce(o.kind, 'vol'),
    'max_participants', o.max_participants,
    'participants', coalesce((
      select jsonb_agg(jsonb_build_object(
               'registration_id', r.id, 'user_id', p.id, 'full_name', p.full_name,
               'avatar_url', p.avatar_url,
               'phone', case when v_staff or p.id = v_uid then p.phone end)
             order by r.created_at, r.id)
      from public.registrations r join public.profiles p on p.id = r.user_id
      where r.outing_id = o.id and r.status = 'confirmed' and r.aircraft_id is null
        and coalesce(o.kind, 'vol') <> 'vol'), '[]'::jsonb),
    'is_organizer', o.instructor_id = v_uid,
    'organizer_weight_kg', case when o.instructor_id = v_uid then
                             (select pw.weight_kg from public.pilot_weights pw where pw.user_id = o.instructor_id) end,
    'approval', o.approval, 'rejection_reason', o.rejection_reason,
    'can_edit', v_staff or (o.instructor_id = v_uid and o.approval <> 'approved'),
    'aircraft', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', a.id, 'registration', a.registration, 'model', a.model, 'type', a.type, 'seats', a.seats,
               'instructor_onboard', a.id = o.instructor_aircraft_id,
               'capacity', greatest(a.seats - case when a.id = o.instructor_aircraft_id then 1 else 0 end, 0),
               'occupants', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'registration_id', r.id, 'user_id', p.id, 'full_name', p.full_name,
                          'avatar_url', p.avatar_url,
                          'released', exists (select 1 from public.pilot_types pt
                                              where pt.user_id = p.id and pt.aircraft_type = a.type),
                          'phone', case when v_staff or p.id = v_uid then p.phone end,
                          'weight_kg', case when o.instructor_id = v_uid then
                                         (select pw.weight_kg from public.pilot_weights pw where pw.user_id = p.id) end)
                        order by r.created_at, r.id)
                 from public.registrations r join public.profiles p on p.id = r.user_id
                 where r.outing_id = o.id and r.status = 'confirmed' and r.aircraft_id = a.id), '[]'::jsonb)
             ) order by oa.position, a.registration)
      from public.outing_aircraft oa join public.aircraft a on a.id = oa.aircraft_id
      where oa.outing_id = o.id), '[]'::jsonb),
    'waitlist', coalesce((
      select jsonb_agg(jsonb_build_object(
               'registration_id', w.id, 'user_id', w.user_id, 'full_name', w.full_name,
               'avatar_url', w.avatar_url, 'released', false,
               'phone', case when v_staff or w.user_id = v_uid then w.phone end,
               'weight_kg', case when o.instructor_id = v_uid then
                              (select pw.weight_kg from public.pilot_weights pw where pw.user_id = w.user_id) end,
               'position', w.pos) order by w.pos)
      from (select r.id, r.user_id, p.full_name, p.phone, p.avatar_url,
                   row_number() over (order by r.created_at, r.id) as pos
            from public.registrations r join public.profiles p on p.id = r.user_id
            where r.outing_id = o.id and r.status = 'waitlist') w), '[]'::jsonb),
    'my_registration', (
      select jsonb_build_object('id', r.id, 'status', r.status, 'aircraft_id', r.aircraft_id)
      from public.registrations r
      where r.outing_id = o.id and r.user_id = v_uid and r.status <> 'cancelled')
  ) into v_result
  from public.outings o join public.profiles ip on ip.id = o.instructor_id
  where o.id = p_id;

  return v_result;
end;
$$;

create or replace function public.cancel_outing(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_outing public.outings;
begin
  select * into v_outing from public.outings where id = p_id for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  -- un membre peut retirer sa propre proposition non publiée
  if not public.can_organize() and not (v_outing.instructor_id = auth.uid() and v_outing.approval <> 'approved') then
    raise exception 'Action réservée aux organisateurs.';
  end if;
  if v_outing.status = 'cancelled' then raise exception 'Sortie déjà annulée.'; end if;

  update public.outings set status = 'cancelled', updated_at = now() where id = p_id;

  return jsonb_build_object('recipients', coalesce((
    select jsonb_agg(jsonb_build_object('user_id', p.id, 'email', p.email, 'full_name', p.full_name))
    from public.registrations r join public.profiles p on p.id = r.user_id
    where r.outing_id = p_id and r.status <> 'cancelled'), '[]'::jsonb));
end;
$$;

create or replace function public.review_outing(p_id uuid, p_approve boolean, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_outing public.outings;
begin
  if not public.can_organize() then raise exception 'Action réservée aux organisateurs.'; end if;
  select * into v_outing from public.outings where id = p_id for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  if v_outing.approval = 'approved' then raise exception 'Cette sortie est déjà publiée.'; end if;

  update public.outings set
    approval = case when p_approve then 'approved' else 'rejected' end,
    rejection_reason = case when p_approve then null else nullif(btrim(p_reason), '') end,
    approved_by = case when p_approve then auth.uid() end,
    approved_at = case when p_approve then now() end,
    updated_at = now()
  where id = p_id;

  return (select jsonb_build_object('email', p.email, 'full_name', p.full_name, 'title', v_outing.title,
                                    'departure_at', v_outing.departure_at)
          from public.profiles p where p.id = v_outing.instructor_id);
end;
$$;

revoke execute on function public.save_outing(uuid, text, text, text, text, timestamptz, timestamptz, timestamptz, uuid[], uuid, text, int) from public, anon;
grant execute on function public.save_outing(uuid, text, text, text, text, timestamptz, timestamptz, timestamptz, uuid[], uuid, text, int) to authenticated;
revoke execute on function public._rebalance_outing(uuid) from public, anon, authenticated;

notify pgrst, 'reload schema';


-- ===================== Mise à jour n°12 : bar en sections =====================
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

-- =====================================================================
--  Mise à jour n°13 : tout le monde est « Membre » ; Instructeur et
--  Administrateur deviennent des fonctions, comme Trésorier, Secrétaire,
--  Membre du CA et Responsable maintenance.
--  (La colonne role reste le niveau de droits calculé automatiquement.)
-- =====================================================================
alter table public.profiles add column if not exists is_instructor boolean not null default false;
update public.profiles set is_instructor = true where role = 'instructor' and not is_instructor;

create or replace function public.set_function(p_user uuid, p_function text, p_value boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v public.profiles%rowtype;
  v_admin boolean;
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  select * into v from public.profiles where id = p_user for update;
  if not found then raise exception 'Membre introuvable.'; end if;
  if v.role = 'pending' then
    raise exception 'Validez d''abord ce compte avant de lui attribuer une fonction.';
  end if;

  v_admin := v.role = 'admin';
  case p_function
    when 'admin' then
      if not p_value and p_user = auth.uid() then
        raise exception 'Vous ne pouvez pas retirer vos propres droits administrateur.';
      end if;
      v_admin := p_value;
      if not p_value then v.is_secretary := false; end if;
    when 'secretaire' then
      if not p_value and p_user = auth.uid() then
        raise exception 'Demandez à un autre administrateur de vous retirer le titre de secrétaire.';
      end if;
      v.is_secretary := p_value;
      if p_value then v_admin := true; end if;
    when 'instructeur' then v.is_instructor := p_value;
    when 'ca'          then v.is_board := p_value;
    when 'tresorier'   then v.is_treasurer := p_value;
    when 'maintenance' then v.is_maintenance := p_value;
    else raise exception 'Fonction inconnue : %', p_function;
  end case;

  update public.profiles set
    is_instructor  = v.is_instructor,
    is_board       = v.is_board,
    is_treasurer   = v.is_treasurer,
    is_maintenance = v.is_maintenance,
    is_secretary   = v.is_secretary,
    role = case when v_admin then 'admin'::public.user_role
                when v.is_instructor then 'instructor'::public.user_role
                else 'member'::public.user_role end
  where id = p_user;
end;
$$;
revoke execute on function public.set_function(uuid, text, boolean) from public, anon;
grant execute on function public.set_function(uuid, text, boolean) to authenticated;

-- Annuaire : le badge « Instructeur » suit la fonction
create or replace function public.member_directory()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id, 'full_name', p.full_name, 'phone', p.phone, 'avatar_url', p.avatar_url,
             'role', p.role, 'is_instructor', p.is_instructor,
             'types', coalesce((select jsonb_agg(pt.aircraft_type order by pt.aircraft_type)
                                from public.pilot_types pt where pt.user_id = p.id), '[]'::jsonb))
           order by lower(p.full_name))
    from public.profiles p
    where p.role <> 'pending'), '[]'::jsonb);
end;
$$;
revoke execute on function public.member_directory() from public, anon;
grant execute on function public.member_directory() to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
--  Mise à jour n°14 : email à tous les membres quand un événement est
--  publié (chacun peut se désabonner dans « Mon compte »).
-- =====================================================================
alter table public.profiles add column if not exists notify_events boolean not null default true;

-- Destinataires : membres validés, abonnés, sauf la personne qui publie.
-- Réservé aux organisateurs, et seulement pour un événement publié.
create or replace function public.event_mail_recipients(p_outing uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.can_organize() then
    raise exception 'Action réservée aux organisateurs.';
  end if;
  if not exists (select 1 from public.outings where id = p_outing and approval = 'approved' and status = 'open') then
    return '[]'::jsonb;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('email', p.email, 'full_name', p.full_name))
    from public.profiles p
    where p.role <> 'pending' and p.notify_events and coalesce(p.email, '') <> ''
      and p.id is distinct from auth.uid()), '[]'::jsonb);
end;
$$;
revoke execute on function public.event_mail_recipients(uuid) from public, anon;
grant execute on function public.event_mail_recipients(uuid) to authenticated;

create or replace function public.set_event_notifications(p_value boolean)
returns void
language sql security definer set search_path = ''
as $$
  update public.profiles set notify_events = p_value where id = auth.uid();
$$;
revoke execute on function public.set_event_notifications(boolean) from public, anon;
grant execute on function public.set_event_notifications(boolean) to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
--  Mise à jour n°15 : documents des avions (onglet Flotte) ajoutés ou
--  modifiés par les administrateurs, membres du CA, instructeurs et
--  responsables maintenance. Lecture : tous les membres validés.
-- =====================================================================
create or replace function public.can_manage_docs()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((
    select p.role <> 'pending'
       and (p.role in ('admin', 'instructor') or p.is_instructor or p.is_board or p.is_maintenance)
    from public.profiles p where p.id = auth.uid()), false);
$$;
revoke execute on function public.can_manage_docs() from public, anon;
grant execute on function public.can_manage_docs() to authenticated;

drop policy if exists aircraft_documents_insert on public.aircraft_documents;
create policy aircraft_documents_insert on public.aircraft_documents for insert to authenticated
  with check (public.can_manage_docs());
drop policy if exists aircraft_documents_update on public.aircraft_documents;
create policy aircraft_documents_update on public.aircraft_documents for update to authenticated
  using (public.can_manage_docs()) with check (public.can_manage_docs());
drop policy if exists aircraft_documents_delete on public.aircraft_documents;
create policy aircraft_documents_delete on public.aircraft_documents for delete to authenticated
  using (public.can_manage_docs());

do $$
begin
  execute 'drop policy if exists aircraft_docs_insert on storage.objects';
  execute 'create policy aircraft_docs_insert on storage.objects for insert to authenticated with check (bucket_id = ''aircraft-docs'' and public.can_manage_docs())';
  execute 'drop policy if exists aircraft_docs_update on storage.objects';
  execute 'create policy aircraft_docs_update on storage.objects for update to authenticated using (bucket_id = ''aircraft-docs'' and public.can_manage_docs())';
  execute 'drop policy if exists aircraft_docs_delete on storage.objects';
  execute 'create policy aircraft_docs_delete on storage.objects for delete to authenticated using (bucket_id = ''aircraft-docs'' and public.can_manage_docs())';
exception when others then
  raise notice 'Stockage : droits non modifiés (%)', sqlerrm;
end $$;

notify pgrst, 'reload schema';

-- =====================================================================
--  Mise à jour n°16 : sécurité et RGPD
--   1. Verrouillage : plus aucune suppression définitive de données du club
--      (avions, carte du bar, documents archivés au lieu d'être effacés).
--   2. Journal des modifications inaltérable (lecture : administrateurs).
--   3. RGPD : masquer son téléphone, demande de suppression de compte,
--      anonymisation par un administrateur, informations légales du club.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Défense en profondeur
-- ---------------------------------------------------------------------
-- Les visiteurs non connectés n'exécutent aucune fonction du club
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig, has_function_privilege('authenticated', p.oid, 'execute') as auth_ok
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
      and p.proname not in ('get_club_info')
  loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    -- les membres connectés gardent exactement les mêmes droits qu'avant
    if f.auth_ok then execute format('grant execute on function %s to authenticated', f.sig); end if;
  end loop;
end $$;
-- Les helpers de droits restent utilisables par les membres connectés (RLS)
grant execute on function public.app_role() to authenticated;
grant execute on function public.is_approved() to authenticated;
grant execute on function public.is_staff() to authenticated;
grant execute on function public.is_treasurer() to authenticated;
grant execute on function public.can_manage_fleet() to authenticated;
grant execute on function public.can_organize() to authenticated;
grant execute on function public.can_manage_docs() to authenticated;
grant execute on function public.bar_month_of(timestamptz) to authenticated;

-- TRUNCATE (vidage de table) interdit à tous les comptes applicatifs
do $$
declare t record;
begin
  for t in select c.oid::regclass as tbl from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind = 'r'
  loop
    execute format('revoke truncate on %s from public, anon, authenticated', t.tbl);
  end loop;
end $$;

-- Avions : on ne supprime plus, on désactive (historique des sorties préservé)
drop policy if exists aircraft_delete on public.aircraft;

-- Carte du bar : le trésorier ajoute et modifie, mais ne supprime pas (il retire de la vente)
drop policy if exists bar_products_write on public.bar_products;
drop policy if exists bar_products_insert on public.bar_products;
create policy bar_products_insert on public.bar_products for insert to authenticated
  with check (public.is_treasurer());
drop policy if exists bar_products_update on public.bar_products;
create policy bar_products_update on public.bar_products for update to authenticated
  using (public.is_treasurer()) with check (public.is_treasurer());

-- ---------------------------------------------------------------------
-- 2. Documents des avions : archivage au lieu de suppression
-- ---------------------------------------------------------------------
alter table public.aircraft_documents add column if not exists archived_at timestamptz;
alter table public.aircraft_documents add column if not exists archived_by uuid references public.profiles (id) on delete set null;

drop policy if exists aircraft_documents_select on public.aircraft_documents;
create policy aircraft_documents_select on public.aircraft_documents for select to authenticated
  using (public.is_approved() and (archived_at is null or public.can_manage_docs()));
drop policy if exists aircraft_documents_delete on public.aircraft_documents;

create or replace function public.archive_document(p_id uuid, p_archive boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.can_manage_docs() then
    raise exception 'Action réservée aux administrateurs, instructeurs, membres du CA et responsables maintenance.';
  end if;
  update public.aircraft_documents
     set archived_at = case when p_archive then now() else null end,
         archived_by = case when p_archive then auth.uid() else null end
   where id = p_id;
  if not found then raise exception 'Document introuvable.'; end if;
end;
$$;
revoke execute on function public.archive_document(uuid, boolean) from public, anon;
grant execute on function public.archive_document(uuid, boolean) to authenticated;

-- Fichiers : seuls les administrateurs peuvent effacer un fichier du stockage
do $$
begin
  execute 'drop policy if exists aircraft_docs_delete on storage.objects';
  execute 'create policy aircraft_docs_delete on storage.objects for delete to authenticated using (bucket_id = ''aircraft-docs'' and public.app_role() = ''admin'')';
  execute 'drop policy if exists aircraft_docs_update on storage.objects';
  execute 'drop policy if exists avatars_delete_admin on storage.objects';
  execute 'create policy avatars_delete_admin on storage.objects for delete to authenticated using (bucket_id = ''avatars'' and public.app_role() = ''admin'')';
exception when others then
  raise notice 'Stockage : droits non modifiés (%)', sqlerrm;
end $$;

-- ---------------------------------------------------------------------
-- 3. Journal des modifications (inaltérable)
-- ---------------------------------------------------------------------
create table if not exists public.audit_log (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  actor       uuid,                       -- auth.uid() de l'auteur (nom affiché via profiles)
  action      text not null,              -- insert / update / delete
  table_name  text not null,
  row_id      text,
  details     jsonb
);
alter table public.audit_log enable row level security;
revoke all on public.audit_log from public, anon, authenticated;
grant select on public.audit_log to authenticated;
drop policy if exists audit_log_select on public.audit_log;
create policy audit_log_select on public.audit_log for select to authenticated
  using (public.app_role() = 'admin');

create or replace function public._audit_immutable()
returns trigger language plpgsql as $$
begin
  raise exception 'Le journal des modifications ne peut être ni modifié ni effacé.';
end;
$$;
drop trigger if exists audit_log_immutable on public.audit_log;
create trigger audit_log_immutable before update or delete on public.audit_log
  for each row execute function public._audit_immutable();
revoke execute on function public._audit_immutable() from public, anon, authenticated;

-- Journalise : pour une modification, seules les colonnes changées (ancienne → nouvelle valeur).
-- Pour les profils, seules les fonctions / droits sont journalisés (pas les données personnelles).
create or replace function public._audit()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_old jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_new jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_details jsonb;
  v_keys text[];
  k text;
begin
  if tg_table_name = 'profiles' then
    v_keys := array['role', 'is_instructor', 'is_board', 'is_treasurer', 'is_secretary', 'is_maintenance', 'anonymized_at'];
  end if;

  if tg_op = 'UPDATE' then
    v_details := '{}'::jsonb;
    for k in select jsonb_object_keys(v_new) loop
      if (v_keys is null or k = any (v_keys)) and (v_old -> k) is distinct from (v_new -> k) then
        v_details := v_details || jsonb_build_object(k, jsonb_build_object('avant', v_old -> k, 'apres', v_new -> k));
      end if;
    end loop;
    if v_details = '{}'::jsonb then return new; end if;
  elsif tg_op = 'DELETE' then
    v_details := case when v_keys is null then v_old else '{}'::jsonb end;
  else
    v_details := case when v_keys is null then v_new else '{}'::jsonb end;
  end if;

  insert into public.audit_log (actor, action, table_name, row_id, details)
  values (auth.uid(), lower(tg_op), tg_table_name,
          coalesce(v_new ->> 'id', v_old ->> 'id', v_new ->> 'user_id', v_old ->> 'user_id'), v_details);
  return coalesce(new, old);
end;
$$;
revoke execute on function public._audit() from public, anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['aircraft', 'aircraft_documents', 'announcements', 'bar_products',
                           'bar_consumptions', 'bar_settlements', 'outings', 'profiles']
  loop
    execute format('drop trigger if exists zz_audit on public.%I', t);
    if t = 'bar_consumptions' then
      -- consommations : on journalise les annulations (les ajouts sont déjà la donnée elle-même)
      execute format('create trigger zz_audit after delete on public.%I for each row execute function public._audit()', t);
    elsif t = 'profiles' then
      execute format('create trigger zz_audit after update on public.%I for each row execute function public._audit()', t);
    else
      execute format('create trigger zz_audit after insert or update or delete on public.%I for each row execute function public._audit()', t);
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 4. RGPD côté membre
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists show_phone boolean not null default true;
alter table public.profiles add column if not exists deletion_requested_at timestamptz;
alter table public.profiles add column if not exists anonymized_at timestamptz;

create or replace function public.set_phone_visibility(p_value boolean)
returns void language sql security definer set search_path = '' as $$
  update public.profiles set show_phone = p_value where id = auth.uid();
$$;
revoke execute on function public.set_phone_visibility(boolean) from public, anon;
grant execute on function public.set_phone_visibility(boolean) to authenticated;

create or replace function public.request_account_deletion(p_value boolean)
returns void language sql security definer set search_path = '' as $$
  update public.profiles set deletion_requested_at = case when p_value then now() else null end where id = auth.uid();
$$;
revoke execute on function public.request_account_deletion(boolean) from public, anon;
grant execute on function public.request_account_deletion(boolean) to authenticated;

-- Anonymisation (droit à l'effacement) : par un administrateur, jamais sur son propre compte.
-- Les données personnelles sont effacées ; l'historique comptable du bar et des sorties est
-- conservé sous le nom « Ancien membre ». Le compte ne peut plus se connecter au site.
create or replace function public.anonymize_member(p_user uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare r record;
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  if p_user = auth.uid() then
    raise exception 'Vous ne pouvez pas anonymiser votre propre compte.';
  end if;
  if not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'Membre introuvable.';
  end if;

  -- Désinscription des événements à venir (les places libérées sont réattribuées)
  for r in
    select distinct g.outing_id from public.registrations g join public.outings o on o.id = g.outing_id
    where g.user_id = p_user and g.status <> 'cancelled' and o.departure_at > now()
  loop
    update public.registrations set status = 'cancelled'
     where outing_id = r.outing_id and user_id = p_user and status <> 'cancelled';
    perform public._rebalance_outing(r.outing_id);
  end loop;

  delete from public.pilot_weights where user_id = p_user;
  delete from public.pilot_types where user_id = p_user;

  update public.profiles set
    full_name = 'Ancien membre',
    email = 'anonyme-' || left(p_user::text, 8) || '@invalid.local',
    phone = null, address = null, emergency_name = null, emergency_phone = null,
    avatar_url = null,
    role = 'pending',
    is_instructor = false, is_board = false, is_treasurer = false, is_secretary = false, is_maintenance = false,
    notify_events = false, show_phone = false,
    anonymized_at = now()
  where id = p_user;
end;
$$;
revoke execute on function public.anonymize_member(uuid) from public, anon;
grant execute on function public.anonymize_member(uuid) to authenticated;

-- Annuaire : respecte « masquer mon téléphone », exclut les comptes anonymisés
create or replace function public.member_directory()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id, 'full_name', p.full_name,
             'phone', case when p.show_phone or p.id = auth.uid() then p.phone end,
             'avatar_url', p.avatar_url,
             'role', p.role, 'is_instructor', p.is_instructor,
             'types', coalesce((select jsonb_agg(pt.aircraft_type order by pt.aircraft_type)
                                from public.pilot_types pt where pt.user_id = p.id), '[]'::jsonb))
           order by lower(p.full_name))
    from public.profiles p
    where p.role <> 'pending' and p.anonymized_at is null), '[]'::jsonb);
end;
$$;
revoke execute on function public.member_directory() from public, anon;
grant execute on function public.member_directory() to authenticated;

-- ---------------------------------------------------------------------
-- 5. Informations légales du club (mentions légales), modifiables par les admins
-- ---------------------------------------------------------------------
create table if not exists public.club_info (
  id                    int primary key default 1 check (id = 1),
  association_name      text not null default 'Aéroclub Air France Provence',
  legal_form            text default 'Association régie par la loi du 1er juillet 1901',
  address               text,
  registration_number   text,       -- n° RNA et/ou SIRET
  publication_director  text,       -- directeur de la publication (président)
  contact_email         text,
  contact_phone         text,
  updated_at            timestamptz not null default now()
);
insert into public.club_info (id) values (1) on conflict (id) do nothing;
alter table public.club_info enable row level security;
revoke all on public.club_info from public, anon, authenticated;

-- Lecture publique (page « Mentions légales » accessible sans connexion)
create or replace function public.get_club_info()
returns jsonb language sql stable security definer set search_path = '' as $$
  select to_jsonb(c) - 'id' from public.club_info c where c.id = 1;
$$;
revoke execute on function public.get_club_info() from public;
grant execute on function public.get_club_info() to anon, authenticated;

create or replace function public.set_club_info(p_info jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  update public.club_info set
    association_name     = coalesce(nullif(btrim(p_info ->> 'association_name'), ''), association_name),
    legal_form           = nullif(btrim(p_info ->> 'legal_form'), ''),
    address              = nullif(btrim(p_info ->> 'address'), ''),
    registration_number  = nullif(btrim(p_info ->> 'registration_number'), ''),
    publication_director = nullif(btrim(p_info ->> 'publication_director'), ''),
    contact_email        = nullif(btrim(p_info ->> 'contact_email'), ''),
    contact_phone        = nullif(btrim(p_info ->> 'contact_phone'), ''),
    updated_at           = now()
  where id = 1;
end;
$$;
revoke execute on function public.set_club_info(jsonb) from public, anon;
grant execute on function public.set_club_info(jsonb) to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
--  Mise à jour n°17 : annonces publiées par toute personne ayant une
--  fonction (admin, instructeur, CA, trésorier, secrétaire, resp.
--  maintenance). Les simples membres les lisent seulement.
-- =====================================================================
drop policy if exists announcements_insert on public.announcements;
create policy announcements_insert on public.announcements for insert to authenticated
  with check (public.can_organize());
drop policy if exists announcements_delete on public.announcements;
create policy announcements_delete on public.announcements for delete to authenticated
  using (public.can_organize());

notify pgrst, 'reload schema';

-- =====================================================================
--  Mise à jour n°18 : documents des avions ajoutés / modifiés par toute
--  personne ayant une fonction (admin, instructeur, CA, trésorier,
--  secrétaire, resp. maintenance). Les simples membres les consultent.
-- =====================================================================
create or replace function public.can_manage_docs()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((
    select p.role <> 'pending'
       and (p.role in ('admin', 'instructor') or p.is_instructor or p.is_board or p.is_maintenance
            or p.is_treasurer or p.is_secretary)
    from public.profiles p where p.id = auth.uid()), false);
$$;
revoke execute on function public.can_manage_docs() from public, anon;
grant execute on function public.can_manage_docs() to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
--  Mise à jour n°19 : accueil façon « Inside AFPA »
--   1. Indisponibilité d'un avion avec période (du … au …)
--   2. Flotte complète du club (ajout des avions manquants)
--   3. Chiffres de l'accueil (membres actifs) et « Équipage de l'année »
--   4. Liens utiles (outils de vol, réseaux) modifiables par les admins
-- =====================================================================

-- 1. Période d'indisponibilité ----------------------------------------
alter table public.aircraft add column if not exists unavailable_from date;
alter table public.aircraft add column if not exists unavailable_until date;
grant update (unavailable_from, unavailable_until) on public.aircraft to authenticated;

drop function if exists public.set_aircraft_availability(uuid, boolean, text);
create or replace function public.set_aircraft_availability(
  p_id uuid, p_available boolean, p_reason text default null,
  p_from date default null, p_until date default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.can_manage_fleet() then
    raise exception 'Réservé aux administrateurs et aux responsables maintenance.';
  end if;
  if not p_available and p_from is not null and p_until is not null and p_until < p_from then
    raise exception 'La date de fin doit être après la date de début.';
  end if;
  update public.aircraft
     set available = p_available,
         unavailable_reason = case when p_available then null else nullif(btrim(coalesce(p_reason, '')), '') end,
         unavailable_from   = case when p_available then null else p_from end,
         unavailable_until  = case when p_available then null else p_until end
   where id = p_id;
  if not found then raise exception 'Avion introuvable.'; end if;
end;
$$;
revoke execute on function public.set_aircraft_availability(uuid, boolean, text, date, date) from public, anon;
grant execute on function public.set_aircraft_availability(uuid, boolean, text, date, date) to authenticated;

-- 2. Flotte du club (n'ajoute que les avions absents, ne modifie rien d'existant)
insert into public.aircraft (registration, model, type, seats)
select v.reg, v.model, v.type, v.seats
from (values
  ('F-HSAA', 'PS28 Cruiser',  'PS28',  2),
  ('F-HNLR', 'PS28 Cruiser',  'PS28',  2),
  ('F-HUIT', 'PS28 Cruiser',  'PS28',  2),
  ('F-HSAC', 'PS28 Cruiser',  'PS28',  2),
  ('F-HPSA', 'PS28 Cruiser',  'PS28',  2),
  ('F-HSAG', 'PS28 Cruiser',  'PS28',  2),
  ('F-HVXD', 'Dynamic WT9',   'WT9',   2),
  ('F-HUFA', 'Bristell B23',  'B23',   2),
  ('F-HCLI', 'Robin DR400',   'DR400', 4),
  ('F-HXAF', 'Diamond DA40',  'DA40',  4)
) v(reg, model, type, seats)
where not exists (select 1 from public.aircraft a where upper(a.registration) = v.reg);

-- 3. Chiffres de l'accueil ---------------------------------------------
alter table public.profiles add column if not exists show_in_bar_ranking boolean not null default true;

create or replace function public.club_stats()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  return jsonb_build_object(
    'active_members', (select count(*) from public.profiles
                        where role <> 'pending' and anonymized_at is null));
end;
$$;
revoke execute on function public.club_stats() from public, anon;
grant execute on function public.club_stats() to authenticated;

-- « Équipage de l'année » : les 3 plus fidèles clients du bar sur l'année civile
-- (prénom + initiale, nombre de consommations ; jamais les montants).
-- Chacun peut s'en retirer dans « Mon compte ».
create or replace function public.bar_ranking(p_year int default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_year int := coalesce(p_year, extract(year from (now() at time zone 'Europe/Paris'))::int);
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  return coalesce((
    select jsonb_agg(x order by x.rank)
    from (
      select row_number() over (order by sum(c.quantity) desc, min(c.created_at)) as rank,
             split_part(btrim(p.full_name), ' ', 1)
               || case when position(' ' in btrim(p.full_name)) > 0
                       then ' ' || upper(left(split_part(btrim(p.full_name), ' ', 2), 1)) || '.' else '' end as name,
             p.avatar_url,
             sum(c.quantity)::int as consos
      from public.bar_consumptions c
      join public.profiles p on p.id = c.user_id
      where extract(year from (c.created_at at time zone 'Europe/Paris')) = v_year
        and p.role <> 'pending' and p.anonymized_at is null and p.show_in_bar_ranking
      group by p.id, p.full_name, p.avatar_url
      order by sum(c.quantity) desc, min(c.created_at)
      limit 3
    ) x), '[]'::jsonb);
end;
$$;
revoke execute on function public.bar_ranking(int) from public, anon;
grant execute on function public.bar_ranking(int) to authenticated;

create or replace function public.set_bar_ranking_visibility(p_value boolean)
returns void language sql security definer set search_path = '' as $$
  update public.profiles set show_in_bar_ranking = p_value where id = auth.uid();
$$;
revoke execute on function public.set_bar_ranking_visibility(boolean) from public, anon;
grant execute on function public.set_bar_ranking_visibility(boolean) to authenticated;

-- 4. Liens utiles --------------------------------------------------------
create table if not exists public.club_links (
  id        uuid primary key default gen_random_uuid(),
  section   text not null check (section in ('outils', 'liens')),
  title     text not null check (length(btrim(title)) between 1 and 60),
  subtitle  text check (subtitle is null or length(subtitle) <= 80),
  url       text not null check (url ~* '^https?://'),
  icon      text check (icon is null or length(icon) <= 8),
  position  int not null default 0,
  created_at timestamptz not null default now()
);
alter table public.club_links enable row level security;
revoke truncate on public.club_links from public, anon, authenticated;
drop policy if exists club_links_select on public.club_links;
create policy club_links_select on public.club_links for select to authenticated using (public.is_approved());
drop policy if exists club_links_insert on public.club_links;
create policy club_links_insert on public.club_links for insert to authenticated with check (public.app_role() = 'admin');
drop policy if exists club_links_update on public.club_links;
create policy club_links_update on public.club_links for update to authenticated
  using (public.app_role() = 'admin') with check (public.app_role() = 'admin');
drop policy if exists club_links_delete on public.club_links;
create policy club_links_delete on public.club_links for delete to authenticated using (public.app_role() = 'admin');

insert into public.club_links (section, title, subtitle, url, icon, position)
select v.section, v.title, v.subtitle, v.url, v.icon, v.pos
from (values
  ('outils', 'Aérogest Online', 'Réservation & planning', 'https://online.aerogest.fr/Connection/logon', '✈️', 1),
  ('outils', 'AéroGligli', 'Formation théorique', 'https://www.aerogligli.fr/', '📖', 2),
  ('outils', 'FlightProgress', 'Progression formation', 'https://www.f-prog.com/', '📈', 3),
  ('outils', 'NOTAM / SOFIA', 'Briefing pré-vol', 'https://sofia-briefing.aviation-civile.gouv.fr/', '📋', 4),
  ('outils', 'Aeroweb', 'Météo aéro Météo-France', 'https://aviation.meteo.fr/', '🌦️', 5),
  ('outils', 'SIA / OLIVIA', 'Cartes VAC, AIP', 'https://www.sia.aviation-civile.gouv.fr/', '🗺️', 6),
  ('liens', 'Site internet', 'af-provenceaviation.fr', 'https://af-provenceaviation.fr', '🌐', 1),
  ('liens', 'Facebook', '@AeroclubAirFranceProvence', 'https://www.facebook.com/AeroclubAirFranceProvence', '📘', 2),
  ('liens', 'Instagram', '@airfranceprovenceaviation', 'https://www.instagram.com/airfranceprovenceaviation', '📷', 3)
) v(section, title, subtitle, url, icon, pos)
where not exists (select 1 from public.club_links l where l.title = v.title);

-- Journal : les liens aussi sont tracés
drop trigger if exists zz_audit on public.club_links;
create trigger zz_audit after insert or update or delete on public.club_links
  for each row execute function public._audit();

notify pgrst, 'reload schema';

-- =====================================================================
--  Mise à jour n°20 : masse et centrage par avion (d'après le manuel de vol
--  et la dernière fiche de pesée). Lecture : tous les membres validés.
--  Modification : administrateurs et responsables maintenance.
-- =====================================================================
create table if not exists public.aircraft_mb (
  aircraft_id     uuid primary key references public.aircraft (id) on delete cascade,
  serial          text,                               -- n° de série
  empty_mass      numeric(7,2) check (empty_mass is null or empty_mass > 0),      -- masse à vide (kg)
  empty_moment    numeric(9,3),                        -- moment à vide (kg.m)
  mtow            numeric(7,2) check (mtow is null or mtow > 0),                  -- masse max décollage (kg)
  mlw             numeric(7,2) check (mlw is null or mlw > 0),                    -- masse max atterrissage (kg), facultatif
  fuel_arm        numeric(6,3),                        -- bras du carburant (m)
  fuel_density    numeric(4,3) not null default 0.72 check (fuel_density between 0.5 and 1),
  fuel_capacity_l numeric(6,1) check (fuel_capacity_l is null or fuel_capacity_l > 0),
  stations        jsonb not null default '[]'::jsonb,  -- [{label, arm, max}]
  envelope        jsonb not null default '[]'::jsonb,  -- [{arm, mass}] polygone du domaine de centrage
  source          text,                                -- ex. « Manuel de vol rév. 3 — pesée du 12/03/2025 »
  updated_at      timestamptz not null default now(),
  updated_by      uuid references public.profiles (id) on delete set null default auth.uid()
);
alter table public.aircraft_mb enable row level security;
revoke truncate on public.aircraft_mb from public, anon, authenticated;

drop policy if exists aircraft_mb_select on public.aircraft_mb;
create policy aircraft_mb_select on public.aircraft_mb for select to authenticated using (public.is_approved());
drop policy if exists aircraft_mb_insert on public.aircraft_mb;
create policy aircraft_mb_insert on public.aircraft_mb for insert to authenticated with check (public.can_manage_fleet());
drop policy if exists aircraft_mb_update on public.aircraft_mb;
create policy aircraft_mb_update on public.aircraft_mb for update to authenticated
  using (public.can_manage_fleet()) with check (public.can_manage_fleet());
-- pas de suppression : on corrige les valeurs

drop trigger if exists zz_audit on public.aircraft_mb;
create trigger zz_audit after insert or update on public.aircraft_mb
  for each row execute function public._audit();

-- Pré-remplissage F-HSAA (valeurs relevées dans l'outil Inside AFPA : masse et moment à vide,
-- postes de chargement, MTOW). Le bras carburant et le domaine de centrage restent à saisir
-- depuis le manuel de vol avant que le calcul soit disponible.
insert into public.aircraft_mb (aircraft_id, serial, empty_mass, empty_moment, mtow, stations, source)
select a.id, 'C0502', 393.5, 169.8, 600,
       '[{"label":"Pilote","arm":0.70,"max":115},{"label":"Passager","arm":0.70,"max":115},{"label":"Bagages coffre AR","arm":1.31,"max":18}]'::jsonb,
       'Repris de l''outil Inside AFPA — à compléter (bras carburant, domaine de centrage)'
from public.aircraft a
where a.registration = 'F-HSAA'
  and not exists (select 1 from public.aircraft_mb m where m.aircraft_id = a.id);

notify pgrst, 'reload schema';

-- =====================================================================
--  Mise à jour n°21
--   1. Nouvelle catégorie de documents « Équipements & avionique »
--   2. Masse et centrage : masse max sans carburant (MZFW) et postes
--      « carburant » (réservoir supplémentaire en litres) / « aile »
--   3. Données de masse et centrage de la flotte, relevées dans les manuels
--      de vol et les fiches de pesée fournis (Inside, export du 25/09/2026)
-- =====================================================================

-- 1. Catégorie « equipements »
alter table public.aircraft_documents drop constraint if exists aircraft_documents_category_check;
alter table public.aircraft_documents add constraint aircraft_documents_category_check
  check (category in ('manuel','checklist','masse_centrage','performances','procedures','administratif','maintenance','equipements','autre'));

-- 2. Masse max sans carburant (ou sans carburant ni charge en aile)
alter table public.aircraft_mb add column if not exists mzfw numeric(7,2) check (mzfw is null or mzfw > 0);

-- 3. Données par avion. Ne remplace que des fiches jamais retouchées à la main
--    (vides, pré-remplies depuis Inside, ou issues de ce même import).
with src (reg, serial, empty_mass, empty_moment, mtow, mlw, mzfw, fuel_arm, fuel_capacity_l, stations, envelope, source) as (
  values
  -- PS-28 Cruiser : manuel de vol PS-POH-1-1-11 §2 et §6 ; domaine 420–525 mm (28–35 % MAC)
  ('F-HSAA', 'C0502', 393.5, 169.789, 600, 600, null, 0.180, 113,
   '[{"label":"Pilote","arm":0.70,"max":115},{"label":"Passager","arm":0.70,"max":115},{"label":"Bagages (coffre arrière)","arm":1.31,"max":18},{"label":"Casier aile gauche","arm":0.60,"max":10,"wing":true},{"label":"Casier aile droite","arm":0.60,"max":10,"wing":true}]',
   '[{"arm":0.420,"mass":300},{"arm":0.420,"mass":600},{"arm":0.525,"mass":600},{"arm":0.525,"mass":300}]',
   'Manuel de vol PS-28 Cruiser (PS-POH-1-1-11) §2 et §6 — fiche de pesée du 03/08/2026 [import 2026-09-25]'),
  ('F-HNLR', 'C0435', 386.5, 164.2625, 600, 600, null, 0.180, 113,
   '[{"label":"Pilote","arm":0.70,"max":115},{"label":"Passager","arm":0.70,"max":115},{"label":"Bagages (coffre arrière)","arm":1.31,"max":18},{"label":"Casier aile gauche","arm":0.60,"max":10,"wing":true},{"label":"Casier aile droite","arm":0.60,"max":10,"wing":true}]',
   '[{"arm":0.420,"mass":300},{"arm":0.420,"mass":600},{"arm":0.525,"mass":600},{"arm":0.525,"mass":300}]',
   'Manuel de vol PS-28 Cruiser (PS-POH-1-1-11) §2 et §6 — fiche de pesée du 16/10/2024 (S/N C0435) [import 2026-09-25]'),
  ('F-HUIT', 'C0409', 387.5, 173.212, 600, 600, null, 0.180, 113,
   '[{"label":"Pilote","arm":0.70,"max":115},{"label":"Passager","arm":0.70,"max":115},{"label":"Bagages (coffre arrière)","arm":1.31,"max":18},{"label":"Casier aile gauche","arm":0.60,"max":10,"wing":true},{"label":"Casier aile droite","arm":0.60,"max":10,"wing":true}]',
   '[{"arm":0.420,"mass":300},{"arm":0.420,"mass":600},{"arm":0.525,"mass":600},{"arm":0.525,"mass":300}]',
   'Manuel de vol PS-28 Cruiser (PS-POH-1-1-11) §2 et §6 — rapport de pesée du 15/12/2017 [import 2026-09-25]'),
  ('F-HSAC', 'C0531', 393.0, 170.0222, 600, 600, null, 0.180, 113,
   '[{"label":"Pilote","arm":0.70,"max":115},{"label":"Passager","arm":0.70,"max":115},{"label":"Bagages (coffre arrière)","arm":1.31,"max":18},{"label":"Casier aile gauche","arm":0.60,"max":10,"wing":true},{"label":"Casier aile droite","arm":0.60,"max":10,"wing":true}]',
   '[{"arm":0.420,"mass":300},{"arm":0.420,"mass":600},{"arm":0.525,"mass":600},{"arm":0.525,"mass":300}]',
   'Manuel de vol PS-28 Cruiser (PS-POH-1-1-11) §2 et §6 — fiche de pesée du 12/05/2015 [import 2026-09-25]'),
  ('F-HPSA', 'C0658', 402.7, 173.3057, 600, 600, null, 0.180, 113,
   '[{"label":"Pilote","arm":0.70,"max":115},{"label":"Passager","arm":0.70,"max":115},{"label":"Bagages (coffre arrière)","arm":1.31,"max":18},{"label":"Casier aile gauche","arm":0.60,"max":10,"wing":true},{"label":"Casier aile droite","arm":0.60,"max":10,"wing":true}]',
   '[{"arm":0.420,"mass":300},{"arm":0.420,"mass":600},{"arm":0.525,"mass":600},{"arm":0.525,"mass":300}]',
   'Manuel de vol PS-28 Cruiser (PS-POH-1-1-11) §2 et §6 — fiche de pesée PS-28 N Cruiser du 23/03/2022 [import 2026-09-25]'),
  ('F-HSAG', 'C0602', null, null, 600, 600, null, 0.180, 113,
   '[{"label":"Pilote","arm":0.70,"max":115},{"label":"Passager","arm":0.70,"max":115},{"label":"Bagages (coffre arrière)","arm":1.31,"max":18},{"label":"Casier aile gauche","arm":0.60,"max":10,"wing":true},{"label":"Casier aile droite","arm":0.60,"max":10,"wing":true}]',
   '[{"arm":0.420,"mass":300},{"arm":0.420,"mass":600},{"arm":0.525,"mass":600},{"arm":0.525,"mass":300}]',
   'Manuel de vol PS-28 Cruiser (PS-POH-1-1-11) §2 et §6 — fiche de pesée non fournie : masse et moment à vide à saisir [import 2026-09-25]'),
  -- WT9 Dynamic LSA/Club : POH AS-POH-10-508 §2.4, §6.4 (fig. 6-2) et §6.5 ; masse à vide de base (carburant inutilisable inclus)
  ('F-HVXD', 'DY-508/2014 LSA', 344.6, 911.16, 600, 600, null, 2.580, 119,
   '[{"label":"Pilote","arm":3.130,"max":120},{"label":"Passager","arm":3.130,"max":120},{"label":"Bagages (2 × 20 kg max)","arm":3.795,"max":40}]',
   '[{"arm":2.704,"mass":405},{"arm":2.704,"mass":542.5},{"arm":2.748,"mass":600},{"arm":2.824,"mass":600},{"arm":2.824,"mass":465.3},{"arm":2.810,"mass":445},{"arm":2.713,"mass":405}]',
   'POH WT9 Dynamic LSA/Club §2.4 et §6 (fig. 6-2) — pesée du 24/03/2020, masse à vide de base [import 2026-09-25]'),
  -- Bristell B23-915 : AFM ADXC-73-003 §2.7–2.8 et §6 ; MAC 1,343 m, bord d'attaque MAC 1,377 m
  ('F-HUFA', '0077', 469.5, 800.8, 750, 750, 660, 1.600, 112,
   '[{"label":"Pilote","arm":2.085,"max":null},{"label":"Passager","arm":2.085,"max":null},{"label":"Bagages arrière (bas)","arm":2.520,"max":15},{"label":"Bagages arrière (haut)","arm":2.800,"max":1},{"label":"Casier aile gauche","arm":2.025,"max":20,"wing":true},{"label":"Casier aile droite","arm":2.025,"max":20,"wing":true}]',
   '[{"arm":1.7128,"mass":519},{"arm":1.7128,"mass":600},{"arm":1.7934,"mass":750},{"arm":1.8403,"mass":750},{"arm":1.8403,"mass":600},{"arm":1.8067,"mass":519}]',
   'AFM Bristell B23-915 (ADXC-73-003) §2.7, §2.8 et §6 — pesée du 25/01/2023 ; MZFW = masse max sans carburant ni charge en aile [import 2026-09-25]'),
  -- Robin DR400/180 : manuel de vol éd. 20 §2 (plan de chargement) et §6 ; limites de la fiche de pesée (12 % à 25 % / 33 % de 1,71 m)
  ('F-HCLI', null, 644, 211.876, 1100, 1045, null, 1.120, 109,
   '[{"label":"Pilote (siège avant, bras moyen)","arm":0.41,"max":null},{"label":"Passager avant (bras moyen)","arm":0.41,"max":null},{"label":"Passagers arrière (total)","arm":1.19,"max":null},{"label":"Bagages","arm":1.90,"max":60},{"label":"Réservoirs d''ailes","arm":0.10,"max":80,"fuel":true}]',
   '[{"arm":0.2052,"mass":600},{"arm":0.2052,"mass":750},{"arm":0.428,"mass":1100},{"arm":0.564,"mass":1100},{"arm":0.564,"mass":600}]',
   'Manuel de vol DR400/180 éd. 20 §2 et §6 — rapport de pesée du 20/04/2018 ; catégorie Normale [import 2026-09-25]'),
  -- Diamond DA40 : AFM 6.01.01-E §2.7, §6.4 ; réservoirs standard. MTOW 1150 kg tant que la modification
  -- MÄM 40-227 (1200 kg) n'est pas confirmée : la case n'est pas cochée dans le manuel fourni.
  ('F-HXAF', null, 774.5, 1878.16, 1150, 1092, 1150, 2.630, 151,
   '[{"label":"Pilote","arm":2.30,"max":null},{"label":"Passager avant","arm":2.30,"max":null},{"label":"Passagers arrière (total)","arm":3.25,"max":null},{"label":"Bagages (compartiment standard)","arm":3.65,"max":30},{"label":"Tube à bagages (si installé)","arm":4.32,"max":5}]',
   '[{"arm":2.40,"mass":780},{"arm":2.40,"mass":980},{"arm":2.46,"mass":1150},{"arm":2.59,"mass":1150},{"arm":2.59,"mass":780}]',
   'AFM DA 40 (6.01.01-E rév. 8) §2.7 et §6.4 — rapport de pesée (correctif n°1) du 16/02/2018 ; MTOW 1150 kg (1200 kg seulement si MÄM 40-227 appliquée) ; MLW 1092 kg (jambe de train d''origine) [import 2026-09-25]')
)
insert into public.aircraft_mb as m
  (aircraft_id, serial, empty_mass, empty_moment, mtow, mlw, mzfw, fuel_arm, fuel_density, fuel_capacity_l, stations, envelope, source, updated_at, updated_by)
select a.id, s.serial, s.empty_mass::numeric, s.empty_moment::numeric, s.mtow::numeric, s.mlw::numeric, s.mzfw::numeric,
       s.fuel_arm::numeric, 0.72, s.fuel_capacity_l::numeric, s.stations::jsonb, s.envelope::jsonb, s.source, now(), null
from src s
join public.aircraft a on upper(a.registration) = s.reg
on conflict (aircraft_id) do update set
  serial          = coalesce(excluded.serial, m.serial),
  empty_mass      = coalesce(excluded.empty_mass, m.empty_mass),
  empty_moment    = coalesce(excluded.empty_moment, m.empty_moment),
  mtow = excluded.mtow, mlw = excluded.mlw, mzfw = excluded.mzfw,
  fuel_arm = excluded.fuel_arm, fuel_density = excluded.fuel_density, fuel_capacity_l = excluded.fuel_capacity_l,
  stations = excluded.stations, envelope = excluded.envelope, source = excluded.source, updated_at = now()
where m.source is null
   or m.source like 'Repris de l''outil Inside%'
   or m.source like '%[import 2026-09-25]';

notify pgrst, 'reload schema';

-- =====================================================================
--  Mise à jour n°22 : carte du bar (prix de septembre 2026)
--  Les produits existants sont renommés / mis à jour (l'historique des
--  consommations garde le nom et le prix de l'époque). Les produits qui ne
--  sont plus à la carte sont masqués, jamais supprimés.
-- =====================================================================
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

notify pgrst, 'reload schema';

-- =====================================================================
--  Mise à jour n°23 : carte des « bons plans » sur les aérodromes
--  (restaurants, avitaillement, hébergement, visites…). Chaque membre
--  validé peut en ajouter ; l'auteur ou un administrateur peut le modifier
--  ou le retirer (archivage : rien n'est effacé).
-- =====================================================================
create table if not exists public.airfield_tips (
  id            uuid primary key default gen_random_uuid(),
  icao          text not null check (icao ~ '^[A-Z]{2}[A-Z0-9]{2}$'),
  airfield_name text not null check (length(btrim(airfield_name)) between 1 and 80),
  lat           numeric(8,5) not null check (lat between -90 and 90),
  lon           numeric(8,5) not null check (lon between -180 and 180),
  category      text not null default 'resto' check (category in ('resto','avitaillement','hebergement','visite','autre')),
  title         text not null check (length(btrim(title)) between 1 and 80),
  description   text check (description is null or length(description) <= 1000),
  on_field      boolean not null default true,
  contact       text check (contact is null or (length(contact) <= 200 and (contact ~* '^https?://' or contact ~ '^[0-9 +().-]{6,25}$'))),
  created_by    uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  archived_at   timestamptz
);
create index if not exists airfield_tips_icao on public.airfield_tips (icao) where archived_at is null;
alter table public.airfield_tips enable row level security;
revoke truncate on public.airfield_tips from public, anon, authenticated;

drop policy if exists airfield_tips_select on public.airfield_tips;
create policy airfield_tips_select on public.airfield_tips for select to authenticated using (public.is_approved());
drop policy if exists airfield_tips_insert on public.airfield_tips;
create policy airfield_tips_insert on public.airfield_tips for insert to authenticated
  with check (public.is_approved() and created_by = auth.uid() and archived_at is null);
drop policy if exists airfield_tips_update on public.airfield_tips;
create policy airfield_tips_update on public.airfield_tips for update to authenticated
  using (public.is_approved() and (created_by = auth.uid() or public.app_role() = 'admin'))
  with check (public.is_approved() and (created_by = auth.uid() or public.app_role() = 'admin'));
-- pas de suppression : on archive (archived_at)
revoke delete on public.airfield_tips from authenticated, anon;

drop trigger if exists zz_audit on public.airfield_tips;
create trigger zz_audit after insert or update on public.airfield_tips
  for each row execute function public._audit();

-- Premier bon plan (repris d'Inside)
insert into public.airfield_tips (icao, airfield_name, lat, lon, category, title, description, on_field, contact, created_by)
select 'LFTF', 'Cuers-Pierrefeu', 43.2476, 6.1267, 'resto', 'Le Saint Tex',
       'Un restaurant sympathique sur l''AD avec une carte restreinte composée de plats traditionnels faits maison (tartare, pâtes carbonara, entrecôte-frites).',
       true, 'https://www.facebook.com/lesainttex/', null
where not exists (select 1 from public.airfield_tips where icao = 'LFTF' and title = 'Le Saint Tex');

notify pgrst, 'reload schema';

-- =====================================================================
--  Mise à jour n°24 : déplacer un membre d'équipage d'un avion à l'autre
--  (glisser-déposer sur la page d'une sortie avion).
--  - Déposer sur un avion qui a une place libre : la personne y est déplacée.
--  - Déposer sur une personne d'un autre avion : les deux échangent leur place.
--  - L'organisateur à bord peut aussi être déplacé ou échangé.
--  Réservé aux organisateurs (instructeurs, CA, fonctions, admin) et à
--  l'organisateur de la sortie.
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

create or replace function public.move_crew(
  p_outing   uuid,
  p_who      text,              -- id d'inscription, ou 'organizer'
  p_aircraft uuid,              -- avion de destination
  p_with     text default null  -- échange : id d'inscription, ou 'organizer'
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_outing public.outings;
  v_from   uuid;              -- avion de départ
  v_reg    public.registrations;
  v_other  public.registrations;
  v_cap    int;
  v_used   int;
begin
  if v_uid is null then raise exception 'Vous devez être connecté.'; end if;
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;

  select * into v_outing from public.outings where id = p_outing for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  if not (public.can_organize() or v_outing.instructor_id = v_uid) then
    raise exception 'Seul un organisateur peut répartir les équipages.';
  end if;
  if v_outing.status = 'cancelled' then raise exception 'Cette sortie est annulée.'; end if;
  if coalesce(v_outing.kind, 'vol') <> 'vol' then raise exception 'Cet événement n''a pas d''avions.'; end if;
  if not exists (select 1 from public.outing_aircraft where outing_id = p_outing and aircraft_id = p_aircraft) then
    raise exception 'Cet avion ne fait pas partie de la sortie.';
  end if;

  -- Qui bouge, et d'où ?
  if p_who = 'organizer' then
    if v_outing.instructor_aircraft_id is null then raise exception 'L''organisateur n''est pas à bord.'; end if;
    v_from := v_outing.instructor_aircraft_id;
  else
    select * into v_reg from public.registrations
     where id = p_who::uuid and outing_id = p_outing and status = 'confirmed' for update;
    if not found then raise exception 'Cette personne n''a pas de place confirmée dans cette sortie.'; end if;
    v_from := v_reg.aircraft_id;
  end if;
  if v_from = p_aircraft then return; end if;

  if p_with is null then
    -- Déplacement simple : il faut une place libre à l'arrivée
    select greatest(a.seats - case when v_outing.instructor_aircraft_id = a.id then 1 else 0 end, 0)
      into v_cap from public.aircraft a where a.id = p_aircraft;
    select count(*) into v_used from public.registrations
     where outing_id = p_outing and status = 'confirmed' and aircraft_id = p_aircraft;
    -- l'organisateur occupe un siège de plus
    if p_who = 'organizer' then v_cap := v_cap - 1; end if;
    if v_used >= v_cap then
      raise exception 'Cet avion est complet : déposez la personne sur un membre de l''équipage pour échanger leurs places.';
    end if;
    if p_who = 'organizer' then
      update public.outings set instructor_aircraft_id = p_aircraft where id = p_outing;
    else
      update public.registrations set aircraft_id = p_aircraft where id = v_reg.id;
    end if;
  else
    if p_with = p_who then return; end if;
    -- Échange de places avec quelqu'un de l'avion de destination
    if p_with = 'organizer' then
      if v_outing.instructor_aircraft_id is distinct from p_aircraft then
        raise exception 'L''organisateur n''est pas dans cet avion.';
      end if;
      update public.outings set instructor_aircraft_id = v_from where id = p_outing;
      update public.registrations set aircraft_id = p_aircraft where id = v_reg.id;
    else
      select * into v_other from public.registrations
       where id = p_with::uuid and outing_id = p_outing and status = 'confirmed' and aircraft_id = p_aircraft for update;
      if not found then raise exception 'Cette personne n''est pas dans cet avion.'; end if;
      update public.registrations set aircraft_id = v_from where id = v_other.id;
      if p_who = 'organizer' then
        update public.outings set instructor_aircraft_id = p_aircraft where id = p_outing;
      else
        update public.registrations set aircraft_id = p_aircraft where id = v_reg.id;
      end if;
    end if;
  end if;

  -- Contrôle final : aucun avion ne dépasse sa capacité
  if exists (
    select 1
    from public.outing_aircraft oa
    join public.aircraft a on a.id = oa.aircraft_id
    join public.outings o on o.id = oa.outing_id
    where oa.outing_id = p_outing
      and (select count(*) from public.registrations r
            where r.outing_id = p_outing and r.status = 'confirmed' and r.aircraft_id = oa.aircraft_id)
          > greatest(a.seats - case when o.instructor_aircraft_id = a.id then 1 else 0 end, 0)
  ) then
    raise exception 'Ce déplacement dépasserait le nombre de places d''un avion.';
  end if;
end;
$$;
revoke execute on function public.move_crew(uuid, text, uuid, text) from public, anon;
grant execute on function public.move_crew(uuid, text, uuid, text) to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
--  Mise à jour n°25 : instructeur référent pour les sorties proposées
-- =====================================================================
-- =====================================================================
--  Mise à jour n°25 : instructeur référent + alignement sur la base en service
--  - Ajoute la colonne `referent_instructor_id` sur `outings` (réservée pour
--    un usage futur : la validation d'une proposition ne la renseigne pas).
--  - Reprend les versions de get_outing() et move_crew() réellement en
--    service : poids lu sur pilot_weights.updated_at, et contrôle du lâcher
--    (une personne non lâchée sur le type ne peut monter dans un avion que
--    si un instructeur est à bord).
--  La version précédente de ce fichier ne pouvait pas s'exécuter (rôle « ca »
--  inexistant, colonne weighed_at inexistante) : elle est remplacée.
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

alter table public.outings
  add column if not exists referent_instructor_id uuid references public.profiles(id);

CREATE OR REPLACE FUNCTION public.get_outing(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_staff boolean := public.is_staff();
  v_row   public.outings;
  v_org   public.profiles;
  v_kind  text;
  v_ac    jsonb;
  v_wait  jsonb;
  v_part  jsonb;
  v_mine  jsonb;
  v_org_w numeric;
begin
  select * into v_row from public.outings where id = p_id;
  if not found then return null; end if;

  v_kind := coalesce(v_row.kind, 'vol');

  if v_row.approval <> 'approved' and v_row.status <> 'cancelled' then
    if not (v_staff or v_row.instructor_id = v_uid) then return null; end if;
  end if;
  if v_row.status = 'cancelled' then
    if not (v_staff or v_row.instructor_id = v_uid
            or exists (select 1 from public.registrations where outing_id = p_id and user_id = v_uid)) then
      return null;
    end if;
  end if;

  select * into v_org from public.profiles where id = v_row.instructor_id;

  if v_row.instructor_id = v_uid then
    select weight_kg into v_org_w from public.pilot_weights where user_id = v_uid order by updated_at desc limit 1;
  end if;

  if v_kind = 'vol' then
    select coalesce(jsonb_agg(ac_data order by ac_reg), '[]') into v_ac
    from (
      select
        a.registration as ac_reg,
        jsonb_build_object(
          'id', a.id,
          'registration', a.registration,
          'model', a.model,
          'type', a.type,
          'seats', a.seats,
          'instructor_onboard', v_row.instructor_aircraft_id = a.id,
          'capacity', greatest(a.seats - case when v_row.instructor_aircraft_id = a.id then 1 else 0 end, 0),
          'occupants', coalesce((
            select jsonb_agg(jsonb_build_object(
              'registration_id', r.id,
              'user_id', r.user_id,
              'full_name', p.full_name,
              'avatar_url', p.avatar_url,
              'released', exists (
                select 1 from public.pilot_types pt
                 where pt.user_id = r.user_id and pt.aircraft_type = a.type
              ),
              'phone', case when v_staff or v_row.instructor_id = v_uid then p.phone end,
              'weight_kg', case when v_row.instructor_id = v_uid then pw.weight_kg end
            ) order by r.created_at)
            from public.registrations r
            join public.profiles p on p.id = r.user_id
            left join public.pilot_weights pw on pw.user_id = r.user_id
              and pw.updated_at = (select max(updated_at) from public.pilot_weights where user_id = r.user_id)
            where r.outing_id = p_id and r.status = 'confirmed' and r.aircraft_id = a.id
          ), '[]')
        ) as ac_data
      from public.outing_aircraft oa
      join public.aircraft a on a.id = oa.aircraft_id
      where oa.outing_id = p_id
    ) sub;
  else
    v_ac := '[]';
  end if;

  select coalesce(jsonb_agg(w order by w_created), '[]') into v_wait
  from (
    select jsonb_build_object(
      'registration_id', r.id,
      'user_id', r.user_id,
      'full_name', p.full_name,
      'avatar_url', p.avatar_url,
      'released', false,
      'phone', case when v_staff or v_row.instructor_id = v_uid then p.phone end,
      'weight_kg', case when v_row.instructor_id = v_uid then pw.weight_kg end,
      'position', row_number() over (order by r.created_at)
    ) as w,
    r.created_at as w_created
    from public.registrations r
    join public.profiles p on p.id = r.user_id
    left join public.pilot_weights pw on pw.user_id = r.user_id
      and pw.updated_at = (select max(updated_at) from public.pilot_weights where user_id = r.user_id)
    where r.outing_id = p_id and r.status = 'waitlist'
  ) sub;

  if v_kind <> 'vol' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'registration_id', r.id,
      'user_id', r.user_id,
      'full_name', p.full_name,
      'avatar_url', p.avatar_url,
      'released', false,
      'phone', case when v_staff or v_row.instructor_id = v_uid then p.phone end
    ) order by r.created_at), '[]') into v_part
    from public.registrations r
    join public.profiles p on p.id = r.user_id
    where r.outing_id = p_id and r.status = 'confirmed';
  else
    v_part := '[]';
  end if;

  select jsonb_build_object('id', r.id, 'status', r.status, 'aircraft_id', r.aircraft_id) into v_mine
  from public.registrations r
  where r.outing_id = p_id and r.user_id = v_uid
  limit 1;

  return jsonb_build_object(
    'id',                    v_row.id,
    'title',                 v_row.title,
    'destination',           v_row.destination,
    'description',           v_row.description,
    'meeting_point',         v_row.meeting_point,
    'departure_at',          v_row.departure_at,
    'return_at',             v_row.return_at,
    'registration_deadline', v_row.registration_deadline,
    'max_participants',      v_row.max_participants,
    'kind',                  v_kind,
    'status',                v_row.status,
    'instructor_aircraft_id',v_row.instructor_aircraft_id,
    'instructor', jsonb_build_object(
      'id',          v_org.id,
      'full_name',   v_org.full_name,
      'phone',       case when v_staff or v_row.instructor_id = v_uid then v_org.phone end,
      'avatar_url',  v_org.avatar_url
    ),
    'can_manage',            v_staff,
    'is_organizer',          v_row.instructor_id = v_uid,
    'organizer_weight_kg',   v_org_w,
    'approval',              v_row.approval,
    'rejection_reason',      v_row.rejection_reason,
    'can_edit',              v_staff or (v_row.instructor_id = v_uid and v_row.approval <> 'approved'),
    'aircraft',              v_ac,
    'waitlist',              v_wait,
    'participants',          v_part,
    'my_registration',       v_mine
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.move_crew(p_outing uuid, p_who text, p_aircraft uuid, p_with text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid           uuid := auth.uid();
  v_outing        public.outings;
  v_from          uuid;
  v_reg           public.registrations;
  v_other         public.registrations;
  v_cap           int;
  v_used          int;
  v_person_uid    uuid;
  v_ac_type       text;
  v_nom           text;
  v_has_instructor boolean;
  v_is_instructor  boolean;
begin
  if v_uid is null then raise exception 'Vous devez être connecté.'; end if;
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;

  select * into v_outing from public.outings where id = p_outing for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  if not (public.can_organize() or v_outing.instructor_id = v_uid) then
    raise exception 'Seul un organisateur peut répartir les équipages.';
  end if;
  if v_outing.status = 'cancelled' then raise exception 'Cette sortie est annulée.'; end if;
  if coalesce(v_outing.kind, 'vol') <> 'vol' then raise exception 'Cet événement n''a pas d''avions.'; end if;
  if not exists (select 1 from public.outing_aircraft where outing_id = p_outing and aircraft_id = p_aircraft) then
    raise exception 'Cet avion ne fait pas partie de la sortie.';
  end if;

  if p_who = 'organizer' then
    if v_outing.instructor_aircraft_id is null then raise exception 'L''organisateur n''est pas à bord.'; end if;
    v_from := v_outing.instructor_aircraft_id;
  else
    select * into v_reg from public.registrations
     where id = p_who::uuid and outing_id = p_outing and status = 'confirmed' for update;
    if not found then raise exception 'Cette personne n''a pas de place confirmée dans cette sortie.'; end if;
    v_from := v_reg.aircraft_id;
  end if;
  if v_from = p_aircraft then return; end if;

  if p_who <> 'organizer' then
    v_person_uid := v_reg.user_id;
    select a.type into v_ac_type from public.aircraft a where a.id = p_aircraft;
    select coalesce(pr.is_instructor, false) into v_is_instructor
      from public.profiles pr where pr.id = v_person_uid;
    if not v_is_instructor then
      v_has_instructor := (v_outing.instructor_aircraft_id = p_aircraft)
        or exists (
          select 1 from public.registrations r
          join public.profiles pr on pr.id = r.user_id
          where r.outing_id = p_outing
            and r.status = 'confirmed'
            and r.aircraft_id = p_aircraft
            and pr.is_instructor = true
        );
      if v_ac_type is not null and not v_has_instructor then
        if not exists (
          select 1 from public.pilot_types pt
          where pt.user_id = v_person_uid and pt.aircraft_type = v_ac_type
        ) then
          select pr.full_name into v_nom from public.profiles pr where pr.id = v_person_uid;
          raise exception '% n''est pas lâché(e) sur % — déplacement refusé.', v_nom, v_ac_type;
        end if;
      end if;
    end if;
  end if;

  if p_with is null then
    select greatest(a.seats - case when v_outing.instructor_aircraft_id = a.id then 1 else 0 end, 0)
      into v_cap from public.aircraft a where a.id = p_aircraft;
    select count(*) into v_used from public.registrations
     where outing_id = p_outing and status = 'confirmed' and aircraft_id = p_aircraft;
    if p_who = 'organizer' then v_cap := v_cap - 1; end if;
    if v_used >= v_cap then
      raise exception 'Cet avion est complet : déposez la personne sur un membre de l''équipage pour échanger leurs places.';
    end if;
    if p_who = 'organizer' then
      update public.outings set instructor_aircraft_id = p_aircraft where id = p_outing;
    else
      update public.registrations set aircraft_id = p_aircraft where id = v_reg.id;
    end if;
  else
    if p_with = p_who then return; end if;
    if p_with = 'organizer' then
      if v_outing.instructor_aircraft_id is distinct from p_aircraft then
        raise exception 'L''organisateur n''est pas dans cet avion.';
      end if;
      update public.outings set instructor_aircraft_id = v_from where id = p_outing;
      update public.registrations set aircraft_id = p_aircraft where id = v_reg.id;
    else
      select * into v_other from public.registrations
       where id = p_with::uuid and outing_id = p_outing and status = 'confirmed' and aircraft_id = p_aircraft for update;
      if not found then raise exception 'Cette personne n''est pas dans cet avion.'; end if;
      update public.registrations set aircraft_id = v_from where id = v_other.id;
      if p_who = 'organizer' then
        update public.outings set instructor_aircraft_id = p_aircraft where id = p_outing;
      else
        update public.registrations set aircraft_id = p_aircraft where id = v_reg.id;
      end if;
    end if;
  end if;

  if exists (
    select 1
    from public.outing_aircraft oa
    join public.aircraft a on a.id = oa.aircraft_id
    join public.outings o on o.id = oa.outing_id
    where oa.outing_id = p_outing
      and (select count(*) from public.registrations r
            where r.outing_id = p_outing and r.status = 'confirmed' and r.aircraft_id = oa.aircraft_id)
          > greatest(a.seats - case when o.instructor_aircraft_id = a.id then 1 else 0 end, 0)
  ) then
    raise exception 'Ce déplacement dépasserait le nombre de places d''un avion.';
  end if;
end;
$function$;

revoke execute on function public.get_outing(uuid) from public, anon;
grant execute on function public.get_outing(uuid) to authenticated;
revoke execute on function public.move_crew(uuid, text, uuid, text) from public, anon;
grant execute on function public.move_crew(uuid, text, uuid, text) to authenticated;

notify pgrst, 'reload schema';


-- =====================================================================
--  Mise à jour n°26 : données masse & centrage depuis les manuels de vol
-- =====================================================================
-- =====================================================================
--  Mise à jour n°26 : données masse & centrage depuis les manuels de vol
--  et fiches de pesée de chaque appareil.
--  « Base toi sur les manuels de vol de chaque avion, n'invente rien. »
-- =====================================================================

-- -------------------------------------------------------------------------
-- PS-28 Cruiser × 5  (F-HNLR, F-HSAC, F-HUIT, F-HPSA, F-HSAA)
--
-- Sources : Manuel de vol PS-28 Cruiser (Czech Sport Aircraft)
--           + fiches de pesée individuelles
-- MTOW : 600 kg — MLW : 600 kg (avion LSA)
-- Datum : Rib #4 (nervure n°4) — d'après POH section 6.4
-- Réservoir principal : 2 × 57 L (total 114 L), bras 0.180 m
-- Postes (d'après tableau de chargement du POH) :
--   Pilote           0.700 m  max 115 kg
--   Passager         0.700 m  max 115 kg
--   Bagages coffre   1.310 m  max 18 kg
--   Casiers d'aile   0.600 m  max 20 kg  (10 kg par aile × 2, dans l'aile → exclus du MZFW)
--   Carburant        0.180 m  max 114 L  (fuel, density 0.72)
-- Domaine : rectangle 0.420–0.525 m × 400–600 kg
-- -------------------------------------------------------------------------

-- F-HNLR
insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow, mlw,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  null,             -- numéro de série non disponible dans les documents fournis
  386.5,            -- fiche de pesée F-HNLR
  164.2625,         -- fiche de pesée F-HNLR
  600, 600,
  0.180, 0.72, 114,
  '[
    {"label":"Pilote",         "arm":0.700,"max":115},
    {"label":"Passager",       "arm":0.700,"max":115},
    {"label":"Bagages coffre", "arm":1.310,"max":18},
    {"label":"Casiers aile",   "arm":0.600,"max":20, "wing":true},
    {"label":"Carburant",      "arm":0.180,"max":114,"fuel":true}
  ]'::jsonb,
  '[
    {"arm":0.420,"mass":400},
    {"arm":0.420,"mass":600},
    {"arm":0.525,"mass":600},
    {"arm":0.525,"mass":400}
  ]'::jsonb,
  'Manuel de vol PS-28 Cruiser (Czech Sport Aircraft) + fiche de pesée F-HNLR',
  now()
from public.aircraft a
where a.registration = 'F-HNLR'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = excluded.mlw,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- F-HSAC
insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow, mlw,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  null,
  393.0,            -- fiche de pesée F-HSAC
  170.022,          -- fiche de pesée F-HSAC
  600, 600,
  0.180, 0.72, 114,
  '[
    {"label":"Pilote",         "arm":0.700,"max":115},
    {"label":"Passager",       "arm":0.700,"max":115},
    {"label":"Bagages coffre", "arm":1.310,"max":18},
    {"label":"Casiers aile",   "arm":0.600,"max":20, "wing":true},
    {"label":"Carburant",      "arm":0.180,"max":114,"fuel":true}
  ]'::jsonb,
  '[
    {"arm":0.420,"mass":400},
    {"arm":0.420,"mass":600},
    {"arm":0.525,"mass":600},
    {"arm":0.525,"mass":400}
  ]'::jsonb,
  'Manuel de vol PS-28 Cruiser (Czech Sport Aircraft) + fiche de pesée F-HSAC',
  now()
from public.aircraft a
where a.registration = 'F-HSAC'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = excluded.mlw,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- F-HUIT
insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow, mlw,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  null,
  387.5,            -- fiche de pesée F-HUIT
  173.212,          -- fiche de pesée F-HUIT
  600, 600,
  0.180, 0.72, 114,
  '[
    {"label":"Pilote",         "arm":0.700,"max":115},
    {"label":"Passager",       "arm":0.700,"max":115},
    {"label":"Bagages coffre", "arm":1.310,"max":18},
    {"label":"Casiers aile",   "arm":0.600,"max":20, "wing":true},
    {"label":"Carburant",      "arm":0.180,"max":114,"fuel":true}
  ]'::jsonb,
  '[
    {"arm":0.420,"mass":400},
    {"arm":0.420,"mass":600},
    {"arm":0.525,"mass":600},
    {"arm":0.525,"mass":400}
  ]'::jsonb,
  'Manuel de vol PS-28 Cruiser (Czech Sport Aircraft) + fiche de pesée F-HUIT',
  now()
from public.aircraft a
where a.registration = 'F-HUIT'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = excluded.mlw,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- F-HPSA
insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow, mlw,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  null,
  402.7,            -- fiche de pesée F-HPSA
  173.3057,         -- fiche de pesée F-HPSA
  600, 600,
  0.180, 0.72, 114,
  '[
    {"label":"Pilote",         "arm":0.700,"max":115},
    {"label":"Passager",       "arm":0.700,"max":115},
    {"label":"Bagages coffre", "arm":1.310,"max":18},
    {"label":"Casiers aile",   "arm":0.600,"max":20, "wing":true},
    {"label":"Carburant",      "arm":0.180,"max":114,"fuel":true}
  ]'::jsonb,
  '[
    {"arm":0.420,"mass":400},
    {"arm":0.420,"mass":600},
    {"arm":0.525,"mass":600},
    {"arm":0.525,"mass":400}
  ]'::jsonb,
  'Manuel de vol PS-28 Cruiser (Czech Sport Aircraft) + fiche de pesée F-HPSA',
  now()
from public.aircraft a
where a.registration = 'F-HPSA'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = excluded.mlw,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- F-HSAA  (remplace l'entrée partielle de la migration-20)
insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow, mlw,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  'C0502',          -- numéro de série (figurait dans la migration-20)
  393.5,            -- fiche de pesée F-HSAA
  169.789,          -- fiche de pesée F-HSAA (169.8 arrondi précédent, valeur exacte)
  600, 600,
  0.180, 0.72, 114,
  '[
    {"label":"Pilote",         "arm":0.700,"max":115},
    {"label":"Passager",       "arm":0.700,"max":115},
    {"label":"Bagages coffre", "arm":1.310,"max":18},
    {"label":"Casiers aile",   "arm":0.600,"max":20, "wing":true},
    {"label":"Carburant",      "arm":0.180,"max":114,"fuel":true}
  ]'::jsonb,
  '[
    {"arm":0.420,"mass":400},
    {"arm":0.420,"mass":600},
    {"arm":0.525,"mass":600},
    {"arm":0.525,"mass":400}
  ]'::jsonb,
  'Manuel de vol PS-28 Cruiser (Czech Sport Aircraft) + fiche de pesée F-HSAA',
  now()
from public.aircraft a
where a.registration = 'F-HSAA'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = excluded.mlw,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- -------------------------------------------------------------------------
-- Diamond DA40 (F-HXAF)
--
-- Sources : DA40 POH + fiche de pesée F-HXAF
-- MTOW : 1150 kg — MLW : 1092 kg — MZFW : 1150 kg
-- Datum : bord d'attaque intrados (standard Diamond)
-- Réservoir : 2 × 64 L = 128 L usable, bras 2.630 m
-- Postes :
--   Sièges avant           2.300 m  pas de max individuel (limite structurelle combinée)
--   Sièges arrière         3.250 m  idem
--   Bagages standard       3.650 m  max 30 kg
--   Bagages tube            4.320 m  max 5 kg
-- -------------------------------------------------------------------------

insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow, mlw, mzfw,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  null,
  774.5,            -- fiche de pesée F-HXAF
  1878.16,          -- fiche de pesée F-HXAF  (en kg.m)
  1150, 1092, 1150,
  2.630, 0.72, 128,
  '[
    {"label":"Sièges avant",      "arm":2.300,"max":null},
    {"label":"Sièges arrière",    "arm":3.250,"max":null},
    {"label":"Bagages standard",  "arm":3.650,"max":30},
    {"label":"Bagages tube",      "arm":4.320,"max":5}
  ]'::jsonb,
  '[
    {"arm":2.40,"mass":780},
    {"arm":2.40,"mass":980},
    {"arm":2.46,"mass":1150},
    {"arm":2.59,"mass":1150},
    {"arm":2.59,"mass":780}
  ]'::jsonb,
  'Manuel de vol Diamond DA40 + fiche de pesée F-HXAF',
  now()
from public.aircraft a
where a.registration = 'F-HXAF'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = excluded.mlw,
  mzfw             = excluded.mzfw,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- -------------------------------------------------------------------------
-- Robin DR400-180 (F-HCLI)
--
-- Sources : Manuel de vol Robin DR400-180 + fiche de pesée F-HCLI
-- MTOW : 1100 kg — MLW : 1045 kg
-- Datum : bord d'attaque de la voilure rectangulaire
-- Pas de réservoir principal central (fuel_capacity_l = null) :
--   les réservoirs sont 2 postes de chargement en litres.
--   Le bras de référence carburant (fuel_arm) est celui du réservoir principal
--   utilisé comme bras par défaut pour le trip fuel.
-- Postes :
--   Sièges avant      0.410 m  max 154 kg (2 places)
--   Sièges arrière    1.190 m  max 154 kg (2 places)
--   Réservoir princ.  1.120 m  max 110 L  (fuel) — 78 kg / 0.72 = 108.3 L ≈ 110 L (fiche pesée confirme 79.2 kg = 110 L)
--   Réservoir ailes   0.100 m  max 80 L   (fuel, dans l'aile → wing)
--   Bagages           1.900 m  max 60 kg
-- Domaine : trapèze (d'après diagramme manuel DR400)
-- -------------------------------------------------------------------------

insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow, mlw,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  null,
  644.0,            -- fiche de pesée F-HCLI
  211.876,          -- fiche de pesée F-HCLI  (en kg.m)
  1100, 1045,
  1.120, 0.72, null,   -- pas de réservoir central ; bras = réservoir principal
  '[
    {"label":"Sièges avant",          "arm":0.410,"max":154},
    {"label":"Sièges arrière",        "arm":1.190,"max":154},
    {"label":"Réservoir principal",   "arm":1.120,"max":110,"fuel":true},
    {"label":"Réservoir ailes",       "arm":0.100,"max":80, "fuel":true,"wing":true},
    {"label":"Bagages",               "arm":1.900,"max":60}
  ]'::jsonb,
  '[
    {"arm":0.205,"mass":750},
    {"arm":0.328,"mass":1100},
    {"arm":0.564,"mass":1100},
    {"arm":0.428,"mass":750}
  ]'::jsonb,
  'Manuel de vol Robin DR400-180 + fiche de pesée F-HCLI',
  now()
from public.aircraft a
where a.registration = 'F-HCLI'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = excluded.mlw,
  mzfw             = null,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- -------------------------------------------------------------------------
-- Bristell B23-915 (F-HUFA)
--
-- Sources : Manuel de vol Bristell B23-915 (ADXC-73-003-AFM, Rév.B3, 24.11.2023)
--           + fiche de pesée F-HUFA (BRM-211, 07.07.2022)
-- MTOW : 750 kg (LSA)
-- S/N : 0077
-- Datum : flasque hélice (Propeller Flange)
-- Conversion %MAC → mètres : bras_m = MAC_LE + (%MAC/100) × MAC = 1.377 + (%MAC/100) × 1.343
-- Réservoir (§2.13) : 2 réservoirs × 60 L = 120 L total ; utilisable 2×56 = 112 L
--   Carburant approuvé : UL95/SP95, AVGAS UL91, AVGAS 100LL
--   bras : 1.600 m (§6.5 — "FUEL weight = qty×0.72 kg/liter, arm 1.600")
-- Postes (§6.5) :
--   Pilote & Passager           2.085 m  max 2×120 kg (voir §6.4 ; min 55 kg pilote)
--   Bagages derrière sièges     2.520 m  max 16 kg (lower 15 kg + upper 1 kg, §2.7)
--   Casiers aile (wing lockers) 2.025 m  max 40 kg (2×20 kg/côté, §2.7) — dans l'aile
--   Carburant                   1.600 m  max 120 L total (fuel)
-- Domaine CG (§2.8 — graphique en %MAC converti en mètres) :
--   %MAC 25%→34.5% (operating CG range)
--   Points clés :  (1.713,530) (1.713,600) (1.753,660) (1.793,750) (1.834,750) (1.840,600) (1.834,530)
-- -------------------------------------------------------------------------

insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  '0077',
  469.5,            -- fiche de pesée F-HUFA (07.07.2022)
  800.8,            -- fiche de pesée F-HUFA  (en kg.m)
  750,
  1.600, 0.72, 120,   -- §2.13 : 2×60 L = 120 L total
  '[
    {"label":"Pilote & Passager",       "arm":2.085,"max":240},
    {"label":"Bagages derrière sièges", "arm":2.520,"max":16},
    {"label":"Casiers aile",            "arm":2.025,"max":40,"wing":true},
    {"label":"Carburant",               "arm":1.600,"max":120,"fuel":true}
  ]'::jsonb,
  '[
    {"arm":1.713,"mass":530},
    {"arm":1.713,"mass":600},
    {"arm":1.753,"mass":660},
    {"arm":1.793,"mass":750},
    {"arm":1.834,"mass":750},
    {"arm":1.840,"mass":600},
    {"arm":1.834,"mass":530}
  ]'::jsonb,
  'Manuel de vol Bristell B23-915 (ADXC-73-003-AFM Rév.B3) + fiche de pesée F-HUFA (BRM-211 07.07.2022)',
  now()
from public.aircraft a
where a.registration = 'F-HUFA'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = null,
  mzfw             = null,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- -------------------------------------------------------------------------
-- WT9 Dynamic LSA (F-HVXD)
--
-- Sources : Manuel de vol WT9 Dynamic LSA (aerodynamika Žilina)
--           + fiche de pesée F-HVXD
-- MTOW : 600 kg (LSA)
-- Datum : 1.975 m en avant de la face intérieure du pare-feu (firewall)
-- Réservoir : 80 L usable, bras 2.580 m, densité 0.72
-- Postes (tableau Section 6 du POH) :
--   Pilote / Passager   3.130 m  max 120 kg combiné
--   Bagages             3.795 m  max 40 kg (2 × 20 kg)
-- Domaine CG (Section 6 du POH, graphique de centrage) :
--   polygone à 8 points lus sur le diagramme
-- Masse à vide : fiche de pesée F-HVXD (339.6 kg / 898.26 kg.m)
--   NB : le W&B Record du POH indique 344.6 kg / 911.16 kg.m après SB SBLSA-916-2019
--        (mars 2020) — la fiche de pesée individuelle fait foi.
-- -------------------------------------------------------------------------

insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  null,
  339.6,            -- fiche de pesée F-HVXD
  898.26,           -- fiche de pesée F-HVXD  (en kg.m)
  600,
  2.580, 0.72, 80,
  '[
    {"label":"Pilote / Passager", "arm":3.130,"max":120},
    {"label":"Bagages",           "arm":3.795,"max":40}
  ]'::jsonb,
  '[
    {"arm":2.704,"mass":405.0},
    {"arm":2.713,"mass":405.0},
    {"arm":2.730,"mass":412.0},
    {"arm":2.810,"mass":445.0},
    {"arm":2.824,"mass":465.3},
    {"arm":2.824,"mass":600.0},
    {"arm":2.748,"mass":600.0},
    {"arm":2.704,"mass":542.5}
  ]'::jsonb,
  'Manuel de vol WT9 Dynamic LSA (aerodynamika Žilina) + fiche de pesée F-HVXD',
  now()
from public.aircraft a
where a.registration = 'F-HVXD'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = null,
  mzfw             = null,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

notify pgrst, 'reload schema';


-- =====================================================================
--  Mise à jour n°25 bis : shop
-- =====================================================================
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
-- (seulement si le catalogue est vide, pour pouvoir relancer ce fichier sans créer de doublons)
insert into public.shop_items (name, description, price_cents, category, sizes, colors, position)
select * from (values
  ('T-shirt club', 'T-shirt coton 100% aux couleurs du club, logo brodé au cœur', 2500, 'Vêtements', 'XS,S,M,L,XL,XXL', 'Blanc,Marine', 1),
  ('Polaire softshell', 'Veste softshell légère avec logo club, idéale pour les briefings sur le tarmac', 5500, 'Vêtements', 'S,M,L,XL,XXL', 'Marine,Gris', 2),
  ('Casquette brodée', 'Casquette ajustable avec logo club brodé', 2000, 'Accessoires', null, 'Marine,Blanc', 3),
  ('Mug "Pilote"', 'Mug céramique 350 ml, motif avion et indicatif LFMA', 1200, 'Accessoires', null, 'Blanc', 4),
  ('Sticker pack', 'Pack de 5 stickers vinyle : logo club, LFMA, avions de la flotte…', 500, 'Accessoires', null, null, 5)
) as v(name, description, price_cents, category, sizes, colors, position)
where not exists (select 1 from public.shop_items);

-- Colonnes ajoutées depuis (nom et prix figés à la commande, débit de l'ardoise)
alter table public.shop_orders
  add column if not exists item_name       text,
  add column if not exists price_cents     int,
  add column if not exists ardoise_charged boolean not null default false;

notify pgrst, 'reload schema';


-- =====================================================================
--  Mise à jour n°27 : Shareflight
-- =====================================================================
-- =====================================================================
--  Mise à jour n°27 : Shareflight — covoiturage aérien entre membres
--
--  Un pilote publie un projet de vol (départ, destination, date,
--  places libres, commentaire) ; d'autres membres peuvent s'inscrire
--  comme passagers. Le pilote ou un admin peut clore ou annuler le vol.
--  Les passagers peuvent se désinscrire tant que le vol n'est pas clôturé.
-- =====================================================================

-- Table principale : propositions de vols
create table if not exists public.flight_shares (
  id            uuid primary key default gen_random_uuid(),
  pilot_id      uuid not null references public.profiles (id) on delete cascade default auth.uid(),
  -- Aérodrome départ
  dep_icao      text not null check (dep_icao ~ '^[A-Z]{2}[A-Z0-9]{2}$'),
  dep_name      text not null check (length(btrim(dep_name)) between 1 and 80),
  dep_lat       numeric(8,5) not null,
  dep_lon       numeric(8,5) not null,
  -- Aérodrome arrivée
  arr_icao      text not null check (arr_icao ~ '^[A-Z]{2}[A-Z0-9]{2}$'),
  arr_name      text not null check (length(btrim(arr_name)) between 1 and 80),
  arr_lat       numeric(8,5) not null,
  arr_lon       numeric(8,5) not null,
  -- Vol
  flight_date   date not null,
  seats         smallint not null default 1 check (seats between 1 and 5),
  aircraft      text check (aircraft is null or length(btrim(aircraft)) <= 40),
  comment       text check (comment is null or length(comment) <= 600),
  -- Statut : open | closed | cancelled
  status        text not null default 'open' check (status in ('open','closed','cancelled')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  closed_at     timestamptz
);

create index if not exists flight_shares_date on public.flight_shares (flight_date) where status = 'open';
create index if not exists flight_shares_pilot on public.flight_shares (pilot_id);

alter table public.flight_shares enable row level security;
revoke truncate on public.flight_shares from public, anon, authenticated;

-- Lecture : tout membre approuvé
drop policy if exists flight_shares_select on public.flight_shares;
create policy flight_shares_select on public.flight_shares
  for select to authenticated using (public.is_approved());

-- Insertion : membre approuvé uniquement, pour soi-même
drop policy if exists flight_shares_insert on public.flight_shares;
create policy flight_shares_insert on public.flight_shares
  for insert to authenticated
  with check (public.is_approved() and pilot_id = auth.uid());

-- Mise à jour : pilote ou admin (statut, fermeture…)
drop policy if exists flight_shares_update on public.flight_shares;
create policy flight_shares_update on public.flight_shares
  for update to authenticated
  using (public.is_approved() and (pilot_id = auth.uid() or public.app_role() = 'admin'))
  with check (public.is_approved() and (pilot_id = auth.uid() or public.app_role() = 'admin'));

-- Pas de suppression physique
revoke delete on public.flight_shares from authenticated, anon;

-- Audit
drop trigger if exists zz_audit on public.flight_shares;
create trigger zz_audit after insert or update on public.flight_shares
  for each row execute function public._audit();


-- Table des passagers inscrits
create table if not exists public.flight_share_seats (
  id            uuid primary key default gen_random_uuid(),
  share_id      uuid not null references public.flight_shares (id) on delete cascade,
  member_id     uuid not null references public.profiles (id) on delete cascade,
  message       text check (message is null or length(message) <= 300),
  created_at    timestamptz not null default now(),
  unique (share_id, member_id)
);

create index if not exists flight_share_seats_share on public.flight_share_seats (share_id);

alter table public.flight_share_seats enable row level security;
revoke truncate on public.flight_share_seats from public, anon, authenticated;

-- Lecture : tout membre approuvé
drop policy if exists flight_share_seats_select on public.flight_share_seats;
create policy flight_share_seats_select on public.flight_share_seats
  for select to authenticated using (public.is_approved());

-- Inscription : pour soi-même, vol ouvert, pas déjà inscrit, place disponible
drop policy if exists flight_share_seats_insert on public.flight_share_seats;
create policy flight_share_seats_insert on public.flight_share_seats
  for insert to authenticated
  with check (
    public.is_approved()
    and member_id = auth.uid()
    and exists (
      select 1 from public.flight_shares fs
      where fs.id = share_id
        and fs.status = 'open'
        and fs.pilot_id <> auth.uid()
        and (
          select count(*) from public.flight_share_seats s2 where s2.share_id = fs.id
        ) < fs.seats
    )
  );

-- Désinscription : soi-même ou admin
drop policy if exists flight_share_seats_delete on public.flight_share_seats;
create policy flight_share_seats_delete on public.flight_share_seats
  for delete to authenticated
  using (public.is_approved() and (member_id = auth.uid() or public.app_role() = 'admin'));

notify pgrst, 'reload schema';


-- =====================================================================
--  Mise à jour n°28 : corrections avant la mise en service
-- =====================================================================
-- =====================================================================
--  Mise à jour n°28 : corrections avant la mise en service
--  - Aligne le dépôt sur la base réelle (colonnes du shop, tables du quiz,
--    colonne referent_instructor_id) : sans effet si c'est déjà le cas.
--  - Shop : annulation par le membre et passage « livrée » avec débit de
--    l'ardoise, par des fonctions sécurisées (les tables restent protégées).
--  - Quiz : la bonne réponse n'est plus lisible avant d'avoir répondu, les
--    réponses ne sont plus lisibles sans être connecté ; question du jour,
--    réponse et classement passent par des fonctions.
--  - Stats bar + shop pour les administrateurs et le trésorier.
--  - Stockage : seuls les administrateurs déposent les images du shop
--    (images uniquement, 5 Mo maximum).
--  - Petits durcissements signalés par l'outil de sécurité de Supabase.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 0. Alignement du dépôt sur la base réelle --------------------------------
alter table public.outings
  add column if not exists referent_instructor_id uuid references public.profiles (id);

alter table public.shop_orders
  add column if not exists item_name       text,
  add column if not exists price_cents     int,
  add column if not exists ardoise_charged boolean not null default false;

create table if not exists public.quiz_questions (
  id          serial primary key,
  question    text not null,
  option_a    text not null,
  option_b    text not null,
  option_c    text not null,
  option_d    text not null,
  correct     char(1) not null check (correct in ('a', 'b', 'c', 'd')),
  explanation text,
  category    text,
  active      boolean not null default true
);
create table if not exists public.quiz_answers (
  id          serial primary key,
  user_id     uuid not null references auth.users (id) on delete cascade,
  question_id int  not null references public.quiz_questions (id),
  answered_on date not null,
  is_correct  boolean not null,
  unique (user_id, answered_on)
);
alter table public.quiz_questions enable row level security;
alter table public.quiz_answers  enable row level security;

-- 1. Shop --------------------------------------------------------------------
create or replace function public.cancel_shop_order(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.shop_orders;
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  select * into v_order from public.shop_orders where id = p_id for update;
  if not found then raise exception 'Commande introuvable.'; end if;
  if v_order.user_id <> auth.uid() and public.app_role() <> 'admin' then
    raise exception 'Ce n''est pas votre commande.';
  end if;
  if v_order.status <> 'pending' and public.app_role() <> 'admin' then
    raise exception 'Cette commande est déjà en préparation : contactez le club pour l''annuler.';
  end if;
  if v_order.status in ('delivered', 'cancelled') then raise exception 'Cette commande est déjà clôturée.'; end if;
  update public.shop_orders set status = 'cancelled', updated_at = now() where id = p_id;
end;
$$;

-- Change le statut d'une commande ; « delivered » débite l'ardoise du membre une seule fois.
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
begin
  if public.app_role() is distinct from 'admin' then raise exception 'Réservé aux administrateurs.'; end if;
  if p_status not in ('pending', 'confirmed', 'ready', 'delivered', 'cancelled') then
    raise exception 'Statut inconnu.';
  end if;
  select * into v_order from public.shop_orders where id = p_id for update;
  if not found then raise exception 'Commande introuvable.'; end if;

  if p_status = 'delivered' and not v_order.ardoise_charged and coalesce(v_order.price_cents, 0) > 0 then
    v_variant := concat_ws(' / ', nullif(v_order.size, ''), nullif(v_order.color, ''));
    v_label := 'Shop – ' || coalesce(v_order.item_name, 'Article')
               || case when v_variant <> '' then ' (' || v_variant || ')' else '' end;
    insert into public.bar_consumptions (user_id, product_id, product_name, unit_price_cents, quantity, created_by)
    values (v_order.user_id, null, v_label, v_order.price_cents, v_order.quantity, auth.uid());
    v_charged := true;
  end if;

  update public.shop_orders
     set status = p_status,
         ardoise_charged = ardoise_charged or v_charged,
         updated_at = now()
   where id = p_id;
  return jsonb_build_object('charged', v_charged);
end;
$$;

revoke execute on function public.cancel_shop_order(uuid) from public, anon;
revoke execute on function public.set_shop_order_status(uuid, text) from public, anon;
grant execute on function public.cancel_shop_order(uuid) to authenticated;
grant execute on function public.set_shop_order_status(uuid, text) to authenticated;

-- Fonction de déclencheur : n'a pas à être appelable depuis l'API
do $$ begin
  if exists (select 1 from pg_proc where proname = 'touch_shop_order' and pronamespace = 'public'::regnamespace) then
    execute 'revoke execute on function public.touch_shop_order() from public, anon, authenticated';
  end if;
end $$;

-- 2. Quiz --------------------------------------------------------------------
drop policy if exists quiz_answers_all_read on public.quiz_answers;
drop policy if exists quiz_answers_own_read on public.quiz_answers;
drop policy if exists quiz_answers_own_insert on public.quiz_answers;
drop policy if exists quiz_questions_read on public.quiz_questions;
-- Plus aucun accès direct : tout passe par les fonctions ci-dessous
revoke all on public.quiz_questions, public.quiz_answers from anon, authenticated;

-- Jour du quiz = date à Paris
create or replace function public.quiz_day() returns date
language sql stable set search_path = ''
as $$ select (now() at time zone 'Europe/Paris')::date $$;

-- Question du jour, sans la bonne réponse (et la réponse du membre s'il a déjà joué)
create or replace function public.quiz_today()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_n   int;
  v_q   public.quiz_questions;
  v_ans public.quiz_answers;
begin
  if not public.is_approved() then return null; end if;
  select count(*) into v_n from public.quiz_questions where active;
  if v_n = 0 then return null; end if;
  select * into v_q from public.quiz_questions where active order by id
   offset ((public.quiz_day() - date '2026-01-01') % v_n + v_n) % v_n limit 1;
  select * into v_ans from public.quiz_answers where user_id = auth.uid() and answered_on = public.quiz_day();
  return jsonb_build_object(
    'id', v_q.id, 'question', v_q.question, 'category', v_q.category,
    'option_a', v_q.option_a, 'option_b', v_q.option_b, 'option_c', v_q.option_c, 'option_d', v_q.option_d,
    'already_answered', v_ans.id is not null,
    -- après avoir répondu, on peut revoir la correction
    'correct', case when v_ans.id is not null then v_q.correct end,
    'explanation', case when v_ans.id is not null then v_q.explanation end
  );
end;
$$;

-- Enregistre la réponse du jour (une seule par jour) et renvoie la correction
create or replace function public.quiz_answer(p_question int, p_answer text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today jsonb := public.quiz_today();
  v_q     public.quiz_questions;
  v_ok    boolean;
begin
  if v_today is null then raise exception 'Pas de question aujourd''hui.'; end if;
  if (v_today->>'id')::int <> p_question then raise exception 'Ce n''est plus la question du jour : rechargez la page.'; end if;
  if (v_today->>'already_answered')::boolean then raise exception 'Vous avez déjà répondu aujourd''hui.'; end if;
  select * into v_q from public.quiz_questions where id = p_question;
  v_ok := v_q.correct = lower(btrim(p_answer));
  insert into public.quiz_answers (user_id, question_id, answered_on, is_correct)
  values (auth.uid(), p_question, public.quiz_day(), v_ok)
  on conflict (user_id, answered_on) do nothing;
  return jsonb_build_object('correct', v_ok, 'answer', v_q.correct, 'explanation', v_q.explanation);
end;
$$;

-- Classement : membres validés, non anonymisés
create or replace function public.quiz_leaderboard()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  return coalesce((
    select jsonb_agg(x order by x.correct desc, x.total desc, x.full_name)
    from (
      select p.id as user_id, p.full_name, p.avatar_url,
             count(*)::int as total, count(*) filter (where a.is_correct)::int as correct
      from public.quiz_answers a
      join public.profiles p on p.id = a.user_id
      where p.role <> 'pending' and p.anonymized_at is null
      group by p.id, p.full_name, p.avatar_url
      order by 5 desc, 4 desc
      limit 50
    ) x), '[]'::jsonb);
end;
$$;

-- Mes 30 dernières réponses
create or replace function public.quiz_my_history()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'question_id', a.question_id, 'answered_on', a.answered_on, 'is_correct', a.is_correct,
           'question', q.question, 'category', q.category) order by a.answered_on desc), '[]'::jsonb)
  from (select * from public.quiz_answers where user_id = auth.uid() order by answered_on desc limit 30) a
  join public.quiz_questions q on q.id = a.question_id;
$$;

revoke execute on function public.quiz_today(), public.quiz_answer(int, text), public.quiz_leaderboard(),
  public.quiz_my_history(), public.quiz_day() from public, anon;
grant execute on function public.quiz_today(), public.quiz_answer(int, text), public.quiz_leaderboard(),
  public.quiz_my_history(), public.quiz_day() to authenticated;

-- 3. Stats bar + shop (administrateurs et trésorier) -------------------------
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
                 and date_trunc('month', o.created_at at time zone 'Europe/Paris') = m)::bigint as shop
      from generate_series(v_from, (now() at time zone 'Europe/Paris')::date, interval '1 month') as m
    ) t), '[]'::jsonb);
end;
$$;
revoke execute on function public.revenue_stats(int) from public, anon;
grant execute on function public.revenue_stats(int) to authenticated;

-- 4. Stockage des images du shop ---------------------------------------------
do $$ begin
  if to_regclass('storage.buckets') is not null then
    update storage.buckets
       set file_size_limit = 5242880,
           allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
     where id = 'documents';
  end if;
end $$;
drop policy if exists "Authenticated users can upload shop images" on storage.objects;
drop policy if exists shop_images_insert on storage.objects;
create policy shop_images_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'documents' and name like 'shop/%' and public.app_role() = 'admin');
drop policy if exists shop_images_delete on storage.objects;
create policy shop_images_delete on storage.objects for delete to authenticated
  using (bucket_id = 'documents' and name like 'shop/%' and public.app_role() = 'admin');

-- 5. Durcissements signalés par Supabase ---------------------------------------
do $$ begin
  if exists (select 1 from pg_proc where proname = 'bar_month_of' and pronamespace = 'public'::regnamespace) then
    execute 'alter function public.bar_month_of(timestamptz) set search_path = ''''';
  end if;
  if exists (select 1 from pg_proc where proname = '_audit_immutable' and pronamespace = 'public'::regnamespace) then
    execute 'alter function public._audit_immutable() set search_path = ''''';
  end if;
end $$;

notify pgrst, 'reload schema';

-- Vérification
select
  exists (select 1 from pg_proc where proname = 'set_shop_order_status')
  and exists (select 1 from pg_proc where proname = 'quiz_today')
  and exists (select 1 from pg_proc where proname = 'revenue_stats')
  and not exists (select 1 from pg_policies where tablename = 'quiz_answers' and policyname = 'quiz_answers_all_read')
  as "MISE A JOUR 28 OK";


-- =====================================================================
--  Mise à jour n°29 : Espace pédagogique
-- =====================================================================
-- =====================================================================
--  Mise à jour n°29 : Espace pédagogique
--  - Deux nouvelles fonctions à attribuer dans « Gestion des droits » :
--    chef pilote et responsable conformité. Avec les administrateurs, ce
--    sont eux qui publient dans l'Espace pédagogique.
--  - Documents pédagogiques (stockage privé, réservé aux membres validés).
--  - Annonces pédagogiques.
--  - Retours d'expérience (REX) : tout membre peut en déposer, de façon
--    anonyme s'il le souhaite ; le chef pilote et le responsable conformité
--    les analysent et publient un résumé et les enseignements.
--    Volontairement non journalisés, pour préserver l'anonymat.
--  - Nouveau type d'événement « Formation » (briefings, soirées théoriques).
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Nouvelles fonctions -----------------------------------------------------
alter table public.profiles
  add column if not exists is_chief_pilot boolean not null default false,
  add column if not exists is_compliance  boolean not null default false;

-- Peut publier dans l'Espace pédagogique
create or replace function public.can_teach()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select p.role = 'admin' or (p.role <> 'pending' and (p.is_chief_pilot or p.is_compliance))
    from public.profiles p where p.id = auth.uid()), false);
$$;
revoke execute on function public.can_teach() from public, anon;
grant execute on function public.can_teach() to authenticated;

-- 2. Type d'événement « Formation » -------------------------------------------
alter table public.outings drop constraint if exists outings_kind_check;
alter table public.outings add constraint outings_kind_check
  check (kind in ('vol', 'activite', 'evenement', 'formation'));

-- 3. Documents pédagogiques ----------------------------------------------------
create table if not exists public.pedagogy_documents (
  id          uuid primary key default gen_random_uuid(),
  category    text not null default 'autre'
              check (category in ('cours', 'procedures', 'securite', 'reglementation', 'examens', 'autre')),
  title       text not null check (length(btrim(title)) between 1 and 200),
  description text check (description is null or length(description) <= 1000),
  file_path   text not null unique,
  file_name   text not null,
  mime_type   text,
  size_bytes  bigint,
  created_by  uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at  timestamptz not null default now(),
  archived_at timestamptz
);
alter table public.pedagogy_documents enable row level security;
revoke truncate on public.pedagogy_documents from public, anon, authenticated;
drop policy if exists pedagogy_documents_select on public.pedagogy_documents;
create policy pedagogy_documents_select on public.pedagogy_documents for select to authenticated
  using (public.is_approved() and (archived_at is null or public.can_teach()));
drop policy if exists pedagogy_documents_insert on public.pedagogy_documents;
create policy pedagogy_documents_insert on public.pedagogy_documents for insert to authenticated
  with check (public.can_teach());
drop policy if exists pedagogy_documents_update on public.pedagogy_documents;
create policy pedagogy_documents_update on public.pedagogy_documents for update to authenticated
  using (public.can_teach()) with check (public.can_teach());
drop trigger if exists zz_audit on public.pedagogy_documents;
create trigger zz_audit after insert or update on public.pedagogy_documents
  for each row execute function public._audit();

do $$ begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit)
    values ('pedagogy', 'pedagogy', false, 52428800)
    on conflict (id) do update set public = false, file_size_limit = 52428800;
  end if;
end $$;
drop policy if exists pedagogy_files_select on storage.objects;
create policy pedagogy_files_select on storage.objects for select to authenticated
  using (bucket_id = 'pedagogy' and public.is_approved());
drop policy if exists pedagogy_files_insert on storage.objects;
create policy pedagogy_files_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'pedagogy' and public.can_teach());
drop policy if exists pedagogy_files_delete on storage.objects;
create policy pedagogy_files_delete on storage.objects for delete to authenticated
  using (bucket_id = 'pedagogy' and public.can_teach());

-- 4. Annonces pédagogiques ------------------------------------------------------
create table if not exists public.pedagogy_posts (
  id          uuid primary key default gen_random_uuid(),
  title       text not null check (length(btrim(title)) between 1 and 200),
  body        text not null check (length(btrim(body)) between 1 and 5000),
  important   boolean not null default false,
  created_by  uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  archived_at timestamptz
);
alter table public.pedagogy_posts enable row level security;
revoke truncate on public.pedagogy_posts from public, anon, authenticated;
drop policy if exists pedagogy_posts_select on public.pedagogy_posts;
create policy pedagogy_posts_select on public.pedagogy_posts for select to authenticated
  using (public.is_approved() and (archived_at is null or public.can_teach()));
drop policy if exists pedagogy_posts_insert on public.pedagogy_posts;
create policy pedagogy_posts_insert on public.pedagogy_posts for insert to authenticated
  with check (public.can_teach());
drop policy if exists pedagogy_posts_update on public.pedagogy_posts;
create policy pedagogy_posts_update on public.pedagogy_posts for update to authenticated
  using (public.can_teach()) with check (public.can_teach());
drop trigger if exists zz_audit on public.pedagogy_posts;
create trigger zz_audit after insert or update on public.pedagogy_posts
  for each row execute function public._audit();

-- 5. Retours d'expérience (REX) -------------------------------------------------
create table if not exists public.rex_reports (
  id             uuid primary key default gen_random_uuid(),
  author_id      uuid references public.profiles (id) on delete set null,
  anonymous      boolean not null default false,
  occurred_on    date check (occurred_on is null or occurred_on <= current_date + 1),
  phase          text not null default 'autre'
                 check (phase in ('sol', 'roulage', 'decollage', 'montee', 'croisiere', 'navigation',
                                  'approche', 'atterrissage', 'radio', 'meteo', 'autre')),
  title          text not null check (length(btrim(title)) between 1 and 200),
  description    text not null check (length(btrim(description)) between 1 and 5000),
  status         text not null default 'nouveau' check (status in ('nouveau', 'en_analyse', 'publie', 'clos')),
  public_summary text check (public_summary is null or length(public_summary) <= 5000),
  lessons        text check (lessons is null or length(lessons) <= 5000),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  published_at   timestamptz,
  -- un REX anonyme ne garde aucune trace de son auteur
  check (not anonymous or author_id is null)
);
alter table public.rex_reports enable row level security;
revoke truncate on public.rex_reports from public, anon, authenticated;
drop policy if exists rex_select on public.rex_reports;
create policy rex_select on public.rex_reports for select to authenticated
  using (public.can_teach() or (author_id is not null and author_id = auth.uid()));
drop policy if exists rex_insert on public.rex_reports;
create policy rex_insert on public.rex_reports for insert to authenticated
  with check (
    public.is_approved() and status = 'nouveau' and public_summary is null and lessons is null
    and published_at is null
    and ((anonymous and author_id is null) or (not anonymous and author_id = auth.uid()))
  );
drop policy if exists rex_update on public.rex_reports;
create policy rex_update on public.rex_reports for update to authenticated
  using (public.can_teach()) with check (public.can_teach());

create or replace function public._rex_touch()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  if tg_op = 'UPDATE' then
    -- le texte du déclarant et l'auteur ne se modifient pas
    new.author_id := old.author_id;
    new.anonymous := old.anonymous;
    new.description := old.description;
    new.created_at := old.created_at;
  end if;
  if new.status = 'publie' then
    if coalesce(btrim(new.public_summary), '') = '' then
      raise exception 'Rédigez le résumé public avant de publier ce REX.';
    end if;
    new.published_at := coalesce(new.published_at, now());
  end if;
  return new;
end;
$$;
drop trigger if exists rex_touch on public.rex_reports;
create trigger rex_touch before insert or update on public.rex_reports
  for each row execute function public._rex_touch();

-- REX publiés, visibles par tous les membres : sans auteur ni récit d'origine
create or replace function public.rex_published()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', r.id, 'title', r.title, 'phase', r.phase,
             'month', to_char(coalesce(r.occurred_on, r.created_at::date), 'YYYY-MM'),
             'summary', r.public_summary, 'lessons', r.lessons, 'published_at', r.published_at)
           order by r.published_at desc)
    from public.rex_reports r where r.status = 'publie'), '[]'::jsonb);
end;
$$;

-- Emails des personnes à prévenir quand un REX est déposé
create or replace function public.rex_reviewers()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case when public.is_approved() then coalesce((
    select jsonb_agg(jsonb_build_object('email', p.email, 'full_name', p.full_name))
    from public.profiles p
    where p.role <> 'pending' and p.anonymized_at is null and (p.is_chief_pilot or p.is_compliance)
      and coalesce(p.email, '') <> ''), '[]'::jsonb) else '[]'::jsonb end;
$$;
revoke execute on function public.rex_published(), public.rex_reviewers() from public, anon;
grant execute on function public.rex_published(), public.rex_reviewers() to authenticated;

-- 6. Fonctions existantes mises à jour ------------------------------------------
--    (organiser des événements, gérer les documents des avions, attribuer les
--     nouvelles fonctions, annuaire, type « formation » dans save_outing)
CREATE OR REPLACE FUNCTION public.can_organize()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce((select role in ('instructor', 'admin')
                          or (role <> 'pending' and (is_board or is_treasurer or is_secretary or is_maintenance or is_chief_pilot or is_compliance))
                   from public.profiles where id = auth.uid()), false)
$function$;

CREATE OR REPLACE FUNCTION public.can_manage_docs()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce((
    select p.role <> 'pending'
       and (p.role in ('admin', 'instructor') or p.is_instructor or p.is_board or p.is_maintenance
            or p.is_treasurer or p.is_secretary or p.is_chief_pilot or p.is_compliance)
    from public.profiles p where p.id = auth.uid()), false);
$function$;

CREATE OR REPLACE FUNCTION public.set_function(p_user uuid, p_function text, p_value boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v public.profiles%rowtype;
  v_admin boolean;
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  select * into v from public.profiles where id = p_user for update;
  if not found then raise exception 'Membre introuvable.'; end if;
  if v.role = 'pending' then
    raise exception 'Validez d''abord ce compte avant de lui attribuer une fonction.';
  end if;

  v_admin := v.role = 'admin';
  case p_function
    when 'admin' then
      if not p_value and p_user = auth.uid() then
        raise exception 'Vous ne pouvez pas retirer vos propres droits administrateur.';
      end if;
      v_admin := p_value;
      if not p_value then v.is_secretary := false; end if;
    when 'secretaire' then
      if not p_value and p_user = auth.uid() then
        raise exception 'Demandez à un autre administrateur de vous retirer le titre de secrétaire.';
      end if;
      v.is_secretary := p_value;
      if p_value then v_admin := true; end if;
    when 'instructeur' then v.is_instructor := p_value;
    when 'ca'          then v.is_board := p_value;
    when 'tresorier'   then v.is_treasurer := p_value;
    when 'maintenance' then v.is_maintenance := p_value;
    when 'chef_pilote' then v.is_chief_pilot := p_value;
    when 'conformite'  then v.is_compliance := p_value;
    else raise exception 'Fonction inconnue : %', p_function;
  end case;

  update public.profiles set
    is_instructor  = v.is_instructor,
    is_board       = v.is_board,
    is_treasurer   = v.is_treasurer,
    is_maintenance = v.is_maintenance,
    is_secretary   = v.is_secretary,
    is_chief_pilot = v.is_chief_pilot,
    is_compliance  = v.is_compliance,
    role = case when v_admin then 'admin'::public.user_role
                when v.is_instructor then 'instructor'::public.user_role
                else 'member'::public.user_role end
  where id = p_user;
end;
$function$;

CREATE OR REPLACE FUNCTION public.member_directory()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id, 'full_name', p.full_name,
             'phone', case when p.show_phone or p.id = auth.uid() then p.phone end,
             'avatar_url', p.avatar_url,
             'role', p.role, 'is_instructor', p.is_instructor,
             'is_chief_pilot', p.is_chief_pilot, 'is_compliance', p.is_compliance,
             'types', coalesce((select jsonb_agg(pt.aircraft_type order by pt.aircraft_type)
                                from public.pilot_types pt where pt.user_id = p.id), '[]'::jsonb))
           order by lower(p.full_name))
    from public.profiles p
    where p.role <> 'pending' and p.anonymized_at is null), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION public.save_outing(p_id uuid, p_title text, p_destination text, p_description text, p_meeting_point text, p_departure_at timestamp with time zone, p_return_at timestamp with time zone, p_deadline timestamp with time zone, p_aircraft uuid[], p_instructor_aircraft uuid, p_kind text DEFAULT 'vol'::text, p_max_participants integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid    uuid := auth.uid();
  v_outing public.outings;
  v_i      int;
  v_staff  boolean;
  v_notify jsonb := '[]'::jsonb;
  v_kind   text := coalesce(nullif(p_kind, ''), 'vol');
  v_ac     uuid[] := coalesce(p_aircraft, '{}');
  v_ins_ac uuid := p_instructor_aircraft;
  v_max    int := p_max_participants;
begin
  v_staff := public.can_organize();
  if not public.is_approved() then
    raise exception 'Votre compte n''est pas encore validé.';
  end if;
  if p_title is null or length(btrim(p_title)) = 0 then raise exception 'Le titre est obligatoire.'; end if;
  if p_departure_at is null then raise exception 'La date de départ est obligatoire.'; end if;
  if p_return_at is not null and p_return_at < p_departure_at then
    raise exception 'Le retour doit être après le départ.';
  end if;
  if p_deadline is not null and p_deadline > p_departure_at then
    raise exception 'La date limite d''inscription doit précéder le départ.';
  end if;
  if v_kind not in ('vol', 'activite', 'evenement', 'formation') then raise exception 'Type d''événement inconnu.'; end if;
  if v_kind <> 'vol' then
    v_ac := '{}'; v_ins_ac := null;
    if v_max is not null and v_max < 1 then raise exception 'Le nombre de places doit être d''au moins 1.'; end if;
  else
    v_max := null;
  end if;
  if v_kind = 'vol' and coalesce(array_length(v_ac, 1), 0) = 0 then
    raise exception 'Sélectionnez au moins un avion.';
  end if;
  if (select count(distinct x) from unnest(v_ac) x) <> coalesce(array_length(v_ac, 1), 0) then
    raise exception 'Un avion est sélectionné deux fois.';
  end if;
  if (select count(*) from public.aircraft where id = any (v_ac)) <> coalesce(array_length(v_ac, 1), 0) then
    raise exception 'Avion inconnu.';
  end if;
  if v_ins_ac is not null and not (v_ins_ac = any (v_ac)) then
    raise exception 'L''avion de l''instructeur doit faire partie des avions de la sortie.';
  end if;

  if p_id is null then
    insert into public.outings (title, destination, description, meeting_point, departure_at,
                                return_at, registration_deadline, instructor_id, instructor_aircraft_id,
                                approval, approved_by, approved_at, kind, max_participants)
    values (btrim(p_title), nullif(btrim(p_destination), ''), nullif(btrim(p_description), ''),
            nullif(btrim(p_meeting_point), ''), p_departure_at, p_return_at, p_deadline,
            v_uid, v_ins_ac,
            case when v_staff then 'approved' else 'pending' end,
            case when v_staff then v_uid end, case when v_staff then now() end, v_kind, v_max)
    returning * into v_outing;
    -- Proposition d'un membre : on prévient les instructeurs et administrateurs
    if not v_staff then
      select coalesce(jsonb_agg(jsonb_build_object('email', email, 'full_name', full_name)), '[]'::jsonb)
        into v_notify from public.profiles where role in ('instructor', 'admin');
    end if;
  else
    select * into v_outing from public.outings where id = p_id for update;
    if not found then raise exception 'Sortie introuvable.'; end if;
    if v_outing.status = 'cancelled' then raise exception 'Sortie annulée : modification impossible.'; end if;
    if not v_staff and not (v_outing.instructor_id = v_uid and v_outing.approval <> 'approved') then
      raise exception 'Seul un organisateur (instructeur, administrateur, membre du CA…) peut modifier un événement publié.';
    end if;

    update public.outings set
      title = btrim(p_title),
      destination = nullif(btrim(p_destination), ''),
      description = nullif(btrim(p_description), ''),
      meeting_point = nullif(btrim(p_meeting_point), ''),
      departure_at = p_departure_at,
      return_at = p_return_at,
      registration_deadline = p_deadline,
      instructor_aircraft_id = v_ins_ac,
      kind = v_kind,
      max_participants = v_max,
      -- une proposition refusée puis corrigée repart en validation
      approval = case when approval = 'rejected' then 'pending' else approval end,
      updated_at = now()
    where id = p_id
    returning * into v_outing;

    delete from public.outing_aircraft
     where outing_id = p_id and not (aircraft_id = any (v_ac));
  end if;

  -- L'instructeur qui vole n'est pas aussi un "passager" inscrit
  if v_ins_ac is not null then
    update public.registrations
       set status = 'cancelled', aircraft_id = null, cancelled_at = now()
     where outing_id = v_outing.id and user_id = v_outing.instructor_id and status <> 'cancelled';
  end if;

  for v_i in 1 .. coalesce(array_length(v_ac, 1), 0) loop
    insert into public.outing_aircraft (outing_id, aircraft_id, position)
    values (v_outing.id, v_ac[v_i], v_i)
    on conflict (outing_id, aircraft_id) do update set position = excluded.position;
  end loop;

  return jsonb_build_object('outing_id', v_outing.id,
                            'approval', (select approval from public.outings where id = v_outing.id),
                            'notify_staff', v_notify,
                            'changes', public._rebalance_outing(v_outing.id));
end;
$function$;

notify pgrst, 'reload schema';

select
  exists (select 1 from information_schema.columns where table_name = 'profiles' and column_name = 'is_chief_pilot')
  and to_regclass('public.pedagogy_documents') is not null
  and to_regclass('public.pedagogy_posts') is not null
  and to_regclass('public.rex_reports') is not null
  and exists (select 1 from pg_proc where proname = 'rex_published')
  as "MISE A JOUR 29 OK";


-- =====================================================================
--  Mise à jour n°30 : sorties avion — lâchers et accompagnants
-- =====================================================================
-- =====================================================================
--  Mise à jour n°30 : sorties avion — lâchers et accompagnants (+1)
--  Un membre est placé dans un avion :
--   - s'il est lâché sur le type de cet avion (rubrique « Mon compte »),
--   - ou s'il est instructeur,
--   - ou si un instructeur est à bord de cet avion (organisateur instructeur
--     ou instructeur inscrit placé dans cet avion).
--  Sinon il reste en liste d'attente, même s'il reste des sièges ailleurs.
--  Les places sont toujours attribuées dans l'ordre d'inscription.
--  Le déplacement manuel (move_crew) applique la même règle, y compris
--  quand on déplace l'instructeur hors de son avion.
--  Accompagnants (+1), si l'organisateur les autorise sur l'événement :
--   - sortie avion : 1 accompagnant qui ne pilote pas (nom + poids), placé
--     sur un siège libre de n'importe quel avion ;
--   - activité / événement convivial : jusqu'à 5 accompagnants, pour que
--     l'organisateur connaisse le nombre exact de participants.
--  Un accompagnant n'a une place que si le membre qui l'amène en a une, et
--  il part avec lui s'il se désinscrit. Il compte dans les places.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 0. Accompagnants : colonnes ----------------------------------------------------
alter table public.outings
  add column if not exists guests_allowed boolean not null default false;

alter table public.registrations
  add column if not exists guest_of        uuid references public.registrations (id) on delete cascade,
  add column if not exists guest_name      text,
  add column if not exists guest_weight_kg numeric(5,1);

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'registrations_guest_check') then
    alter table public.registrations add constraint registrations_guest_check check (
      (guest_of is null and guest_name is null and guest_weight_kg is null)
      or (guest_of is not null and length(btrim(guest_name)) between 1 and 120
          and (guest_weight_kg is null or guest_weight_kg between 2 and 250)));
  end if;
end $$;

-- Un membre = une inscription active ; un accompagnant par inscription
drop index if exists public.registrations_one_active_per_user;
create unique index registrations_one_active_per_user on public.registrations (outing_id, user_id)
  where status <> 'cancelled' and guest_of is null;
-- (le nombre d'accompagnants par membre est contrôlé par add_guest / set_guest_count)
drop index if exists public.registrations_one_guest;
create index if not exists registrations_guest_of on public.registrations (guest_of) where guest_of is not null;

create or replace function public._is_instructor(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select p.is_instructor or p.role = 'instructor' from public.profiles p where p.id = p_user), false);
$$;

create or replace function public._is_released(p_user uuid, p_type text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_type is null
      or exists (select 1 from public.pilot_types pt where pt.user_id = p_user and pt.aircraft_type = p_type);
$$;

-- Peut voler dans cet avion pour cette sortie, compte tenu de qui est à bord actuellement
create or replace function public._can_fly_in(p_user uuid, p_aircraft uuid, p_outing uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public._is_instructor(p_user)
      or public._is_released(p_user, (select a.type from public.aircraft a where a.id = p_aircraft))
      or exists (select 1 from public.outings o
                  where o.id = p_outing and o.instructor_aircraft_id = p_aircraft
                    and public._is_instructor(o.instructor_id))
      or exists (select 1 from public.registrations r
                  where r.outing_id = p_outing and r.status = 'confirmed' and r.aircraft_id = p_aircraft
                    and r.guest_of is null and r.user_id <> p_user and public._is_instructor(r.user_id));
$$;

revoke execute on function public._is_instructor(uuid), public._is_released(uuid, text),
  public._can_fly_in(uuid, uuid, uuid) from public, anon, authenticated;

create or replace function public._rebalance_outing(p_outing uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_outing   public.outings;
  v_ac       uuid[]    := '{}';
  v_type     text[]    := '{}';
  v_cap      int[]     := '{}';
  v_used     int[]     := '{}';
  v_instr    boolean[] := '{}';   -- un instructeur est à bord
  v_total    int := 0;
  v_idx      int := 0;
  v_keep     uuid[] := '{}';      -- gardent leur avion
  v_place    uuid[] := '{}';      -- à placer
  v_left     uuid[] := '{}';      -- pas de siège compatible pour l'instant
  v_assign   jsonb := '{}'::jsonb; -- registration_id -> aircraft_id
  v_changes  jsonb := '[]'::jsonb;
  v_i        int;
  v_slot     int;
  v_pass     int;
  v_progress boolean;
  v_is_instr boolean;
  v_ok       boolean;
  r          record;
begin
  select * into v_outing from public.outings where id = p_outing;
  if not found or v_outing.status = 'cancelled' then
    return v_changes;
  end if;

  -- Activité / événement / formation sans avion : les N premiers inscrits sont confirmés
  if coalesce(v_outing.kind, 'vol') <> 'vol' then
    v_total := coalesce(v_outing.max_participants, 1000000);
    for r in
      select reg.id, reg.status, reg.guest_of
      from public.registrations reg
      where reg.outing_id = p_outing and reg.status <> 'cancelled'
      order by reg.created_at, reg.id
    loop
      -- un accompagnant n'a une place que si le membre qui l'amène en a une
      if r.guest_of is not null and not (r.guest_of = any (v_keep)) then
        v_ok := false;
      elsif v_idx < v_total then
        v_idx := v_idx + 1;
        v_ok := true;
        if r.guest_of is null then v_keep := v_keep || r.id; end if;
      else
        v_ok := false;
      end if;
      if v_ok then
        if r.status <> 'confirmed' then
          update public.registrations set status = 'confirmed', aircraft_id = null where id = r.id;
          v_changes := v_changes || jsonb_build_object('registration_id', r.id, 'change', 'promoted');
        end if;
      elsif r.status <> 'waitlist' then
        update public.registrations set status = 'waitlist', aircraft_id = null where id = r.id;
        v_changes := v_changes || jsonb_build_object('registration_id', r.id, 'change', 'demoted');
      end if;
    end loop;
  else
    -- Avions de la sortie
    for r in
      select oa.aircraft_id, a.type,
             greatest(a.seats - case when v_outing.instructor_aircraft_id = oa.aircraft_id then 1 else 0 end, 0) as cap
      from public.outing_aircraft oa
      join public.aircraft a on a.id = oa.aircraft_id
      where oa.outing_id = p_outing
      order by oa.position, a.registration
    loop
      v_ac    := v_ac || r.aircraft_id;
      v_type  := v_type || r.type;
      v_cap   := v_cap || r.cap;
      v_used  := v_used || 0;
      v_instr := v_instr || (v_outing.instructor_aircraft_id = r.aircraft_id
                             and public._is_instructor(v_outing.instructor_id));
      v_total := v_total + r.cap;
    end loop;

    -- 1) Les instructeurs inscrits, puis les autres membres, puis leurs accompagnants
    --    gardent leur avion si c'est encore possible
    for v_pass in 1 .. 3 loop
      for r in
        select reg.id, reg.user_id, reg.status, reg.aircraft_id, reg.guest_of
        from public.registrations reg
        where reg.outing_id = p_outing and reg.status = 'confirmed'
          and case v_pass
                when 1 then reg.guest_of is null and public._is_instructor(reg.user_id)
                when 2 then reg.guest_of is null and not public._is_instructor(reg.user_id)
                else reg.guest_of is not null and reg.guest_of = any (v_keep)
              end
        order by reg.created_at, reg.id
      loop
        v_i := array_position(v_ac, r.aircraft_id);
        if v_i is not null and v_used[v_i] < v_cap[v_i]
           and (v_pass <> 2 or v_instr[v_i] or public._is_released(r.user_id, v_type[v_i])) then
          v_used[v_i] := v_used[v_i] + 1;
          if v_pass = 1 then v_instr[v_i] := true; end if;
          v_keep := v_keep || r.id;
        end if;
      end loop;
    end loop;

    -- 2) Les autres sont placés dans l'ordre d'inscription, dans le premier avion compatible.
    --    Plusieurs tours : un instructeur placé plus tard peut rendre un avion accessible.
    select coalesce(array_agg(reg.id order by reg.created_at, reg.id), '{}') into v_place
    from public.registrations reg
    where reg.outing_id = p_outing and reg.status <> 'cancelled' and not (reg.id = any (v_keep));

    loop
      v_progress := false;
      v_left := '{}';
      for r in
        select reg.id, reg.user_id, reg.guest_of
        from public.registrations reg
        where reg.id = any (v_place)
        order by reg.created_at, reg.id
      loop
        -- un accompagnant ne prend un siège que si le membre qui l'amène en a un
        if r.guest_of is not null and not (r.guest_of = any (v_keep) or v_assign ? r.guest_of::text) then
          v_left := v_left || r.id;
          continue;
        end if;
        v_is_instr := r.guest_of is null and public._is_instructor(r.user_id);
        v_slot := null;
        for v_i in 1 .. coalesce(array_length(v_ac, 1), 0) loop
          if v_used[v_i] < v_cap[v_i]
             and (r.guest_of is not null or v_is_instr or v_instr[v_i] or public._is_released(r.user_id, v_type[v_i])) then
            -- un instructeur va de préférence là où il n'y a pas encore d'instructeur
            if v_is_instr and v_instr[v_i] and v_slot is null then
              v_slot := -v_i;  -- repli possible, on continue de chercher mieux
              continue;
            end if;
            v_slot := v_i;
            exit;
          end if;
        end loop;
        if v_slot is not null and v_slot < 0 then v_slot := -v_slot; end if;

        if v_slot is null then
          v_left := v_left || r.id;
        else
          v_used[v_slot] := v_used[v_slot] + 1;
          if v_is_instr then v_instr[v_slot] := true; end if;
          v_assign := v_assign || jsonb_build_object(r.id::text, v_ac[v_slot]);
          v_progress := true;
        end if;
      end loop;
      v_place := v_left;
      exit when not v_progress or coalesce(array_length(v_place, 1), 0) = 0;
    end loop;

    -- 3) Application et liste des changements
    for r in
      select reg.id, reg.status, reg.aircraft_id
      from public.registrations reg
      where reg.outing_id = p_outing and reg.status <> 'cancelled'
    loop
      if r.id = any (v_keep) then
        continue;
      elsif v_assign ? r.id::text then
        update public.registrations
           set status = 'confirmed', aircraft_id = (v_assign ->> r.id::text)::uuid
         where id = r.id;
        if r.status = 'waitlist' then
          v_changes := v_changes || jsonb_build_object('registration_id', r.id, 'change', 'promoted');
        end if;
      elsif r.status <> 'waitlist' or r.aircraft_id is not null then
        update public.registrations set status = 'waitlist', aircraft_id = null where id = r.id;
        if r.status = 'confirmed' then
          v_changes := v_changes || jsonb_build_object('registration_id', r.id, 'change', 'demoted');
        end if;
      end if;
    end loop;
  end if;

  -- Enrichit avec les coordonnées (pour l'envoi des emails côté serveur)
  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id', p.id, 'email', p.email, 'full_name', p.full_name,
           'change', c ->> 'change')), '[]'::jsonb)
    into v_changes
  from jsonb_array_elements(v_changes) c
  join public.registrations reg on reg.id = (c ->> 'registration_id')::uuid
  join public.profiles p on p.id = reg.user_id
  where reg.guest_of is null;

  return v_changes;
end;
$$;
revoke execute on function public._rebalance_outing(uuid) from public, anon, authenticated;

-- Déplacement manuel : même règle
CREATE OR REPLACE FUNCTION public.move_crew(p_outing uuid, p_who text, p_aircraft uuid, p_with text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid           uuid := auth.uid();
  v_outing        public.outings;
  v_from          uuid;
  v_reg           public.registrations;
  v_other         public.registrations;
  v_cap           int;
  v_used          int;
  v_person_uid    uuid;
  v_ac_type       text;
  v_nom           text;
  v_has_instructor boolean;
  v_is_instructor  boolean;
begin
  if v_uid is null then raise exception 'Vous devez être connecté.'; end if;
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;

  select * into v_outing from public.outings where id = p_outing for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  if not (public.can_organize() or v_outing.instructor_id = v_uid) then
    raise exception 'Seul un organisateur peut répartir les équipages.';
  end if;
  if v_outing.status = 'cancelled' then raise exception 'Cette sortie est annulée.'; end if;
  if coalesce(v_outing.kind, 'vol') <> 'vol' then raise exception 'Cet événement n''a pas d''avions.'; end if;
  if not exists (select 1 from public.outing_aircraft where outing_id = p_outing and aircraft_id = p_aircraft) then
    raise exception 'Cet avion ne fait pas partie de la sortie.';
  end if;

  if p_who = 'organizer' then
    if v_outing.instructor_aircraft_id is null then raise exception 'L''organisateur n''est pas à bord.'; end if;
    v_from := v_outing.instructor_aircraft_id;
  else
    select * into v_reg from public.registrations
     where id = p_who::uuid and outing_id = p_outing and status = 'confirmed' for update;
    if not found then raise exception 'Cette personne n''a pas de place confirmée dans cette sortie.'; end if;
    v_from := v_reg.aircraft_id;
  end if;
  if v_from = p_aircraft then return; end if;

  if p_who <> 'organizer' and v_reg.guest_of is null then
    v_person_uid := v_reg.user_id;
    select a.type into v_ac_type from public.aircraft a where a.id = p_aircraft;
    v_is_instructor := public._is_instructor(v_person_uid);
    if not v_is_instructor then
      v_has_instructor := (v_outing.instructor_aircraft_id = p_aircraft and public._is_instructor(v_outing.instructor_id))
        or exists (
          select 1 from public.registrations r
          where r.outing_id = p_outing
            and r.status = 'confirmed'
            and r.aircraft_id = p_aircraft
            and r.id <> v_reg.id
            and r.guest_of is null
            and public._is_instructor(r.user_id)
        );
      if v_ac_type is not null and not v_has_instructor then
        if not exists (
          select 1 from public.pilot_types pt
          where pt.user_id = v_person_uid and pt.aircraft_type = v_ac_type
        ) then
          select pr.full_name into v_nom from public.profiles pr where pr.id = v_person_uid;
          raise exception '% n''est pas lâché(e) sur % — déplacement refusé.', v_nom, v_ac_type;
        end if;
      end if;
    end if;
  end if;

  if p_with is null then
    select greatest(a.seats - case when v_outing.instructor_aircraft_id = a.id then 1 else 0 end, 0)
      into v_cap from public.aircraft a where a.id = p_aircraft;
    select count(*) into v_used from public.registrations
     where outing_id = p_outing and status = 'confirmed' and aircraft_id = p_aircraft;
    if p_who = 'organizer' then v_cap := v_cap - 1; end if;
    if v_used >= v_cap then
      raise exception 'Cet avion est complet : déposez la personne sur un membre de l''équipage pour échanger leurs places.';
    end if;
    if p_who = 'organizer' then
      update public.outings set instructor_aircraft_id = p_aircraft where id = p_outing;
    else
      update public.registrations set aircraft_id = p_aircraft where id = v_reg.id;
    end if;
  else
    if p_with = p_who then return; end if;
    if p_with = 'organizer' then
      if v_outing.instructor_aircraft_id is distinct from p_aircraft then
        raise exception 'L''organisateur n''est pas dans cet avion.';
      end if;
      update public.outings set instructor_aircraft_id = v_from where id = p_outing;
      update public.registrations set aircraft_id = p_aircraft where id = v_reg.id;
    else
      select * into v_other from public.registrations
       where id = p_with::uuid and outing_id = p_outing and status = 'confirmed' and aircraft_id = p_aircraft for update;
      if not found then raise exception 'Cette personne n''est pas dans cet avion.'; end if;
      update public.registrations set aircraft_id = v_from where id = v_other.id;
      if p_who = 'organizer' then
        update public.outings set instructor_aircraft_id = p_aircraft where id = p_outing;
      else
        update public.registrations set aircraft_id = p_aircraft where id = v_reg.id;
      end if;
    end if;
  end if;

  if exists (
    select 1
    from public.outing_aircraft oa
    join public.aircraft a on a.id = oa.aircraft_id
    join public.outings o on o.id = oa.outing_id
    where oa.outing_id = p_outing
      and (select count(*) from public.registrations r
            where r.outing_id = p_outing and r.status = 'confirmed' and r.aircraft_id = oa.aircraft_id)
          > greatest(a.seats - case when o.instructor_aircraft_id = a.id then 1 else 0 end, 0)
  ) then
    raise exception 'Ce déplacement dépasserait le nombre de places d''un avion.';
  end if;

  -- Contrôle final des lâchers : personne ne doit se retrouver sans instructeur sur un type
  -- où il n'est pas lâché (cas d'un instructeur qu'on déplace hors de son avion, ou d'un échange)
  select pr.full_name, a.type into v_nom, v_ac_type
    from public.registrations r
    join public.aircraft a on a.id = r.aircraft_id
    join public.profiles pr on pr.id = r.user_id
    join public.outings o on o.id = r.outing_id
   where r.outing_id = p_outing and r.status = 'confirmed'
     and r.aircraft_id in (v_from, p_aircraft)
     and r.guest_of is null
     and not public._can_fly_in(r.user_id, a.id, p_outing)
   limit 1;
  if found then
    raise exception '% se retrouverait sans instructeur sur un % où il/elle n''est pas lâché(e) — déplacement refusé.', v_nom, v_ac_type;
  end if;
end;
$function$;

-- Fonctions des sorties adaptées aux accompagnants
CREATE OR REPLACE FUNCTION public.register_for_outing(p_outing uuid, p_user uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid     uuid := auth.uid();
  v_target  uuid;
  v_outing  public.outings;
  v_reg     public.registrations;
  v_changes jsonb;
  v_pos     int;
begin
  if v_uid is null then raise exception 'Vous devez être connecté.'; end if;
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;

  v_target := coalesce(p_user, v_uid);
  if v_target <> v_uid and not public.can_organize() then
    raise exception 'Seul un organisateur peut inscrire un autre membre.';
  end if;

  select * into v_outing from public.outings where id = p_outing for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  if v_outing.status = 'cancelled' then raise exception 'Cette sortie est annulée.'; end if;
  if v_outing.approval <> 'approved' then raise exception 'Cette sortie n''a pas encore été validée par un instructeur.'; end if;
  if v_outing.departure_at <= now() then raise exception 'Cette sortie a déjà eu lieu.'; end if;
  if v_outing.registration_deadline is not null and now() > v_outing.registration_deadline
     and not public.can_organize() then
    raise exception 'Les inscriptions sont closes pour cette sortie.';
  end if;
  if not exists (select 1 from public.profiles where id = v_target and role <> 'pending') then
    raise exception 'Ce membre n''existe pas ou n''est pas encore validé.';
  end if;
  if v_target = v_outing.instructor_id and v_outing.instructor_aircraft_id is not null then
    raise exception 'L''instructeur de la sortie occupe déjà un siège.';
  end if;
  if exists (select 1 from public.registrations
             where outing_id = p_outing and user_id = v_target and status <> 'cancelled' and guest_of is null) then
    raise exception 'Déjà inscrit à cette sortie.';
  end if;

  insert into public.registrations (outing_id, user_id, status, created_by)
  values (p_outing, v_target, 'waitlist', v_uid)
  returning * into v_reg;

  v_changes := public._rebalance_outing(p_outing);

  select * into v_reg from public.registrations where id = v_reg.id;
  if v_reg.status = 'waitlist' then
    select count(*) into v_pos from public.registrations
     where outing_id = p_outing and status = 'waitlist'
       and (created_at, id) <= (v_reg.created_at, v_reg.id);
  end if;

  return jsonb_build_object(
    'registration_id', v_reg.id,
    'status', v_reg.status,
    'waitlist_position', v_pos,
    'changes', coalesce((select jsonb_agg(c) from jsonb_array_elements(v_changes) c
                         where (c ->> 'user_id')::uuid <> v_target), '[]'::jsonb)
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.list_outings(p_past boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;

  return coalesce((
    select jsonb_agg(row_to_json(t) order by
             case when p_past then null else t.departure_at end asc,
             case when p_past then t.departure_at end desc)
    from (
      select o.id, o.title, o.destination, o.departure_at, o.return_at,
             o.registration_deadline, o.status,
             ip.full_name as instructor_name,
             (o.instructor_aircraft_id is not null) as instructor_flies,
             case when coalesce(o.kind, 'vol') = 'vol' then
             (select coalesce(sum(greatest(a.seats - case when a.id = o.instructor_aircraft_id then 1 else 0 end, 0)), 0)
                from public.outing_aircraft oa join public.aircraft a on a.id = oa.aircraft_id
               where oa.outing_id = o.id)
             else o.max_participants end as total_capacity,
             coalesce(o.kind, 'vol') as kind, o.max_participants, o.meeting_point,
             (select count(*) from public.registrations r
               where r.outing_id = o.id and r.status = 'confirmed') as confirmed_count,
             (select count(*) from public.registrations r
               where r.outing_id = o.id and r.status = 'waitlist') as waitlist_count,
             (select string_agg(a.registration || ' (' || a.seats || 'pl.)', ', ' order by oa.position)
                from public.outing_aircraft oa join public.aircraft a on a.id = oa.aircraft_id
               where oa.outing_id = o.id) as aircraft_summary,
             (select r.status from public.registrations r
               where r.outing_id = o.id and r.user_id = v_uid and r.status <> 'cancelled'
                 and r.guest_of is null) as my_status,
             (o.instructor_id = v_uid) as i_am_instructor,
             o.approval, o.rejection_reason
      from public.outings o
      join public.profiles ip on ip.id = o.instructor_id
      where (o.approval = 'approved' or o.instructor_id = v_uid or public.can_organize())
        and case when p_past
                 then coalesce(o.return_at, o.departure_at) < now()
                 else coalesce(o.return_at, o.departure_at) >= now() end
      limit 200
    ) t), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION public.cancel_registration(p_registration uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid    uuid := auth.uid();
  v_reg    public.registrations;
  v_outing public.outings;
begin
  if v_uid is null then raise exception 'Vous devez être connecté.'; end if;

  select * into v_reg from public.registrations where id = p_registration;
  if not found then raise exception 'Inscription introuvable.'; end if;

  -- verrouille la sortie pour sérialiser les modifications
  select * into v_outing from public.outings where id = v_reg.outing_id for update;
  select * into v_reg from public.registrations where id = p_registration;

  if v_reg.user_id <> v_uid and not public.is_staff() then
    raise exception 'Vous ne pouvez pas annuler l''inscription d''un autre membre.';
  end if;
  if v_reg.status = 'cancelled' then raise exception 'Inscription déjà annulée.'; end if;
  if v_outing.departure_at <= now() and not public.is_staff() then
    raise exception 'La sortie a déjà commencé : contactez l''instructeur.';
  end if;

  -- le membre et son accompagnant éventuel
  update public.registrations
     set status = 'cancelled', aircraft_id = null, cancelled_at = now()
   where (id = p_registration or guest_of = p_registration) and status <> 'cancelled';

  if v_outing.departure_at <= now() then
    return jsonb_build_object('changes', '[]'::jsonb);
  end if;
  return jsonb_build_object('changes', public._rebalance_outing(v_outing.id));
end;
$function$;

CREATE OR REPLACE FUNCTION public.cancel_outing(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_outing public.outings;
begin
  select * into v_outing from public.outings where id = p_id for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  -- un membre peut retirer sa propre proposition non publiée
  if not public.can_organize() and not (v_outing.instructor_id = auth.uid() and v_outing.approval <> 'approved') then
    raise exception 'Action réservée aux organisateurs.';
  end if;
  if v_outing.status = 'cancelled' then raise exception 'Sortie déjà annulée.'; end if;

  update public.outings set status = 'cancelled', updated_at = now() where id = p_id;

  return jsonb_build_object('recipients', coalesce((
    select jsonb_agg(jsonb_build_object('user_id', p.id, 'email', p.email, 'full_name', p.full_name))
    from public.registrations r join public.profiles p on p.id = r.user_id
    where r.outing_id = p_id and r.status <> 'cancelled' and r.guest_of is null), '[]'::jsonb));
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_outing(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_staff boolean := public.is_staff();
  v_row   public.outings;
  v_org   public.profiles;
  v_kind  text;
  v_ac    jsonb;
  v_wait  jsonb;
  v_part  jsonb;
  v_mine  jsonb;
  v_org_w numeric;
  v_guest jsonb;
begin
  select * into v_row from public.outings where id = p_id;
  if not found then return null; end if;

  v_kind := coalesce(v_row.kind, 'vol');

  if v_row.approval <> 'approved' and v_row.status <> 'cancelled' then
    if not (v_staff or v_row.instructor_id = v_uid) then return null; end if;
  end if;
  if v_row.status = 'cancelled' then
    if not (v_staff or v_row.instructor_id = v_uid
            or exists (select 1 from public.registrations where outing_id = p_id and user_id = v_uid)) then
      return null;
    end if;
  end if;

  select * into v_org from public.profiles where id = v_row.instructor_id;

  if v_row.instructor_id = v_uid then
    select weight_kg into v_org_w from public.pilot_weights where user_id = v_uid order by updated_at desc limit 1;
  end if;

  if v_kind = 'vol' then
    select coalesce(jsonb_agg(ac_data order by ac_reg), '[]') into v_ac
    from (
      select
        a.registration as ac_reg,
        jsonb_build_object(
          'id', a.id,
          'registration', a.registration,
          'model', a.model,
          'type', a.type,
          'seats', a.seats,
          'instructor_onboard', v_row.instructor_aircraft_id = a.id,
          'capacity', greatest(a.seats - case when v_row.instructor_aircraft_id = a.id then 1 else 0 end, 0),
          'occupants', coalesce((
            select jsonb_agg(jsonb_build_object(
              'registration_id', r.id,
              'user_id', r.user_id,
              'full_name', coalesce(r.guest_name, p.full_name),
              'avatar_url', case when r.guest_of is null then p.avatar_url end,
              'is_guest', r.guest_of is not null,
              'host_name', case when r.guest_of is not null then p.full_name end,
              'released', r.guest_of is not null or public._is_instructor(r.user_id) or exists (
                select 1 from public.pilot_types pt
                 where pt.user_id = r.user_id and pt.aircraft_type = a.type
              ),
              'phone', case when r.guest_of is null and (v_staff or v_row.instructor_id = v_uid) then p.phone end,
              'weight_kg', case when v_row.instructor_id = v_uid or r.user_id = v_uid
                                then case when r.guest_of is null then pw.weight_kg else r.guest_weight_kg end end
            ) order by r.created_at)
            from public.registrations r
            join public.profiles p on p.id = r.user_id
            left join public.pilot_weights pw on pw.user_id = r.user_id
              and pw.updated_at = (select max(updated_at) from public.pilot_weights where user_id = r.user_id)
            where r.outing_id = p_id and r.status = 'confirmed' and r.aircraft_id = a.id
          ), '[]')
        ) as ac_data
      from public.outing_aircraft oa
      join public.aircraft a on a.id = oa.aircraft_id
      where oa.outing_id = p_id
    ) sub;
  else
    v_ac := '[]';
  end if;

  select coalesce(jsonb_agg(w order by w_created), '[]') into v_wait
  from (
    select jsonb_build_object(
      'registration_id', r.id,
      'user_id', r.user_id,
      'full_name', coalesce(r.guest_name, p.full_name),
      'avatar_url', case when r.guest_of is null then p.avatar_url end,
      'is_guest', r.guest_of is not null,
      'host_name', case when r.guest_of is not null then p.full_name end,
      'released', false,
      'phone', case when r.guest_of is null and (v_staff or v_row.instructor_id = v_uid) then p.phone end,
      'weight_kg', case when v_row.instructor_id = v_uid or r.user_id = v_uid
                        then case when r.guest_of is null then pw.weight_kg else r.guest_weight_kg end end,
      'position', row_number() over (order by r.created_at)
    ) as w,
    r.created_at as w_created
    from public.registrations r
    join public.profiles p on p.id = r.user_id
    left join public.pilot_weights pw on pw.user_id = r.user_id
      and pw.updated_at = (select max(updated_at) from public.pilot_weights where user_id = r.user_id)
    where r.outing_id = p_id and r.status = 'waitlist'
  ) sub;

  if v_kind <> 'vol' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'registration_id', r.id,
      'user_id', r.user_id,
      'full_name', coalesce(r.guest_name, p.full_name),
      'avatar_url', case when r.guest_of is null then p.avatar_url end,
      'is_guest', r.guest_of is not null,
      'host_name', case when r.guest_of is not null then p.full_name end,
      'released', false,
      'phone', case when r.guest_of is null and (v_staff or v_row.instructor_id = v_uid) then p.phone end
    ) order by r.created_at), '[]') into v_part
    from public.registrations r
    join public.profiles p on p.id = r.user_id
    where r.outing_id = p_id and r.status = 'confirmed';
  else
    v_part := '[]';
  end if;

  select jsonb_build_object('id', r.id, 'status', r.status, 'aircraft_id', r.aircraft_id) into v_mine
  from public.registrations r
  where r.outing_id = p_id and r.user_id = v_uid and r.guest_of is null and r.status <> 'cancelled'
  limit 1;

  select jsonb_build_object('id', g.id, 'name', g.guest_name, 'weight_kg', g.guest_weight_kg,
                            'status', g.status, 'aircraft_id', g.aircraft_id) into v_guest
  from public.registrations g
  join public.registrations h on h.id = g.guest_of
  where g.outing_id = p_id and h.user_id = v_uid and g.status <> 'cancelled'
  limit 1;

  return jsonb_build_object(
    'id',                    v_row.id,
    'title',                 v_row.title,
    'destination',           v_row.destination,
    'description',           v_row.description,
    'meeting_point',         v_row.meeting_point,
    'departure_at',          v_row.departure_at,
    'return_at',             v_row.return_at,
    'registration_deadline', v_row.registration_deadline,
    'max_participants',      v_row.max_participants,
    'kind',                  v_kind,
    'status',                v_row.status,
    'instructor_aircraft_id',v_row.instructor_aircraft_id,
    'instructor', jsonb_build_object(
      'id',          v_org.id,
      'full_name',   v_org.full_name,
      'phone',       case when v_staff or v_row.instructor_id = v_uid then v_org.phone end,
      'avatar_url',  v_org.avatar_url
    ),
    'can_manage',            v_staff,
    'is_organizer',          v_row.instructor_id = v_uid,
    'organizer_weight_kg',   v_org_w,
    'approval',              v_row.approval,
    'rejection_reason',      v_row.rejection_reason,
    'can_edit',              v_staff or (v_row.instructor_id = v_uid and v_row.approval <> 'approved'),
    'aircraft',              v_ac,
    'waitlist',              v_wait,
    'participants',          v_part,
    'my_registration',       v_mine,
    'my_guest',              v_guest,
    'my_guest_count',        (select count(*) from public.registrations g
                               join public.registrations h on h.id = g.guest_of
                              where g.outing_id = p_id and h.user_id = v_uid and g.status <> 'cancelled'),
    'guests_allowed',        coalesce(v_row.guests_allowed, false)
  );
end;
$function$;

-- Ajouter / retirer son accompagnant
create or replace function public.add_guest(p_outing uuid, p_name text, p_weight numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_outing  public.outings;
  v_host    public.registrations;
  v_guest   public.registrations;
  v_changes jsonb;
begin
  if v_uid is null then raise exception 'Vous devez être connecté.'; end if;
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;
  select * into v_outing from public.outings where id = p_outing for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  if coalesce(v_outing.kind, 'vol') <> 'vol' then raise exception 'Les accompagnants concernent les sorties avion.'; end if;
  if not v_outing.guests_allowed then raise exception 'L''organisateur n''autorise pas d''accompagnant sur cette sortie.'; end if;
  if v_outing.status = 'cancelled' or v_outing.approval <> 'approved' then raise exception 'Cette sortie n''est pas ouverte.'; end if;
  if v_outing.departure_at <= now() then raise exception 'Cette sortie a déjà eu lieu.'; end if;
  if v_outing.registration_deadline is not null and now() > v_outing.registration_deadline then
    raise exception 'Les inscriptions sont closes pour cette sortie.';
  end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'Indiquez le nom de votre accompagnant.'; end if;
  if p_weight is not null and (p_weight < 2 or p_weight > 250) then raise exception 'Poids invalide.'; end if;

  select * into v_host from public.registrations
   where outing_id = p_outing and user_id = v_uid and guest_of is null and status <> 'cancelled';
  if not found then raise exception 'Inscrivez-vous d''abord à la sortie.'; end if;
  if exists (select 1 from public.registrations where guest_of = v_host.id and status <> 'cancelled') then
    raise exception 'Vous avez déjà un accompagnant sur cette sortie.';
  end if;

  insert into public.registrations (outing_id, user_id, status, created_by, guest_of, guest_name, guest_weight_kg)
  values (p_outing, v_uid, 'waitlist', v_uid, v_host.id, left(btrim(p_name), 120), p_weight)
  returning * into v_guest;

  v_changes := public._rebalance_outing(p_outing);
  select * into v_guest from public.registrations where id = v_guest.id;
  return jsonb_build_object('registration_id', v_guest.id, 'status', v_guest.status,
    'changes', coalesce((select jsonb_agg(c) from jsonb_array_elements(v_changes) c
                         where (c ->> 'user_id')::uuid <> v_uid), '[]'::jsonb));
end;
$$;
revoke execute on function public.add_guest(uuid, text, numeric) from public, anon;
grant execute on function public.add_guest(uuid, text, numeric) to authenticated;

-- Événement sans avion : le membre indique combien de personnes il amène (0 à 5)
create or replace function public.set_guest_count(p_outing uuid, p_count int)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_outing  public.outings;
  v_host    public.registrations;
  v_name    text;
  v_current int;
  v_i       int;
  v_changes jsonb;
begin
  if v_uid is null then raise exception 'Vous devez être connecté.'; end if;
  if p_count is null or p_count < 0 or p_count > 5 then raise exception 'Entre 0 et 5 accompagnants.'; end if;
  select * into v_outing from public.outings where id = p_outing for update;
  if not found then raise exception 'Événement introuvable.'; end if;
  if coalesce(v_outing.kind, 'vol') = 'vol' then raise exception 'Pour une sortie avion, ajoutez votre accompagnant avec son nom et son poids.'; end if;
  if p_count > 0 and not v_outing.guests_allowed then raise exception 'L''organisateur n''autorise pas d''accompagnant sur cet événement.'; end if;
  if v_outing.status = 'cancelled' then raise exception 'Cet événement est annulé.'; end if;
  if v_outing.departure_at <= now() then raise exception 'Cet événement a déjà eu lieu.'; end if;

  select * into v_host from public.registrations
   where outing_id = p_outing and user_id = v_uid and guest_of is null and status <> 'cancelled';
  if not found then raise exception 'Inscrivez-vous d''abord à l''événement.'; end if;
  select split_part(btrim(full_name), ' ', 1) into v_name from public.profiles where id = v_uid;

  select count(*) into v_current from public.registrations where guest_of = v_host.id and status <> 'cancelled';
  if p_count > v_current then
    for v_i in v_current + 1 .. p_count loop
      insert into public.registrations (outing_id, user_id, status, created_by, guest_of, guest_name)
      values (p_outing, v_uid, 'waitlist', v_uid, v_host.id, 'Accompagnant ' || v_i || ' de ' || coalesce(v_name, 'membre'));
    end loop;
  elsif p_count < v_current then
    -- on retire d'abord les derniers ajoutés
    update public.registrations set status = 'cancelled', aircraft_id = null, cancelled_at = now()
     where id in (select id from public.registrations
                   where guest_of = v_host.id and status <> 'cancelled'
                   order by created_at desc, id desc limit v_current - p_count);
  end if;

  v_changes := public._rebalance_outing(p_outing);
  return jsonb_build_object(
    'changes', v_changes,
    'confirmed', (select count(*) from public.registrations where guest_of = v_host.id and status = 'confirmed'),
    'waitlist',  (select count(*) from public.registrations where guest_of = v_host.id and status = 'waitlist'));
end;
$$;
revoke execute on function public.set_guest_count(uuid, int) from public, anon;
grant execute on function public.set_guest_count(uuid, int) to authenticated;

-- L'organisateur autorise ou non les accompagnants (s'il les interdit, ceux déjà inscrits sont retirés)
create or replace function public.set_guests_allowed(p_outing uuid, p_allowed boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_outing public.outings;
  v_removed jsonb := '[]'::jsonb;
begin
  select * into v_outing from public.outings where id = p_outing for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  if not (public.can_organize() or v_outing.instructor_id = auth.uid()) then
    raise exception 'Action réservée aux organisateurs.';
  end if;
  if coalesce(v_outing.guests_allowed, false) = coalesce(p_allowed, false) then
    return jsonb_build_object('changes', '[]'::jsonb, 'removed', '[]'::jsonb);
  end if;
  update public.outings set guests_allowed = coalesce(p_allowed, false), updated_at = now() where id = p_outing;
  if not coalesce(p_allowed, false) then
    select coalesce(jsonb_agg(jsonb_build_object('email', p.email, 'full_name', p.full_name, 'guest', g.guest_name)), '[]'::jsonb)
      into v_removed
    from public.registrations g join public.profiles p on p.id = g.user_id
    where g.outing_id = p_outing and g.guest_of is not null and g.status <> 'cancelled';
    update public.registrations set status = 'cancelled', aircraft_id = null, cancelled_at = now()
     where outing_id = p_outing and guest_of is not null and status <> 'cancelled';
  end if;
  return jsonb_build_object('changes', public._rebalance_outing(p_outing), 'removed', v_removed);
end;
$$;
revoke execute on function public.set_guests_allowed(uuid, boolean) from public, anon;
grant execute on function public.set_guests_allowed(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';

select exists (select 1 from pg_proc where proname = '_can_fly_in')
   and exists (select 1 from pg_proc where proname = 'add_guest')
   and exists (select 1 from pg_proc where proname = 'set_guest_count') as "MISE A JOUR 30 OK";


-- =====================================================================
--  Mise à jour n°31 : placement d'office par l'organisateur
-- =====================================================================
-- =====================================================================
--  Mise à jour n°31 : placement d'office par l'organisateur
--  L'organisateur d'une sortie avion (ou un organisateur du club) peut
--  placer dans un avion une personne en liste d'attente, même si elle
--  n'est pas lâchée sur ce type et sans instructeur à bord : c'est sa
--  décision. La personne garde alors sa place lors des recalculs ; le
--  badge « non lâché » reste affiché.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

alter table public.registrations
  add column if not exists forced_seat boolean not null default false;

create or replace function public.place_waitlisted(p_registration uuid, p_aircraft uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_reg    public.registrations;
  v_outing public.outings;
  v_cap    int;
  v_used   int;
begin
  if v_uid is null then raise exception 'Vous devez être connecté.'; end if;
  select * into v_reg from public.registrations where id = p_registration;
  if not found then raise exception 'Inscription introuvable.'; end if;
  select * into v_outing from public.outings where id = v_reg.outing_id for update;
  select * into v_reg from public.registrations where id = p_registration;

  if not (public.can_organize() or v_outing.instructor_id = v_uid) then
    raise exception 'Seul un organisateur peut placer quelqu''un dans un avion.';
  end if;
  if coalesce(v_outing.kind, 'vol') <> 'vol' then raise exception 'Cet événement n''a pas d''avions.'; end if;
  if v_outing.status = 'cancelled' then raise exception 'Cette sortie est annulée.'; end if;
  if v_reg.status <> 'waitlist' then raise exception 'Cette personne n''est pas en liste d''attente.'; end if;
  if not exists (select 1 from public.outing_aircraft where outing_id = v_outing.id and aircraft_id = p_aircraft) then
    raise exception 'Cet avion ne fait pas partie de la sortie.';
  end if;
  if v_reg.guest_of is not null
     and not exists (select 1 from public.registrations where id = v_reg.guest_of and status = 'confirmed') then
    raise exception 'Placez d''abord le membre qui amène cet accompagnant.';
  end if;

  select greatest(a.seats - case when v_outing.instructor_aircraft_id = a.id then 1 else 0 end, 0)
    into v_cap from public.aircraft a where a.id = p_aircraft;
  select count(*) into v_used from public.registrations
   where outing_id = v_outing.id and status = 'confirmed' and aircraft_id = p_aircraft;
  if v_used >= v_cap then raise exception 'Cet avion est complet.'; end if;

  update public.registrations
     set status = 'confirmed', aircraft_id = p_aircraft,
         forced_seat = (v_reg.guest_of is null and not public._can_fly_in(v_reg.user_id, p_aircraft, v_outing.id))
   where id = p_registration;

  return (select jsonb_build_object('user_id', p.id, 'email', p.email, 'full_name', p.full_name, 'change', 'promoted')
            from public.profiles p where p.id = v_reg.user_id and v_reg.guest_of is null);
end;
$$;
revoke execute on function public.place_waitlisted(uuid, uuid) from public, anon;
grant execute on function public.place_waitlisted(uuid, uuid) to authenticated;

-- Recalcul des places : une personne placée d'office garde son siège
create or replace function public._rebalance_outing(p_outing uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_outing   public.outings;
  v_ac       uuid[]    := '{}';
  v_type     text[]    := '{}';
  v_cap      int[]     := '{}';
  v_used     int[]     := '{}';
  v_instr    boolean[] := '{}';   -- un instructeur est à bord
  v_total    int := 0;
  v_idx      int := 0;
  v_keep     uuid[] := '{}';      -- gardent leur avion
  v_place    uuid[] := '{}';      -- à placer
  v_left     uuid[] := '{}';      -- pas de siège compatible pour l'instant
  v_assign   jsonb := '{}'::jsonb; -- registration_id -> aircraft_id
  v_changes  jsonb := '[]'::jsonb;
  v_i        int;
  v_slot     int;
  v_pass     int;
  v_progress boolean;
  v_is_instr boolean;
  v_ok       boolean;
  r          record;
begin
  select * into v_outing from public.outings where id = p_outing;
  if not found or v_outing.status = 'cancelled' then
    return v_changes;
  end if;

  -- Activité / événement / formation sans avion : les N premiers inscrits sont confirmés
  if coalesce(v_outing.kind, 'vol') <> 'vol' then
    v_total := coalesce(v_outing.max_participants, 1000000);
    for r in
      select reg.id, reg.status, reg.guest_of
      from public.registrations reg
      where reg.outing_id = p_outing and reg.status <> 'cancelled'
      order by reg.created_at, reg.id
    loop
      -- un accompagnant n'a une place que si le membre qui l'amène en a une
      if r.guest_of is not null and not (r.guest_of = any (v_keep)) then
        v_ok := false;
      elsif v_idx < v_total then
        v_idx := v_idx + 1;
        v_ok := true;
        if r.guest_of is null then v_keep := v_keep || r.id; end if;
      else
        v_ok := false;
      end if;
      if v_ok then
        if r.status <> 'confirmed' then
          update public.registrations set status = 'confirmed', aircraft_id = null where id = r.id;
          v_changes := v_changes || jsonb_build_object('registration_id', r.id, 'change', 'promoted');
        end if;
      elsif r.status <> 'waitlist' then
        update public.registrations set status = 'waitlist', aircraft_id = null where id = r.id;
        v_changes := v_changes || jsonb_build_object('registration_id', r.id, 'change', 'demoted');
      end if;
    end loop;
  else
    -- Avions de la sortie
    for r in
      select oa.aircraft_id, a.type,
             greatest(a.seats - case when v_outing.instructor_aircraft_id = oa.aircraft_id then 1 else 0 end, 0) as cap
      from public.outing_aircraft oa
      join public.aircraft a on a.id = oa.aircraft_id
      where oa.outing_id = p_outing
      order by oa.position, a.registration
    loop
      v_ac    := v_ac || r.aircraft_id;
      v_type  := v_type || r.type;
      v_cap   := v_cap || r.cap;
      v_used  := v_used || 0;
      v_instr := v_instr || (v_outing.instructor_aircraft_id = r.aircraft_id
                             and public._is_instructor(v_outing.instructor_id));
      v_total := v_total + r.cap;
    end loop;

    -- 1) Les instructeurs inscrits, puis les autres membres, puis leurs accompagnants
    --    gardent leur avion si c'est encore possible
    for v_pass in 1 .. 3 loop
      for r in
        select reg.id, reg.user_id, reg.status, reg.aircraft_id, reg.guest_of, reg.forced_seat
        from public.registrations reg
        where reg.outing_id = p_outing and reg.status = 'confirmed'
          and case v_pass
                when 1 then reg.guest_of is null and public._is_instructor(reg.user_id)
                when 2 then reg.guest_of is null and not public._is_instructor(reg.user_id)
                else reg.guest_of is not null and reg.guest_of = any (v_keep)
              end
        order by reg.created_at, reg.id
      loop
        v_i := array_position(v_ac, r.aircraft_id);
        if v_i is not null and v_used[v_i] < v_cap[v_i]
           and (v_pass <> 2 or r.forced_seat or v_instr[v_i] or public._is_released(r.user_id, v_type[v_i])) then
          v_used[v_i] := v_used[v_i] + 1;
          if v_pass = 1 then v_instr[v_i] := true; end if;
          v_keep := v_keep || r.id;
        end if;
      end loop;
    end loop;

    -- 2) Les autres sont placés dans l'ordre d'inscription, dans le premier avion compatible.
    --    Plusieurs tours : un instructeur placé plus tard peut rendre un avion accessible.
    select coalesce(array_agg(reg.id order by reg.created_at, reg.id), '{}') into v_place
    from public.registrations reg
    where reg.outing_id = p_outing and reg.status <> 'cancelled' and not (reg.id = any (v_keep));

    loop
      v_progress := false;
      v_left := '{}';
      for r in
        select reg.id, reg.user_id, reg.guest_of
        from public.registrations reg
        where reg.id = any (v_place)
        order by reg.created_at, reg.id
      loop
        -- un accompagnant ne prend un siège que si le membre qui l'amène en a un
        if r.guest_of is not null and not (r.guest_of = any (v_keep) or v_assign ? r.guest_of::text) then
          v_left := v_left || r.id;
          continue;
        end if;
        v_is_instr := r.guest_of is null and public._is_instructor(r.user_id);
        v_slot := null;
        for v_i in 1 .. coalesce(array_length(v_ac, 1), 0) loop
          if v_used[v_i] < v_cap[v_i]
             and (r.guest_of is not null or v_is_instr or v_instr[v_i] or public._is_released(r.user_id, v_type[v_i])) then
            -- un instructeur va de préférence là où il n'y a pas encore d'instructeur
            if v_is_instr and v_instr[v_i] and v_slot is null then
              v_slot := -v_i;  -- repli possible, on continue de chercher mieux
              continue;
            end if;
            v_slot := v_i;
            exit;
          end if;
        end loop;
        if v_slot is not null and v_slot < 0 then v_slot := -v_slot; end if;

        if v_slot is null then
          v_left := v_left || r.id;
        else
          v_used[v_slot] := v_used[v_slot] + 1;
          if v_is_instr then v_instr[v_slot] := true; end if;
          v_assign := v_assign || jsonb_build_object(r.id::text, v_ac[v_slot]);
          v_progress := true;
        end if;
      end loop;
      v_place := v_left;
      exit when not v_progress or coalesce(array_length(v_place, 1), 0) = 0;
    end loop;

    -- 3) Application et liste des changements
    for r in
      select reg.id, reg.status, reg.aircraft_id
      from public.registrations reg
      where reg.outing_id = p_outing and reg.status <> 'cancelled'
    loop
      if r.id = any (v_keep) then
        continue;
      elsif v_assign ? r.id::text then
        update public.registrations
           set status = 'confirmed', aircraft_id = (v_assign ->> r.id::text)::uuid
         where id = r.id;
        if r.status = 'waitlist' then
          v_changes := v_changes || jsonb_build_object('registration_id', r.id, 'change', 'promoted');
        end if;
      elsif r.status <> 'waitlist' or r.aircraft_id is not null then
        update public.registrations set status = 'waitlist', aircraft_id = null, forced_seat = false where id = r.id;
        if r.status = 'confirmed' then
          v_changes := v_changes || jsonb_build_object('registration_id', r.id, 'change', 'demoted');
        end if;
      end if;
    end loop;
  end if;

  -- Enrichit avec les coordonnées (pour l'envoi des emails côté serveur)
  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id', p.id, 'email', p.email, 'full_name', p.full_name,
           'change', c ->> 'change')), '[]'::jsonb)
    into v_changes
  from jsonb_array_elements(v_changes) c
  join public.registrations reg on reg.id = (c ->> 'registration_id')::uuid
  join public.profiles p on p.id = reg.user_id
  where reg.guest_of is null;

  return v_changes;
end;
$$;
revoke execute on function public._rebalance_outing(uuid) from public, anon, authenticated;

-- Déplacement manuel : une personne placée d'office se déplace librement
CREATE OR REPLACE FUNCTION public.move_crew(p_outing uuid, p_who text, p_aircraft uuid, p_with text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid           uuid := auth.uid();
  v_outing        public.outings;
  v_from          uuid;
  v_reg           public.registrations;
  v_other         public.registrations;
  v_cap           int;
  v_used          int;
  v_person_uid    uuid;
  v_ac_type       text;
  v_nom           text;
  v_has_instructor boolean;
  v_is_instructor  boolean;
begin
  if v_uid is null then raise exception 'Vous devez être connecté.'; end if;
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;

  select * into v_outing from public.outings where id = p_outing for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  if not (public.can_organize() or v_outing.instructor_id = v_uid) then
    raise exception 'Seul un organisateur peut répartir les équipages.';
  end if;
  if v_outing.status = 'cancelled' then raise exception 'Cette sortie est annulée.'; end if;
  if coalesce(v_outing.kind, 'vol') <> 'vol' then raise exception 'Cet événement n''a pas d''avions.'; end if;
  if not exists (select 1 from public.outing_aircraft where outing_id = p_outing and aircraft_id = p_aircraft) then
    raise exception 'Cet avion ne fait pas partie de la sortie.';
  end if;

  if p_who = 'organizer' then
    if v_outing.instructor_aircraft_id is null then raise exception 'L''organisateur n''est pas à bord.'; end if;
    v_from := v_outing.instructor_aircraft_id;
  else
    select * into v_reg from public.registrations
     where id = p_who::uuid and outing_id = p_outing and status = 'confirmed' for update;
    if not found then raise exception 'Cette personne n''a pas de place confirmée dans cette sortie.'; end if;
    v_from := v_reg.aircraft_id;
  end if;
  if v_from = p_aircraft then return; end if;

  -- (une personne placée d'office par l'organisateur peut être déplacée librement)
  if p_who <> 'organizer' and v_reg.guest_of is null and not v_reg.forced_seat then
    v_person_uid := v_reg.user_id;
    select a.type into v_ac_type from public.aircraft a where a.id = p_aircraft;
    v_is_instructor := public._is_instructor(v_person_uid);
    if not v_is_instructor then
      v_has_instructor := (v_outing.instructor_aircraft_id = p_aircraft and public._is_instructor(v_outing.instructor_id))
        or exists (
          select 1 from public.registrations r
          where r.outing_id = p_outing
            and r.status = 'confirmed'
            and r.aircraft_id = p_aircraft
            and r.id <> v_reg.id
            and r.guest_of is null
            and public._is_instructor(r.user_id)
        );
      if v_ac_type is not null and not v_has_instructor then
        if not exists (
          select 1 from public.pilot_types pt
          where pt.user_id = v_person_uid and pt.aircraft_type = v_ac_type
        ) then
          select pr.full_name into v_nom from public.profiles pr where pr.id = v_person_uid;
          raise exception '% n''est pas lâché(e) sur % — déplacement refusé.', v_nom, v_ac_type;
        end if;
      end if;
    end if;
  end if;

  if p_with is null then
    select greatest(a.seats - case when v_outing.instructor_aircraft_id = a.id then 1 else 0 end, 0)
      into v_cap from public.aircraft a where a.id = p_aircraft;
    select count(*) into v_used from public.registrations
     where outing_id = p_outing and status = 'confirmed' and aircraft_id = p_aircraft;
    if p_who = 'organizer' then v_cap := v_cap - 1; end if;
    if v_used >= v_cap then
      raise exception 'Cet avion est complet : déposez la personne sur un membre de l''équipage pour échanger leurs places.';
    end if;
    if p_who = 'organizer' then
      update public.outings set instructor_aircraft_id = p_aircraft where id = p_outing;
    else
      update public.registrations set aircraft_id = p_aircraft where id = v_reg.id;
    end if;
  else
    if p_with = p_who then return; end if;
    if p_with = 'organizer' then
      if v_outing.instructor_aircraft_id is distinct from p_aircraft then
        raise exception 'L''organisateur n''est pas dans cet avion.';
      end if;
      update public.outings set instructor_aircraft_id = v_from where id = p_outing;
      update public.registrations set aircraft_id = p_aircraft where id = v_reg.id;
    else
      select * into v_other from public.registrations
       where id = p_with::uuid and outing_id = p_outing and status = 'confirmed' and aircraft_id = p_aircraft for update;
      if not found then raise exception 'Cette personne n''est pas dans cet avion.'; end if;
      update public.registrations set aircraft_id = v_from where id = v_other.id;
      if p_who = 'organizer' then
        update public.outings set instructor_aircraft_id = p_aircraft where id = p_outing;
      else
        update public.registrations set aircraft_id = p_aircraft where id = v_reg.id;
      end if;
    end if;
  end if;

  if exists (
    select 1
    from public.outing_aircraft oa
    join public.aircraft a on a.id = oa.aircraft_id
    join public.outings o on o.id = oa.outing_id
    where oa.outing_id = p_outing
      and (select count(*) from public.registrations r
            where r.outing_id = p_outing and r.status = 'confirmed' and r.aircraft_id = oa.aircraft_id)
          > greatest(a.seats - case when o.instructor_aircraft_id = a.id then 1 else 0 end, 0)
  ) then
    raise exception 'Ce déplacement dépasserait le nombre de places d''un avion.';
  end if;

  -- Contrôle final des lâchers : personne ne doit se retrouver sans instructeur sur un type
  -- où il n'est pas lâché (cas d'un instructeur qu'on déplace hors de son avion, ou d'un échange)
  select pr.full_name, a.type into v_nom, v_ac_type
    from public.registrations r
    join public.aircraft a on a.id = r.aircraft_id
    join public.profiles pr on pr.id = r.user_id
    join public.outings o on o.id = r.outing_id
   where r.outing_id = p_outing and r.status = 'confirmed'
     and r.aircraft_id in (v_from, p_aircraft)
     and r.guest_of is null
     and not r.forced_seat
     and not public._can_fly_in(r.user_id, a.id, p_outing)
   limit 1;
  if found then
    raise exception '% se retrouverait sans instructeur sur un % où il/elle n''est pas lâché(e) — déplacement refusé.', v_nom, v_ac_type;
  end if;
end;
$function$;

notify pgrst, 'reload schema';

select exists (select 1 from pg_proc where proname = 'place_waitlisted') as "MISE A JOUR 31 OK";


-- =====================================================================
--  Mise à jour n°32 : sécurisation et sauvegarde
-- =====================================================================
-- =====================================================================
--  Mise à jour n°32 : sécurisation et sauvegarde
--  - Aligne les fichiers du dépôt sur la base en service (catégorie
--    « Taxes » des bons plans, détails des tables du quiz et du shop,
--    version de review_outing) : une nouvelle installation est identique.
--  - Anonymisation RGPD plus complète (accompagnants, REX signés, messages,
--    notes de commande, nouvelles fonctions).
--  - Export complet des données du club pour les administrateurs
--    (page « Sauvegarde »).
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Alignement ---------------------------------------------------------------
alter table public.airfield_tips drop constraint if exists airfield_tips_category_check;
alter table public.airfield_tips add constraint airfield_tips_category_check
  check (category in ('resto', 'avitaillement', 'hebergement', 'visite', 'taxes', 'autre'));

update public.quiz_questions set category = 'general' where category is null;
alter table public.quiz_questions alter column category set default 'general';
alter table public.quiz_questions alter column category set not null;
alter table public.quiz_questions alter column active set default true;
alter table public.quiz_questions alter column active set not null;
alter table public.quiz_answers alter column id type bigint;
alter table public.quiz_answers alter column answered_on set default current_date;
create index if not exists quiz_answers_user_date on public.quiz_answers (user_id, answered_on);
create index if not exists quiz_answers_date on public.quiz_answers (answered_on);

update public.shop_orders o set item_name = coalesce(o.item_name, i.name, 'Article'),
                                price_cents = coalesce(o.price_cents, i.price_cents, 0)
  from public.shop_items i where i.id = o.item_id and (o.item_name is null or o.price_cents is null);
alter table public.shop_orders alter column item_name set not null;
alter table public.shop_orders alter column price_cents set not null;

-- Flotte : de 1 à 9 places (et plus seulement 2 ou 4), pour tout type d'avion
alter table public.aircraft drop constraint if exists aircraft_seats_check;
alter table public.aircraft add constraint aircraft_seats_check check (seats between 1 and 9);

drop function if exists public.review_outing(uuid, boolean, text);
CREATE OR REPLACE FUNCTION public.review_outing(p_id uuid, p_approve boolean, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_outing public.outings;
begin
  if not public.is_staff() then raise exception 'Action réservée aux instructeurs.'; end if;
  select * into v_outing from public.outings where id = p_id for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  if v_outing.approval = 'approved' then raise exception 'Cette sortie est déjà publiée.'; end if;

  update public.outings set
    approval = case when p_approve then 'approved' else 'rejected' end,
    rejection_reason = case when p_approve then null else nullif(btrim(p_reason), '') end,
    approved_by = case when p_approve then auth.uid() end,
    approved_at = case when p_approve then now() end,
    updated_at = now()
  where id = p_id;

  return (select jsonb_build_object(
                   'email', p.email,
                   'full_name', p.full_name,
                   'title', v_outing.title,
                   'departure_at', v_outing.departure_at)
          from public.profiles p where p.id = v_outing.instructor_id);
end;
$function$;

revoke execute on function public.review_outing(uuid, boolean, text) from public, anon;
grant execute on function public.review_outing(uuid, boolean, text) to authenticated;

-- 2. Anonymisation RGPD complète ------------------------------------------------
CREATE OR REPLACE FUNCTION public.anonymize_member(p_user uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r record;
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Action réservée aux administrateurs.';
  end if;
  if p_user = auth.uid() then
    raise exception 'Vous ne pouvez pas anonymiser votre propre compte.';
  end if;
  if not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'Membre introuvable.';
  end if;

  -- Désinscription des événements à venir (les places libérées sont réattribuées)
  for r in
    select distinct g.outing_id from public.registrations g join public.outings o on o.id = g.outing_id
    where g.user_id = p_user and g.status <> 'cancelled' and o.departure_at > now()
  loop
    update public.registrations set status = 'cancelled'
     where outing_id = r.outing_id and user_id = p_user and status <> 'cancelled';
    perform public._rebalance_outing(r.outing_id);
  end loop;

  delete from public.pilot_weights where user_id = p_user;
  -- accompagnants annoncés, REX signés, messages : plus rien ne le relie à une personne
  update public.registrations set guest_name = 'Accompagnant', guest_weight_kg = null
   where user_id = p_user and guest_of is not null;
  update public.rex_reports set author_id = null where author_id = p_user;
  update public.flight_share_seats set message = null where member_id = p_user;
  update public.shop_orders set note = null where user_id = p_user;
  delete from public.pilot_types where user_id = p_user;

  update public.profiles set
    full_name = 'Ancien membre',
    email = 'anonyme-' || left(p_user::text, 8) || '@invalid.local',
    phone = null, address = null, emergency_name = null, emergency_phone = null,
    avatar_url = null,
    role = 'pending',
    is_instructor = false, is_board = false, is_treasurer = false, is_secretary = false, is_maintenance = false,
    is_chief_pilot = false, is_compliance = false,
    notify_events = false, show_phone = false,
    anonymized_at = now()
  where id = p_user;
end;
$function$;

revoke execute on function public.anonymize_member(uuid) from public, anon;
grant execute on function public.anonymize_member(uuid) to authenticated;

-- 3. Export complet (sauvegarde) pour les administrateurs ------------------------
create or replace function public.admin_export()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_out jsonb := '{}'::jsonb;
  v_t   text;
  v_rows jsonb;
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Réservé aux administrateurs.';
  end if;
  for v_t in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' order by c.relname
  loop
    execute format('select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from public.%I t', v_t) into v_rows;
    v_out := v_out || jsonb_build_object(v_t, v_rows);
  end loop;
  return jsonb_build_object(
    'format', 'sauvegarde-aeroclub-v1',
    'exported_at', now(),
    'tables', v_out,
    'files', (select coalesce(jsonb_agg(jsonb_build_object('bucket', o.bucket_id, 'path', o.name) order by o.bucket_id, o.name), '[]'::jsonb)
                from storage.objects o)
  );
end;
$$;
revoke execute on function public.admin_export() from public, anon;
grant execute on function public.admin_export() to authenticated;

notify pgrst, 'reload schema';

select exists (select 1 from pg_proc where proname = 'admin_export') as "MISE A JOUR 32 OK";


-- ===================== Vérification finale =====================
notify pgrst, 'reload schema';
select
  (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'aircraft' and column_name = 'available') = 1
    and exists (select 1 from pg_proc where proname = 'set_aircraft_availability')
    and exists (select 1 from pg_proc where proname = 'set_maintenance')
    and exists (select 1 from pg_proc where proname = 'review_outing')
    and to_regclass('public.announcements') is not null
    and to_regclass('public.bar_products') is not null
    and to_regclass('public.pilot_weights') is not null
    and to_regclass('public.aircraft_documents') is not null
    and exists (select 1 from information_schema.columns where table_name = 'outings' and column_name = 'kind')
    and exists (select 1 from information_schema.columns where table_name = 'bar_products' and column_name = 'category')
    and exists (select 1 from pg_proc where proname = 'set_function')
    and exists (select 1 from pg_proc where proname = 'event_mail_recipients')
    and exists (select 1 from pg_proc where proname = 'can_manage_docs')
    and exists (select 1 from pg_proc where proname = 'anonymize_member')
    and to_regclass('public.audit_log') is not null
    and to_regclass('public.club_links') is not null
    and to_regclass('public.aircraft_mb') is not null
    and exists (select 1 from information_schema.columns where table_name = 'aircraft_mb' and column_name = 'mzfw')
    and to_regclass('public.airfield_tips') is not null
    and exists (select 1 from pg_proc where proname = 'move_crew')
    and exists (select 1 from information_schema.columns where table_name = 'outings' and column_name = 'referent_instructor_id')
    and to_regclass('public.shop_orders') is not null
    and to_regclass('public.flight_shares') is not null
    and exists (select 1 from pg_proc where proname = 'set_shop_order_status')
    and exists (select 1 from pg_proc where proname = 'quiz_today')
    and to_regclass('public.rex_reports') is not null
    and exists (select 1 from pg_proc where proname = '_can_fly_in')
    and exists (select 1 from pg_proc where proname = 'set_guest_count')
    and exists (select 1 from pg_proc where proname = 'place_waitlisted')
    and exists (select 1 from pg_proc where proname = 'admin_export')
  as "TOUT EST A JOUR",
  (select count(*) from public.profiles) as membres,
  (select string_agg(registration, ', ' order by registration) from public.aircraft) as avions,
  (select count(*) from public.aircraft_mb where empty_mass is not null and jsonb_array_length(envelope) >= 3) as "avions M&C prêts";
