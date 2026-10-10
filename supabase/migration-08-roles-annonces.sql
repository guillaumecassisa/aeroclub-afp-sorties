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
