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
